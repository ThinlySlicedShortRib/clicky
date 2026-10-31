# Clicky Foundation

A local base for demo builds. It needs no Cloudflare Worker and no API keys: replies come from a logged-in CLI, speech goes through Apple Speech and `say`, and scripted checks run without a human.

Measurements below were taken on 2026-11-01 on an M5 Pro MacBook with one display (1512x982 points, 3024x1964 pixels), macOS 26.6.2, Xcode 27.2.

## Build and run

```bash
scripts/build-and-run.sh               # build, then relaunch the app
scripts/build-and-run.sh --build-only  # build only
```

The app lands in `build/DerivedData/Build/Products/Debug/Clicky.app`. The script fails if the build isn't signed by `Apple Development: Yi Hsiang Chen (KNT3H5Z889)`.

The signing team in the project is `79QJCK6NWQ`. That is the team ID in the certificate's OU field; `KNT3H5Z889` in the certificate's name is a personal ID, and Xcode rejects it as a team.

Permissions persist across rebuilds because the designated requirement stays the same (checked before and after a rebuild). It depends on the bundle ID and certificate name, so changing either resets all grants. Every checkout of this repo shares those grants.

The rule against running `xcodebuild` from a terminal came from unstable signing. With this signature it no longer applies. Sign with this identity and nothing else.

## Permissions

Clicky had none of these when this was written. Only a human can grant them.

| Permission | Needed for | Where to grant |
|---|---|---|
| Screen & System Audio Recording | Real screen capture | System Settings > Privacy & Security. Add `Clicky.app` if it isn't listed, then quit and relaunch it. |
| Accessibility | The ctrl+option hotkey | System Settings > Privacy & Security, or the panel's button |
| Microphone | Voice input | The panel's button, or the prompt on first hotkey press |
| Speech Recognition | Apple Speech transcription | The prompt on first hotkey press, or System Settings > Privacy & Security |

The panel also has a fifth step, Screen Content. It is a one-time test capture inside Clicky, and it is what lets the cursor overlay appear automatically at launch.

Check the current state at any time:

```bash
scripts/headless.sh --headless-permissions
```

When capture is blocked, the app speaks "I can't see your screen yet...", and headless commands return the exact fix with exit code 3.

`screencapture` from the agent's shell is blocked as well (`could not create image from display`), so it can't stand in for a real capture on this machine.

## Swapping models

There is one config value: `BrainModel` in `leanring-buddy/Info.plist`. `CLICKY_BRAIN_MODEL` overrides it without a rebuild.

| Value | Backend |
|---|---|
| `claude-sonnet-5-5` (default) | claude CLI with that model. Any `claude-*` ID works. |
| `codex` | codex CLI with its default model |
| `codex:<model>` | codex CLI with that model |

```bash
CLICKY_BRAIN_MODEL=codex scripts/build-and-run.sh
scripts/headless.sh --headless-point --model claude-opus-5-5 --prompt "..."
```

The panel's Sonnet/Opus picker changes the model for the current launch only, so a saved choice can't shadow the config value.

To add a backend, implement the `Brain` protocol in `Brain.swift` and route to it in `BrainConfiguration.makeBrain`.

### Showing cost

`CompanionManager.lastBrainUsage` is a `BrainUsage` struct holding tokens, cost and timing. Follow these rules on screen:

- If `isCostEstimated` is true, the display must say "estimated". It is always true for the claude CLI.
- `costInUSD` is nil for codex, which reports tokens but no cost. Show tokens, not $0.
- Any nil means "not reported", never zero.

The claude figure is the CLI's own list-price calculation, not a billed amount. A logged-in subscription may not be charged per token at all. A typical Blender request cost about $0.001 estimated with the prompt cache warm, and about $0.009 on the first call.

## Measured latency

Time to first text runs from launching the CLI to the first reply text, measured inside the app, so CLI startup is included. Each sample sent one 1280x831 JPEG of the real Blender UI through the full headless path.

| Backend | First text, median | Range | Samples | Streams? |
|---|---|---|---|---|
| claude CLI, `claude-sonnet-5-5` | **1.57s** | 1.11s to 2.63s | 20 | Yes |
| codex CLI, default model | 3.79s | 3.02s to 7.06s | 10 | No |

