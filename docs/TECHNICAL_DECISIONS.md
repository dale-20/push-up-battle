# Technical Decisions and Spikes

## Pose estimation (implemented; not yet device-validated)

- **Choice:** Google ML Kit bundled Pose Detection (base model) in stream mode, wrapped in a Godot Android Plugin v2 (`android-plugin/`, singleton `PushUpPose`).
- **Why:** the bundled model ships with the APK, so first-run airplane-mode play works. It returns 33 body landmarks with per-landmark in-frame likelihood. Requires API 23+; the app's minimum is 24.
- **Camera ownership:** the plugin owns the only camera session (CameraX `ImageAnalysis`, about 640×480, front camera, mirrored). It sends Godot a 240 px-tall RGBA thumbnail for the positioning and in-game preview, so Godot's `CameraServer` is no longer used when the plugin is present. This avoids two components competing for the camera. Builds without the plugin (desktop) fall back to `CameraServer` preview plus the practice-rep input.
- **Privacy:** only landmark numbers and the preview thumbnail cross into Godot. Nothing is saved to storage, and nothing camera-related is part of the multiplayer protocol.

## iPhone pose estimation (built in CI; not yet device-validated)

- **Choice:** Apple Vision `VNDetectHumanBodyPoseRequest` (built into iOS 14+, on-device, no model download) in a GDExtension (`ios-plugin/src/pushup_pose.mm`) that registers the same `PushUpPose` singleton and signals as the Android plugin. `pose_provider.gd`, the front/side views and `RepTracker` are shared and unchanged.
- **Landmarks:** Vision's 19 joints are mapped onto the ML Kit indices that `pose_provider.gd` reads (shoulders 11/12, elbows 13/14, wrists 15/16, hips 23/24, and so on). The rest stay zero. Coordinates are converted to ML Kit's convention (units of image height, y down). The camera is AVFoundation at 640×480, portrait, mirrored for the front camera.
- **Open risk:** Vision joint confidence is not calibrated like ML Kit's in-frame likelihood. The shared 0.35 cutoffs (`MIN_LIKELIHOOD`, `LOST_CONFIDENCE`) may need an iOS-specific value after the first iPhone trial.
- **Build:** the team has no Mac, so `.github/workflows/ios.yml` builds on a GitHub-hosted Mac. It dumps the API from Godot 4.7, builds godot-cpp and the plugin, exports an Xcode project (the iOS preset has `export_project_only`), and runs `xcodebuild` without code signing. Testers sign and install the unsigned `.ipa` with Sideloadly and their own Apple ID (see README). The generated `addons/pushup_pose_ios/` is git-ignored, so Windows and Android builds never see the iOS library.
- **Cross-platform matches:** Android and iPhone use the same ENet protocol, so mixed matches should work. iOS shows a Local Network permission prompt the first time a match connects. Not yet tested.

## Rep signal

`scripts/pose_provider.gd` (autoload `Pose`) converts landmarks into one number per frame:

```
depth = 1 - (wrist.y - shoulder.y) / (|shoulder-elbow| + |elbow-wrist|)
```

This is the fraction of arm length the shoulder has dropped toward the wrist: about 0.0 at the top of a push-up and about 0.6-0.8 at the bottom of a full rep. Because it is divided by arm length, it doesn't depend on how far the player is from the phone. The side (left or right arm) with the higher minimum likelihood across shoulder, elbow, wrist and hip is used, and that minimum is the confidence. Depth is lightly smoothed (EMA 0.5).

**Facing the phone (front view).** Players can also face the camera. Then the arms point toward the lens and foreshorten as they bend, so the side formula barely moves: a phone trial facing the camera read only 0.16–0.29 for full reps. The hip is also usually hidden. When both shoulders and both wrists are visible and shoulder width / shoulder-to-wrist distance is above 0.5 (with hysteresis: it stays in front view until the ratio drops under 0.3), depth is instead:

