//
//  PerformanceServices.swift
//  XConnectFTP
//
//  Created by Codex on 21/3/26.
//

import CryptoKit
import Dispatch
import Foundation
#if canImport(Darwin)
import Darwin
#endif

struct DirectorySnapshot<Item: Sendable>: Sendable {
    let items: [Item]
    let cachedAt: Date

    init(items: [Item], cachedAt: Date = Date()) {
        self.items = items
        self.cachedAt = cachedAt
    }

    func isExpired(maxAge: TimeInterval, now: Date = Date()) -> Bool {
        now.timeIntervalSince(cachedAt) > maxAge
    }
}

enum FTPFeatureSupport: String, Sendable {
    case unknown
    case supported
    case unsupported
}

enum TransferHashAlgorithm: String, CaseIterable, Sendable {
    case sha256 = "SHA-256"
    case sha1 = "SHA-1"
    case md5 = "MD5"
    case crc32 = "CRC32"

    static func from(featureToken token: String) -> TransferHashAlgorithm? {
        switch token
            .uppercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "") {
        case "SHA256", "XSHA256":
            return .sha256
        case "SHA1", "XSHA1":
            return .sha1
        case "MD5", "XMD5":
            return .md5
        case "CRC32", "XCRC", "CRC":
            return .crc32
        default:
            return nil
        }
    }
}

enum RemoteHashStrategy: Sendable, Equatable {
    case hash(TransferHashAlgorithm?)
    case xsha256
    case xsha1
    case md5
    case xmd5
    case xcrc

    var command: String {
        switch self {
        case .hash:
            return "HASH"
        case .xsha256:
            return "XSHA256"
        case .xsha1:
            return "XSHA1"
        case .md5:
            return "MD5"
        case .xmd5:
            return "XMD5"
        case .xcrc:
            return "XCRC"
        }
    }

    var algorithm: TransferHashAlgorithm? {
        switch self {
        case .hash(let algorithm):
            return algorithm
        case .xsha256:
            return .sha256
        case .xsha1:
            return .sha1
        case .md5, .xmd5:
            return .md5
        case .xcrc:
            return .crc32
        }
    }
}

struct FTPServerCapabilities: Sendable, Equatable {
    var mlsdSupport: FTPFeatureSupport = .unknown
    var sizeSupport: FTPFeatureSupport = .unknown
    var hashStrategy: RemoteHashStrategy?
}

actor FTPCapabilityCache {
    private var cachedCapabilities: FTPServerCapabilities?

    func capabilities() -> FTPServerCapabilities? {
        cachedCapabilities
    }

    func update(_ capabilities: FTPServerCapabilities) {
        cachedCapabilities = capabilities
    }

    func mutate(_ transform: (inout FTPServerCapabilities) -> Void) {
        var capabilities = cachedCapabilities ?? FTPServerCapabilities()
        transform(&capabilities)
        cachedCapabilities = capabilities
    }

    func reset() {
        cachedCapabilities = nil
    }
}

struct RemoteTransferChecksum: Sendable, Equatable {
    let algorithm: TransferHashAlgorithm
    let value: String
}

struct RemoteFileVerification: Sendable, Equatable {
    let size: Int64?
    let checksum: RemoteTransferChecksum?
}

enum TransferVerificationError: LocalizedError {
    case sizeMismatch(expected: Int64, actual: Int64)
    case checksumMismatch(algorithm: TransferHashAlgorithm)
    case unreadableLocalFile

    var errorDescription: String? {
        switch self {
        case .sizeMismatch(let expected, let actual):
            return "Transfer verification failed: file size mismatch (%lld != %lld).".localized(actual, expected)
        case .checksumMismatch(let algorithm):
            return "Transfer verification failed: %@ checksum does not match.".localized(algorithm.rawValue)
        case .unreadableLocalFile:
            return "Could not read the local file to verify the transfer.".localized
        }
    }
}

struct TransferVerifier {
    static func verify(localFileAt fileURL: URL, against remote: RemoteFileVerification) throws {
        if let expectedSize = remote.size {
            guard let fileSize = try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber else {
                throw TransferVerificationError.unreadableLocalFile
            }
            let actualSize = fileSize.int64Value
            guard actualSize == expectedSize else {
                throw TransferVerificationError.sizeMismatch(expected: expectedSize, actual: actualSize)
            }
        }

        if let checksum = remote.checksum {
            let localChecksum = try checksumString(for: fileURL, algorithm: checksum.algorithm)
            guard checksum.value.caseInsensitiveCompare(localChecksum) == .orderedSame else {
                throw TransferVerificationError.checksumMismatch(algorithm: checksum.algorithm)
            }
        }
    }

