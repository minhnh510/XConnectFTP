//
//  FTPParsing.swift
//  XConnectFTP
//
//  Created by Codex on 21/3/26.
//

import Foundation

struct FTPReply: Sendable {
    let code: Int
    let message: String
    let lines: [String]
}

struct PassiveEndpoint {
    let host: String
    let port: Int

    static func parseEPSV(from message: String, fallbackHost: String) -> PassiveEndpoint? {
        guard let start = message.firstIndex(of: "("),
              let end = message[start...].firstIndex(of: ")") else {
            return nil
        }

        let payload = message[message.index(after: start)..<end]
        let digits = payload.filter(\.isNumber)
        guard let port = Int(digits), !digits.isEmpty else {
            return nil
        }
        return PassiveEndpoint(host: fallbackHost, port: port)
    }

    static func parsePASV(from message: String) -> PassiveEndpoint? {
        guard let start = message.firstIndex(of: "("),
              let end = message[start...].firstIndex(of: ")") else {
            return nil
        }

        let values = message[message.index(after: start)..<end]
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }

        guard values.count == 6 else {
            return nil
        }

        let host = values[0...3].map(String.init).joined(separator: ".")
        let port = values[4] * 256 + values[5]
        return PassiveEndpoint(host: host, port: port)
    }
}

enum FTPHost {
    static func connectionHost(for rawHost: String) -> String {
        let trimmed = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 2,
              trimmed.hasPrefix("["),
              trimmed.hasSuffix("]") else {
            return trimmed
        }

        return String(trimmed.dropFirst().dropLast())
    }

    static func prefersExtendedPassive(for rawHost: String) -> Bool {
        connectionHost(for: rawHost).contains(":")
    }
}

enum FTPError: LocalizedError {
    case notConnected
    case connectionClosed
    case invalidReply(String)
    case unexpectedReply(Int, String)
    case passiveModeUnavailable
    case networkTimeout
    case ftpsDataSessionResumptionRequired
    case localFilesystem(String)
    case trustRejected
    case automaticReconnectFailed(String)
    case operationCancelled

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "No FTP/FTPS connection is currently active.".localized
        case .connectionClosed:
            return "The FTP connection was closed by the server.".localized
        case .invalidReply(let reply):
            return "The server returned an invalid reply: %@".localized(reply)
        case .unexpectedReply(let code, let message):
            return "The server returned code %d: %@".localized(code, message)
        case .passiveModeUnavailable:
            return "The server did not provide a passive mode endpoint.".localized
        case .networkTimeout:
            return "The FTP operation timed out while waiting for the server.".localized
        case .ftpsDataSessionResumptionRequired:
            return "The FTPS server requires TLS session reuse for data connections when using PROT P. The current version of XConnectFTP does not support this FTPS mode. Disable TLS session resumption on the server or use a different protocol or server.".localized
        case .localFilesystem(let message):
            return message
        case .trustRejected:
            return "The FTPS connection was canceled because the certificate was not accepted.".localized
        case .automaticReconnectFailed(let reason):
            return "The FTP connection was interrupted and XConnectFTP could not reconnect automatically: %@".localized(reason)
        case .operationCancelled:
            return "The operation was canceled.".localized
        }
    }
}

enum FTPPath {
    static func normalize(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "/" }
        let isAbsolute = trimmed.hasPrefix("/")
        let parts = trimmed.split(separator: "/").reduce(into: [String]()) { partialResult, component in
            switch component {
            case ".":
                break
            case "..":
                if !partialResult.isEmpty {
                    partialResult.removeLast()
                }
            default:
                partialResult.append(String(component))
            }
        }
        let joined = parts.joined(separator: "/")
        if joined.isEmpty {
            return isAbsolute ? "/" : "."
        }
        return isAbsolute ? "/\(joined)" : joined
    }

    static func join(_ base: String, child: String) -> String {
        let normalizedBase = normalize(base)
        let trimmedChild = child.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedBase == "/" {
            return normalize("/\(trimmedChild)")
        }
        return normalize("\(normalizedBase)/\(trimmedChild)")
    }

    static func resolve(_ path: String, relativeTo base: String) -> String {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            return normalize(base)
        }
        if trimmedPath.hasPrefix("/") {
            return normalize(trimmedPath)
        }
        return join(base, child: trimmedPath)
    }

    static func parent(of path: String) -> String {
        let normalized = normalize(path)
        guard normalized != "/" else { return "/" }
        let parent = (normalized as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : normalize(parent)
    }

    static func name(from path: String) -> String {
        (normalize(path) as NSString).lastPathComponent
    }
}

enum FTPListingFormat {
    case mlsd
    case unixList
}

