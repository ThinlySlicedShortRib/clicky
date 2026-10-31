# Clicky - Agent Instructions

<!-- This is the single source of truth for all AI coding agents. CLAUDE.md is a symlink to this file. -->
<!-- AGENTS.md spec: https://github.com/agentsmd/agents.md — supported by Claude Code, Cursor, Copilot, Gemini CLI, and others. -->

## Overview

macOS menu bar companion app. Lives entirely in the macOS status bar (no dock icon, no main window). Clicking the menu bar icon opens a custom floating panel with companion voice controls. Uses push-to-talk (ctrl+option) to capture voice input, transcribes it via Apple Speech, and sends the transcript + a screenshot of the user's screen to a `Brain`, which by default shells out to the logged-in `claude` CLI. Replies are spoken via `say`. A blue cursor overlay can fly to and point at UI elements Claude references on any connected monitor.

**This fork is the foundation for demo builds. Read `docs/FOUNDATION.md` first**: it covers building, swapping models, headless checks, measured latency, and what is and isn't verified. No keys or Cloudflare Worker are needed; the upstream Worker sections below are kept for reference only.

## Architecture

- **App Type**: Menu bar-only (`LSUIElement=true`), no dock icon or main window
- **Framework**: SwiftUI (macOS native) with AppKit bridging for menu bar panel and cursor overlay
- **Pattern**: MVVM with `@StateObject` / `@Published` state management
- **AI Chat**: `Brain` protocol. Default is the `claude` CLI (`claude-sonnet-5-5`) in stream-json mode, with `codex` as the alternate. One config value, `BrainModel` in Info.plist, selects it; `CLICKY_BRAIN_MODEL` overrides it
- **Speech-to-Text**: Apple Speech by default (`VoiceTranscriptionProvider` in Info.plist). AssemblyAI and OpenAI providers remain but need keys
- **Text-to-Speech**: macOS `say` behind `CompanionTextToSpeechClient`
- **Screen Capture**: ScreenCaptureKit (macOS 14.2+), multi-monitor support
- **Voice Input**: Push-to-talk via `AVAudioEngine` + pluggable transcription-provider layer. System-wide keyboard shortcut via listen-only CGEvent tap.
- **Show Me Once**: Teach mode records a demonstration, `LessonCompiler` turns it into a `.clicky` lesson, and follow mode replays it on someone else's setup. See `docs/demo/show-me-once/DEMO.md`
- **Element Pointing**: Claude embeds `[POINT:x,y:label:screenN]` tags in responses. The overlay parses these, maps coordinates to the correct monitor, and animates the blue cursor along a bezier arc to the target.
- **Concurrency**: `@MainActor` isolation, async/await throughout
- **Analytics**: None. `ClickyAnalytics.swift` is a no-op seam; PostHog was removed

### API Proxy (Cloudflare Worker, unused here)

Upstream never calls external APIs directly. All requests go through a Cloudflare Worker (`worker/src/index.ts`) that holds the real API keys as secrets.

| Route | Upstream | Purpose |
|-------|----------|---------|
| `POST /chat` | `api.anthropic.com/v1/messages` | Claude vision + streaming chat |
| `POST /tts` | `api.elevenlabs.io/v1/text-to-speech/{voiceId}` | ElevenLabs TTS audio |
| `POST /transcribe-token` | `streaming.assemblyai.com/v3/token` | Fetches a short-lived (480s) AssemblyAI websocket token |

Worker secrets: `ANTHROPIC_API_KEY`, `ASSEMBLYAI_API_KEY`, `ELEVENLABS_API_KEY`
Worker vars: `ELEVENLABS_VOICE_ID`

### Key Architecture Decisions

**Menu Bar Panel Pattern**: The companion panel uses `NSStatusItem` for the menu bar icon and a custom borderless `NSPanel` for the floating control panel. This gives full control over appearance (dark, rounded corners, custom shadow) and avoids the standard macOS menu/popover chrome. The panel is non-activating so it doesn't steal focus. A global event monitor auto-dismisses it on outside clicks.

