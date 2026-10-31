# Follow Along evidence

Everything here came from real runs on 2026-11-01: an M5 Pro MacBook, 1512x982 display, Blender 5.2.2 LTS, `claude-sonnet-5-5` for planning and locating, `claude-haiku-5-5` for success checks. Costs are the claude CLI's own list-price estimates (`total_cost_usd`), not billed amounts.

**No macOS permissions were granted for Screen Recording, Accessibility or Microphone, so nothing here is a real on-screen run.** Read "What hasn't been seen" before relying on any of it.

## How the rehearsal works

`scripts/rehearse_follow_along.py` drives the app's real lesson runner against a real Blender window.

**Real:** Blender 5.2's UI, the lesson from the real pipeline, every model call, parsing, coordinate mapping, the change gate, the cost figures, and the `say` voice in the full run.

**Standing in:**

- **The screen.** Blender exports its own window, and that frame is placed where the window server says the window is. ScreenCaptureKit isn't used. Every run's `captureSourceDescription` says so.
- **The student.** A script with no Blender knowledge does what each step says, at exactly the point Clicky flew to, using Blender's `event_simulate`. A wrong point really does miss, which happened during development and failed the step. It's more precise than a person, and it has no judgement.
- **The words.** "what does this do?" and the other lines arrive as finished transcripts, through the same call push-to-talk uses. The hotkey, microphone and Apple Speech aren't involved.

Blender's own state is read after each passed step, so results don't rest on a model's opinion. See `run-full/blender-state-after-each-step.json`.

The rehearsal can't be reached from the demo path. `FollowAlongCoordinator.startLesson` always uses `FollowAlongScreenCaptureSource`. Launching the real path with no Screen Recording was tested: the lesson stopped at step 1 with the permission error, after 0 model calls, and it never fell back to a fixture.

## Files

| Path | What it is |
|---|---|
| `lesson.json` | The generated lesson, exactly as the app saved it |
| `run-full/run-transcript.md` | Readable transcript of the full run |
| `run-full/events.jsonl` | The app's own event log for that run |
| `run-full/summary.json` | Every `BrainUsage` value from that run |
| `run-full/blender-state-after-each-step.json` | Blender's ground truth |
| `run-full/images/` | The frames the model saw. The blue box is where the cursor pointed, drawn afterwards. |
| `run-warm-repeat/` | The same lesson run again with the location cache warm |
| `reliability/` | Summaries of the other runs in the table below |
| `surfaces/` | The real SwiftUI paste pill, meter and end card, drawn to PNG from the full run's summary |

The tutorial's frames and video aren't in this repo.

## The full run

Commit `0876abf`, cold location cache, real `say` voice. All 10 steps passed.

It covered:

- **Wrong turn.** The student left for the Layout workspace on purpose. Clicky said: "looks like you're still in the layout workspace. click the shading tab at the top to get to the node editor."
- **Question.** "what does this do?" got a correct answer about the Voronoi node, then a reminder to finish dropping it.
- **"wait, go back".** Returned to the scale step, then "okay i did it" confirmed it and moved forward. Understood locally, at no cost.
- **Two real interface adaptations**, below.
- **Second opinion.** Haiku said "not yet" on a finished step, and the stronger model corrected it.

Blender's final state: `Voronoi Texture.Color -> Principled BSDF.Base Color`, `Voronoi Texture.Distance -> Principled BSDF.Roughness`, scale `10.0`.

### The magic moment

Neither line is scripted. Both were generated in that run:

> in the video you opened the intensity dropdown to pick how the cells are coloured. this version doesn't have it, and your cube already shows coloured cells from the color output, so there's nothing to open here.

> in the video you'd drag from the fac dot, but this version calls that output distance. drag from the distance dot at the top of the voronoi node to the roughness dot on the shader.

These are correct for Blender 5.2.2. Checked directly: the Voronoi node's outputs are `Distance, Color, Position, W, Radius`, and it has no coloring property and no `Fac`.

## Cost

| | Clean lesson, cold cache | Full run | Warm repeat |
|---|---|---|---|
| Time | 181s to 182s | 273s | 195s |
| Model calls | 19 | 27 | 17 |
| Screens looked at / sent | 58 / 19 | 84 / 27 | 72 / 17 |
| Steps reused from location cache | 0 | 1 | 4 |
| **Cost, estimated** | **$0.143 to $0.162** | **$0.227** | **$0.113** |
| Looking every second, same model, estimated | $2.29 to $2.37 | $3.49 | $2.42 |
| Looking every second, cheapest model, estimated | $0.10 to $0.12 | $0.13 | $0.09 |

