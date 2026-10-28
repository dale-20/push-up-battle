# Technical Decisions and Spikes

## Pose estimation candidate (not yet implemented or device-validated)

- **Candidate:** Google ML Kit bundled Pose Detection in stream mode, integrated through a Godot Android Plugin v2.
- **Reason:** the bundled model ships with the APK, supporting first-run airplane-mode play. The base model returns 33 body landmarks and per-landmark confidence; the stream mode is intended for video.
- **Frame signal:** derive normalized torso height from shoulder/hip landmarks, plus a confidence value. Pass only those numbers into `RepTracker.update_pose()`; keep image frames inside the Android camera pipeline.
- **Camera ownership:** the current positioning screen uses Godot `CameraServer` to preview the Android camera. A CameraX-based pose plugin may need to own preview and analysis together. Check camera-session compatibility before keeping both; replace the current preview path if they compete for the camera.
- **Risks:** ML Kit pose detection is documented as beta, increases APK size by roughly 10 MB for the base bundled option, and requires Android API 23 or newer. Validate latency, tracking confidence, permission behavior and thermal performance on the team's phones before committing to it.

## Current implementation

Godot `CameraServer` preview is wired into the positioning screen. `RepTracker` has the top/down/return cycle, confidence gate and stability checks. A practice input remains available while the pose provider is being built.
