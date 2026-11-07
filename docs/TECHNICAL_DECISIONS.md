# Technical Decisions and Spikes

## Pose estimation (implemented; not yet device-validated)

- **Choice:** Google ML Kit bundled Pose Detection (base model) in stream mode, wrapped in a Godot Android Plugin v2 (`android-plugin/`, singleton `PushUpPose`).
- **Why:** the bundled model ships with the APK, so first-run airplane-mode play works. It returns 33 body landmarks with per-landmark in-frame likelihood. Requires API 23+; the app's minimum is 24.
- **Camera ownership:** the plugin owns the only camera session (CameraX `ImageAnalysis`, about 640×480, front camera, mirrored). It sends Godot a 240 px-tall RGBA thumbnail for the positioning and in-game preview, so Godot's `CameraServer` is no longer used when the plugin is present. This avoids two components competing for the camera. Builds without the plugin (desktop) fall back to `CameraServer` preview plus the practice-rep input.
- **Privacy:** only landmark numbers and the preview thumbnail cross into Godot. Nothing is saved to storage, and nothing camera-related is part of the multiplayer protocol.

## Rep signal

`scripts/pose_provider.gd` (autoload `Pose`) converts landmarks into one number per frame:

```
depth = 1 - (wrist.y - shoulder.y) / (|shoulder-elbow| + |elbow-wrist|)
```

This is the fraction of arm length the shoulder has dropped toward the wrist: about 0.0 at the top of a push-up and about 0.6-0.8 at the bottom of a full rep. Because it is divided by arm length, it doesn't depend on how far the player is from the phone. The side (left or right arm) with the higher minimum likelihood across shoulder, elbow, wrist and hip is used, and that minimum is the confidence. Depth is lightly smoothed (EMA 0.5).

`scripts/rep_tracker.gd` counts a rep for top → down past `down_delta` (0.40) held for 0.08 s → back within `return_delta` (0.15) of the top held for 0.16 s. Half reps (~0.3) do not count. When confidence drops below 0.35, the in-progress rep is discarded and counting resumes only after a stable top position. The game shows a specific recovery hint: no body, arm hidden, or too far.

The thresholds are starting points from geometry, **not** yet tuned on the team's phones. Tune `down_delta`/`return_delta` from the Milestone 2 device trials.

## Wi-Fi match

- **Transport:** Godot ENet on UDP port 27045, one host and one guest. The host screen lists its private IPv4 addresses so the guest knows what to type. The guest validates the IP before connecting and gives up after 8 s with an explanation. Peer timeouts are 3–8 s, so a phone that drops off Wi-Fi ends the match quickly on the other phone.
- **Flow:** both phones go to a positioning screen with the camera. The host picks the match length (any level's time limit) and taps START. Both phones then run the same 5 s countdown and the timed match. Most valid reps wins, with no goal cap. Online play has no pause, because it would desynchronize the clocks. The back button is ignored mid-match, and LEAVE MATCH quits deliberately.
- **Authority:** the host decides. When its clock ends it waits 0.75 s for guest reps still in flight, then sends `(host score, guest score, rejected count)` to the guest. Each phone derives its outcome from those same numbers, so both screens always agree. Either player can start a rematch. If the rival has left, the result screen says so and offers no rematch.
- **Separation from the campaign:** online matches never touch unlocks or level stats. The tests check this on both phones.

### Host score validation (proposed; team to confirm)

Camera frames never leave a phone, so the host cannot prove that a guest's rep was real. `scripts/score_validator.gd` rejects only reports that are **impossible**:

1. Each report may raise the guest's score by at most **one** rep. Every rep is sent as its own reliable, ordered message, so honest reports always go up by 1.
2. The total can't exceed **one rep per 0.6 s** of match time, plus 2 to allow for bunched Wi-Fi packets. The rep tracker itself needs about 0.5 s per rep.
3. Reports are accepted only while the host's match clock runs, from 0.25 s before it starts until 0.75 s after it ends.
4. Rejected reports are counted and shown on **both** result screens.
5. The host's own count is trusted. This is a same-room game, so both players can see each other.

This stops a tampered client from claiming 50 reps, but it can't stop a guest who fakes reps at a believable rate. Only an in-person referee could. The team should agree that this limit is acceptable for the lab.

## Tests

- `tests/test_rep_tracker.gd`: synthetic depth sequences (full, partial, fast, interrupted, bottom start, jitter) plus landmark geometry.
- `tests/test_main_flow.gd`: offline campaign (unlocks, timer failure, pause, restart persistence, corrupt save).
- `tests/test_score_validator.gd`: host score-validation rules.
- `tests/test_online_match.gd`: **two Godot processes** (host and guest) over loopback ENet, using the real game code. It covers join, a match with a forged score, a rematch ending in a tie, a guest leaving mid-match, an invalid IP, an unreachable host, and campaign separation. Run it with `powershell -File tests/run_online_test.ps1`.

Run the others with `godot --headless --path . --script res://tests/<file>.gd`.

## Building the plugin

```
cd android-plugin
gradlew :plugin:assemble        # needs JAVA_HOME (JDK 17) and ANDROID_HOME
```

This copies `PushUpPose-debug.aar` and `PushUpPose-release.aar` to `addons/pushup_pose/bin/`. The Android export preset uses Gradle build, so Project → Install Android Build Template must have been run once (it creates `android/`, which is gitignored).

## Known risks to check on devices

- Latency and frame rate of ML Kit stream mode on the team's phones. The rep tracker assumes at least 10 fps.
- Landmark stability when the floor, lighting or clothing is low contrast.
- Heat and battery during a 60 s level.
- Portrait framing of a horizontal body: only shoulder, arm and hip need to be visible, but the phone has to be far enough away.