Building the lesson costs **$0.205 estimated** once per video, and then nobody pays it again: $0.048 for the transcript pass and $0.157 for the key frame pass. It took about 2 minutes. Earlier versions of the lesson cost another $0.27 or so while I tuned the prompts, and that isn't in these figures.

**How the comparison is calculated.** "Same model" is the lesson's seconds times its real mean cost per locate call, so one model does everything once a second. "Cheapest model" is the same seconds at Haiku's real mean cost per check.

**The comparison has limits, and they matter:**

- The like-for-like figure is about 15 times higher for a clean lesson. That's an estimate of a design nobody built.
- **The cheapest-model figure is lower than what Clicky actually spent.** Haiku looking once a second would cost less than this lesson. It wouldn't do the job, because it can't reliably locate controls or find the way back from a wrong turn, as development showed. But "15 times cheaper" alone isn't the whole picture, so the end card prints both.
- A warm cache helps less than I hoped. Steps 1 to 4 reuse their locations, but the node lands somewhere new each run, so later steps need fresh locates. The large saving is the plan, not the location cache.
- A logged-in subscription may not be charged per token at all.

## Reliability

Ten complete lessons on the last three commits. Nine finished. Earlier runs aren't counted, since the code was still changing to fix what they found.

| Run | Commit | Scenario | Result | Time | Cost, est |
|---|---|---|---|---|---|
| `final-full` | `7a53d43` | Full | 10 of 10 | 265s | $0.298 |
| `final-warm` | `7a53d43` | Clean, warm | 10 of 10 | 171s | $0.161 |
| `final-cold-1` | `7a53d43` | Clean, cold | **Stalled at step 10** | 368s | $0.235 |
| `final-cold-2` | `7a53d43` | Clean, cold | 10 of 10 | 181s | $0.145 |
| `final-cold-3` | `7a53d43` | Clean, cold | 10 of 10 | 181s | $0.162 |
| `final-cold-4` | `7a53d43` | Clean, cold | 10 of 10 | 182s | $0.143 |
| Full, log not kept | `6fb22c8` | Full | 10 of 10 | 259s | $0.208 |
| Warm, log not kept | `6fb22c8` | Clean, warm | 10 of 10 | 212s | $0.175 |
| `ev-full` | `0876abf` | Full | 10 of 10 | 273s | $0.227 |
| `ev-warm` | `0876abf` | Clean, warm | 10 of 10 | 195s | $0.113 |

**The stall:** the student had done everything right, and Blender confirmed every link. The node had landed far from the others, so zooming to fit made the controls tiny, and both models misread a finished link. The final student never says "skip", so the run stopped there. Since then Clicky says it can't tell and offers skip, but that line hasn't fired in any run yet.

## What hasn't been seen

**None of these have ever run for real. They need permissions, a person, or both.**

- **Real screen capture during a lesson.** ScreenCaptureKit has never supplied a frame to the runner. One run of the real path stopped at the permission error, as designed.
- **Push-to-talk during a lesson.** The hotkey, the microphone and Apple Speech were never involved. Voice routing is only tested from a finished transcript.
- **The cursor flying, seen by anyone.** The overlay ran during rehearsals, but no pixels were captured, and these runs didn't record where it landed. The blue boxes in the images show the target, not a capture of the cursor.
- **The paste flow.** The pill has only been drawn to PNG. Typing, command+V, return, and command+shift+Y have never run in a live window. Only the clipboard-to-field logic is tested, through a self-test. The fix for a menu bar app having no Edit menu is untested live.
- **The meter and end card as real windows.** They've only been drawn as images, so their position on screen, and the Done button, are unseen.
- **The voice.** `say` ran in the full run, but nobody listened. The clean runs were muted.
- **A real person.** The student clicks perfectly and has no judgement. A human will move the mouse, hesitate and misclick. Expect surprises on the first real run.

## Known problems

- **Model output varies.** The wording, and where the node gets dropped, change every run. One rehearsal said the old dropdown became the `F1` dropdown, which is wrong. The prompt now rules that out, and it didn't recur in the last ten runs, but check every take.
- **Very small controls are a real limit.** At a far zoom a click can land one row off, and a finished step can be misread. Pointing works on a 1280px image, so tiny UI suffers.
- **Haiku's labels aren't stable.** It sometimes says "not yet" when the student has left the step entirely. A free local check catches that: if a fifth of the screen changed and the step isn't done, Clicky re-locates.
- **Repeat runs on a real screen start cold.** Location cache entries from rehearsals won't match a real screen, so the first real run costs like a cold one.
- **One display only.** Lessons use the screen the cursor is on.
- **Importing depends on YouTube.** Subtitle requests hit a 429 once, and the importer retries. A video with no English captions can't be imported.
