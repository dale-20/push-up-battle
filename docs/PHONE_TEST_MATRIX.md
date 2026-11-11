# Phone Test Matrix

Fill one row for each actual device/run. Do not infer results from editor or emulator behavior.

| Date | Tester/device (anonymous ID) | Android or iOS/version | Install/launch | Portrait/layout | Touch | Saved unlock after restart | Airplane mode | Wi-Fi host/join | Shows in Matches nearby | Hotspot host | Disconnect behavior | Performance/heat | Notes |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
|  |  |  |  |  |  |  |  |  |  |  |  |  |  |
|  |  |  |  |  |  |  |  |  |  |  |  |  |  |

## Run checklist

- A debug APK is available at `build/android/PushUpBattle.apk`; install and test it on each phone before recording outcomes.
- Install the exported APK and launch it from a clean state.
- Complete Level 1, force-close and reopen; verify Level 2 is unlocked.
- Enable airplane mode and play all five levels; note any dependency or error.
- Pair two phones on the same Wi-Fi: tap Host on one (it should open the "Waiting for a rival" page), check that the host's name appears under Matches nearby on the other within ~2 s, tap it, finish a match, and check that both result screens show the same two scores.
- Hotspot: turn on Mobile Hotspot on the host phone, connect the guest phone to it, and repeat the step above. The host page should show "Your hotspot". Try an Android and an iPhone hotspot if available.
- Tap Cancel hosting; the match should disappear from the guest's list within ~4 s. Also try joining by typing the IP under "Enter IP manually".
- Tap REMATCH on the guest; confirm both phones count down together.
- Record an unreachable-host attempt (wrong IP: it should give up within ~8 s with a message) and a disconnect during play (turn off Wi-Fi on one phone: the other should show "match ended" within ~8 s).
- After online matches, confirm campaign unlocks are unchanged.
- Observe text, buttons, orientation, frame pacing and device heat during a session.
- Camera permission and preview, plus pose checks, still need real Android device validation. Pose inference is not integrated yet.
