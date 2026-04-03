# Changelog

All notable changes to `XConnectFTP` will be documented in this file.

This changelog starts from the current repository state. The project is currently configured with marketing version `1.0.2`; until version tags or dated releases are added, earlier milestones are summarized from repository history instead of exact release numbers.

## [Unreleased]

### Added

- Pane-specific search fields for the local and remote browser panes.
- Sortable `Name`, `Size`, and `Modified` columns for both browser tables.
- Validation tests covering browser search matching and row sorting behavior.
- Repo guidance in `AGENTS.md` for browser search/sort hotspots and table-state guardrails.

### Changed

- Browser table display state now rebuilds from raw local and remote directory snapshots so filtering and sorting stay aligned with selection, rename, refresh, and drag/drop flows.
- Browser row sorting now uses shared comparator rules that keep folders grouped before files and place unknown `Size` and `Modified` values last.
- Added localized `Search` strings for both English and Vietnamese.

## Earlier Repository Milestones

### Dark Theme

- Added a dark appearance option for the macOS app.

### Release Automation

- Updated GitHub Actions and release packaging workflow.

### Sync And Localization

- Added Apple Sign In and iCloud sync for saved site metadata.
- Added English and Vietnamese localization support.
- Added per-site local root persistence.

### Visual Refresh

- Updated the app icon and expanded localization coverage.

### Initial Release

- Initial macOS SwiftUI FTP and explicit FTPS desktop client.
- Added dual-pane browsing, drag/drop, copy/paste, upload/download, rename, and delete workflows.
