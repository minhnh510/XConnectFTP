import XCTest
@testable import XConnectFTPCore

final class CoreParsingTests: XCTestCase {
    func testConnectionDraftValidationBuildsProfile() throws {
        var draft = ConnectionProfileDraft()
        draft.name = "Production"
        draft.host = "192.168.1.10"
        draft.portText = "21"
        draft.username = "demo"
        draft.password = "secret"
        draft.protocolMode = .ftpsExplicit
        draft.initialRemotePath = "/incoming"

        let profile = try draft.buildProfile(existingID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))

        XCTAssertEqual(profile.name, "Production")
        XCTAssertEqual(profile.host, "192.168.1.10")
        XCTAssertEqual(profile.port, 21)
        XCTAssertEqual(profile.username, "demo")
        XCTAssertEqual(profile.protocolMode, .ftpsExplicit)
        XCTAssertEqual(profile.initialRemotePath, "/incoming")
    }

    func testConnectionDraftPreservesExistingLocalRootPath() throws {
        var draft = ConnectionProfileDraft()
        draft.name = "Production"
        draft.host = "192.168.1.10"
        draft.portText = "21"
        draft.username = "demo"
        draft.password = "secret"

        let profile = try draft.buildProfile(
            existingID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"),
            existingLocalRootPath: "/Users/demo/Documents"
        )

        XCTAssertEqual(profile.localRootPath, "/Users/demo/Documents")
    }

    func testConnectionDraftRejectsInvalidPort() {
        var draft = ConnectionProfileDraft()
        draft.name = "Broken"
        draft.host = "10.0.0.1"
        draft.portText = "70000"
        draft.username = "demo"
        draft.password = "secret"

        XCTAssertThrowsError(try draft.buildProfile(existingID: nil))
    }

    func testFTPPathNormalizationAndParent() {
        XCTAssertEqual(FTPPath.normalize("/folder/./nested/../file.txt"), "/folder/file.txt")
        XCTAssertEqual(FTPPath.join("/folder", child: "child.txt"), "/folder/child.txt")
        XCTAssertEqual(FTPPath.parent(of: "/folder/child.txt"), "/folder")
        XCTAssertEqual(FTPPath.parent(of: "/"), "/")
    }

    func testPassiveEndpointParsing() {
        let pasv = PassiveEndpoint.parsePASV(from: "227 Entering Passive Mode (192,168,1,2,195,80)")
        XCTAssertEqual(pasv?.host, "192.168.1.2")
        XCTAssertEqual(pasv?.port, 50000)

        let epsv = PassiveEndpoint.parseEPSV(from: "229 Entering Extended Passive Mode (|||32123|)", fallbackHost: "10.0.0.5")
        XCTAssertEqual(epsv?.host, "10.0.0.5")
        XCTAssertEqual(epsv?.port, 32123)
    }

    func testFTPHostNormalizationAndPassivePreference() {
        XCTAssertEqual(FTPHost.connectionHost(for: " ftp.example.com "), "ftp.example.com")
        XCTAssertEqual(FTPHost.connectionHost(for: "[2001:db8::25]"), "2001:db8::25")
        XCTAssertFalse(FTPHost.prefersExtendedPassive(for: "ftp.example.com"))
        XCTAssertTrue(FTPHost.prefersExtendedPassive(for: "[2001:db8::25]"))
    }

    func testMLSDParsingReturnsDirectoryAndFile() {
        let listing = """
        type=dir;modify=20260320101010; documents
        type=file;size=42;modify=20260320111213; report.txt
        """

        let items = FTPDirectoryParser.parse(listing, directory: "/", format: .mlsd)

        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].name, "documents")
        XCTAssertTrue(items[0].isDirectory)
        XCTAssertEqual(items[1].name, "report.txt")
        XCTAssertEqual(items[1].size, 42)
        XCTAssertEqual(items[1].path, "/report.txt")
    }

    func testUnixListParsingReturnsExpectedKinds() {
        let listing = """
        drwxr-xr-x  3 owner  group      96 Mar 21 10:15 uploads
        -rw-r--r--  1 owner  group    4096 Mar 20 2026 notes.txt
        """

        let items = FTPDirectoryParser.parse(listing, directory: "/remote", format: .unixList)

        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].path, "/remote/uploads")
        XCTAssertTrue(items[0].isDirectory)
        XCTAssertEqual(items[1].path, "/remote/notes.txt")
        XCTAssertEqual(items[1].size, 4096)
    }
}
