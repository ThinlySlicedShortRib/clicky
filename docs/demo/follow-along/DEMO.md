# Follow Along: demo script

**The hook:** "I pasted a YouTube tutorial into Clicky and it taught me Blender."

**What it shows:** paste a link, and the blue cursor teaches that tutorial live inside the real app. When the 2019 video no longer matches Blender 5.2, Clicky notices, finds out what replaced the old control, and says so.

Length is about 90 seconds at 16:9. It's written for one person, on camera for the first and last lines, screen for the rest.

## Read this first

- **Permissions come first.** Nothing here has been filmed yet, because macOS permissions aren't granted. See "Before you shoot".
- **Clicky's lines below are real output from a real run, but they will change.** They're model-generated, so every take words them differently. Nothing is canned. Say your own lines as written and let Clicky's land as they do. If its line is weaker in a take, retake it. Don't dub it.
- **Read cost figures off your own screen.** The numbers in this doc come from a rehearsal, and the meter in your take will differ. Never quote a figure that isn't on screen in that take.
- **Use cuts, not speed-ups.** A full lesson runs about 3 to 4 minutes, so the 90 seconds comes from cutting between moments. If you do speed anything up, put "sped up" on screen.

## The story

| Time | On screen | You say |
|---|---|---|
| 0:00 | Face to camera, then hard cut to Blender | "I pasted a YouTube tutorial into Clicky and it taught me Blender." |
| 0:03 | The tutorial on YouTube, then its title and "2019" | "Here's the problem with learning from YouTube. I'm watching this tutorial from 2019, I've got Blender 5.2, and the buttons in the video don't exist any more." |
| 0:12 | Blender, then the paste pill appearing next to the cursor | "So I hit one shortcut, paste the link..." |
| 0:15 | Press return. "reading the transcript", then "writing your lesson" | "...and Clicky reads the whole video once and turns it into a lesson. Then it just teaches me, in the real app." |
| 0:21 | Cursor flies to Shading, the Add menu opens, Voronoi lands | *Let Clicky talk, then click along.* |
| 0:30 | You drag the wire. The cube turns to stained glass. | "I'm not watching anything. I'm doing it. It waits until it can see I've done each step, then moves on by itself." |
| 0:38 | Cursor sits on the node's Scale field | Hold ctrl+option: **"what does this do?"** Let Clicky answer. |
| 0:47 | **THE MAGIC MOMENT.** Cursor on the Voronoi node, voice over a quiet screen | *Say nothing. Let Clicky say it.* |
| 0:58 | Hold on your face or the cursor for one beat | "That wasn't scripted. It compared the video to my screen, saw the dropdown was gone, and worked out what replaced it." |
| 1:05 | The cost meter, full screen crop | "Now the part I'd actually worry about if I worked there. Here's what that lesson cost. Looking at my screen every second would've been about [the figure on your meter]. It only pays to look when the screen really changes." |
| 1:15 | End card | "And the lesson is saved, so the next person doing this tutorial starts with it already built." |
| 1:20 | Back to face | "You took Skills out and said they'd be back in a new form. I think this might be the form: every tutorial on YouTube is already a skill. Someone just has to teach it. I'd love to build this with you." |

Clicky's real lines from the rehearsal, for reference:

- **The magic moment (step 7):** "in the video you opened a dropdown that said intensity to pick cells. this version doesn't have it, and your cube already shows flat coloured cells, so there's nothing to open."
- **Second adaptation (step 10):** "the video's voronoi node has a grey fac output for a black and white result, but this version has distance, color and position outputs, and distance is the grey one."
- **Going off track:** "you're still in the layout workspace, so the node editor isn't open yet. click the shading tab at the top to switch over."
- **"what does this do?":** "the voronoi texture node makes a cellular pattern by scattering random points and measuring how far each spot is from its nearest one. that gives you cells, cracks, or stone-like shapes you can feed into things like color or roughness."

I confirmed the magic moment against Blender 5.2.2 directly: the Voronoi node has outputs `Distance, Color, Position, W, Radius`, and no coloring property. There's no `Fac` and no Intensity/Cells dropdown.

## Why this matters

- **Teaching ordinary people.** The internet already holds a tutorial for nearly everything, but tutorials go stale, and a beginner can't tell a renamed button from their own mistake. That's where people quit.
- **Cost per user.** The plan is built once, then cached, so the second person pays nothing for it. Screens are compared on the Mac for free, and only a real change reaches a model. Easy questions go to the cheapest model, and hard ones go to a stronger one.
- **Skills.** Upstream removed them and said they'd return in a new form. A lesson built from a video is a skill that nobody had to write.

