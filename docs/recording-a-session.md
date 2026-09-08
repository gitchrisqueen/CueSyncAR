# Recording a session at the table

One recording is enough for every later change to be checked against your
real table without you standing at it. Budget about 15 minutes total.

## Before you start (once, at the Mac)

1. Build the app onto the iPhone/iPad from the branch that has the ● record
   button. Make sure Wi-Fi is the same network as the Mac.
2. Charge the device to at least 50 %. A 5-minute recording is ~225 MB; the
   app refuses to start with under 400 MB free.

## Set up the table

3. Lights on, no dark corners — the detector is blind at shot speed, and
   dim cloth makes it worse. Push chairs and stray objects away from the rails.
4. Lay out **5–7 balls** spread over the whole table (not a rack): the cue
   ball plus a few object balls, none touching a cushion, at least two in
   the far half. Leave them there for the first minute.
5. Stand at the **head rail** with the device held chest-high, pointing down
   the table so all four cushions are in view.

## Press, in this order

6. Open the app. If the table restores by itself ("Table restored in …") skip
   to step 8. Otherwise tap the **rectangle** button and tap the four
   **cushion-nose corners**, drag the dots onto the noses, then **Lock**.
7. Wait for the status capsule to say **Tracking N balls** and for rings to
   appear on the balls. If the cue ball has no white ring, **tap it** once
   ("Marked as cue ball").
8. Tap the **antenna** button so the HUD shows `Mirror: http://…:8787` (this
   is how the Mac pulls the file later; leave it on).
9. Tap the **●** button, read the size line, tap **Start recording**.

## How to tell it is recording

10. A red **REC 0:05 · 34 frames · ~4 MB** badge appears under the status
    capsule and the numbers climb every second. The overlay colours switch to
    bright magenta/cyan/red — that is on purpose (a machine-readable palette).
    Starting restarts ball tracking, so the rings vanish for ~2 s and come
    back; **if the cue ball's ring is not white/cyan, tap the cue ball again**
    (that tap is recorded too). If the badge does not appear, the HUD tells
    you why ("Can't record: …") — fix that and tap ● again. **A silent ● is
    a bug: report it.**

## What to do during the recording (aim for 3–4 minutes, cap is 5)

11. **0:00–0:45 — stand still**, then walk slowly once around the table,
    keeping all the balls in frame. Do not shoot yet.
12. **0:45–2:30 — shoot 4 slow shots** (lag speed, not power): two straight
    shots at an object ball, one shot into a cushion, one where you first
    **tap a pocket** on screen to call it. Between shots, hold still for
    5 seconds so the tracker settles. Aim with the cue stick along the line
    for a couple of seconds before each shot — the stick detection is part
    of what is being recorded.
13. **2:30–3:30 — perturb the tracker**: cover the cue ball with your hand
    for 3 seconds, move one object ball by hand to a new spot, then
    **long-press** the screen once (tracking reset).
14. Tap **●** again to stop. If you forget, it stops itself at 5:00.

## How to tell it worked

15. The HUD shows **"Saved. N frames, S s, M MB → pull-session.sh"** and the
    overlay colours go back to normal. On the mirror page in a browser the
    recorder line shows `last: device-… frames …`. If it says **"Recording
    save FAILED"**, screenshot it and try one more short recording.

## Get it onto the Mac

16. Keep the app open with the mirror on. On the Mac, in the repo:

    ```
    Scripts/pull-session.sh <the IP shown after Mirror:>
    ```

    It downloads the newest finished bundle into `Sessions/<id>/`, resumes
    if Wi-Fi drops (just run it again), and verifies every file's sha256. It
    ends with `done: … all files verified` and prints the one-line replay
    command (`CUESYNC_REPLAY_BUNDLE=… swift test …`) that turns the bundle
    into the golden every later change is judged against. Fallback without
    Wi-Fi: plug in the device, Finder → device → Files → CueSync AR →
    Sessions, drag the folder over.

## If something looks wrong

- **No rings / "Place the cue ball"** before recording: tap the cue ball to
  mark it; if nothing is tracked at all, long-press to reset tracking, then
  wait 5 s.
- **"Can't record: Calibrate the table first"**: do step 6.
- **Badge shows "video dropped N"**: harmless for replay (frames and
  detections are still complete); mention it when you hand over the bundle.
- **Badge shows ERROR …**: the recording stops itself and saves what it has;
  pull it anyway and include the error text.
- **Camera freezes or goes black** while recording: force-quit the app and
  say so — that is the ARFrame-retention symptom and the recorder must be
  suspected first.
- **pull-session.sh cannot reach the device**: same Wi-Fi? Mirror still on
  (antenna green)? App still in the foreground?
