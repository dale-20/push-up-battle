class_name ScoreValidator
extends RefCounted

## Host-side plausibility check for rep counts reported by the guest phone.
##
## Camera frames never leave a phone, so the host cannot prove a rep was real.
## It can only reject reports that are impossible:
##   * each report may raise the score by at most one rep (each rep is sent as
##     its own reliable, ordered message, so honest reports always step by 1);
##   * the total can't exceed one rep per MIN_REP_SECONDS of match time, plus a
##     small burst allowance for Wi-Fi packets that arrive bunched together;
##   * reports are only accepted while the match clock runs, plus a short grace
##     period for messages already in flight when time expires.
## Rejections are counted and shown on both result screens.
## The host's own count is trusted (same-room game; documented team decision).

## Fastest plausible clean rep. The rep tracker itself needs about 0.5 s.
const MIN_REP_SECONDS := 0.6
const BURST_ALLOWANCE := 2
const EARLY_TOLERANCE_SECONDS := 0.25
const LATE_GRACE_SECONDS := 0.75

var accepted := 0
var rejected := 0

func reset() -> void:
	accepted = 0
	rejected = 0

## [param elapsed] is host match time since the countdown ended;
## [param duration] is the match length in seconds. Returns true if accepted.
func submit(score: int, elapsed: float, duration: float) -> bool:
	if score <= accepted:
		return false  # Duplicate or stale report; nothing to change.
	var in_window := elapsed >= -EARLY_TOLERANCE_SECONDS and elapsed <= duration + LATE_GRACE_SECONDS
	var cap := floori(maxf(elapsed, 0.0) / MIN_REP_SECONDS) + BURST_ALLOWANCE
	if not in_window or accepted + 1 > cap:
		rejected += 1
		return false
	accepted += 1
	if score != accepted:
		rejected += 1  # Claimed a jump of more than one rep; only one is credited.
	return score == accepted
