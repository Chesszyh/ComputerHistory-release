# Changelog

## 0.3.1 - 2026-10-27

- Separate activity ownership from summary writing, retain task returns as distinct appearances, and preserve completed generation stages during retries.
- Allow editing final timeline titles and summaries, associating or separating tasks, and splitting grouped fragments while keeping source evidence read-only.
- Record browsing scrolls, report unavailable input coverage separately from passive activity, and avoid flushing exposed input method composition as committed text.
- Package a macOS app with first-run permission guidance and an independent credential helper retained across ordinary upgrades.
- Preserve authorized helpers when upgrading ad-hoc signed packages and reseal the updated app.
- Keep the standalone setup window at its intended size, allow long messages to scroll, and preserve access to its footer actions.
- Open the installed app from the launcher and document app upgrades, credential recovery, and standalone window verification.


## 0.3.0 - 2026-10-26

### Timeline and summaries
- Offer fixed ten-minute and continuous-task modes, summary editing, and copying selections across pages.
- Keep top-level start times unique and intervals ordered without overlaps. Fold simultaneous or intersecting activities while preserving their summaries, sources, edits, and copying.
- Group steps serving the same goal and retain distinct goals. Show brief checks, conversations, leisure, and work equally instead of demoting them to an “other activities” category.
- Label extended passive interface observations as “No clear activity” without asking the model to invent a task. Preserve the observations and combine adjoining passive periods.
- Use system input idle time to distinguish unlocked inactivity from locking or sleep, with explicit transitions on resumed input, pause, and stop.
- Refine activity prompts to preserve concrete objects, discussion points, observed results, source details, and attributed claims.

- Resolve full source identities for restarted segments, correct pending-memory counts, and fill missing or failed report dependencies automatically. Preserve usable summaries and wait for active memory writers.

### Interface and performance
- Refine folded activities, the current-window card, away records, and the trash view.
- Update the last-write label every second without increasing disk polling; clarify request accounting and custom prompt updates.
- Keep paginated history scroll height current on macOS 15.
- Avoid publishing unchanged content versions, model health, and backup state; reuse timeline date formatters and keep historical caches valid during ongoing away periods.
- Stop polling the current window in the menu bar while recording is paused; reuse segment timestamp parsing and reduce index file-attribute overhead while retaining atomic-replacement detection.
- Add regression coverage for passive interfaces, stale merged caches, generated intervals, copy/delete behavior, and native refreshes.

### Releases
- Support alpha, beta, and rc candidates without replacing the latest stable release.

## 0.2.4 - 2026-10-23

### Features
- Choose fixed ten-minute summaries or adjacent-task continuity, then recalculate today's summaries, all summaries, or keep the existing cache.
- Edit summary titles and content in fixed mode, retain manual changes across regeneration, and restore automatic text when needed.
- Select multiple summaries across pages and copy only the selected activities with explicit dates and times.

### Fixes & Improvements
- Keep a single timeline without overlapping activity intervals; separate task returns and activities interrupted by time away from the computer.
- Preserve activity content when splitting older merged summaries, validate contiguous source attribution, and retain existing summaries when a daily rebuild fails or is cancelled.
- Move logs into the collapsed runtime section and make the trash a matching icon in the left footer.
- Keep background Keychain access quiet and provide an explicit authorization command for saved model credentials.

## 0.2.3 - 2026-10-22

### Features
- Add a user-directory installer with a stable executable location, login-item updates, upgrade rollback, and data-preserving uninstall.
- Add a portable, read-only activity recall Skill for querying local summaries and evidence from other coding agents.

### Fixes & Improvements
- Require HTTPS for remote model endpoints by default, retain loopback HTTP, and support explicit per-model consent for remote HTTP. Apply the same checks to model catalogs and reject automatic model-request redirects.
- Check observation policy before reading interaction targets, validate clicked application and window identity, and retain text and interface baselines correctly after write failures.
- Validate narrative source references and preserve source-backed evidence when rendering activity summaries.
- Preserve complete release verification while testing both development and public branches; document first launch, permissions, upgrades, and uninstall for direct downloads.

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
