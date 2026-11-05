# Push-Up Battle

A portrait-mode Godot 4 mobile-game prototype for the ITSD 85 lab. It includes a five-level offline campaign, on-device unlock and sound settings, a threshold-based rep-cycle detector API, and a host/join same-Wi-Fi match flow.

## Run

Open this folder in Godot 4.7 or later and run the project. The project is set to portrait orientation and uses a 720 × 1280 logical viewport. For desktop iteration, Space or **Log Practice Rep** adds a practice rep.

## Current status

- Offline campaign, level goals/timers, results, retry/next/menu actions and saved unlocks are implemented.
- Settings and credits screens are included.
- Online host/join uses Godot ENet on port `27045`. The host starts the shared level and publishes the match result. Both phones must be on the same Wi-Fi; the joining player enters the host's local IP.
- **Pose tracking:** the `PushUpPose` Android plugin (`android-plugin/`) runs Google ML Kit's bundled pose model on the phone through CameraX. `scripts/pose_provider.gd` (autoload `Pose`) turns landmarks into a depth signal that drives `scripts/rep_tracker.gd` (top → down → return cycle with confidence gating). When tracking is lost, the in-progress rep is discarded and the game shows a recovery hint. Thresholds still need tuning on real phones; see `docs/TECHNICAL_DECISIONS.md`.
- `scripts/camera_preview.gd` shows the plugin's local preview with a pose skeleton and framing guide. Builds without the plugin (desktop) show the practice rep input instead.
- Headless tests: `godot --headless --path . --script res://tests/test_rep_tracker.gd` (also `test_main_flow.gd`).
- The online prototype shares score data but still needs testing on two physical phones, including network failure, simultaneous completion and host validation against forged scores.
- Camera, pose and install behavior have not yet been verified on an Android phone.

Raw video is not part of the multiplayer protocol. Pose detection runs locally; camera frames are never uploaded or saved.

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

The Android export preset (`export_presets.cfg`) has Camera permission enabled and uses Gradle build, which the pose plugin requires. One-time setup:

1. In Godot's Editor Settings, set the JDK 17 path and the Android SDK path. The SDK needs platform-tools, build-tools 36.1.0 and platform android-36.
2. Install the Godot 4.7 export templates, then run **Project → Install Android Build Template**. If you export from the command line (`--headless --export-debug`), add `org.gradle.daemon=false` to `android/build/gradle.properties`. Otherwise the export hangs after Gradle finishes.
3. Build the plugin: `cd android-plugin` and `gradlew :plugin:assemble`. This writes the AARs to `addons/pushup_pose/bin/`.

Then export to `build/android/PushUpBattle.apk` and install it on at least two phones before collecting lab evidence.

## Team evidence

Use the templates under `docs/` to record real device runs and anonymized playtests. Do not fill in test outcomes until the team has observed them. Record the tester's consent and avoid collecting identifying information.