Claude's total reply time for a short answer was a median of 2.68s (5 samples). Codex gives its whole reply at once, so its total is about the same as its first text.

Claude is the default because it was faster and streams. Images go inline as base64, which saves a file-reading tool round trip. Both backends accepted every image in these runs.

Keeping a pre-spawned `claude` process ready gave no reliable gain (0.71s to 1.60s against 1.38s to 1.64s cold), so it isn't implemented.

Not measured: the full hotkey-to-voice delay, because that needs the permissions above.

## Headless checks

`scripts/headless.sh` runs one command and prints one JSON object. It launches through `open` so macOS applies Clicky's own permissions, not the shell's. **File paths must be absolute**, because `open` starts the app at `/`.

Exit codes: 0 success, 1 check failed, 2 bad arguments, 3 permission missing.

```bash
# Permissions and pure logic (parsing, mapping, simulated display layouts)
scripts/headless.sh --headless-permissions
scripts/headless.sh --headless-self-test

# capture -> brain -> parsed POINT
scripts/headless.sh --headless-point --prompt "where is the file menu?"

# The same, on a saved image, if capture is blocked or you want a repeatable input.
# --image-rect places it on the display in top-left points. Omit it for full screen.
scripts/headless.sh --headless-point --image /abs/shot.png --image-only \
    --image-rect 0,65,1512,917 --prompt "where is the file menu?" \
    --verify-text "File" --fly

# Fly the overlay to a display point (top-left origin, in points)
scripts/headless.sh --headless-fly-to 400,300 --label "here"

# The full post-transcription pipeline, including speech. No fixture fallback.
scripts/headless.sh --headless-ask "what's on my screen?"

# Voice
scripts/headless.sh --headless-say "hello" --interrupt-after 0.8
scripts/headless.sh --headless-transcribe /abs/speech.aiff

# Window position from the window server. Needs no permission.
scripts/headless.sh --headless-window-bounds Blender
```

Other `--headless-point` options:

| Option | Purpose |
|---|---|
| `--verify-rect x,y,w,h` | Pass only if the point lands inside this display rectangle |
| `--model <value>` | Use this Brain value for this run |
| `--save-sent-image /abs/out.jpg` | Save the exact image sent to the model |
| `--max-dimension <pixels>` | Fixture image size |
| `--second-screen-image /abs/two.png` | Add a simulated second display |
| `--prior-user`, `--prior-assistant` | Add one earlier exchange of context |
| `--cancel-after <seconds>` | Cancel the Brain call mid-request |

A `--verify-text` result of `unverified` means OCR couldn't find the text, which says nothing about the point. Treat it as no result, not as a pass.

### Pointing check against Blender

```bash
/usr/bin/python3 -I scripts/verify_blender_point.py
/usr/bin/python3 -I scripts/verify_blender_point.py --window 150,120,1100,720
/usr/bin/python3 -I scripts/verify_blender_point.py --model codex --only Modeling --runs 3
```

It launches Blender with factory settings, runs 10 targets, then quits Blender. Ground truth doesn't come from the model: Vision OCR finds text, and Blender's own layout gives editor rectangles. Read `capture source` in the summary. With Screen Recording granted it says `screencapturekit`. Otherwise it says `fixture`, meaning Blender's export of its own window was placed where the window server says that window is.

## What is real

Everything here was run, and the results come from those runs.

| Area | Result |
|---|---|
| Build | Signed command-line build works, and the app launches and stays up |
| Phoning home | PostHog removed, FormSpark removed, 0 network sockets while idle |
| Claude and codex Brains | Real calls with real images, including through `open` |
| Cancellation | Killing a request mid-flight left no `claude` process behind |
| Conversation context | A prior exchange reached the model |
| Pointing, maximized window | 18 of 20 passed, 0 missed, 2 unverified |
| Pointing, 1100x720 offset window | 9 of 10 passed. The tenth asked for a tab scrolled out of view, and the model said so. |
| Pointing, small icons | 9 of 9 within 2pt at 1280px, with centres read off the image by eye |
| Codex pointing | 9 of 10 passed, 0 missed, 1 unverified |
| Overlay flight | Tip landed 0pt from target at center, menu bar corner, and left edge |
| `say` voice | Samantha selected, process ran, and interrupting left no `say` process. Nobody listened to the audio. |
| Blocked capture | Clear error, spoken message, exit code 3 |