    static func checksumString(for fileURL: URL, algorithm: TransferHashAlgorithm) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        switch algorithm {
        case .sha256:
            var hasher = SHA256()
            while autoreleasepool(invoking: { true }) {
                let chunk = handle.readData(ofLength: 1024 * 1024)
                guard !chunk.isEmpty else { break }
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        case .sha1:
            var hasher = Insecure.SHA1()
            while autoreleasepool(invoking: { true }) {
                let chunk = handle.readData(ofLength: 1024 * 1024)
                guard !chunk.isEmpty else { break }
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        case .md5:
            var hasher = Insecure.MD5()
            while autoreleasepool(invoking: { true }) {
                let chunk = handle.readData(ofLength: 1024 * 1024)
                guard !chunk.isEmpty else { break }
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        case .crc32:
            var crc: UInt32 = 0xFFFF_FFFF
            while autoreleasepool(invoking: { true }) {
                let chunk = handle.readData(ofLength: 1024 * 1024)
                guard !chunk.isEmpty else { break }
                crc = CRC32.update(crc, with: chunk)
            }
            return String(format: "%08x", crc ^ 0xFFFF_FFFF)
        }
    }
}

actor TrustFingerprintStore {
    private var approvedFingerprints = Set<String>()

    func contains(_ fingerprint: String) -> Bool {
        approvedFingerprints.contains(fingerprint)
    }

    func insert(_ fingerprint: String) {
        approvedFingerprints.insert(fingerprint)
    }

    func reset() {
        approvedFingerprints.removeAll()
    }
}

actor TempTransferStore {
    private let fileManager: FileManager
    private let baseDirectoryURL: URL

    init(
        fileManager: FileManager = .default,
        baseDirectoryURL: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("XConnectFTP-Transfers", isDirectory: true)
    ) {
        self.fileManager = fileManager
        self.baseDirectoryURL = baseDirectoryURL
    }

    func prepareOperationDirectory(prefix: String) throws -> URL {
        try ensureBaseDirectory()
        let directoryURL = baseDirectoryURL.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try createSecureDirectory(at: directoryURL)
        return directoryURL
    }

    func cleanupOperationDirectory(_ directoryURL: URL) {
        try? fileManager.removeItem(at: directoryURL)
    }

    func sweepStaleArtifacts(olderThan maxAge: TimeInterval = 60 * 30) {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: baseDirectoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let cutoff = Date().addingTimeInterval(-maxAge)
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
            let referenceDate = values?.contentModificationDate ?? values?.creationDate ?? .distantPast
            if referenceDate < cutoff {
                try? fileManager.removeItem(at: entry)
            }
        }
    }

    private func ensureBaseDirectory() throws {
        if !fileManager.fileExists(atPath: baseDirectoryURL.path) {
            try createSecureDirectory(at: baseDirectoryURL)
        } else {
            try configureDirectory(at: baseDirectoryURL)
        }
    }

    private func createSecureDirectory(at directoryURL: URL) throws {
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try configureDirectory(at: directoryURL)
    }

    private func configureDirectory(at directoryURL: URL) throws {
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = directoryURL
        try mutableURL.setResourceValues(values)
    }
}

private enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 {
            if value & 1 == 1 {
                value = 0xEDB8_8320 ^ (value >> 1)
            } else {
                value >>= 1
            }
        }
        return value
    }

    static func update(_ crc: UInt32, with data: Data) -> UInt32 {
        data.reduce(crc) { partialCRC, byte in
            let index = Int((partialCRC ^ UInt32(byte)) & 0xFF)
            return table[index] ^ (partialCRC >> 8)
        }
    }
}

