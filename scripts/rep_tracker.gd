class_name RepTracker
extends RefCounted

## Stateful push-up detector. Feed a depth signal and confidence from a local
## pose provider; it emits a rep only after a stable down-and-up cycle.
##
## Depth is the fraction of arm length the shoulder has dropped toward the
## wrist (see PoseProvider.analyze): about 0.0 at the top of a push-up and
## roughly 0.6-0.8 at the bottom of a full rep. Larger values mean lower.
signal rep_counted(total: int)
signal tracking_changed(is_tracking: bool)

enum Phase { WAITING_FOR_TOP, AT_TOP, LOWERING, AT_BOTTOM, RISING }

## Depth below the top position required before the bottom counts.
## Half reps (about 0.3) must stay under this. Lowered from 0.40 after a
## 2026-11-09 phone trial: full reps bottomed at 0.42-0.87 and one real rep
## that peaked at 0.45 was missed.
const DEFAULT_DOWN_DELTA := 0.35
## The player must come back within this distance of the top to finish a rep.
const DEFAULT_RETURN_DELTA := 0.15
const TOP_STABLE_SECONDS := 0.16
const BOTTOM_STABLE_SECONDS := 0.08
const LOST_CONFIDENCE := 0.35
const TOP_STABILITY_DELTA := 0.05

var down_delta := DEFAULT_DOWN_DELTA
var return_delta := DEFAULT_RETURN_DELTA
var phase: Phase = Phase.WAITING_FOR_TOP
var reps := 0
var baseline := 0.0
var tracked := false
var stable_time := 0.0
var movement_delta := 0.0

func reset() -> void:
	phase = Phase.WAITING_FOR_TOP
	reps = 0
	baseline = 0.0
	stable_time = 0.0
	movement_delta = 0.0
	_set_tracking(false)

func update_pose(depth: float, confidence: float, delta: float) -> void:
	if confidence < LOST_CONFIDENCE or is_nan(depth):
		# Losing the body mid-rep discards that rep: counting resumes only
		# after the player holds a stable top position again.
		stable_time = 0.0
		phase = Phase.WAITING_FOR_TOP
		_set_tracking(false)
		return
	_set_tracking(true)
	if phase == Phase.WAITING_FOR_TOP:
		if stable_time == 0.0 or absf(depth - baseline) > TOP_STABILITY_DELTA:
			baseline = depth
			stable_time = maxf(delta, 0.0001)
		else:
			stable_time += delta
		if stable_time >= TOP_STABLE_SECONDS:
			phase = Phase.AT_TOP
			stable_time = 0.0
		return

	movement_delta = depth - baseline
	match phase:
		Phase.AT_TOP:
			if movement_delta < 0.0:
				# The player is higher than the stored top (e.g. tracking began
				# mid-rep). Follow them up so the real top becomes the baseline.
				baseline = depth
				movement_delta = 0.0
			elif movement_delta >= down_delta:
				phase = Phase.LOWERING
				stable_time = 0.0
		Phase.LOWERING:
			if movement_delta >= down_delta:
				stable_time += delta
				if stable_time >= BOTTOM_STABLE_SECONDS:
					phase = Phase.AT_BOTTOM
					stable_time = 0.0
			elif movement_delta < return_delta:
				phase = Phase.AT_TOP
				stable_time = 0.0
		Phase.AT_BOTTOM:
			if movement_delta < return_delta:
				phase = Phase.RISING
				stable_time = 0.0
		Phase.RISING:
			if movement_delta < return_delta:
				stable_time += delta
				if stable_time >= TOP_STABLE_SECONDS:
					reps += 1
					rep_counted.emit(reps)
					phase = Phase.AT_TOP
					stable_time = 0.0
			elif movement_delta >= down_delta:
				phase = Phase.AT_BOTTOM
				stable_time = 0.0

func _set_tracking(value: bool) -> void:
	if tracked == value:
		return
	tracked = value
	tracking_changed.emit(tracked)