enum FTPDirectoryParser {
    static func parse(_ rawListing: String, directory: String, format: FTPListingFormat) -> [RemoteItem] {
        switch format {
        case .mlsd:
            return parseMLSD(rawListing, directory: directory)
        case .unixList:
            return parseUnixList(rawListing, directory: directory)
        }
    }

    static func parseMLSD(_ rawListing: String, directory: String) -> [RemoteItem] {
        rawListing
            .split(whereSeparator: \.isNewline)
            .compactMap { parseMLSDLine(String($0), directory: directory) }
    }

    static func parseUnixList(_ rawListing: String, directory: String) -> [RemoteItem] {
        rawListing
            .split(whereSeparator: \.isNewline)
            .compactMap { parseUnixListLine(String($0), directory: directory) }
    }

    static func parseMLSDLine(_ line: String, directory: String) -> RemoteItem? {
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let spaceIndex = trimmedLine.firstIndex(of: " ") else {
            return nil
        }

        let factsSegment = trimmedLine[..<spaceIndex]
        let name = trimmedLine[trimmedLine.index(after: spaceIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != "." else {
            return nil
        }

        var typeValue: String?
        var size: Int64?
        var modifiedAt: Date?
        var factStart = factsSegment.startIndex

        while factStart < factsSegment.endIndex {
            let nextSeparator = factsSegment[factStart...].firstIndex(of: ";") ?? factsSegment.endIndex
            let fact = factsSegment[factStart..<nextSeparator]

            if let equalIndex = fact.firstIndex(of: "=") {
                let key = fact[..<equalIndex]
                let value = fact[fact.index(after: equalIndex)...]
                switch key.lowercased() {
                case "type":
                    typeValue = String(value).lowercased()
                case "size":
                    size = Int64(value)
                case "modify":
                    modifiedAt = parseMLSDDate(String(value))
                default:
                    break
                }
            }

            if nextSeparator == factsSegment.endIndex {
                break
            }
            factStart = factsSegment.index(after: nextSeparator)
        }

        guard let typeValue else {
            return nil
        }

        let kind: RemoteItemKind
        if typeValue.contains("dir") || typeValue.contains("cdir") || typeValue.contains("pdir") {
            kind = .directory
        } else if typeValue.contains("os.unix=slink") || typeValue.contains("slink") {
            kind = .symbolicLink
        } else {
            kind = .file
        }

        let path = FTPPath.join(directory, child: name)
        return RemoteItem(path: path, name: name, kind: kind, size: size, modifiedAt: modifiedAt)
    }

    static func parseUnixListLine(_ line: String, directory: String) -> RemoteItem? {
        let parts = line.split(maxSplits: 8, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
        guard parts.count >= 9 else {
            return nil
        }

        let permissions = parts[0]
        let nameComponent = String(parts[8])
        let name = nameComponent.components(separatedBy: " -> ").first ?? nameComponent
        guard !name.isEmpty, name != "." else {
            return nil
        }

        let kind: RemoteItemKind
        switch permissions.first {
        case "d":
            kind = .directory
        case "l":
            kind = .symbolicLink
        default:
            kind = .file
        }

        let size = Int64(parts[4])
        let month = String(parts[5])
        let day = String(parts[6])
        let yearOrTime = String(parts[7])
        let modifiedAt = parseUnixListDate(month: month, day: day, yearOrTime: yearOrTime)
        let path = FTPPath.join(directory, child: name)

        return RemoteItem(path: path, name: name, kind: kind, size: size, modifiedAt: modifiedAt)
    }

    private static func parseMLSDDate(_ value: String) -> Date? {
        let trimmed = String(value.prefix(14))
        return FTPDateParsers.parseMLSD(trimmed)
    }

    private static func parseUnixListDate(month: String, day: String, yearOrTime: String) -> Date? {
        let currentYear = Calendar.current.component(.year, from: Date())

        if yearOrTime.contains(":") {
            let composed = "\(month) \(day) \(currentYear) \(yearOrTime)"
            let date = FTPDateParsers.parseUnixDateTime(composed)

            if let date, date > Date().addingTimeInterval(86_400) {
                return Calendar.current.date(byAdding: .year, value: -1, to: date)
            }
            return date
        } else {
            return FTPDateParsers.parseUnixDate("\(month) \(day) \(yearOrTime)")
        }
    }
}

private enum FTPDateParsers {
    private static let lock = NSLock()

    private static let mlsdFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter
    }()

    private static let unixDateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d yyyy HH:mm"
        return formatter
    }()

    private static let unixDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d yyyy"
        return formatter
    }()

    static func parseMLSD(_ value: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return mlsdFormatter.date(from: value)
    }

    static func parseUnixDateTime(_ value: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return unixDateTimeFormatter.date(from: value)
    }

    static func parseUnixDate(_ value: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return unixDateFormatter.date(from: value)
    }
}
