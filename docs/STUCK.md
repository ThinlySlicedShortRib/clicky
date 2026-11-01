# Stuck

Clicky notices you're stuck and gently offers help. Nothing about you leaves your Mac, and it never takes a screenshot until you say yes.

It's off by default. Results here are from 2026-11-01 on the machine described in `docs/FOUNDATION.md`. The proof behind each one is in `docs/demo/stuck/evidence/`.

## What happens

1. You turn it on by agreeing to one sentence in the menu bar panel.
2. A listen-only event tap reduces input to timing and counts, held in memory for 2 minutes.
3. When the score crosses the threshold, the blue cursor drifts over with no sound. A tiny "want a hand?" appears, and leaves by itself after 7 seconds. Hovering pauses that. It never takes focus.
4. **nah** raises the threshold. Ignoring it raises it a little.
5. **yes** takes one screenshot of one display, with a blue flash and a chip saying where it's going. Normal Clicky help follows, with the cursor pointing at the answer.

## What it knows

An event has a category, a monotonic time, and for clicks and movement a 160pt tile. Nothing else exists to store: `StuckBehaviourEvent` has no string field, and `stuck-harness checks` verifies that by reflection.

| Input | What's kept |
|---|---|
| cmd-z or ctrl-z | "undo" |
| shift-cmd-z | "redo" |
| escape | "cancel" |
| tab | "tab press" |
| any other key | "other key press". The key is gone. |
| held keys | nothing, autorepeat is dropped |
| click | "click", plus the 160pt tile |
| mouse movement | per second: distance and which tiles |
| scroll | "scroll tick" |
| frontmost app | "went to a browser" or "came back" only |

**The honest part about the tap:** a keyboard tap necessarily *receives* every key press. `StuckEventClassifier` reads the key code to recognise exactly z, tab and escape, then discards it. Nothing keeps it, but no design can make a keyboard tap not see the key. Secure input, such as password fields, is hidden from the tap by macOS.

The bundle ID of the frontmost app is compared against a list of browsers and dropped.

Three values are saved in UserDefaults: whether Stuck is on, whether answers are local, and how far declining has raised the threshold. No behaviour is ever saved.

## The receipt

Right-click the menu bar icon, or use the panel. It lists everything in memory, each line with its time until wipe. It's built only from the detector's own arrays, and the harness checks that it accounts for every retained item.

It also shows numbers from the kernel, not from a promise: open internet sockets, bytes written since Stuck went on, and screenshots taken. **forget now** empties memory.

## How the score works

The score is a plain sum of named lines, shown on the receipt. All numbers are in `StuckScoringModel`.

| Signal | Points | Why |
|---|---|---|
| Undo loop | 22 per repeat, max 66 | Undos at least 2.5s apart, with an attempt between them, no more than 18s apart. Time in a browser doesn't break a loop. |
| Cancel loop | 18 per repeat, max 72 | Escapes at least 1.5s apart |
| Flipping back and forth | 12 per tab after 2, max 48 | Within 30s |
| Returning to one spot | 14 per return after 1, max 72 | Counted per tile. This is how repeatedly opening a menu shows up, because the tap can't see menus inside apps like Blender. |
| Restless cursor | 2.5 per second, max 30 | At least 5s of movement with no click or key, in 6 tiles or fewer |
| Stillness after activity | 15 to 30 | 8 to 40s still after at least 6 actions. Longer reads as walking away. |
| Browser and back | 18 per trip, max 36 | Away for 60s or less |

| Flow penalty | Points |
|---|---|
| Typing, past 12 keys in 30s | -1.5 per key, max -80 |
| New screen areas, past 4 in 30s | -8 per area, max -40 |
| Drags, past 3 in 30s | -6 per drag, max -36 |
| 20 or more scroll ticks in 30s | -12 |
| Redo | -15 each, max -30. Undo and redo together is comparing, not flailing. |

**An offer needs all of these:**

