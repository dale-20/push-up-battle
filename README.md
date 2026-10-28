# Push-Up Battle

A portrait-mode Godot 4 mobile-game prototype for the ITSD 85 lab. It includes a five-level offline campaign, on-device unlock and sound settings, a threshold-based rep-cycle detector API, and a host/join same-Wi-Fi match flow.

## Run

Open this folder in Godot 4.7 or later and run the project. The project is set to portrait orientation and uses a 720 × 1280 logical viewport. For desktop iteration, Space or **Log Practice Rep** adds a practice rep.

## Current status

- Offline campaign, level goals/timers, results, retry/next/menu actions and saved unlocks are implemented.
- Settings and credits screens are included.
- Online host/join uses Godot ENet on port `27045`. The host starts the shared level and publishes the match result. Both phones must be on the same Wi-Fi; the joining player enters the host's local IP.
- `scripts/rep_tracker.gd` implements a calibrated top → down → return cycle with separate thresholds, confidence gating and stability checks.
- `scripts/camera_preview.gd` requests Android camera permission on the positioning screen and displays a local preview with a framing guide. No frames are saved or transmitted.
- **Pose inference is not integrated yet.** The challenge still exposes a practice rep input. Choose and validate an Android pose plugin/model on the team's phones, then feed normalized torso height and confidence into `RepTracker.update_pose()`.
- The online prototype shares score data but still needs testing on two physical phones, including network failure, simultaneous completion and host validation against forged scores.

Raw video is not part of the multiplayer protocol. A real pose provider should run locally and must not upload or persist camera frames.

## Project map

```text
scenes/main.tscn       Main app scene
scripts/main.gd        Screens, campaign, local save and ENet match flow
scripts/rep_tracker.gd Rep cycle state machine for a local pose provider
scripts/camera_preview.gd Android permission flow and local preview
scripts/camera_guide.gd Framing overlay
docs/GDD.md            One-page game design document
docs/CREDITS.md        Asset and license record
docs/PHONE_TEST_MATRIX.md  Device test template
docs/PLAYTEST.md       Consent, observation and iteration templates
```

## Export

An Android export preset with Camera permission is included in `export_presets.cfg`. Install the Android export templates and SDK in Godot, then export an APK to `build/android/PushUpBattle.apk`. Install on at least two phones before collecting lab evidence. The APK is not included yet.

## Team evidence

Use the templates under `docs/` to record real device runs and anonymized playtests. Do not fill in test outcomes until the team has observed them. Record the tester's consent and avoid collecting identifying information.
