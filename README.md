# XConnectFTP

XConnectFTP is a macOS SwiftUI desktop client for `FTP` and explicit `FTPS`, built around a dual-pane workflow similar to Finder/FileZilla.

Made by XMT Solutions: <https://xmtg.vn/>

## Highlights

- Saved sites with `host`, `port`, `username`, `password`, protocol mode, and optional initial remote path
- `FTP` and explicit `FTPS` support with `AUTH TLS`, `PBSZ 0`, and `PROT P`
- Finder-like dual-pane browser for local and remote files
- Native multi-select, double-click to open folders, context menus, and keyboard shortcuts
- Drag and drop between local and remote panes
- `Cmd+C` / `Cmd+V` flows for local and remote copy/paste
- Batch and recursive upload/download/move/delete/rename
- Remote same-pane copy via temporary staging
- Local root access via security-scoped bookmarks
- FTPS certificate trust prompt with session-scoped fingerprint approval
- Apple Sign In + iCloud sync for saved site metadata
- English and Vietnamese localization with in-app language switching
- About, Help, and Settings windows

## Performance Work Already Included

- Streaming upload/download instead of buffering full files in memory
- Streaming remote listing parse
- Adaptive upload chunk sizing
- Coalesced progress updates
- Session-scoped FTP capability cache
- Remote directory cache with targeted invalidation
- Shell-first bootstrap for faster cold start
- Preformatted browser row models
- Local directory watcher for targeted refresh

## Security Notes

- Plain `FTP` is supported for compatibility, but it is not encrypted.
- The app surfaces an `Insecure FTP` warning when a connection uses plain FTP.
- FTPS trust is scoped to the current session and tied to certificate fingerprint approval.
- Passwords are stored in the local macOS Keychain.
- Only saved site metadata is synced through iCloud. Passwords are not synced.

## Current Limitations

- One active session at a time
- Sequential transfers only
- Passive mode only
- No `SFTP`
- Remote same-pane copy is implemented as download-to-temp then upload
- Some FTPS servers require TLS session reuse on data connections; the current transport stack does not support that server requirement yet

## Build

Open `XConnectFTP.xcodeproj` in Xcode and run the `XConnectFTP` macOS target.

Command-line build used for validation:

```bash
xcodebuild -quiet -scheme XConnectFTP -project XConnectFTP.xcodeproj -configuration Debug -destination 'platform=macOS' -derivedDataPath ./.derivedData CODE_SIGNING_ALLOWED=NO build
```

## Test

SwiftPM validation tests:

```bash
swift test
```

## Project Structure

- `XConnectFTP/`
  SwiftUI app, UI state, FTP client, sync logic, interaction models, and performance services
- `Config/`
  `Info.plist`, entitlements, and app configuration
- `XConnectFTPTests/`
  parser and performance-oriented validation tests
- `Package.swift`
  lightweight SwiftPM target for validating core code paths
- `AGENTS.md`
  repo-specific implementation notes and localization guardrails for future work

## Sync And Localization

- Saved sites can be synced with iCloud after signing in with Apple.
- Sync is metadata-only; passwords remain local in Keychain.
- The app supports English and Vietnamese.
- User-facing text should be localized through `XConnectFTP/Localization.swift` and both `en.lproj` / `vi.lproj` string tables.

## Repository

GitHub: <https://github.com/minhnh510/XConnectFTP>