- Score at or above the threshold (100 by default) on 2 readings in a row
- At least 2 different signals
- At least 1 strong signal: undo, cancel, flipping or returning. Stillness, restlessness and browser trips alone never fire.
- 1.2s since the last key or click, so it never interrupts mid-action
- Clicky isn't already listening or talking
- 120s since the last offer, or 300s since the last decline

**Learning:** a decline multiplies the threshold by 1.4, ignoring by 1.12, and a yes divides by 1.2. Four declines exceed the highest possible score (354), so offers stop until you reset it on the receipt.

## Results

All of this is **synthetic**. Traces are hand-written models of behaviour from `stuck-harness/TraceGenerators.swift`, and nobody has been measured. Numbers were tuned on one seed set and scored once on seeds and a noise level the tuning never saw.

```bash
scripts/stuck-harness.sh evaluate
scripts/stuck-harness.sh checks
```

| Held-out, 300 seeds per scenario | Result |
|---|---|
| Precision | **99.6%** (95% CI 99.1 to 99.8), 6 false offers |
| Recall, excluding 2 deliberately hard scenarios | **81.1%** |
| Recall, all stuck scenarios | **60.8%** (95% CI 58.9 to 62.8) |
| False offers in 200 busy hours | 25, so **0.125 per hour** |

Tuning set for comparison: 99.4% precision, 61.1% recall.

Precision depends on how many stuck traces are in the set, which is arbitrary, so false offers per hour is the more useful figure.

Recall is weak on purpose. It's 98% for an undo loop, but 46% for flipping a mode and 65% for clicking one control, and 0% for both hard scenarios: someone frozen, staring at the screen, is invisible to a behaviour-only detector. Threshold 100 sits on a knee: at 80, precision drops to 89.4%.

After 1 decline, 14.9% of obvious stuck traces still get an offer. After 2, none do. So in practice it goes quiet after two declines, sooner than the four the formula needs.

**A small real sample.** A shadow run used the real tap and detector on real use of this Mac, with no UI, for 280 seconds: 2,367 events, peak score 30, 0 offers. It's short, unlabelled, and contained no undos, so it's a sanity check and not a measurement.

## Privacy proof

```bash
scripts/prove-privacy.sh            # move the mouse and press keys while it runs
sudo scripts/prove-privacy.sh       # adds fs_usage
```

It measures from outside the app with lsof, nettop, the kernel's `proc_pid_rusage` write counters and a sweep of `~/Library`, which catches writes a daemon makes on the app's behalf. It first runs a negative control, a child that really writes and connects, because a zero means nothing unless the instrument can read non-zero. It asks the running app how many events it handled, and refuses a full pass if that was 0.

The best run so far had 389 real events: 0 sockets, 0 bytes on the network, 0 logical writes, 0 files changed. The control read 1 socket and about 2MB. `fs_usage` needs root and has not been run.

The proof covers detection only. Saying yes opens a connection, by design.

## What leaves the Mac

Saying yes sends these to the model provider, and only these:

- 1 screenshot of the display the cursor is on
- The receipt lines at that moment, such as "5 undos in 31s"

With the default Brain that's Anthropic, through the claude CLI, and the pill and the chip both say so. The receipt lines are then wiped, and conversation history stores a placeholder rather than the lines, so they can't outlive the 2 minutes on this Mac.

Holding ctrl+option still works as it always did: a screenshot of every display, sent to the normal Brain.

## Local mode

The panel's "answer on this mac" switch uses `OllamaBrain`, which only ever talks to `127.0.0.1`. Any model is `BrainModel=ollama:<model>`, or `CLICKY_STUCK_LOCAL_BRAIN` for Stuck alone.

Measured through the app with the real help prompt and a Blender frame. Cold means the model was unloaded first, with its files already in the OS cache. Every other run used a different image.