## Shot list

Display set to 1512x982 or larger, recorded at 16:9. Crop the top and bottom in the edit if you record the full display.

| # | Shot | Exact actions |
|---|---|---|
| 1 | Face, hook | Record it last, when you know how the demo went. |
| 2 | The tutorial | Open https://www.youtube.com/watch?v=_deRNqDcwRk and show the title. Copy the link with command+C. Keep this shot short, and don't play the video with its sound on. |
| 3 | Paste | `scripts/demo-follow-along.sh --paste`. Move the mouse to the middle of Blender. Press command+shift+Y. Press command+V, then return. |
| 4 | Import | Delete the saved lesson first if you want the real progress text: `rm -rf ~/Library/Application\ Support/Clicky/follow-along/lessons/_deRNqDcwRk`. It takes about 1 to 2 minutes and costs about $0.15 to $0.20 estimated, so keep one take and cut it short. |
| 5 | The lesson | Follow Clicky. Click where the cursor sits. If the Voronoi node lands cut off, Clicky asks you to press Home. Do it, because it's part of the lesson. |
| 6 | Voice | At the drag or Scale step, hold ctrl+option and say "what does this do?", then let go. Then finish the step. |
| 7 | Magic moment | Don't touch anything while Clicky is speaking at step 7. |
| 8 | Meter | Bottom left of the screen. Crop it large in the edit. Make sure "est" stays readable. |
| 9 | End card | It appears when the last step passes. Hold for 3 seconds. |
| 10 | Face, ending | One take, looking at the lens. |

Cut-ins worth having: the wire landing as the cube changes, and the cursor's flight to the Voronoi node.

## Before you shoot

1. Quit the official HeyClicky app. It shares the ctrl+option hotkey, and its cursor would appear in your recording. The preflight warns about this.
2. Build once, then run `scripts/demo-follow-along.sh --check`. It lists exactly what's missing.
3. Grant, in System Settings > Privacy & Security, for the `Clicky.app` the script prints: Screen & System Audio Recording, then Accessibility. Microphone and Speech Recognition appear as prompts on the first hotkey press. Then run `--check` again until it says all four are granted and a real capture worked.
4. **Do one full lesson off camera first.** Everything below "What hasn't been seen" in `evidence/README.md` will be happening for the first time.
5. Optional, for a much better voice: System Settings > Accessibility > Spoken Content > System Voice > Manage Voices, then download a Premium or Enhanced English voice. Clicky picks it up automatically. The default is Samantha.

## Retake checklist

Retake if any of these happen:

- [ ] Clicky pointed at the wrong control, or anywhere you had to hunt for it.
- [ ] The magic moment was worded badly, or it didn't fire. It comes from a model, so it can vary. If step 7 says something inaccurate, retake it. **Never post a take where Clicky states something false about Blender.** A wrong answer in the rehearsal said the old dropdown became the `F1` dropdown. That's fixed, but check each take for it.
- [ ] The meter shows "cost not reported", which means a backend reported no cost.
- [ ] The word "est" was cut off or hidden.
- [ ] The lesson stalled for more than a few seconds with nothing happening. Saying "okay i did it" asks for a check. Saying "skip" moves on.
- [ ] A private folder, name, or notification is visible. The script opens Blender with an empty home folder so the file browser stays clean. If you reuse a Blender that was already open, check this.
- [ ] You can hear two voices, or see two cursors. HeyClicky is still running.
- [ ] Any figure you say doesn't match the screen in that same take.

## Credit and licence

- **Tutorial:** "Procedural Textures - Blender 2.80 Fundamentals", by the official Blender channel, uploaded 2019-07.
- **Link:** https://www.youtube.com/watch?v=_deRNqDcwRk
- **Licence:** YouTube lists it as "Creative Commons Attribution license (reuse allowed)". This is the metadata field read through yt-dlp on 2026-11-01. Check the video's page yourself before posting.
- **Public posting needs credit.** Attribution is a condition of that licence. Put the title, channel, link and licence in the video description, and on screen if any of the tutorial is visible. For any other tutorial, get the creator's permission.
- **Don't republish the video.** The app downloads a small copy to read it locally. That copy stays in `~/Library/Application Support/Clicky/follow-along`, and it isn't in this repo. Neither are its frames. Only keep a tutorial shot in your video if it's brief and credited.
- **Blender** is a trademark of the Blender Foundation. This demo isn't endorsed by them, or by HeyClicky.