**Cursor Overlay**: A full-screen transparent `NSPanel` hosts the blue cursor companion. It's non-activating, joins all Spaces, and never steals focus. The cursor position, response text, waveform, and pointing animations all render in this overlay via SwiftUI through `NSHostingView`.

**Global Push-To-Talk Shortcut**: Background push-to-talk uses a listen-only `CGEvent` tap instead of an AppKit global monitor so modifier-based shortcuts like `ctrl + option` are detected more reliably while the app is running in the background.

**Shared URLSession for AssemblyAI**: A single long-lived `URLSession` is shared across all AssemblyAI streaming sessions (owned by the provider, not the session). Creating and invalidating a URLSession per session corrupts the OS connection pool and causes "Socket is not connected" errors after a few rapid reconnections.

**Transient Cursor Mode**: When "Show Clicky" is off, pressing the hotkey fades in the cursor overlay for the duration of the interaction (recording → response → TTS → optional pointing), then fades it out automatically after 1 second of inactivity.

## Key Files

| File | Lines | Purpose |
|------|-------|---------|
| `leanring_buddyApp.swift` | ~89 | Menu bar app entry point. Uses `@NSApplicationDelegateAdaptor` with `CompanionAppDelegate` which creates `MenuBarPanelManager` and starts `CompanionManager`. No main window — the app lives entirely in the status bar. |
| `CompanionManager.swift` | ~1057 | Central state machine. Owns dictation, shortcut monitoring, screen capture, Claude API, ElevenLabs TTS, and overlay management. Tracks voice state (idle/listening/processing/responding), conversation history, model selection, and cursor visibility. Coordinates the full push-to-talk → screenshot → Claude → TTS → pointing pipeline. |
| `MenuBarPanelManager.swift` | ~243 | NSStatusItem + custom NSPanel lifecycle. Creates the menu bar icon, manages the floating companion panel (show/hide/position), installs click-outside-to-dismiss monitor. |
| `CompanionPanelView.swift` | ~761 | SwiftUI panel content for the menu bar dropdown. Shows companion status, push-to-talk instructions, model picker (Sonnet/Opus), permissions UI, DM feedback button, and quit button. Dark aesthetic using `DS` design system. |
| `OverlayWindow.swift` | ~881 | Full-screen transparent overlay hosting the blue cursor, response text, waveform, and spinner. Handles cursor animation, element pointing with bezier arcs, multi-monitor coordinate mapping, and fade-out transitions. |
| `CompanionResponseOverlay.swift` | ~217 | SwiftUI view for the response text bubble and waveform displayed next to the cursor in the overlay. |
| `CompanionScreenCaptureUtility.swift` | ~132 | Multi-monitor screenshot capture using ScreenCaptureKit. Returns labeled image data for each connected display. |
| `BuddyDictationManager.swift` | ~866 | Push-to-talk voice pipeline. Handles microphone capture via `AVAudioEngine`, provider-aware permission checks, keyboard/button dictation sessions, transcript finalization, shortcut parsing, contextual keyterms, and live audio-level reporting for waveform feedback. |
| `BuddyTranscriptionProvider.swift` | ~100 | Protocol surface and provider factory for voice transcription backends. Resolves provider based on `VoiceTranscriptionProvider` in Info.plist — AssemblyAI, OpenAI, or Apple Speech. |
| `AssemblyAIStreamingTranscriptionProvider.swift` | ~478 | Streaming transcription provider. Fetches temp tokens from the Cloudflare Worker, opens an AssemblyAI v3 websocket, streams PCM16 audio, tracks turn-based transcripts, and delivers finalized text on key-up. Shares a single URLSession across all sessions. |
| `OpenAIAudioTranscriptionProvider.swift` | ~317 | Upload-based transcription provider. Buffers push-to-talk audio locally, uploads as WAV on release, returns finalized transcript. |
| `AppleSpeechTranscriptionProvider.swift` | ~147 | Local fallback transcription provider backed by Apple's Speech framework. |
| `BuddyAudioConversionSupport.swift` | ~108 | Audio conversion helpers. Converts live mic buffers to PCM16 mono audio and builds WAV payloads for upload-based providers. |
| `GlobalPushToTalkShortcutMonitor.swift` | ~132 | System-wide push-to-talk monitor. Owns the listen-only `CGEvent` tap and publishes press/release transitions. |
| `Brain.swift` | ~120 | `Brain` protocol, request/response types, `BrainUsage` (tokens, cost, timing), and `BrainConfiguration`, which turns the single `BrainModel` value into a backend. |
| `CLIBrains.swift` | ~550 | `ClaudeCLIBrain` and `CodexCLIBrain`, plus the subprocess runner with streaming stdout, cancellation, and timeouts. |
| `SayTTSClient.swift` | ~155 | `CompanionTextToSpeechClient` seam and the `say`-based client. Picks the best installed English voice. Interruptible. |
| `ScreenshotCoordinateMapper.swift` | ~100 | Single source of truth for mapping screenshot pixels to display points and global AppKit coordinates, and for picking the target screen. |
| `HeadlessCommandRunner.swift` | ~1040 | `--headless-*` entry points: permissions report, self-test, capture-to-POINT check with OCR ground truth, overlay flight, speech, transcription. Run through `scripts/headless.sh`. |
| `LessonModels.swift` | ~310 | Show Me Once formats: the private `TeachRecording` and the shareable `ClickyLesson`. Lesson steps hold meaning, never coordinates. |
| `TeachInputCapture.swift` | ~560 | What teach mode may keep: keystroke categories, the secure-input rules, the accessibility reader (never reads AXValue), the input accumulator, and the control+shift+t hot key. |
| `TeachModeRecorder.swift` | ~700 | Live recording: continuous narration, the event tap, and frames around each action. |
| `LessonCompiler.swift` | ~740 | Recording to `.clicky`: narration alignment, the model call, the teacher-word check, reference crops, voice clips, and a rehearsal for real cost figures. |
| `LessonFollowEngine.swift` | ~460 | Locate and success check, shared by live follow and headless replay. Accessibility and local OCR first, the model only when they can't answer. |
| `LessonFollowController.swift` | ~400 | The live lesson loop. Always captures with ScreenCaptureKit; it has no way to take a saved image. |
| `LessonPackage.swift` | ~240 | Reads and writes `.clicky` zips, treating opened files as untrusted. |
| `LessonImageTools.swift` | ~210 | Crops, downscaling, on-device OCR, and the screen-change fingerprint. |
| `LessonShareCard.swift` | ~360 | Share card and the replay cost estimate. Figures come only from `BrainUsage`. |
| `ShowMeOnceCoordinator.swift` | ~490 | Teach, compile, card and file-open flow, the watching indicator, and the panel section. |
| `HeadlessLessonCommands.swift` | ~1050 | Lesson `--headless-*` commands and self-test. The only place saved images reach lesson logic. |
| `ClaudeAPI.swift` | ~291 | Unused here. Claude vision API client with streaming (SSE) and non-streaming modes. |
| `OpenAIAPI.swift` | ~142 | OpenAI GPT vision API client. |
| `ElevenLabsTTSClient.swift` | ~81 | Unused here, but conforms to `CompanionTextToSpeechClient`. Sends text to the Worker proxy, plays back audio via `AVAudioPlayer`. |
| `ElementLocationDetector.swift` | ~335 | Detects UI element locations in screenshots for cursor pointing. |
| `DesignSystem.swift` | ~880 | Design system tokens — colors, corner radii, shared styles. All UI references `DS.Colors`, `DS.CornerRadius`, etc. |
| `ClickyAnalytics.swift` | ~120 | No-op analytics seam. Call sites remain so a build can add its own project. |
| `WindowPositionManager.swift` | ~262 | Window placement logic, Screen Recording permission flow, and accessibility permission helpers. |
| `AppBundleConfiguration.swift` | ~28 | Runtime configuration reader for keys stored in the app bundle Info.plist. |
| `worker/src/index.ts` | ~142 | Cloudflare Worker proxy. Three routes: `/chat` (Claude), `/tts` (ElevenLabs), `/transcribe-token` (AssemblyAI temp token). |

