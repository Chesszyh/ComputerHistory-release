# Changelog

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
