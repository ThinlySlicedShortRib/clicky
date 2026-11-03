# Journey

A running log of what I tried, what I learned, and where this fork is going. The newest entry is at the bottom.

## How I'm thinking about this

- **Find a real problem before writing code.** I started by looking at what the people behind Clicky care about and who uses it, then looked for gaps.
- **Don't rebuild what already exists.** My first three features were solid, but a full read of the HeyClicky changelog showed that some of them overlapped with things already shipped or tried. So I changed the rule: build only what the product doesn't have, and stay in line with where it's going and who it's for.
- **Plan before building.** From then on, I planned ideas before any code was written.
- **Try the risky idea fast, then let it go.** "What if my phone is the camera and the laptop does the thinking?" became Clicky Eyes. It worked in a test host but not reliably in the real app, so I dropped it rather than force it.
- **Pick a specific use case I actually live.** A general assistant is vague. I considered League of Legends, then chose music, because I already sing covers in Logic Pro and know where beginners get stuck.
- **The user leads, the assistant follows.** I decided Clicky shouldn't judge my singing. The user says what they want, like "add autotune" or "put it in a room", and Clicky shows them how.
- **Teach, but also do.** Learners need proper lessons, but sometimes you just want something done. That's why there are three modes, and Clicky saves a backup copy of the project before it changes anything.
- **Think in outcomes, not features.** The goal became a course that ends with a song you can publish: from "what song are you feeling?" to release.
- **Use the most accurate tool for each job, and have a fallback.** First screenshots. Then Logic's own state through Accessibility, for accuracy. Then community MCP servers as a check when Clicky isn't accurate enough, after reviewing them before trusting them.
- **Use AI where it's strongest, and respect rights.** Claude teaches and plans, Logic's built-in AI makes the music, and music models like ElevenLabs are optional. Rights get flagged early, so "publishable" really means publishable.

## Log

1. **2026-10-31: a keyless foundation.** Upstream Clicky now builds and runs with no API keys and no human in the loop.
   - It uses the `claude` CLI, with `codex` as an alternative.
   - It listens with Apple Speech and speaks with `say`.
   - Headless checks cover it.
   - Measured time to first text: 1.57 s median for claude, 3.79 s for codex.
   - Details are in [FOUNDATION.md](FOUNDATION.md).
2. **2026-11-01: three tutor features.**
   - Follow Along (`follow-along`) turns a YouTube tutorial into a live lesson that waits for you. On Blender, 9 of 10 rehearsal lessons were completed.
   - Show Me Once (`show-me-once`) lets you teach a task once, and Clicky replays it as a lesson.
   - Stuck (`stuck`) detects when you're stuck from your behaviour alone, and runs entirely on your Mac.
   - Each branch has its own docs with measured results.
3. **Lesson: read the changelog first.** Several ideas overlapped with things HeyClicky had shipped or tried, such as proactive help, which later became Suggestions. New rule: build what the product doesn't have.
4. **2026-11-02/03: the Clicky Eyes experiment.**
   - Clicky Eyes is an MCP connector plus a helper app that lets an assistant look through an iPhone using Continuity Camera.
   - In a CLI host it worked: a warm frame took about 0.1 s, and the model described real objects.
   - I didn't pursue it, because it couldn't be made to work reliably in the target app. It stays a local prototype.
5. **2026-11-03: where this is heading, a Logic Pro assistant for singers.** It's a course from "what song are you feeling?" to a finished song you can publish, teaching Logic features along the way.
   - **Modes:**
     - *Teach me:* you do it, while Clicky points and checks.
     - *Show me:* Clicky does it slowly, with narration.
     - *Just do it:* Clicky does it, after saving a backup of the project.
   - **Course stages:**
     1. Pick a direction: an artist, a genre, or a Suno demo you drop in.
     2. Set up the project.
     3. Get the instrumentals in, using Session Players, Apple Loops, or Stem Splitter on a demo.
     4. Song structure.
     5. Lyrics and melody.
     6. Record vocals and comp takes.
     7. Polish the vocal with Flex Pitch and a vocal chain: EQ, Pitch Correction, Compressor, DeEsser, and reverb and delay on sends.
     8. Mix.
     9. Master with Mastering Assistant.
     10. Release checklist, including rights for covers and Suno demos.
   - **Fix it** answers "why isn't this working?" at any step.
   - **Memory:** the help gets lighter as you learn.
6. **Reading Logic's state.**
   - I reviewed eight community Logic Pro MCP servers, reading their code only.
   - Only one, MongLong0214/logic-pro-mcp, reads plugin parameter values. But it's AI-generated, fast-moving, its reads move the UI, and it's untested on Logic 12.4.
   - Decision: build a read-only Accessibility reader into Clicky, borrowing approaches from the MIT-licensed repos with credit. That server stays only as an outside check.
   - Nobody has measured reading Pitch Correction's parameters yet.
7. **AI music tools.**
   - v1 uses Claude plus Logic's on-device AI: Session Players, Stem Splitter and Mastering Assistant.
   - Suno has no public API (only an invite-only partner program since July 2026), so users drop in their own Suno files.
   - ElevenLabs Music is licensed for commercial use and exports stems, so it's the candidate for an optional "generate my demo" step.

**Next:** step 1, the Logic state reader, measured against a throwaway test project on Logic 12.4.
