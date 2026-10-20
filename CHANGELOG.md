# Changelog

## 0.2.2 - 2026-10-20

### Features
- Add daily and weekly reports, Markdown/TXT export, and optional private GitHub backups.
- Save reusable model groups and select primary and fallback groups independently; retain each group's credentials in macOS Keychain.
- Fetch available model names and advertised reasoning levels from model services, with manual entry when metadata is unavailable. A blank reasoning level uses the service default.
- Delete individual timeline summaries and manage them in a persistent trash with restore and permanent removal controls.
- Optionally read the local ActivityWatch service for current window, URL, and active/idle observations. Preserve source metadata and apply collection filters without importing earlier history.

### Fixes & Improvements
- Write new event, log, request, and derived-record timestamps in the current system time zone with an explicit offset, while continuing to read legacy dates and retaining stable segment identifiers.
- Reconnect document accessibility after application launches, retry providers that are still starting, and periodically check the connection.
- Replace ambiguous OCR application icons with functional checkboxes and keep disabled entries available for re-enabling. Browser toolbar text no longer prevents OCR fallback.
- Add per-request model fallback, bounded request deadlines, and independent report scheduling so longer reports do not delay recent summaries.
- Add optional persistent local signing hooks for source builds. Downloaded release binaries remain ad hoc signed and are not notarized.

## 0.2.1 - 2026-10-17

### Fixes & Improvements
- **Release Verification**: The menu usage regression test now locates the request group header from the list document instead of fixed window coordinates. The released tree passes both menu panel tests on Apple Silicon; v0.2.1 also ran the remaining checks on Intel CI. Later releases publish Apple Silicon builds only.
- **Documentation**: Corrected the 0.2.0 notes for OCR screen-recording permission, configurable settings fields, and prompt customization.

## 0.2.0 - 2026-10-17

### Features
- **Local OCR Window Reading**: Extract readable text from inaccessible application windows (Electron apps, custom canvases, etc.) on-device with Apple's Vision framework. Requires Screen Recording permission because the window image is captured locally with ScreenCaptureKit; screenshots are not saved.
- **Native Model and Collector Settings**: In-app configuration pane for model API keys (stored in macOS Keychain), base URL, model name, reasoning effort, pricing and budgets, an optional comparison model, and collector application/domain filters. Collector settings apply while running; model settings apply to the next generation task.
- **Custom Activity Summaries**: Customize the 10-minute, 6-hour, and narrative prompts with draft validation and persistence.
- **Redesigned Usage Dashboard**: Modern metrics overview card highlighting estimated token spend, Prompt/Completion throughput ratio, and request statuses with expandable group comparisons.

### Fixes & Improvements
- **Menubar Navigation**: Standardized secondary view headers with pill back buttons and centered titles; isolated timeline day group rendering to prevent layout jitter.
- **Comprehensive Test Suite**: Expanded to 221 tests, including OCR window text, configuration drafts, and view hierarchy wiring coverage.

## 0.1.0 - 2026-10-16

### Features
- Initial public release of ComputerHistory for macOS (Apple Silicon and Intel).
- Local activity tracking, memory summaries, DeepSeek/custom model support, and menu bar timeline viewer.