## Build & Run

```bash
scripts/build-and-run.sh               # build, sign, relaunch
scripts/build-and-run.sh --build-only  # build and sign only
scripts/headless.sh --headless-self-test
scripts/headless.sh --headless-lesson-self-test
scripts/make-synthetic-lesson.py       # compiler and follow engine, with no human
scripts/demo-show-me-once.sh           # preflight and demo documents

# Known non-blocking warnings: Swift 6 concurrency warnings,
# deprecated onChange warning in OverlayWindow.swift. Do NOT attempt to fix these.
```

Build through `scripts/build-and-run.sh`. It signs with the stable `Apple Development` identity, which keeps TCC (Transparency, Consent, and Control) permissions across rebuilds. Do not change the identity or bundle ID, since either one resets every grant.

Run headless commands through `scripts/headless.sh`, not by executing the binary, so macOS applies Clicky's permissions rather than the shell's.

`CLICKY_DERIVED_DATA_PATH` moves the build output for all three scripts, for parallel checkouts.

## Cloudflare Worker (unused here)

```bash
cd worker
npm install

# Add secrets
npx wrangler secret put ANTHROPIC_API_KEY
npx wrangler secret put ASSEMBLYAI_API_KEY
npx wrangler secret put ELEVENLABS_API_KEY

# Deploy
npx wrangler deploy

# Local dev (create worker/.dev.vars with your keys)
npx wrangler dev
```

