# AGENTS.md

## Scope

This file is the repo-level working guide for agents modifying `XConnectFTP`.

## Project Snapshot

- App name: `XConnectFTP`
- Platform: macOS SwiftUI desktop app
- Protocols: `FTP` and explicit `FTPS`
- Main workflow: dual-pane local/remote browser with Finder-like selection, drag/drop, copy/paste, upload/download, rename, delete

## Build And Test

Run both before handoff:

```bash
xcodebuild -quiet -scheme XConnectFTP -project XConnectFTP.xcodeproj -configuration Debug -destination 'platform=macOS' -derivedDataPath ./.derivedData CODE_SIGNING_ALLOWED=NO build
swift test
```

Notes:

- `xcodebuild` may warn about multiple matching macOS destinations on the same Mac. That warning is acceptable if the build succeeds.
- `swift test` validates the SwiftPM core target defined in `Package.swift`.

## Localization Rules

All user-facing text must be localized.

This includes:

- SwiftUI labels, buttons, menus, tooltips, empty states
- `NSAlert`, `NSOpenPanel`, and any AppKit prompt text
- `statusMessage` and other runtime status/progress text
- `LocalizedError.errorDescription`
- transfer titles such as upload/download/copy/move/delete progress
- duplicate-name suffixes such as `copy`, `copy 2`

Do not rely on `.environment(\\.locale, ...)` alone. String literals are not automatically translated by SwiftUI just because the locale changes.

Use the existing helpers in [XConnectFTP/Localization.swift](/Users/minh.nguyen3/Desktop/project/XConnectFTP/XConnectFTP/Localization.swift):

- Static text: `"Settings".localized`
- Formatted text: `"Connected to %@.".localized(host)`
- Keep using `L10n.format(...)` where that is already the established pattern

When adding or changing a key:

- update both [XConnectFTP/en.lproj/Localizable.strings](/Users/minh.nguyen3/Desktop/project/XConnectFTP/XConnectFTP/en.lproj/Localizable.strings)
- and [XConnectFTP/vi.lproj/Localizable.strings](/Users/minh.nguyen3/Desktop/project/XConnectFTP/XConnectFTP/vi.lproj/Localizable.strings)

Preferred rule for new keys:

- Prefer English source keys for new entries going forward.
- Do not mass-rename existing keys unless the task explicitly calls for cleanup.

If localization helpers are used inside files compiled by the SwiftPM validation target, keep `Localization.swift` included by [Package.swift](/Users/minh.nguyen3/Desktop/project/XConnectFTP/Package.swift).

## AppKit / Windowing Notes

- For AppKit alerts and custom About/Help windows, use `AppIconProvider.image()` instead of `NSApp.applicationIconImage`.
- `Settings` is opened through SwiftUI `openSettings()`, not older AppKit selectors.
- Scene locale is driven by `@AppStorage(AppLanguage.storageKey)` in [XConnectFTP/XConnectFTPApp.swift](/Users/minh.nguyen3/Desktop/project/XConnectFTP/XConnectFTP/XConnectFTPApp.swift).

## UI Guardrails

- Preserve native `Table` selection behavior first.
- Prefer table-level context menus and primary actions over per-cell gesture hacks.
- For drag/drop custom payloads, keep `UTType(exportedAs:)` identifiers in sync with `UTExportedTypeDeclarations` in [Config/Info.plist](/Users/minh.nguyen3/Desktop/project/XConnectFTP/Config/Info.plist).
- For remote export drag flows, do not break `RemoteFilePromiseRegistry` registration.

## FTP / FTPS Notes

- Current FTPS limitation: servers that require TLS session reuse on data connections are not fully supported by the current transport stack. The app currently surfaces a localized explicit error instead of silently downgrading behavior.
- Do not reintroduce automatic `PROT C` fallback unless the task explicitly requires a policy change.
- Plain FTP is supported, but warning text for insecure FTP must remain localized and visible.

## State / Message Hygiene

- Any new `statusMessage` assignment must be localized.
- Any new `BrowserInteractionError`, `StorageError`, `FTPError`, or transfer verification error must be localized.
- Raw server payloads may still appear inside formatted localized wrappers when needed for diagnostics.

## Files To Check When Touching Localization

- [XConnectFTP/Localization.swift](/Users/minh.nguyen3/Desktop/project/XConnectFTP/XConnectFTP/Localization.swift)
- [XConnectFTP/SessionViewModel.swift](/Users/minh.nguyen3/Desktop/project/XConnectFTP/XConnectFTP/SessionViewModel.swift)
- [XConnectFTP/ContentView.swift](/Users/minh.nguyen3/Desktop/project/XConnectFTP/XConnectFTP/ContentView.swift)
- [XConnectFTP/AppSupportViews.swift](/Users/minh.nguyen3/Desktop/project/XConnectFTP/XConnectFTP/AppSupportViews.swift)
- [XConnectFTP/FTPParsing.swift](/Users/minh.nguyen3/Desktop/project/XConnectFTP/XConnectFTP/FTPParsing.swift)
- [XConnectFTP/TransferCoordinator.swift](/Users/minh.nguyen3/Desktop/project/XConnectFTP/XConnectFTP/TransferCoordinator.swift)
- [XConnectFTP/PerformanceServices.swift](/Users/minh.nguyen3/Desktop/project/XConnectFTP/XConnectFTP/PerformanceServices.swift)
- [XConnectFTP/BrowserInteraction.swift](/Users/minh.nguyen3/Desktop/project/XConnectFTP/XConnectFTP/BrowserInteraction.swift)
