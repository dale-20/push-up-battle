class_name RepTracker
extends RefCounted

## Stateful push-up detector. Feed normalized torso height and confidence from a
## local pose provider; it emits a rep only after a stable down-and-up cycle.
signal rep_counted(total: int)
signal tracking_changed(is_tracking: bool)

enum Phase { WAITING_FOR_TOP, AT_TOP, LOWERING, AT_BOTTOM, RISING }

const DEFAULT_DOWN_DELTA := 0.13
const DEFAULT_RETURN_DELTA := 0.055
const STABLE_SECONDS := 0.16
const LOST_CONFIDENCE := 0.35
const TOP_STABILITY_DELTA := 0.035

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

func update_pose(torso_height: float, confidence: float, delta: float) -> void:
	if confidence < LOST_CONFIDENCE:
		stable_time = 0.0
		phase = Phase.WAITING_FOR_TOP
		_set_tracking(false)
		return
	_set_tracking(true)
	if phase == Phase.WAITING_FOR_TOP:
		if stable_time == 0.0 or absf(torso_height - baseline) > TOP_STABILITY_DELTA:
			baseline = torso_height
			stable_time = 0.0
		else:
			stable_time += delta
		if stable_time >= STABLE_SECONDS:
			phase = Phase.AT_TOP
			stable_time = 0.0
		return

	movement_delta = torso_height - baseline
	match phase:
		Phase.AT_TOP:
			if movement_delta >= DEFAULT_DOWN_DELTA:
				phase = Phase.LOWERING
				stable_time = 0.0
		Phase.LOWERING:
			if movement_delta >= DEFAULT_DOWN_DELTA:
				stable_time += delta
				if stable_time >= STABLE_SECONDS:
					phase = Phase.AT_BOTTOM
					stable_time = 0.0
			elif movement_delta < DEFAULT_RETURN_DELTA:
				phase = Phase.AT_TOP
				stable_time = 0.0
		Phase.AT_BOTTOM:
			if movement_delta < DEFAULT_RETURN_DELTA:
				phase = Phase.RISING
				stable_time = 0.0
		Phase.RISING:
			if movement_delta < DEFAULT_RETURN_DELTA:
				stable_time += delta
				if stable_time >= STABLE_SECONDS:
				reps += 1
				rep_counted.emit(reps)
				phase = Phase.AT_TOP
				stable_time = 0.0
			elif movement_delta >= DEFAULT_DOWN_DELTA:
				phase = Phase.AT_BOTTOM
				stable_time = 0.0

func _set_tracking(value: bool) -> void:
	if tracked == value:
		return
	tracked = value
	tracking_changed.emit(tracked)
