# Evidence

Results from 2026-11-01. Every file here came from a real run, except the renders, which are labelled.

Permissions changed partway through. Up to about 13:18 nothing was granted, and by 13:25 everything was. Results before that used Blender's own export of its window.

| File | What it is |
|---|---|
| `harness-results.txt`, `.json` | Tuning and held-out scores. **Synthetic traces.** |
| `harness-checks.txt` | 29 privacy and behaviour checks, including real CGEvent objects |
| `privacy-proof-real-events-earlier-build.txt` | Proof with 389 real events, one build before the final copy and layout changes |
| `privacy-proof-final-build-idle.txt`, `privacy-proof-final-build-idle-240s.txt` | Proofs at 60s and 240s with nobody at the Mac, so no events. Correctly reported as PASS ON IDLE ONLY. |
| `shadow-run-real-input.json` | 280 seconds of real, unlabelled input through the real tap and detector |
| `sonnet-help-accuracy.txt`, `.json` | 10 runs of the real help prompt. Blender export, judged by OCR. |
| `local-model-latency.json` | Ollama cold and new-image timing, plus accuracy |
| `real-capture-local-model.json` | First real ScreenCaptureKit frames through the help path, local model only. The image itself was deleted unseen, as it was a live display. |
| `tap-before-permissions.json`, `tap-after-permissions.json` | The silent keyboard removal, and the fixed state |
| `offer-declined.json`, `offer-ignored.json`, `offer-accepted.json` | Real offers through the real overlay and panel. `scripted: true`. Accepted used the Blender export and a real Sonnet call. |

## Images

These are **renders, not screen recordings.** The app's own views drew themselves over a Blender frame, so they show what the code draws. The pointer is drawn in at its real location.

| File | What it is |
|---|---|
| `images/offer-accepted-render.mp4` | The whole yes sequence |
| `images/offer-declined-render.mp4` | The decline |
| `images/offer-accepted-contact-sheet.jpg` | Stills from the yes |
| `images/offer-pill-render.png` | The pill at 2x |
| `images/receipt-render.png` | The receipt, with scripted contents |
| `images/consent-panel-render.png` | The consent sentence. Shows the setup state, because headless runs skip onboarding defaults. |
| `images/blender-demo-frame.png` | Blender's own export of the demo scene |
