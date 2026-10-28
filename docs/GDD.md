# Push-Up Battle — Game Design Document

## Pitch and players

Push-Up Battle turns a short bodyweight workout into a five-level arcade campaign or a head-to-head Wi-Fi challenge. It is for casual players and classmates who want a clear, quick fitness goal rather than a long training plan. Sessions use only push-ups and a phone in portrait orientation.

## Core loop and controls

Choose offline or online, select a level or host/join a match, review the target and time, position the phone, then complete valid push-ups. During desktop prototyping, Space or the large practice button logs a rep. The intended phone control is hands-free pose counting: stable top position → lower past a calibrated threshold → return to the top threshold. The Android camera and pose provider are not yet connected; no claim of automatic phone-based counting should be made until that integration is tested.

## Goals, win/loss and progression

| Level | Target | Limit | Design intent |
|---|---:|---:|---|
| 1 | 5 reps | 30 sec | Tutorial pace |
| 2 | 8 reps | 35 sec | Faster pace |
| 3 | 12 reps | 45 sec | Sustained pace |
| 4 | 16 reps | 55 sec | Less recovery |
| 5 | 20 reps | 60 sec | Final challenge |

Reach the target before time runs out to clear a level. Clearing unlocks the next level. Level 1 is available on first launch; highest unlocked level and sound preference are stored with Godot `user://` configuration. A miss gives Retry or Menu; a clear gives Retry, Next where applicable, or Menu.

## Modes and screens

Offline campaign works without a network service. Online mode is a two-phone same-Wi-Fi host/join prototype: host starts the shared challenge, both devices submit score counts, and host publishes the result. Scores do not unlock the campaign. Screens include title, main menu, mode selection, level select, online lobby, positioning/calibration, active challenge, pause, results, settings and credits. The system Back/Escape action pauses an active challenge or returns to the menu.

## Visual and audio direction

Portrait, high-contrast dark training floor with lime action color and warm orange secondary color. Large touch targets, short labels and readable body text prioritize glanceable use while exercising. No third-party art or audio is included. Sound can be toggled in Settings and Pause; sound playback can be added with original/licensed assets.

## Risks and next decisions

1. Select an Android camera bridge and pose model; verify permission flow, framing, tracking loss and CPU/heat on multiple phones.
2. Tune pose thresholds with varied body types, camera angles and lighting; reject partial reps and tracking noise.
3. Test ENet discovery/manual IP entry, firewall behavior, disconnects, score authority, ties and synchronized starts on two phones.
4. Validate portrait layouts, touch sizing, offline saves and airplane-mode behavior on devices.
5. Collect at least five consented, anonymized playtests, summarize completion/attempts/comments, apply three documented fixes, then retest with two new players.
