# Show Me Once: demo

Anyone who knows how to do something on their computer does it once while talking. Clicky turns that into a living lesson that anyone else can follow on their own Mac, with the blue cursor and the teacher's own words.

**Format:** about 90 seconds, 16:9, one take per scene.
**Task:** turning a list of what a family spent into a chart in Numbers. It's a real job, it ends in something you can see, and it's 3 clicks and a drag.
**Follower:** [person], a real non-technical person. Swap every `[person]` below for who it really is, and use their real relationship: "my mum", "my grandad". Change "them" to fit.

Before filming, read [What has and hasn't been tested](#what-has-and-hasnt-been-tested). No part of this has been run live in Numbers yet.

## The story

Spoken lines are mine, unless marked as [person] or Clicky. Clicky's lines aren't scripted: they come from my real teaching take, so the line shown here is a stand-in for whatever I really said.

| Time | On screen | Spoken |
|---|---|---|
| 0:00 | [person] at their Mac. The blue cursor lands on Numbers' Chart button. Close on their face. | "My [person] can't do this. I showed Clicky once. Now it teaches them." |
| 0:04 | My screen, the list of spending. | "Every month [person] asks me how to turn this into a chart. Every month I explain it. And I never explain it the same way twice." |
| 0:12 | I press control shift T. The pill appears: "clicky is watching, because you asked". | "So this time I'm just going to do it once, and talk." |
| 0:16 | I do the task for real, in real time. Select, Chart, pick the chart, drag it clear. | "Grab everything from the top of the list down to the last number. Then up here, Chart. I always pick this one, it's the easiest to read. Then drag it out of the way so you can still see your list." |
| 0:30 | I press control shift T. "turning that into a lesson..." then the share card appears. Hold on it. | "I didn't write anything. That's the whole lesson. It's [size off the card], and it costs [cost off the card] to replay, estimated." |
| 0:37 | I drag the `.clicky` file into a message to [person]. Cut to their Mac. The file arrives. | "So I send it to [person]." |
| 0:41 | Wide on their screen. A different spreadsheet, a smaller window, dark mode. Let it sit for a beat. | "This isn't my spreadsheet. Different columns, more rows, smaller window, dark mode. Clicky has never seen any of it." |
| 0:47 | [person] double-clicks the file. The cursor flies to the top of their list. | Clicky, in my voice: "Grab everything from the top of the list down to the last number." |
| 0:54 | [person] drags the selection. Clicky sees it and moves on, without anyone touching anything. The cursor flies to Chart. | Clicky: "Then up here, Chart." |
| 1:00 | [person] holds control option and asks. The cursor waits. | [person]: "Why do I pick that one?" |
| 1:03 | Clicky answers. | Clicky: an answer built from what I said while teaching. |
| 1:09 | [person] picks the chart. It appears, full of their own numbers. Close on the chart, then on [person]. | Whatever [person] really says. Don't script this. Keep it even if it's small. |
| 1:15 | Black, or a plain title. Quote on screen: "We've removed Skills for now... we plan to bring them back in a new form." | "Farza, you shipped skill files for 89 apps, then took them down. I think this is the new form. Nobody writes anything. The people who already know how to do something just show it, once, in their own words." |
| 1:26 | [person]'s chart, full screen. | "Everyone has a [person]. And everyone is somebody's expert." |
| 1:30 | End. | |

Spoken words total about 190, which fits 90 seconds with room to breathe. If it runs long, cut the 0:04 line down first, not the 0:41 pause. That pause is what proves the claim.

## Shot list

Two Macs are ideal: mine for teaching, and [person]'s for following. On one Mac, use a second macOS user or change the setup between scenes, and don't call it a different computer in the film.

Set up first, on each Mac that's filmed:

```bash
CLICKY_TEACHER_NAME=<my first name> scripts/demo-show-me-once.sh
```

It builds, registers `.clicky` files with this build, copies both CSVs to `~/Library/Application Support/Clicky/Demo`, and asks for every permission at once. Grant them, and run it again until it says `Ready`.

### Scene 1: the cold open (0:00)

Film this last. It's the same moment as scene 5, shot on a phone from over [person]'s shoulder.

### Scene 2: teaching (0:12 to 0:30)

1. `CLICKY_TEACHER_NAME=<my first name> scripts/demo-show-me-once.sh --teach`. Numbers opens `teacher-october-spending.csv`, and Clicky starts.
2. Start the screen recording. Move the pointer to the middle of the window.
3. Press **control + shift + t**. Wait for the pill. Starting with a word before the first click helps the opening line.
4. Saying the line as you do each thing, because narration attaches to the action it's said around:
   - Press on the first category cell, drag to the last amount, and let go.
   - Click **Chart** in the toolbar.
   - Click a chart in the picker. Stay on the 2D tab.
   - Drag the chart clear of the table.
5. Say a reason out loud at some point, such as why that chart. That's what the follower's question gets answered from.
6. Say a sign-off, then press **control + shift + t**.
7. Wait for the card. Don't touch it. Stop recording after 3 seconds.

### Scene 3: sending it (0:37)

Press **show file** on the card. The lesson is in `~/Library/Application Support/Clicky/Lessons`. Drag it into Messages or an email to [person]. Film the real send.

### Scene 4: the different setup (0:41)

On [person]'s Mac:

1. Set dark mode in System Settings > Appearance. Whichever the teaching take used, use the opposite.
2. `scripts/demo-show-me-once.sh --follow <path to lesson>` once as a rehearsal, then close the document without saving.
3. For the take: `open -a "Numbers Creator Studio" ~/Library/Application\ Support/Clicky/Demo/follower-household-bills.csv`.
4. Drag the window smaller, to about two thirds of the screen. Keep the toolbar's Chart button visible.

### Scene 5: following (0:47 to 1:15)

1. Start the recording, and start a phone on [person]'s face.
2. [person] double-clicks the `.clicky` file.
3. Hands off. [person] does everything. Nobody gives a hint off camera.
4. Partway through, at the Chart step, [person] holds **control + option**, asks a real question, and lets go.
5. When the chart appears, keep rolling for 5 more seconds.

### Scene 6: the close (1:15)

Record the voiceover separately, and lay it over the quote and the chart.

## Retake checklist

Before every take:

- [ ] `scripts/demo-show-me-once.sh --no-prompts` says `Ready`, with no permissions missing.
- [ ] Do Not Disturb on. Dock hidden. Desktop clear. Other apps quit.
- [ ] The filmed screen is 16:9. A 1512x982 MacBook isn't, so use an external 1920x1080 display, or record a 1512x850 region with the menu bar and toolbar inside it.
- [ ] Mic checked by saying one sentence into a test teach. A failed start shows in the Clicky panel.
- [ ] Numbers has only the demo document open.

Redo the take if:

- [ ] The card has an orange "synthetic" line. That lesson is a test file and can't be used.
- [ ] The card says "replay cost not measured yet". Say the size only, and cut the cost words.
- [ ] A spoken line has lost my words. Check `spokenLineSource` in the lesson. Anything other than `teacherWords` or `teacherNarrationFallback` wasn't said by me.
- [ ] The voice changes partway through a step. It means the line had to be reworded for that screen. That's correct behaviour, but if it sounds wrong, reteach without naming anything specific to my document, like "rent".
- [ ] The cursor pointed at the wrong thing, or the lesson moved on early. Don't cut around it. Find out why first, because the film's whole claim is that this works.
- [ ] [person] was helped, even once.

Between takes:

- [ ] Close the follower document without saving, so the next take starts clean. The CSV on disk doesn't change.
- [ ] Use the same lesson file for every follow take. Each finished run adds its real cost to that file, so the card's number can change. Only say a number that's on the card in that take.

Honesty, on every take:

- [ ] Every number said on film is read off a real card. The cost is always called estimated.
- [ ] Nothing is sped up, cut around, or staged without saying so. Trimming a pause is fine. Hiding a failed step is not.
- [ ] Never use the synthetic Blender lesson in the film.

## What has and hasn't been tested

The evidence is in [`evidence/`](evidence/). See [`evidence/README.md`](evidence/README.md) for the numbers and how they were produced.

**Not run yet, because macOS permissions block it:** live teach mode, live follow mode, the push-to-talk question, real ScreenCaptureKit capture, and anything inside Numbers. I also couldn't open Numbers' UI at all, so its layout here comes from its own bundled text and from general knowledge of the app. Treat the steps in scene 2 as a plan. If Numbers behaves differently, follow what it really does: the lesson learns from the take, not from this file.

**First thing to do after granting permissions:** one full private dry run of scenes 2, 4 and 5, then `scripts/demo-show-me-once.sh --check-pointing` with Numbers in front. If anything fails, fix that before setting up a camera.
