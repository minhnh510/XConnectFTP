import Foundation
import XCTest
@testable import XConnectFTPCore

final class PerformanceServicesTests: XCTestCase {
    func testBrowserDirectorySnapshotDiffTracksInsertedUpdatedRemovedItems() {
        let firstItems = [
            LocalItem(url: URL(fileURLWithPath: "/tmp/a.txt"), name: "a.txt", isDirectory: false, size: 10, modifiedAt: nil),
            LocalItem(url: URL(fileURLWithPath: "/tmp/b.txt"), name: "b.txt", isDirectory: false, size: 20, modifiedAt: nil)
        ]
        let secondItems = [
            LocalItem(url: URL(fileURLWithPath: "/tmp/b.txt"), name: "b.txt", isDirectory: false, size: 21, modifiedAt: nil),
            LocalItem(url: URL(fileURLWithPath: "/tmp/c.txt"), name: "c.txt", isDirectory: false, size: 30, modifiedAt: nil)
        ]

        let firstSnapshot = LocalBrowserSnapshot(
            items: firstItems,
            displayRows: firstItems.map(LocalBrowserRowModel.init),
            version: 1
        )
        let secondSnapshot = LocalBrowserSnapshot(
            items: secondItems,
            displayRows: secondItems.map(LocalBrowserRowModel.init),
            version: 2
        )

        let diff = secondSnapshot.diff(from: firstSnapshot)
        XCTAssertEqual(diff.insertedIDs, ["/tmp/c.txt"])
        XCTAssertEqual(diff.removedIDs, ["/tmp/a.txt"])
        XCTAssertEqual(diff.updatedIDs, ["/tmp/b.txt"])
        XCTAssertTrue(diff.unchangedIDs.isEmpty)
    }

    func testFTPCapabilityCacheUpdatesMutatesAndResets() async {
        let cache = FTPCapabilityCache()
        let initialCapabilities = await cache.capabilities()
        XCTAssertNil(initialCapabilities)

        let capabilities = FTPServerCapabilities(
            mlsdSupport: .supported,
            sizeSupport: .unknown,
            hashStrategy: .xsha256
        )
        await cache.update(capabilities)
        let updatedCapabilities = await cache.capabilities()
        XCTAssertEqual(updatedCapabilities, capabilities)

        await cache.mutate {
            $0.sizeSupport = .supported
        }

        let mutatedCapabilities = await cache.capabilities()
        XCTAssertEqual(
            mutatedCapabilities,
            FTPServerCapabilities(
                mlsdSupport: .supported,
                sizeSupport: .supported,
                hashStrategy: .xsha256
            )
        )

        await cache.reset()
        let resetCapabilities = await cache.capabilities()
        XCTAssertNil(resetCapabilities)
    }

    func testTrustFingerprintStoreOnlyKeepsApprovedFingerprintsInSession() async {
        let trustStore = TrustFingerprintStore()

        let containsBeforeInsert = await trustStore.contains("AA:BB")
        XCTAssertFalse(containsBeforeInsert)
        await trustStore.insert("AA:BB")
        let containsAfterInsert = await trustStore.contains("AA:BB")
        XCTAssertTrue(containsAfterInsert)

        await trustStore.reset()
        let containsAfterReset = await trustStore.contains("AA:BB")
        XCTAssertFalse(containsAfterReset)
    }

