# Stuck: the demo

90 seconds, 16:9. For Farza, from someone who wants to work on Clicky.

**Before anything else:** a real offer in a real Blender session hasn't been seen yet. Everything leading to it has run, but do a full rehearsal before you plan a shoot. See "Not verified" in `docs/STUCK.md`.

## The story

You took proactive away because people felt watched. I built the version that can't watch: it's right about being stuck while knowing nothing about you, and you can check.

## The script

Spoken lines are mine. Silence is part of it, so don't talk over the drift. Read the receipt as it really is: if it says 4 undos, say four.

| Time | On screen | I say |
|---|---|---|
| 0:00 | Your face, or black with the quote in white: *"we'll bring it back when it feels magical without feeling watched."* | "You said you'd bring proactive back when it feels magical without feeling watched. I tried." |
| 0:05 | Blender. Grey cube, orange goal, "pull one corner out, like the goal". | "I've never used Blender. I want to pull out one corner. How hard can it be." |
| 0:12 | Click the cube, g, drag. The whole cube slides away. | "Okay. No." |
| 0:15 | cmd-z. Try again. Whole cube again. | "No." |
| 0:19 | cmd-z. Again. Label on screen: **2x**. | "That's the whole cube again." |
| 0:24 | cmd-z. Again. Label stays. | "Why is it the whole cube." |
| 0:30 | cmd-z. Stop. Hands off. | *(nothing)* |
| 0:32 | The blue cursor drifts over, no sound. "want a hand?" appears. | *(nothing, a full three seconds)* |
| 0:36 | Move onto the pill to hold it. Zoom to the receipt. | "No sound. It didn't take my focus. And it hasn't seen my screen." |
| 0:41 | Hold on the receipt lines. | "This is everything it knows. Five undos. Some clicks. Which keys, it doesn't know. In two minutes this is gone." |
| 0:49 | Back to the pill. Click **yes**. Blue flash, chip: "1 screenshot, just this once, going to anthropic". | "Now it asks. One screenshot, and it tells me where that's going." |
| 0:55 | Spinner, then the cursor flies to Object Mode. Its real voice plays. | *(let it talk)* |
| 1:04 | Press tab. Click a corner. g. Drag. The corner comes out. | "Oh. That's so good." |
| 1:09 | Terminal, the `scripts/prove-privacy.sh` output, zoom to the PASS line. | "And you don't have to trust me. Zero sockets. Zero files written. Real tools, real events, run while I was flailing." |
| 1:18 | Back to the receipt. Click **forget now**. Lines vanish. | "And it forgets on command." |
| 1:21 | Back to your face. | "Say no twice and it leaves you alone. You said some people felt watched. This one can't watch. I'd love to build the real one with you." |
| 1:30 | End. | |

## Shots

Run this first. It preflights permissions, opens the scene, and starts Clicky with Stuck on and the receipt up:

```bash
scripts/demo-stuck.sh
```

Add `--consent-on-camera` to flip the switch on screen.

**1. Hook.** Camera, or the quote on black. Keep it under 5 seconds.

**2. The flail.** One unbroken real take, sped up 2x in the middle and labelled. Screen record at 1512x982 or above.

Loop this 5 times, about 7 seconds each:

1. Click the grey cube.
2. Press g.
3. Move the mouse in a circle for 2 seconds.
4. Click to confirm.
5. Wait 2 seconds.
6. Press cmd-z.
7. Wait 2 seconds.

Then take your hands off the keyboard and mouse. The offer fires at the first quiet moment, usually after 4 or 5 undos, about 40 seconds in. Watch the receipt's score bar. If it stalls, keep looping.

The rules that matter: undos must be at least 2.5s apart, with an attempt between them, and no more than 18s apart. Don't hit undo twice quickly, and don't type.

**3. The offer.** Real time, no cuts, no music. Rest your cursor on the pill to hold it, because hovering pauses the 7 second countdown.

**4. The receipt.** It's at the top right. Zoom in post so the lines read at phone size.

**5. Yes.** Click **yes**. The flash lasts under a second and the chip about 3.5 seconds, so don't cut early.

**6. The fix.** Follow what it said: tab with the cursor over the viewport, click a corner, g, drag, click.

**7. The proof.** Record it during a flail, not after, with a terminal off to the side. Use real output:

```bash
scripts/prove-privacy.sh --seconds 30
```

It needs real input to pass, so do the flail loop while it runs. It launches its own Clicky if none is running. Add `sudo` for fs_usage if you'd like that on screen.

**8. Forget.** Click **forget now** on a full receipt.

**9. End.** Camera.

## Retake checklist

Before every take:

- [ ] Run `scripts/demo-stuck.sh`. It clears the cooldown and anything declining taught it. If you say nah, it won't offer again that take.
- [ ] Close everything private. **The yes sends the whole display to Anthropic.**
- [ ] Do Not Disturb on. Dock hidden.
- [ ] Volume up, because `say` is the voice.
- [ ] Blender frontmost, and the receipt not covering the top left of Blender.
- [ ] `claude` is logged in.
- [ ] Receipt says "noticing timing, nothing else". If it's red, a permission is missing.

If something goes wrong:

| Problem | Fix |
|---|---|
| No offer after 8 undos | Check the receipt. If "typing steadily" appears you pressed too many keys. If undos are being counted but the score is low, slow down to 7 seconds a loop. |
| Offer vanished before I got there | Rest on the pill sooner, or rerun the script |
| Offer fired early | Fine, keep it. It's real. |
| Cursor points at the wrong thing | Retake. In testing it pointed right 10 of 10, on Blender's own export rather than a real capture. |
| "I can't see your screen yet" | Screen Recording is off, or Clicky needs relaunching |
| Proof says PASS ON IDLE ONLY | You didn't move. Run it during a flail. |
| Long pause after yes | First text took 2.8 to 4.1s in testing. Cut the wait, and label the cut. |

## Keeping it honest

- Don't cut the flail so it looks like the offer came faster than it did. If you speed it up, label it.
- Don't re-record the voice or the reply.
- Don't say "nothing leaves your Mac" over the yes shot. One screenshot does, and that's the point of the chip.
- The precision numbers are synthetic. If you quote them, say so.
- The scene's "goal" shape is there so the model can see the task. It's a fair setup, but don't imply Clicky guessed your intent from nothing.