actor TransferProgressCoalescer {
    private let byteThreshold: Int64
    private let minimumInterval: TimeInterval
    private let nowProvider: @Sendable () -> TimeInterval

    private var lastEmittedBytes: Int64 = 0
    private var lastEmittedAt: TimeInterval?
    private var pendingSnapshot: TransferSnapshot?

    init(
        byteThreshold: Int64 = 256 * 1024,
        minimumInterval: TimeInterval = 0.1,
        nowProvider: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.byteThreshold = byteThreshold
        self.minimumInterval = minimumInterval
        self.nowProvider = nowProvider
    }

    func submit(_ snapshot: TransferSnapshot) -> TransferSnapshot? {
        pendingSnapshot = snapshot
        let now = nowProvider()
        let shouldEmit: Bool

        if let lastEmittedAt {
            shouldEmit = snapshot.transferredBytes - lastEmittedBytes >= byteThreshold
                || now - lastEmittedAt >= minimumInterval
        } else {
            shouldEmit = true
        }

        guard shouldEmit else {
            return nil
        }

        return emit(snapshot, now: now)
    }

    func finish() -> TransferSnapshot? {
        guard let pendingSnapshot else {
            return nil
        }

        return emit(pendingSnapshot, now: nowProvider())
    }

    private func emit(_ snapshot: TransferSnapshot, now: TimeInterval) -> TransferSnapshot {
        lastEmittedBytes = snapshot.transferredBytes
        lastEmittedAt = now
        pendingSnapshot = nil
        return snapshot
    }
}

actor LocalDirectoryService {
    struct LoadResult: Sendable {
        let snapshot: LocalBrowserSnapshot
        let diff: DirectoryDiff<LocalItem.ID>
    }

    private var cache: [String: LocalBrowserSnapshot] = [:]
    private let resourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .fileSizeKey,
        .contentModificationDateKey,
        .isHiddenKey
    ]

    func loadDirectory(at url: URL, forceRefresh: Bool = false) throws -> [LocalItem] {
        try loadSnapshot(at: url, forceRefresh: forceRefresh).snapshot.items
    }

    func loadSnapshot(
        at url: URL,
        forceRefresh: Bool = false,
        previousSnapshot: LocalBrowserSnapshot? = nil
    ) throws -> LoadResult {
        let cacheKey = cacheKey(for: url)
        if !forceRefresh, let snapshot = cache[cacheKey] {
            return LoadResult(snapshot: snapshot, diff: snapshot.diff(from: previousSnapshot))
        }

        let fileManager = FileManager.default
        let urls = try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )

        let items = urls.compactMap { fileURL -> LocalItem? in
            guard let values = try? fileURL.resourceValues(forKeys: resourceKeys) else {
                return nil
            }

            return LocalItem(
                url: fileURL,
                name: fileURL.lastPathComponent,
                isDirectory: values.isDirectory ?? false,
                size: values.fileSize.map(Int64.init),
                modifiedAt: values.contentModificationDate
            )
        }
        .sorted(by: Self.sort)

        let previousVersion = previousSnapshot?.version ?? cache[cacheKey]?.version ?? 0
        let snapshot = LocalBrowserSnapshot(
            items: items,
            displayRows: items.map(LocalBrowserRowModel.init),
            version: previousVersion + 1
        )
        cache[cacheKey] = snapshot
        return LoadResult(snapshot: snapshot, diff: snapshot.diff(from: previousSnapshot))
    }

    func invalidateDirectory(at url: URL) {
        cache.removeValue(forKey: cacheKey(for: url))
    }

    func invalidateAll() {
        cache.removeAll()
    }

    private func cacheKey(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    private static func sort(_ lhs: LocalItem, _ rhs: LocalItem) -> Bool {
        if lhs.isDirectory != rhs.isDirectory {
            return lhs.isDirectory && !rhs.isDirectory
        }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
}

final class LocalDirectoryWatcher {
    private let eventQueue = DispatchQueue(label: "vn.xconnect.ftp.local-directory-watcher", qos: .utility)
    private let callbackQueue = DispatchQueue.main
    private var source: DispatchSourceFileSystemObject?
    private var debounceWorkItem: DispatchWorkItem?
    private var watchedPath: String?

    func startWatching(
        directoryURL: URL,
        debounceInterval: TimeInterval = 0.25,
        onChange: @escaping @Sendable (URL) -> Void
    ) throws {
        let standardizedURL = directoryURL.standardizedFileURL
        guard watchedPath != standardizedURL.path else {
            return
        }

        stopWatching()

        let fileDescriptor = open(standardizedURL.path, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            throw POSIXError(code)
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .delete, .rename, .attrib, .extend, .link, .revoke],
            queue: eventQueue
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.debounceWorkItem?.cancel()

            let workItem = DispatchWorkItem {
                onChange(standardizedURL)
            }
            self.debounceWorkItem = workItem
            self.callbackQueue.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
        }

        source.setCancelHandler {
            close(fileDescriptor)
        }

        watchedPath = standardizedURL.path
        self.source = source
        source.resume()
    }

    func stopWatching() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        source?.cancel()
        source = nil
        watchedPath = nil
    }

    deinit {
        stopWatching()
    }
}

