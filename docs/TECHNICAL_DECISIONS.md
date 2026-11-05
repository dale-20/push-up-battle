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

## Tests

- `tests/test_rep_tracker.gd`: synthetic depth sequences (full, partial, fast, interrupted, bottom start, jitter) plus landmark geometry.
- `tests/test_main_flow.gd`: offline Level 1 flow and unlock without the plugin.

Run: `godot --headless --path . --script res://tests/<file>.gd`.

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
