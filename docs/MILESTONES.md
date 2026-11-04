# Milestones

Update the status column as milestones are verified on real devices.

| # | Milestone | Work | Done when | Status |
|---|---|---|---|---|
| 1 | Android foundation | Install/configure Android SDK and Godot export templates. Export and install a basic APK. Check camera permission and preview on both phones. | The APK installs, stays in portrait, and displays the camera preview on both devices. | In progress — debug APK exported; device install/preview not yet verified |
| 2 | Pose-counting spike | Choose and integrate the pose model. Connect its local pose output to the rep detector. Try full, partial, and interrupted movements under different lighting and camera placements. | Full down-and-up movements count once; partial reps do not; tracking loss pauses counting and explains how to recover. **Highest-risk milestone.** | Not started — `RepTracker` ready, no pose provider (ML Kit candidate) |
| 3 | Offline campaign | Finish the five levels, timers, results, retries, unlock rules, sound behavior, and saved progress. Test airplane-mode play. | All five levels work offline; unlocks survive closing and reopening the app. | Code complete — needs device verification |
| 4 | Wi‑Fi matches | Complete host/join, shared start, live scores, winner/tie, rematch, disconnect, and unreachable-host handling. Keep online results separate from campaign unlocks. | Two phones can finish a same-Wi‑Fi match and show the same result. Agree how the host validates received scores. | Code mostly complete — host score validation only clamps; two-phone test pending |
| 5 | Device testing and playtests | Fill the phone matrix. Run sessions with at least five people on Levels 1–3 and one online match. Summarize completion, attempts, and recurring feedback. | Real device results and anonymized playtest notes are recorded. | Not started |
| 6 | Fixes and submission | Make at least three changes based on feedback and retest with two new players. Finalize the APK, demo video, paper, credits, and contribution logs. | Submission package complete. | Not started |