struct StreamingListingAccumulator {
    private let format: FTPListingFormat
    private let directory: String
    private var buffer = Data()
    private(set) var items: [RemoteItem] = []

    init(format: FTPListingFormat, directory: String) {
        self.format = format
        self.directory = directory
    }

    mutating func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        buffer.append(chunk)

        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[..<newlineIndex]
            buffer.removeSubrange(buffer.startIndex...newlineIndex)
            consumeLine(Data(lineData))
        }
    }

    mutating func finish() -> [RemoteItem] {
        if !buffer.isEmpty {
            consumeLine(buffer)
            buffer.removeAll(keepingCapacity: true)
        }

        return items
    }

    private mutating func consumeLine(_ lineData: Data) {
        let line = String(decoding: lineData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }

        let item: RemoteItem?
        switch format {
        case .mlsd:
            item = FTPDirectoryParser.parseMLSDLine(line, directory: directory)
        case .unixList:
            item = FTPDirectoryParser.parseUnixListLine(line, directory: directory)
        }

        if let item {
            items.append(item)
        }
    }
}

final class StreamingFileSink {
    let destinationURL: URL
    private let fileHandle: FileHandle

    init(destinationDirectory: URL, filename: String) throws {
        destinationURL = destinationDirectory.appendingPathComponent(filename)

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        guard FileManager.default.createFile(atPath: destinationURL.path, contents: nil) else {
            throw FTPError.localFilesystem("Could not create the local file at %@.".localized(destinationURL.path))
        }

        fileHandle = try FileHandle(forWritingTo: destinationURL)
    }

    func write(_ chunk: Data) throws {
        try fileHandle.write(contentsOf: chunk)
    }

    func finish() throws {
        try fileHandle.close()
    }

    func discard() {
        try? fileHandle.close()
        try? FileManager.default.removeItem(at: destinationURL)
    }
}

struct DuplicateNameResolver {
    static func uniqueName(
        for originalName: String,
        isDirectory: Bool,
        existingNames: Set<String>,
        reservedNames: inout Set<String>
    ) -> String {
        if isAvailable(originalName, existingNames: existingNames, reservedNames: reservedNames) {
            reserve(originalName, reservedNames: &reservedNames)
            return originalName
        }

        var copyIndex = 1
        while true {
            let candidate = copyName(for: originalName, isDirectory: isDirectory, copyIndex: copyIndex)
            if isAvailable(candidate, existingNames: existingNames, reservedNames: reservedNames) {
                reserve(candidate, reservedNames: &reservedNames)
                return candidate
            }
            copyIndex += 1
        }
    }

    static func copyName(for originalName: String, isDirectory: Bool, copyIndex: Int) -> String {
        let suffix = copyIndex == 1
            ? " copy".localized
            : " copy %d".localized(copyIndex)
        guard !isDirectory else {
            return originalName + suffix
        }

        let nsName = originalName as NSString
        let baseName = nsName.deletingPathExtension
        let pathExtension = nsName.pathExtension
        let hasUsableExtension = !baseName.isEmpty && !pathExtension.isEmpty

        guard hasUsableExtension else {
            return originalName + suffix
        }

        return "\(baseName)\(suffix).\(pathExtension)"
    }

    private static func isAvailable(
        _ candidate: String,
        existingNames: Set<String>,
        reservedNames: Set<String>
    ) -> Bool {
        let normalized = normalize(candidate)
        return !existingNames.contains(normalized) && !reservedNames.contains(normalized)
    }

    private static func reserve(_ name: String, reservedNames: inout Set<String>) {
        reservedNames.insert(normalize(name))
    }

    private static func normalize(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
