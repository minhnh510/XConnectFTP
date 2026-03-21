//
//  FTPStreamClient.swift
//  XConnectFTP
//
//  Created by Codex on 21/3/26.
//

import CryptoKit
import Foundation
import Security

protocol FTPClientProtocol: Sendable {
    func connect(profile: ConnectionProfile, password: String) async throws -> String
    func currentDirectory() async throws -> String
    func list(path: String, forceRefresh: Bool) async throws -> [RemoteItem]
    func changeDirectory(to path: String) async throws -> String
    func createDirectory(named name: String, in directory: String) async throws
    func moveItem(at sourcePath: String, to destinationPath: String) async throws
    func deleteItem(at path: String, isDirectory: Bool) async throws
    func upload(localURL: URL, to remoteDirectory: String, progress: @escaping @Sendable (TransferSnapshot) -> Void) async throws
    func upload(localURL: URL, toRemotePath remotePath: String, progress: @escaping @Sendable (TransferSnapshot) -> Void) async throws
    func download(remotePath: String, to localDirectory: URL, progress: @escaping @Sendable (TransferSnapshot) -> Void) async throws -> URL
    func disconnect() async
    func cancelCurrentTransfer() async
}

extension FTPClientProtocol {
    func list(path: String) async throws -> [RemoteItem] {
        try await list(path: path, forceRefresh: false)
    }

    func upload(localURL: URL, to remoteDirectory: String, progress: @escaping @Sendable (TransferSnapshot) -> Void) async throws {
        let destinationPath = FTPPath.join(remoteDirectory, child: localURL.lastPathComponent)
        try await upload(localURL: localURL, toRemotePath: destinationPath, progress: progress)
    }
}