| Model | Accepts images | Cold first text | First text, median (range) | Total, median | Said "edit mode" | Pointed at the target |
|---|---|---|---|---|---|---|
| `qwen3.6:35b-a3b` | Yes | 11.07s | **2.15s** (2.14 to 2.34) | 3.05s | 10 of 10 | **1 of 10** |
| `qwen3.6:27b-q8_0` | Yes | 14.73s | 7.84s (7.68 to 8.12) | 14.13s | 10 of 10 | 0 of 10 |
| `qwen2.5:14b` | No, HTTP 400 | | | | | |
| `claude-sonnet-5-5`, for comparison | Yes | | 3.60s (2.77 to 4.05) | 5.18s | 10 of 10 | **10 of 10** |

So `qwen3.6:35b-a3b` is the default local model: once loaded it's faster than the cloud, and it gets the diagnosis right, but it can't be trusted to point. Use it to keep the screenshot on your Mac, and use Claude for the demo.

Identical repeat requests measured 0.1s to first text. That's ollama's prompt cache and says nothing about real use, so those runs were discarded.

## Permissions

Stuck needs Input Monitoring or Accessibility for the tap, and Screen Recording for the screenshot on yes.

**`tapCreate` succeeds without permission.** macOS returns a tap, then disables it and removes `keyDown` from its mask: requested `4195582`, reported `4194558`. Checking the return value would show "working" while seeing nothing, so health comes from `CGGetEventTapList`.

```bash
scripts/headless.sh --headless-stuck-tap-check
```

## Scripted checks

These exit the app when done, and any result without real detection behind it says `"scripted": true`.

| Command | Purpose |
|---|---|
| `--headless-stuck-tap-check` | Installs the real tap and reads it back from the system |
| `--headless-stuck-status` | Asks a running Clicky for its counts over Mach IPC |
| `--headless-stuck-shadow <seconds>` | Real tap and detector with no UI. Prints totals at the end. |
| `--headless-stuck-offer --answer yes\|no\|none` | Runs a real offer through the real overlay and panel. `yes` requires `--image`, so a scripted run never takes a real screenshot. `--frames-dir` records frames. |
| `--headless-stuck-receipt-render <png>` | Draws the real receipt |
| `--headless-stuck-consent-render <png>` | Draws the real panel |
| `--headless-point --stuck-prompt --receipt-lines "a\|b"` | Judges the real help prompt |

```bash
scripts/verify_stuck_help.py --runs 10
scripts/verify_stuck_help.py --model ollama:qwen3.6:35b-a3b --real-capture --runs 3
```

`--real-capture` photographs your display, so `verify_stuck_help.py` refuses it with a cloud model unless you add `--allow-cloud-capture`.

Frames come from the app's views drawing themselves, composited over a Blender frame. They show what the code renders, not what reached the display.

Demo honesty: traces are outside the app target, and `prove-privacy.sh` checks the binary contains none. The demo path passes only `--enable-stuck` and `--show-stuck-receipt`, neither of which can inject an event. `--enable-stuck` lasts one launch and saves nothing.

## Not verified

- **An offer firing from real events in a real Blender session.** Every piece has run, but never that whole chain at once: the tap has seen real input, the detector has fired on synthetic traces, and the offer has run when scripted. The first rehearsal is that test.
- **A real click on yes or nah.** The panel accepts first clicks and the answer paths ran, but they were called directly.
- **A yes using a real capture with Claude.** Real capture ran with the local model only, to avoid sending a live display to the cloud. Claude's 10 of 10 used Blender's export.
- **`fs_usage`,** which needs root.
- **Anyone looking at the animation on a real display.** Frames came from the views themselves.
- **Multiple displays.** Only one was attached.

## Known limits

- Stuck itself can only take a screenshot on a yes, but Clicky as a whole has two other routes: the ctrl+option hotkey, and upstream's onboarding demo, which takes one 40 seconds into "Watch Onboarding Again". Onboarding is off by default and only runs if you click that link. The panel's wording doesn't mention it.
- The detector has only ever been tuned on synthetic traces, so expect real numbers to differ.
- The tile grid means two controls within 160pt count as one spot.
- A real capture includes everything on that display, which is why the yes step says what it's about to do.
- A single undo press in a terminal, ctrl-z, counts as an undo.