```text
depth = 1 - (mean wrist.y - mean shoulder.y) / (1.5 * shoulder width)
```

Shoulder width does not change during a rep, and 1.5 is a typical shoulder-to-wrist length in shoulder widths, so the scale roughly matches the side view. The hip is not required. The confidence is the minimum likelihood of both shoulders and both wrists. A view switch needs 3 frames in a row, because single-frame flips happened mid-rep in trials. Trial (2026-11-09, same phone, facing it): top about −0.15, bottoms 0.53–0.60, and 5 of 5 reps counted.

`scripts/rep_tracker.gd` counts a rep for top → down past `down_delta` (0.35) held for 0.08 s → back within `return_delta` (0.15) of the top held for 0.16 s. Half reps (~0.3) do not count. When confidence drops below 0.35, the in-progress rep is discarded and counting resumes only after a stable top position. The game shows a specific recovery hint: no body, arm hidden, or too far.

The thresholds started from geometry. First phone trial (2026-11-09, OPPO CPH2457, front camera, side-on): tracking confidence stayed 0.83–1.00; the top read about 0.02 and full-rep bottoms 0.42–0.87. One real rep peaked at 0.45 and was missed at 0.40, so `down_delta` was lowered to 0.35. `return_delta` (0.15) worked unchanged. Confirm on more phones and players.

## Wi-Fi match

- **Transport:** Godot ENet on UDP port 27045, one host and one guest. A guest that types an IP has it checked before connecting, and the connection gives up after 8 s with an explanation. Peer timeouts are 3–8 s, so a phone that drops off Wi-Fi ends the match quickly on the other phone. Android needs the `INTERNET` permission for any socket. Godot leaves it off by default, so the Android preset now enables it, along with network and Wi-Fi state.
- **Waiting room:** tapping Host opens a "Waiting for a rival" page. It shows the editable player name (saved on the phone), the networks this phone is reachable on ("Wi-Fi" or "Your hotspot", each with its address as a manual-join fallback) and how the rival joins. If the guest leaves before a match starts, the host returns to this page and is listed again.
- **Matches nearby (`scripts/lan_discovery.gd`):** the guest's lobby lists hosts found automatically. Broadcast and multicast are avoided: iOS blocks them without a restricted Apple entitlement, and Android drops them without a multicast lock. Instead, about once a second the guest sends a 5-byte unicast probe (`PUB1?`) to every address in its own /24 subnet. The host answers on UDP **27046** with `{"g":"PUB1","name":…,"port":27045}`, and a host silent for 3.5 s drops off the list. Hosts stop answering once a guest connects. Cellular, VPN and virtual interfaces (`rmnet*`, `ccmni*`, `pdp_ip*`, `tun*`, `vEthernet`, …) are never swept or shown, so carrier 10.x addresses don't leak in. Networks larger than a /24 aren't swept beyond their own /24, so "Enter IP manually" remains as a fallback.
- **Hotspot hosting:** no special code path. The host turns on Mobile Hotspot in Settings, and the guest connects to that hotspot. ENet listens on all interfaces, and the hotspot's address (Android 192.168.x.1 or 10.x.x.1, iPhone 172.20.10.1) is inside the guest's swept /24. The waiting page marks an interface as a hotspot if its name is `ap*`/`swlan*`/`softap*`/`bridge*` or its address ends in `.1`. Matches use only the local link, not mobile data.
- **Flow:** both phones go to a positioning screen with the camera. The host picks the match length (0:30, 1:00, 1:30, 2:00, 3:00 or 5:00; default 1:00, remembered on the host phone) on the waiting page or the positioning screen, and taps START. The guest sees the host's choice live (`receive_match_length`), and `begin_remote_match` carries the length again, so both clocks always agree. Lengths that arrive over the network are checked against that list. Both phones then run the same 5 s countdown and the timed match. Most valid reps wins, with no goal cap. Online play has no pause, because it would desynchronize the clocks. The back button is ignored mid-match, and LEAVE MATCH quits deliberately.
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