private final class FTPSessionDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    private let trustStore = TrustFingerprintStore()
    private let prompt: @Sendable (String, String) async -> Bool

    init(prompt: @escaping @Sendable (String, String) async -> Bool) {
        self.prompt = prompt
    }

    func resetTrustDecisions() async {
        await trustStore.reset()
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        handleChallenge(challenge, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        handleChallenge(challenge, completionHandler: completionHandler)
    }

    private func handleChallenge(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        let host = challenge.protectionSpace.host
        guard let fingerprint = leafCertificateFingerprint(for: trust) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        var evaluationError: CFError?
        if SecTrustEvaluateWithError(trust, &evaluationError) {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }

        Task {
            if await trustStore.contains(fingerprint) {
                completionHandler(.useCredential, URLCredential(trust: trust))
                return
            }

            let message = sanitizedTrustMessage((evaluationError as Error?)?.localizedDescription, host: host)
            let reason = "%@\nFingerprint: %@".localized(message, fingerprint)
            let allowed = await prompt(host, reason)
            if allowed {
                await trustStore.insert(fingerprint)
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        }
    }

    private func leafCertificateFingerprint(for trust: SecTrust) -> String? {
        guard let certificate = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leafCertificate = certificate.first else {
            return nil
        }
        let certificateData = SecCertificateCopyData(leafCertificate) as Data
        let digest = SHA256.hash(data: certificateData)
        return digest.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    private func sanitizedTrustMessage(_ message: String?, host: String) -> String {
        let genericMessage = "The certificate returned by %@ is not trusted.".localized(host)
        guard let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return genericMessage
        }

        let sanitizedQuoted = message.replacingOccurrences(
            of: #"[\"“][^\"”]+[\"”] certificate is not trusted"#,
            with: genericMessage,
            options: .regularExpression
        )
        let sanitizedSingleQuoted = sanitizedQuoted.replacingOccurrences(
            of: #"'[^']+' certificate is not trusted"#,
            with: genericMessage,
            options: .regularExpression
        )
        return sanitizedSingleQuoted
    }
}

actor FTPStreamClient: FTPClientProtocol {
    private enum PassiveTransferStrategy: CaseIterable {
        case extendedPassive
        case passiveControlAddress
        case passiveServerAddress
    }

    private enum DataProtectionMode: String {
        case clear = "C"
        case protected = "P"
    }

    private enum TransferType: String {
        case ascii = "A"
        case binary = "I"
    }

    private let defaultUploadChunkSize = 256 * 1024
    private let largeUploadChunkSize = 1024 * 1024
    private let defaultDataReadChunkSize = 256 * 1024
    private let largeDataReadChunkSize = 1024 * 1024
    private let controlReadChunkSize = 4 * 1024
    private let remoteDirectoryCacheTTL: TimeInterval = 45
    private let remoteDirectoryCacheEntryLimit = 48

    private let delegate: FTPSessionDelegate
    private let session: URLSession
    private let capabilityCache = FTPCapabilityCache()
    private var controlTask: URLSessionStreamTask?
    private var controlBuffer = Data()
    private var currentDataTask: URLSessionStreamTask?
    private var profile: ConnectionProfile?
    private var remoteDirectoryCache: [String: DirectorySnapshot<RemoteItem>] = [:]
    private var isTransferring = false
    private var currentDataProtectionMode: DataProtectionMode = .clear
    private var currentTransferType: TransferType?
    private var workingDirectory: String?

    init(trustPrompt: @escaping @Sendable (String, String) async -> Bool = { _, _ in false }) {
        let delegate = FTPSessionDelegate(prompt: trustPrompt)
        self.delegate = delegate
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    func connect(profile: ConnectionProfile, password: String) async throws -> String {
        await disconnect()

        let task = session.streamTask(withHostName: profile.host, port: profile.port)
        task.resume()

        self.profile = profile
        self.controlTask = task
        self.controlBuffer.removeAll(keepingCapacity: true)
        self.remoteDirectoryCache.removeAll(keepingCapacity: true)
        self.currentTransferType = nil
        self.currentDataProtectionMode = .clear
        self.workingDirectory = nil
        await capabilityCache.reset()

        let welcomeReply = try await readReply()
        guard welcomeReply.code == 220 else {
            throw FTPError.unexpectedReply(welcomeReply.code, welcomeReply.message)
        }

        if profile.protocolMode == .ftpsExplicit {
            let authReply = try await sendCommand("AUTH TLS")
            guard authReply.code == 234 || authReply.code == 220 else {
                throw FTPError.unexpectedReply(authReply.code, authReply.message)
            }
            task.startSecureConnection()

            let pbszReply = try await sendCommand("PBSZ 0")
            guard pbszReply.code == 200 else {
                throw FTPError.unexpectedReply(pbszReply.code, pbszReply.message)
            }

            try await setDataProtectionMode(.protected)
        }

        let userReply = try await sendCommand("USER \(sanitizeArgument(profile.username))")
        switch userReply.code {
        case 230:
            break
        case 331, 332:
            let passReply = try await sendCommand("PASS \(sanitizeArgument(password))")
            guard passReply.code == 230 || passReply.code == 202 else {
                throw FTPError.unexpectedReply(passReply.code, passReply.message)
            }
        default:
            throw FTPError.unexpectedReply(userReply.code, userReply.message)
        }

        _ = try? await sendCommand("OPTS UTF8 ON")
        let initialWorkingDirectory = try await readCurrentDirectoryFromServer()
        _ = await loadCapabilitiesIfNeeded()

        let workingDirectory: String
        if let initialPath = profile.initialRemotePath, !initialPath.isEmpty {
            workingDirectory = try await changeDirectory(to: initialPath)
        } else {
            workingDirectory = initialWorkingDirectory
        }

        return workingDirectory
    }

    func currentDirectory() async throws -> String {
        if let workingDirectory {
            return workingDirectory
        }

        return try await readCurrentDirectoryFromServer()
    }

    private func readCurrentDirectoryFromServer() async throws -> String {
        let reply = try await sendCommand("PWD")
        guard reply.code == 257 else {
            throw FTPError.unexpectedReply(reply.code, reply.message)
        }

        let currentPath = parsePWD(reply.message) ?? "/"
        workingDirectory = currentPath
        return currentPath
    }

    func list(path: String, forceRefresh: Bool = false) async throws -> [RemoteItem] {
        let targetPath = path.isEmpty ? "." : FTPPath.normalize(path)
        if !forceRefresh,
           let snapshot = remoteDirectoryCache[targetPath],
           !snapshot.isExpired(maxAge: remoteDirectoryCacheTTL) {
            return snapshot.items
        }

        try await setTransferType(.ascii)
        let capabilities = await loadCapabilitiesIfNeeded()

        if capabilities.mlsdSupport != .unsupported {
            var accumulator = StreamingListingAccumulator(format: .mlsd, directory: targetPath)
            do {
                try await transferData(command: "MLSD \(sanitizeArgument(targetPath))") { chunk in
                    accumulator.append(chunk)
                }
                await capabilityCache.mutate { $0.mlsdSupport = .supported }
                let items = sortRemoteItems(accumulator.finish())
                cacheRemoteItems(items, for: targetPath)
                return items
            } catch let error as FTPError {
                if shouldMarkUnsupportedFeature(after: error) {
                    await capabilityCache.mutate { $0.mlsdSupport = .unsupported }
                }
            }
        }

        var accumulator = StreamingListingAccumulator(format: .unixList, directory: targetPath)
        try await transferData(command: "LIST \(sanitizeArgument(targetPath))") { chunk in
            accumulator.append(chunk)
        }
        let items = sortRemoteItems(accumulator.finish())
        cacheRemoteItems(items, for: targetPath)
        return items
    }

    func changeDirectory(to path: String) async throws -> String {
        let basePath = workingDirectory ?? "/"
        let resolvedPath = FTPPath.resolve(path, relativeTo: basePath)
        let reply = try await sendCommand("CWD \(sanitizeArgument(resolvedPath))")
        guard reply.code == 250 else {
            throw FTPError.unexpectedReply(reply.code, reply.message)
        }
        workingDirectory = resolvedPath
        return resolvedPath
    }

    func createDirectory(named name: String, in directory: String) async throws {
        let fullPath = FTPPath.join(directory, child: sanitizeFilename(name))
        let reply = try await sendCommand("MKD \(sanitizeArgument(fullPath))")
        guard reply.code == 257 else {
            throw FTPError.unexpectedReply(reply.code, reply.message)
        }
        invalidateRemoteCache(for: directory)
    }

    func moveItem(at sourcePath: String, to destinationPath: String) async throws {
        let normalized = FTPPath.normalize(sourcePath)
        let destination = FTPPath.normalize(destinationPath)
        let sourceParent = FTPPath.parent(of: normalized)
        let destinationParent = FTPPath.parent(of: destination)

        let renameFromReply = try await sendCommand("RNFR \(sanitizeArgument(normalized))")
        guard renameFromReply.code == 350 else {
            throw FTPError.unexpectedReply(renameFromReply.code, renameFromReply.message)
        }

        let renameToReply = try await sendCommand("RNTO \(sanitizeArgument(destination))")
        guard renameToReply.code == 250 else {
            throw FTPError.unexpectedReply(renameToReply.code, renameToReply.message)
        }

        invalidateRemoteCache(for: sourceParent)
        invalidateRemoteCache(for: destinationParent)
        invalidateRemoteCache(for: normalized)
        invalidateRemoteCache(for: destination)
    }

    func deleteItem(at path: String, isDirectory: Bool) async throws {
        let normalized = FTPPath.normalize(path)
        let command = isDirectory ? "RMD \(sanitizeArgument(normalized))" : "DELE \(sanitizeArgument(normalized))"
        let reply = try await sendCommand(command)
        guard reply.code == 250 else {
            throw FTPError.unexpectedReply(reply.code, reply.message)
        }
        invalidateRemoteCache(for: FTPPath.parent(of: normalized))
        invalidateRemoteCache(for: normalized)
    }

    func upload(localURL: URL, to remoteDirectory: String, progress: @escaping @Sendable (TransferSnapshot) -> Void) async throws {
        let destinationPath = FTPPath.join(remoteDirectory, child: localURL.lastPathComponent)
        try await upload(localURL: localURL, toRemotePath: destinationPath, progress: progress)
    }

    func upload(localURL: URL, toRemotePath remotePath: String, progress: @escaping @Sendable (TransferSnapshot) -> Void) async throws {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: localURL.path),
              let fileSize = attributes[.size] as? NSNumber else {
            throw FTPError.localFilesystem("Could not read the local file for upload.".localized)
        }

        try await setTransferType(.binary)

        let destinationPath = FTPPath.normalize(remotePath)
        let remoteDirectory = FTPPath.parent(of: destinationPath)
        let strategies = PassiveTransferStrategy.allCases
        var lastPassiveError: FTPError?

        for (index, strategy) in strategies.enumerated() {
            do {
                try await upload(
                    localURL: localURL,
                    destinationPath: destinationPath,
                    expectedSize: fileSize.int64Value,
                    strategy: strategy,
                    progress: progress
                )
                try await verifyTransfer(localFileURL: localURL, remotePath: destinationPath)
                invalidateRemoteCache(for: remoteDirectory)
                return
            } catch let error as FTPError {
                if requiresFTPSDataSessionResumption(after: error) {
                    throw FTPError.ftpsDataSessionResumptionRequired
                }

                if shouldRetryPassiveTransfer(after: error, attemptIndex: index, totalAttempts: strategies.count) {
                    lastPassiveError = error
                    continue
                }
                throw error
            }
        }

        throw lastPassiveError ?? FTPError.passiveModeUnavailable
    }

    func download(remotePath: String, to localDirectory: URL, progress: @escaping @Sendable (TransferSnapshot) -> Void) async throws -> URL {
        try await setTransferType(.binary)

        let normalizedRemotePath = FTPPath.normalize(remotePath)
        let filename = FTPPath.name(from: normalizedRemotePath)
        let expectedSize = try await fileSize(at: normalizedRemotePath)
        let fileSink = try StreamingFileSink(destinationDirectory: localDirectory, filename: filename)

        do {
            try await transferData(
                command: "RETR \(sanitizeArgument(normalizedRemotePath))",
                progressTitle: "Downloading %@".localized(filename),
                totalBytes: expectedSize,
                progress: progress
            ) { chunk in
                try fileSink.write(chunk)
            }
            try fileSink.finish()
            try await verifyTransfer(localFileURL: fileSink.destinationURL, remotePath: normalizedRemotePath, expectedSize: expectedSize)
            return fileSink.destinationURL
        } catch {
            fileSink.discard()
            throw error
        }
    }

    func disconnect() async {
        if let controlTask {
            _ = try? await sendCommand("QUIT")
            close(controlTask)
        }
        if let currentDataTask {
            close(currentDataTask)
        }
        controlTask = nil
        currentDataTask = nil
        profile = nil
        controlBuffer.removeAll(keepingCapacity: true)
        remoteDirectoryCache.removeAll(keepingCapacity: true)
        isTransferring = false
        currentDataProtectionMode = .clear
        workingDirectory = nil
        currentTransferType = nil
        await capabilityCache.reset()
        await delegate.resetTrustDecisions()
    }

    func cancelCurrentTransfer() async {
        currentDataTask?.cancel()
        currentDataTask = nil
        isTransferring = false
    }

    private func transferData(
        command: String,
        progressTitle: String? = nil,
        totalBytes: Int64? = nil,
        progress: (@Sendable (TransferSnapshot) -> Void)? = nil,
        onChunk: (Data) throws -> Void
    ) async throws {
        let strategies = PassiveTransferStrategy.allCases
        var lastPassiveError: FTPError?

        for (index, strategy) in strategies.enumerated() {
            do {
                try await transferDataOnce(
                    command: command,
                    strategy: strategy,
                    progressTitle: progressTitle,
                    totalBytes: totalBytes,
                    progress: progress,
                    onChunk: onChunk
                )
                return
            } catch let error as FTPError {
                if requiresFTPSDataSessionResumption(after: error) {
                    throw FTPError.ftpsDataSessionResumptionRequired
                }

                if shouldRetryPassiveTransfer(after: error, attemptIndex: index, totalAttempts: strategies.count) {
                    lastPassiveError = error
                    continue
                }
                throw error
            }
        }

        throw lastPassiveError ?? FTPError.passiveModeUnavailable
    }

    private func fileSize(at path: String) async throws -> Int64? {
        let capabilities = await loadCapabilitiesIfNeeded()
        guard capabilities.sizeSupport != .unsupported else {
            return nil
        }

        do {
            let reply = try await sendCommand("SIZE \(sanitizeArgument(path))")
            guard reply.code == 213 else {
                return nil
            }

            await capabilityCache.mutate { $0.sizeSupport = .supported }
            let token = reply.message
                .split(whereSeparator: \.isWhitespace)
                .first
                .map(String.init)
            return token.flatMap(Int64.init)
        } catch let error as FTPError {
            if shouldMarkUnsupportedFeature(after: error) {
                await capabilityCache.mutate { $0.sizeSupport = .unsupported }
                return nil
            }
            throw error
        }
    }

    private func upload(
        localURL: URL,
        destinationPath: String,
        expectedSize: Int64,
        strategy: PassiveTransferStrategy,
        progress: @escaping @Sendable (TransferSnapshot) -> Void
    ) async throws {
        let endpoint = try await passiveEndpoint(using: strategy)
        let dataTask = createDataTask(endpoint: endpoint)
        defer {
            close(dataTask)
            currentDataTask = nil
            isTransferring = false
        }

        let preliminaryReply = try await sendCommand("STOR \(sanitizeArgument(destinationPath))")
        guard preliminaryReply.code == 125 || preliminaryReply.code == 150 else {
            throw FTPError.unexpectedReply(preliminaryReply.code, preliminaryReply.message)
        }

        isTransferring = true
        beginProtectedDataTransferIfNeeded(on: dataTask)

        let fileHandle = try FileHandle(forReadingFrom: localURL)
        defer {
            try? fileHandle.close()
        }

        let progressCoalescer = TransferProgressCoalescer()
        let uploadChunkSize = uploadChunkSize(for: expectedSize)
        var transferredBytes: Int64 = 0
        while autoreleasepool(invoking: { true }) {
            let chunk = fileHandle.readData(ofLength: uploadChunkSize)
            guard !chunk.isEmpty else {
                break
            }

            try Task.checkCancellation()
            try await write(chunk, to: dataTask)
            transferredBytes += Int64(chunk.count)
            if let snapshot = await progressCoalescer.submit(TransferSnapshot(
                title: "Uploading %@".localized(localURL.lastPathComponent),
                transferredBytes: transferredBytes,
                totalBytes: expectedSize
            )) {
                progress(snapshot)
            }
        }

        dataTask.closeWrite()
        let completionReply = try await readReply()
        guard completionReply.code == 226 || completionReply.code == 250 else {
            throw FTPError.unexpectedReply(completionReply.code, completionReply.message)
        }

        if let snapshot = await progressCoalescer.finish() {
            progress(snapshot)
        }
    }

    private func transferDataOnce(
        command: String,
        strategy: PassiveTransferStrategy,
        progressTitle: String? = nil,
        totalBytes: Int64? = nil,
        progress: (@Sendable (TransferSnapshot) -> Void)? = nil,
        onChunk: (Data) throws -> Void
    ) async throws {
        let endpoint = try await passiveEndpoint(using: strategy)
        let dataTask = createDataTask(endpoint: endpoint)
        defer {
            close(dataTask)
            currentDataTask = nil
            isTransferring = false
        }

        let preliminaryReply = try await sendCommand(command)
        switch preliminaryReply.code {
        case 125, 150:
            break
        case 226:
            return
        default:
            throw FTPError.unexpectedReply(preliminaryReply.code, preliminaryReply.message)
        }

        isTransferring = true
        beginProtectedDataTransferIfNeeded(on: dataTask)

        let progressCoalescer = progress == nil ? nil : TransferProgressCoalescer()
        let dataReadChunkSize = dataChunkSize(for: totalBytes)
        var transferredBytes: Int64 = 0

        while true {
            try Task.checkCancellation()
            let (chunk, atEOF) = try await readChunk(from: dataTask, maxLength: dataReadChunkSize)
            if !chunk.isEmpty {
                try onChunk(chunk)
                transferredBytes += Int64(chunk.count)
                if let progress,
                   let progressTitle,
                   let progressCoalescer,
                   let snapshot = await progressCoalescer.submit(TransferSnapshot(
                    title: progressTitle,
                    transferredBytes: transferredBytes,
                    totalBytes: totalBytes
                   )) {
                    progress(snapshot)
                }
            }
            if atEOF {
                break
            }
        }

        let completionReply = try await readReply()
        guard completionReply.code == 226 || completionReply.code == 250 else {
            throw FTPError.unexpectedReply(completionReply.code, completionReply.message)
        }
        if let progress,
           let progressCoalescer,
           let snapshot = await progressCoalescer.finish() {
            progress(snapshot)
        }
    }

    private func setTransferType(_ type: TransferType) async throws {
        guard currentTransferType != type else {
            return
        }

        let reply = try await sendCommand("TYPE \(type.rawValue)")
        guard reply.code == 200 else {
            throw FTPError.unexpectedReply(reply.code, reply.message)
        }
        currentTransferType = type
    }

    private func passiveEndpoint(using strategy: PassiveTransferStrategy) async throws -> PassiveEndpoint {
        guard let profile else { throw FTPError.notConnected }

        switch strategy {
        case .extendedPassive:
            let epsvReply = try await sendCommand("EPSV")
            if epsvReply.code == 229,
               let endpoint = PassiveEndpoint.parseEPSV(from: epsvReply.message, fallbackHost: profile.host) {
                return endpoint
            }
            throw FTPError.passiveModeUnavailable
        case .passiveControlAddress, .passiveServerAddress:
            let pasvReply = try await sendCommand("PASV")
            guard pasvReply.code == 227,
                  let endpoint = PassiveEndpoint.parsePASV(from: pasvReply.message) else {
                throw FTPError.passiveModeUnavailable
            }

            switch strategy {
            case .passiveControlAddress:
                return PassiveEndpoint(host: profile.host, port: endpoint.port)
            case .passiveServerAddress:
                return endpoint
            case .extendedPassive:
                return endpoint
            }
        }
    }

    private func createDataTask(endpoint: PassiveEndpoint) -> URLSessionStreamTask {
        let task = session.streamTask(withHostName: endpoint.host, port: endpoint.port)
        task.resume()
        currentDataTask = task
        return task
    }

    private func beginProtectedDataTransferIfNeeded(on task: URLSessionStreamTask) {
        if profile?.protocolMode == .ftpsExplicit, currentDataProtectionMode == .protected {
            task.startSecureConnection()
        }
    }

    private func setDataProtectionMode(_ mode: DataProtectionMode) async throws {
        guard profile?.protocolMode == .ftpsExplicit else {
            currentDataProtectionMode = .clear
            return
        }

        guard currentDataProtectionMode != mode else {
            return
        }

        let reply = try await sendCommand("PROT \(mode.rawValue)")
        guard reply.code == 200 else {
            throw FTPError.unexpectedReply(reply.code, reply.message)
        }
        currentDataProtectionMode = mode
    }

    private func sendCommand(_ command: String) async throws -> FTPReply {
        guard let controlTask else {
            throw FTPError.notConnected
        }

        let payload = Data((command + "\r\n").utf8)
        try await write(payload, to: controlTask)
        return try await readReply()
    }

    private func readReply() async throws -> FTPReply {
        let firstLine = try await readLine()
        guard firstLine.count >= 3,
              let code = Int(firstLine.prefix(3)) else {
            throw FTPError.invalidReply(firstLine)
        }

        var lines = [firstLine]
        let firstSeparator = firstLine.dropFirst(3).first
        if firstSeparator == "-" {
            let terminatorPrefix = "\(code) "
            while true {
                let line = try await readLine()
                lines.append(line)
                if line.hasPrefix(terminatorPrefix) {
                    break
                }
            }
        }

        let message = lines
            .map(stripReplyPrefix)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return FTPReply(code: code, message: message, lines: lines)
    }

    private func readLine() async throws -> String {
        guard let controlTask else {
            throw FTPError.notConnected
        }

        while true {
            if let range = controlBuffer.range(of: Data([0x0A])) {
                let lineData = controlBuffer.subdata(in: controlBuffer.startIndex..<range.upperBound)
                controlBuffer.removeSubrange(controlBuffer.startIndex..<range.upperBound)
                return String(decoding: lineData, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }

            let (chunk, atEOF) = try await readChunk(from: controlTask, maxLength: controlReadChunkSize)
            if !chunk.isEmpty {
                controlBuffer.append(chunk)
            }
            if atEOF {
                if controlBuffer.isEmpty {
                    throw FTPError.invalidReply("The control connection was closed.".localized)
                }
                let line = String(decoding: controlBuffer, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                controlBuffer.removeAll(keepingCapacity: true)
                return line
            }
        }
    }

    private func readChunk(from task: URLSessionStreamTask, maxLength: Int) async throws -> (Data, Bool) {
        try await withCheckedThrowingContinuation { continuation in
            task.readData(ofMinLength: 1, maxLength: maxLength, timeout: 30) { data, atEOF, error in
                if let error {
                    if (error as NSError).code == NSURLErrorCancelled {
                        continuation.resume(throwing: FTPError.operationCancelled)
                    } else {
                        continuation.resume(throwing: error)
                    }
                    return
                }

                continuation.resume(returning: (data ?? Data(), atEOF))
            }
        }
    }

    private func write(_ data: Data, to task: URLSessionStreamTask) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.write(data, timeout: 30) { error in
                if let error {
                    if (error as NSError).code == NSURLErrorCancelled {
                        continuation.resume(throwing: FTPError.operationCancelled)
                    } else {
                        continuation.resume(throwing: error)
                    }
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func close(_ task: URLSessionStreamTask) {
        task.closeRead()
        task.closeWrite()
        task.cancel()
    }

    private func loadCapabilitiesIfNeeded() async -> FTPServerCapabilities {
        if let cachedCapabilities = await capabilityCache.capabilities() {
            return cachedCapabilities
        }

        var capabilities = FTPServerCapabilities()
        if let reply = try? await sendCommand("FEAT"),
           reply.code == 211 {
            for feature in parseFeatureLines(from: reply) {
                let uppercasedFeature = feature.uppercased()
                if uppercasedFeature.hasPrefix("MLSD") || uppercasedFeature.hasPrefix("MLST") {
                    capabilities.mlsdSupport = .supported
                } else if uppercasedFeature.hasPrefix("SIZE") {
                    capabilities.sizeSupport = .supported
                }
            }
            capabilities.hashStrategy = await preferredHashStrategy(from: parseFeatureLines(from: reply))
        }

        await capabilityCache.update(capabilities)
        return capabilities
    }

    private func preferredHashStrategy(from featureLines: [String]) async -> RemoteHashStrategy? {
        let uppercasedFeatures = featureLines.map { $0.uppercased() }
        if let hashLine = uppercasedFeatures.first(where: { $0.hasPrefix("HASH") }) {
            let algorithms = hashLine
                .split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                .dropFirst()
                .flatMap { $0.split(separator: ";") }
                .compactMap { token -> TransferHashAlgorithm? in
                    TransferHashAlgorithm.from(featureToken: String(token).replacingOccurrences(of: "*", with: ""))
                }
            if let selectedAlgorithm = algorithms.first(where: { [.sha256, .sha1, .md5].contains($0) }) {
                if let reply = try? await sendCommand("OPTS HASH \(selectedAlgorithm.rawValue)"),
                   reply.code == 200 {
                    return .hash(selectedAlgorithm)
                }
            }
            return .hash(nil)
        }

        if uppercasedFeatures.contains(where: { $0.hasPrefix("XSHA256") }) {
            return .xsha256
        }
        if uppercasedFeatures.contains(where: { $0.hasPrefix("XSHA1") }) {
            return .xsha1
        }
        if uppercasedFeatures.contains(where: { $0.hasPrefix("XMD5") }) {
            return .xmd5
        }
        if uppercasedFeatures.contains(where: { $0.hasPrefix("MD5") }) {
            return .md5
        }
        if uppercasedFeatures.contains(where: { $0.hasPrefix("XCRC") || $0.hasPrefix("CRC") }) {
            return .xcrc
        }

        return nil
    }

    private func parseFeatureLines(from reply: FTPReply) -> [String] {
        reply.lines
            .map(stripReplyPrefix)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("211") }
    }

    private func parsePWD(_ message: String) -> String? {
        guard let firstQuote = message.firstIndex(of: "\"") else {
            return nil
        }

        let remainder = message[message.index(after: firstQuote)...]
        guard let secondQuote = remainder.firstIndex(of: "\"") else {
            return nil
        }

        return String(remainder[..<secondQuote])
    }

    private func stripReplyPrefix(from line: String) -> String {
        guard line.count > 4, Int(line.prefix(3)) != nil else {
            return line
        }
        return String(line.dropFirst(4))
    }

    private func sanitizeArgument(_ value: String) -> String {
        value.replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
    }

    private func sanitizeFilename(_ value: String) -> String {
        sanitizeArgument(value.trimmingCharacters(in: .whitespacesAndNewlines))
            .replacingOccurrences(of: "/", with: "_")
    }

    private func cacheRemoteItems(_ items: [RemoteItem], for path: String) {
        remoteDirectoryCache[FTPPath.normalize(path)] = DirectorySnapshot(items: items)
        pruneRemoteDirectoryCache()
    }

    private func invalidateRemoteCache(for path: String) {
        let normalizedPath = FTPPath.normalize(path)
        remoteDirectoryCache.keys
            .filter { key in
                key == normalizedPath || key.hasPrefix(normalizedPath == "/" ? "/" : "\(normalizedPath)/")
            }
            .forEach { remoteDirectoryCache.removeValue(forKey: $0) }
    }

    private func pruneRemoteDirectoryCache() {
        let expiredKeys = remoteDirectoryCache.compactMap { key, snapshot in
            snapshot.isExpired(maxAge: remoteDirectoryCacheTTL) ? key : nil
        }
        for key in expiredKeys {
            remoteDirectoryCache.removeValue(forKey: key)
        }

        guard remoteDirectoryCache.count > remoteDirectoryCacheEntryLimit else {
            return
        }

        let sortedKeys = remoteDirectoryCache
            .sorted { lhs, rhs in
                lhs.value.cachedAt < rhs.value.cachedAt
            }
            .map(\.key)
        let keysToEvict = sortedKeys.prefix(remoteDirectoryCache.count - remoteDirectoryCacheEntryLimit)
        for key in keysToEvict {
            remoteDirectoryCache.removeValue(forKey: key)
        }
    }

    private func uploadChunkSize(for expectedSize: Int64) -> Int {
        expectedSize >= 128 * 1024 * 1024 ? largeUploadChunkSize : defaultUploadChunkSize
    }

    private func dataChunkSize(for totalBytes: Int64?) -> Int {
        guard let totalBytes else {
            return defaultDataReadChunkSize
        }
        return totalBytes >= 128 * 1024 * 1024 ? largeDataReadChunkSize : defaultDataReadChunkSize
    }

    private func verifyTransfer(localFileURL: URL, remotePath: String, expectedSize: Int64? = nil) async throws {
        let verification = try await remoteVerification(for: remotePath, expectedSize: expectedSize)
        do {
            try TransferVerifier.verify(localFileAt: localFileURL, against: verification)
        } catch {
            invalidateRemoteCache(for: FTPPath.parent(of: remotePath))
            throw error
        }
    }

    private func remoteVerification(for remotePath: String, expectedSize: Int64?) async throws -> RemoteFileVerification {
        let size: Int64?
        if let expectedSize {
            size = expectedSize
        } else {
            size = try await fileSize(at: remotePath)
        }
        let checksum = try await remoteChecksum(for: remotePath)
        return RemoteFileVerification(size: size, checksum: checksum)
    }

    private func remoteChecksum(for remotePath: String) async throws -> RemoteTransferChecksum? {
        let capabilities = await loadCapabilitiesIfNeeded()
        guard let strategy = capabilities.hashStrategy else {
            return nil
        }

        do {
            let reply = try await sendCommand("\(strategy.command) \(sanitizeArgument(remotePath))")
            switch reply.code {
            case 213, 250, 251:
                return parseRemoteChecksum(from: reply.message, strategy: strategy)
            default:
                return nil
            }
        } catch let error as FTPError {
            if shouldMarkUnsupportedFeature(after: error) {
                await capabilityCache.mutate { $0.hashStrategy = nil }
                return nil
            }
            throw error
        }
    }

    private func parseRemoteChecksum(from message: String, strategy: RemoteHashStrategy) -> RemoteTransferChecksum? {
        let algorithm = strategy.algorithm ?? message
            .split(whereSeparator: \.isWhitespace)
            .compactMap { TransferHashAlgorithm.from(featureToken: String($0)) }
            .first

        guard let algorithm else {
            return nil
        }

        let expectedLength: Int
        switch algorithm {
        case .md5:
            expectedLength = 32
        case .sha1:
            expectedLength = 40
        case .sha256:
            expectedLength = 64
        case .crc32:
            expectedLength = 8
        }

        let checksum = message
            .split(whereSeparator: { $0.isWhitespace || $0 == ":" || $0 == "(" || $0 == ")" || $0 == "=" })
            .map(String.init)
            .first { token in
                token.count == expectedLength && token.allSatisfy(\.isHexDigit)
            }

        guard let checksum else {
            return nil
        }

        return RemoteTransferChecksum(algorithm: algorithm, value: checksum)
    }

    private func shouldMarkUnsupportedFeature(after error: FTPError) -> Bool {
        switch error {
        case .unexpectedReply(let code, _):
            return [500, 501, 502, 504].contains(code)
        case .passiveModeUnavailable:
            return true
        default:
            return false
        }
    }

    private func shouldRetryPassiveTransfer(
        after error: FTPError,
        attemptIndex: Int,
        totalAttempts: Int
    ) -> Bool {
        guard attemptIndex < totalAttempts - 1 else {
            return false
        }

        switch error {
        case .passiveModeUnavailable:
            return true
        case .unexpectedReply(let code, _):
            return code == 425
        default:
            return false
        }
    }

    private func requiresFTPSDataSessionResumption(after error: FTPError) -> Bool {
        guard profile?.protocolMode == .ftpsExplicit, currentDataProtectionMode == .protected else {
            return false
        }

        guard case .unexpectedReply(let code, let message) = error else {
            return false
        }

        let normalizedMessage = message.lowercased()
        if code == 425 {
            return normalizedMessage.contains("tls session of data connection not resumed")
                || normalizedMessage.contains("tls session not resumed")
                || normalizedMessage.contains("data connection not resumed")
        }

        if code == 534 {
            return normalizedMessage.contains("protection level c not allowed")
                || normalizedMessage.contains("tls session of data connection not resumed")
        }

        return false
    }

    private func sortRemoteItems(_ items: [RemoteItem]) -> [RemoteItem] {
        items.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }
}