The unverified runs were all the "Add" menu, which OCR can't read at that size. Plotting one claude run's points on the screenshot showed all 10 on their targets, including "Add". Codex's "Add" point was about 1pt from claude's.

Accuracy needs no extra upscaling: 1280px and 1568px both hit 9 of 9 small icons, so the image size stays at 1280.

### Fixes to pointing

- A mouse at the very top of a screen counted as being on no screen, which silently dropped the point. It now falls back to the first capture.
- The image's delivered size is used as the coordinate space, not the requested size.
- `screenN` is now an explicit field, so it can't drift if a display fails to encode.
- The display frame fallback mixed Core Graphics and AppKit coordinates.
- The triangle's tip now lands on the target. Its center used to, leaving the tip about 5pt away.
- Menu bar items are reachable. The old 20pt clamp was too large for them.
- Tags with a trailing period, decimals, or several tags no longer get read aloud or lost.
- Both pointing call sites now share one mapper.

## Known limits

**Not yet verified, because permissions block it:**

- The real ScreenCaptureKit path has never captured a frame in this foundation. All pointing results used Blender's own screenshot composited into a display-sized image, so ScreenCaptureKit's scaling is covered by unit logic only. After granting Screen Recording, run `verify_blender_point.py` and confirm `capture source: screencapturekit`.
- The hotkey, microphone capture, and Apple Speech transcription were never exercised. `--headless-transcribe` is built to test transcription but stopped at the permission prompt.
- Nobody has seen the overlay fly. The landing position comes from the view's own state, and the window frame was confirmed, but no pixels were captured.

**Other limits:**

- Real multi-display hardware was not tested. Layouts are simulated in the self-test, and one two-image request correctly returned `screen2`, but only one monitor was attached.
- Within about 12pt of the bottom or right screen edge, clamping leaves the tip up to 4pt off target.
- The default voice is Samantha because no Premium or Enhanced voices are installed. Downloading one in System Settings gets it picked up automatically. `CLICKY_TTS_VOICE` overrides it.
- `CodexCLIBrain` does not stream, and `--ignore-user-config` means it never uses your codex config.
- Replies are spoken only after the whole response arrives, as in upstream. Streaming into speech would feel faster, but isn't built.
- Ollama is not wired up.
- The panel says "Grant all four" and doesn't list Speech Recognition, which is requested on first hotkey press.
- A harmless `default.profraw` warning prints on exit from debug builds.

## Follow Along

A demo build on this base. `docs/demo/follow-along/DEMO.md` has the script, and `docs/demo/follow-along/evidence/README.md` says what was and wasn't verified.

```bash
scripts/demo-follow-along.sh           # preflight, Blender, lesson
scripts/demo-follow-along.sh --check   # setup and preflight only
```

`CLICKY_FOLLOW_ALONG_CHECK_MODEL` overrides the model that judges success checks, which defaults to `claude-haiku-5-5` for claude backends. It reuses the capture, Brain, overlay and speech seams above.

## What changed from upstream

- **Removed:** PostHog, which sent voice transcripts to the upstream author's project, and the FormSpark email post. The `ClickyAnalytics` calls remain as no-ops.
- **Disabled:** login item registration, so a scratch build doesn't start at every login, and first-run onboarding. "Watch Onboarding Again" in the panel still works, and it streams a remote video.
- **Left alone:** Sparkle is still linked but never started, because it didn't block the build. `ClaudeAPI`, `OpenAIAPI`, `ElevenLabsTTSClient`, `ElementLocationDetector`, the other transcription providers and `worker/` are all unused but still compile. `ElevenLabsTTSClient` conforms to `CompanionTextToSpeechClient`, so it can be swapped back in.
