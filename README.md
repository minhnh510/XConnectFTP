# XConnectFTP

XConnectFTP is a macOS SwiftUI desktop client for FTP and explicit FTPS, built around a dual-pane workflow similar to Finder/FileZilla.

## Highlights

- Saved sites with `host`, `port`, `username`, `password`, and protocol selection
- FTP and explicit FTPS (`AUTH TLS`, `PBSZ 0`, `PROT P`)
- Dual-pane local/remote browser
- Finder-like interactions:
  - single select and multi-select
  - drag and drop between local and remote panes
  - `Cmd+C` / `Cmd+V` copy and paste flows
  - batch upload, download, move, delete, rename
- Recursive folder upload/download
- Remote same-pane copy via temp staging
- FTPS certificate trust prompt with session-scoped fingerprint approval
- Performance work already included:
  - streaming transfers
  - capability caching
  - throttled progress updates
  - shell-first bootstrap
  - preformatted browser rows
  - local directory watcher

## Requirements

- macOS 13+
- Xcode 15+ recommended
- Swift Package Manager for validation tests

## Build

Open `XConnectFTP.xcodeproj` in Xcode and run the `XConnectFTP` macOS target.

Command line build:

```bash
xcodebuild -quiet -scheme XConnectFTP -project XConnectFTP.xcodeproj -configuration Debug -destination 'platform=macOS' build
```

## Test

Package validation tests:

```bash
swift test
```

## Project Structure

- `XConnectFTP/`
  - SwiftUI app, session/view model, FTP client, interaction and performance services
- `Config/`
  - app entitlements and `Info.plist`
- `XConnectFTPTests/`
  - parser and performance-oriented validation tests
- `Package.swift`
  - lightweight SwiftPM target for core validation

## Security Notes

- Plain FTP is supported for compatibility, but it is not encrypted.
- FTPS uses explicit TLS and prompts when the certificate cannot be verified.
- Passwords are stored in Keychain.
- Local root access is restored with security-scoped bookmarks.

## Current Status

The app is focused on a pragmatic V1 for macOS:

- one active session at a time
- sequential transfers
- passive mode
- no SFTP
- no parallel transfer queue yet

## Repository

GitHub: <https://github.com/minhnh510/XConnectFTP>
