# Changelog

## 0.2.0 - 2026-10-17

### Features
- **Local OCR Window Reading**: Extract readable text from inaccessible application windows (Electron apps, custom canvases, etc.) via Apple's native Vision framework completely on-device without screen-capture permissions.
- **Native Model and Collector Settings**: In-app configuration pane to configure model API keys (safely persisted in macOS Keychain), Base URL, model name, temperature, and application filters.
- **Custom Activity Summaries**: Support customizing 10-minute and 6-hour activity summarization prompts with live draft validation and persistence.
- **Redesigned Usage Dashboard**: Modern metrics overview card highlighting estimated token spend, Prompt/Completion throughput ratio, and request statuses with expandable group comparisons.

### Fixes & Improvements
- **Menubar Navigation**: Standardized secondary view headers with pill back buttons and centered titles; isolated timeline day group rendering to prevent layout jitter.
- **Comprehensive Test Suite**: Expanded full test coverage to 221 tests, validating OCR parsing, configuration draft state transitions, and view hierarchy wiring.

## 0.1.0 - 2026-10-16

### Features
- Initial public release of ComputerHistory for macOS (Apple Silicon and Intel).
- Local activity tracking, memory summaries, DeepSeek/custom model support, and menu bar timeline viewer.