## Code Style & Conventions

### Variable and Method Naming

IMPORTANT: Follow these naming rules strictly. Clarity is the top priority.

- Be as clear and specific with variable and method names as possible
- **Optimize for clarity over concision.** A developer with zero context on the codebase should immediately understand what a variable or method does just from reading its name
- Use longer names when it improves clarity. Do NOT use single-character variable names
- Example: use `originalQuestionLastAnsweredDate` instead of `originalAnswered`
- When passing props or arguments to functions, keep the same names as the original variable. Do not shorten or abbreviate parameter names. If you have `currentCardData`, pass it as `currentCardData`, not `card` or `cardData`

### Code Clarity

- **Clear is better than clever.** Do not write functionality in fewer lines if it makes the code harder to understand
- Write more lines of code if additional lines improve readability and comprehension
- Make things so clear that someone with zero context would completely understand the variable names, method names, what things do, and why they exist
- When a variable or method name alone cannot fully explain something, add a comment explaining what is happening and why

### Swift/SwiftUI Conventions

- Use SwiftUI for all UI unless a feature is only supported in AppKit (e.g., `NSPanel` for floating windows)
- All UI state updates must be on `@MainActor`
- Use async/await for all asynchronous operations
- Comments should explain "why" not just "what", especially for non-obvious AppKit bridging
- AppKit `NSPanel`/`NSWindow` bridged into SwiftUI via `NSHostingView`
- All buttons must show a pointer cursor on hover
- For any interactive element, explicitly think through its hover behavior (cursor, visual feedback, and whether hover should communicate clickability)

### Do NOT

- Do not add features, refactor code, or make "improvements" beyond what was asked
- Do not add docstrings, comments, or type annotations to code you did not change
- Do not try to fix the known non-blocking warnings (Swift 6 concurrency, deprecated onChange)
- Do not rename the project directory or scheme (the "leanring" typo is intentional/legacy)
- Do not sign with anything other than the identity in `scripts/build-and-run.sh` — it invalidates TCC permissions

## Git Workflow

- Branch naming: `feature/description` or `fix/description`
- Commit messages: imperative mood, concise, explain the "why" not the "what"
- Do not force-push to main

## Self-Update Instructions

<!-- AI agents: follow these instructions to keep this file accurate. -->

When you make changes to this project that affect the information in this file, update this file to reflect those changes. Specifically:

1. **New files**: Add new source files to the "Key Files" table with their purpose and approximate line count
2. **Deleted files**: Remove entries for files that no longer exist
3. **Architecture changes**: Update the architecture section if you introduce new patterns, frameworks, or significant structural changes
4. **Build changes**: Update build commands if the build process changes
5. **New conventions**: If the user establishes a new coding convention during a session, add it to the appropriate conventions section
6. **Line count drift**: If a file's line count changes significantly (>50 lines), update the approximate count in the Key Files table

Do NOT update this file for minor edits, bug fixes, or changes that don't affect the documented architecture or conventions.