    func testTempTransferStoreSweepsOnlyStaleArtifacts() async throws {
        try await withTemporaryDirectory { directoryURL in
            let baseDirectory = directoryURL.appendingPathComponent("Transfers", isDirectory: true)
            let store = TempTransferStore(baseDirectoryURL: baseDirectory)

            let staleDirectory = try await store.prepareOperationDirectory(prefix: "stale")
            let freshDirectory = try await store.prepareOperationDirectory(prefix: "fresh")

            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-60 * 60 * 24)],
                ofItemAtPath: staleDirectory.path
            )

            await store.sweepStaleArtifacts(olderThan: 60)

            XCTAssertFalse(FileManager.default.fileExists(atPath: staleDirectory.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: freshDirectory.path))
        }
    }

    func testStreamingListingAccumulatorParsesLargeMLSDDirectory() throws {
        let lines = (0..<10_000).map { index in
            "type=file;size=\(index);modify=20260320111213; file-\(index).txt"
        }
        let payload = lines.joined(separator: "\r\n")
        let data = Data(payload.utf8)

        var accumulator = StreamingListingAccumulator(format: .mlsd, directory: "/bulk")
        for chunkStart in stride(from: 0, to: data.count, by: 1024) {
            let chunkEnd = min(chunkStart + 1024, data.count)
            accumulator.append(data.subdata(in: chunkStart..<chunkEnd))
        }

        let items = accumulator.finish()
        XCTAssertEqual(items.count, 10_000)
        XCTAssertEqual(items.first?.path, "/bulk/file-0.txt")
        XCTAssertEqual(items.last?.path, "/bulk/file-9999.txt")
    }

    func testStreamingFileSinkWritesChunksSequentially() throws {
        try withTemporaryDirectory { directoryURL in
            let sink = try StreamingFileSink(destinationDirectory: directoryURL, filename: "result.bin")
            try sink.write(Data("hello ".utf8))
            try sink.write(Data("world".utf8))
            try sink.finish()

            let content = try Data(contentsOf: sink.destinationURL)
            XCTAssertEqual(String(decoding: content, as: UTF8.self), "hello world")
        }
    }

    func testTransferProgressCoalescerCoalescesAndFinishesPendingSnapshot() async {
        let timeSource = ManualTimeSource()
        let coalescer = TransferProgressCoalescer(
            byteThreshold: 100,
            minimumInterval: 60,
            nowProvider: { timeSource.current }
        )

        let firstEmission = await coalescer.submit(
            TransferSnapshot(title: "Download", transferredBytes: 10, totalBytes: 500)
        )
        XCTAssertEqual(firstEmission?.transferredBytes, 10)

        let secondEmission = await coalescer.submit(
            TransferSnapshot(title: "Download", transferredBytes: 70, totalBytes: 500)
        )
        XCTAssertNil(secondEmission)

        let finalEmission = await coalescer.finish()
        XCTAssertEqual(finalEmission?.transferredBytes, 70)
    }

    func testLocalDirectoryServiceLoadsAndSortsInBackgroundActor() async throws {
        try await withTemporaryDirectory { directoryURL in
            let uploadsURL = directoryURL.appendingPathComponent("Uploads")
            try FileManager.default.createDirectory(at: uploadsURL, withIntermediateDirectories: false)
            try Data("notes".utf8).write(to: directoryURL.appendingPathComponent("notes.txt"))
            try Data("archive".utf8).write(to: directoryURL.appendingPathComponent("archive.txt"))

            let service = LocalDirectoryService()
            let items = try await service.loadDirectory(at: directoryURL, forceRefresh: true)

            XCTAssertEqual(items.count, 3)
            XCTAssertEqual(items[0].name, "Uploads")
            XCTAssertTrue(items[0].isDirectory)
            XCTAssertEqual(items[1].name, "archive.txt")
            XCTAssertEqual(items[2].name, "notes.txt")
        }
    }

    func testLocalDirectoryServiceLoadSnapshotBuildsRowsAndDiff() async throws {
        try await withTemporaryDirectory { directoryURL in
            try Data("one".utf8).write(to: directoryURL.appendingPathComponent("one.txt"))

            let service = LocalDirectoryService()
            let firstLoad = try await service.loadSnapshot(at: directoryURL, forceRefresh: true)
            XCTAssertEqual(firstLoad.snapshot.displayRows.count, 1)
            XCTAssertEqual(firstLoad.snapshot.displayRows[0].name, "one.txt")
            XCTAssertEqual(
                firstLoad.diff.insertedIDs.map { URL(fileURLWithPath: $0).lastPathComponent },
                ["one.txt"]
            )

            try Data("two".utf8).write(to: directoryURL.appendingPathComponent("two.txt"))

            let secondLoad = try await service.loadSnapshot(
                at: directoryURL,
                forceRefresh: true,
                previousSnapshot: firstLoad.snapshot
            )

            XCTAssertEqual(secondLoad.snapshot.displayRows.count, 2)
            XCTAssertEqual(
                secondLoad.diff.insertedIDs.map { URL(fileURLWithPath: $0).lastPathComponent },
                ["two.txt"]
            )
        }
    }

    func testDuplicateNameResolverAddsCopySuffixBeforeExtension() {
        var reservedNames = Set<String>()
        let existingNames = Set(["report.txt", "report copy.txt"].map {
            $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        })

        let uniqueName = DuplicateNameResolver.uniqueName(
            for: "report.txt",
            isDirectory: false,
            existingNames: existingNames,
            reservedNames: &reservedNames
        )

        XCTAssertEqual(uniqueName, "report copy 2.txt")
    }

    func testDuplicateNameResolverUsesReservedNamesAcrossBatch() {
        var reservedNames = Set<String>()
        let existingNames = Set(["docs"].map {
            $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        })

        let firstCopy = DuplicateNameResolver.uniqueName(
            for: "docs",
            isDirectory: true,
            existingNames: existingNames,
            reservedNames: &reservedNames
        )
        let secondCopy = DuplicateNameResolver.uniqueName(
            for: "docs",
            isDirectory: true,
            existingNames: existingNames,
            reservedNames: &reservedNames
        )

        XCTAssertEqual(firstCopy, "docs copy")
        XCTAssertEqual(secondCopy, "docs copy 2")
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }

        try body(directoryURL)
    }

    private func withTemporaryDirectory(_ body: (URL) async throws -> Void) async throws {
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }

        try await body(directoryURL)
    }
}

private final class ManualTimeSource: @unchecked Sendable {
    var current: TimeInterval = 0
}
