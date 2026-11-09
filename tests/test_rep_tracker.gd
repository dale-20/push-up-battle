extends SceneTree

## Headless checks for the rep counter and pose geometry. Run with:
##   godot --headless --path . --script res://tests/test_rep_tracker.gd
## Exits with code 1 if any check fails.

const RepTrackerScript := preload("res://scripts/rep_tracker.gd")
const PoseScript := preload("res://scripts/pose_provider.gd")
const DT := 1.0 / 15.0  # ML Kit stream mode on a mid-range phone

var _failures := 0

func _initialize() -> void:
	_test_full_reps_count_once()
	_test_partial_reps_do_not_count()
	_test_tracking_loss_discards_rep()
	_test_tracking_starts_at_bottom()
	_test_jitter_at_top_does_not_count()
	_test_fast_reps_count()
	_test_analyze_geometry()
	print("\n%s" % ("ALL TESTS PASSED" if _failures == 0 else "%d CHECK(S) FAILED" % _failures))
	quit(1 if _failures > 0 else 0)

# --- Helpers -----------------------------------------------------------------

func _hold(t: RefCounted, depth: float, seconds: float, confidence := 0.9) -> void:
	for i in int(round(seconds / DT)):
		t.update_pose(depth, confidence, DT)

func _ramp(t: RefCounted, from: float, to: float, seconds: float) -> void:
	var steps := int(round(seconds / DT))
	for i in steps:
		t.update_pose(lerpf(from, to, float(i + 1) / steps), 0.9, DT)

func _rep(t: RefCounted, bottom := 0.7, down_s := 0.6, up_s := 0.6) -> void:
	_ramp(t, 0.0, bottom, down_s)
	_hold(t, bottom, 0.15)
	_ramp(t, bottom, 0.0, up_s)
	_hold(t, 0.0, 0.3)

func _check(name: String, actual, expected) -> void:
	if actual == expected:
		print("PASS  %s" % name)
	else:
		_failures += 1
		print("FAIL  %s: expected %s, got %s" % [name, expected, actual])

# --- Rep tracker ---------------------------------------------------------------

func _test_full_reps_count_once() -> void:
	var t := RepTrackerScript.new()
	_hold(t, 0.0, 0.5)
	for i in 3:
		_rep(t)
	_check("three full reps count three", t.reps, 3)

func _test_partial_reps_do_not_count() -> void:
	var t := RepTrackerScript.new()
	_hold(t, 0.0, 0.5)
	for i in 3:
		_rep(t, 0.3)
	_check("half reps (depth 0.3) do not count", t.reps, 0)
	_rep(t)
	_check("full rep after partials counts", t.reps, 1)

func _test_tracking_loss_discards_rep() -> void:
	var t := RepTrackerScript.new()
	var changes: Array[bool] = []
	t.tracking_changed.connect(func(v: bool): changes.append(v))
	_hold(t, 0.0, 0.5)
	_ramp(t, 0.0, 0.7, 0.6)
	_hold(t, 0.7, 0.15)
	_hold(t, NAN, 0.5, 0.0)  # body leaves frame at the bottom
	_check("tracking reported lost", t.tracked, false)
	_ramp(t, 0.7, 0.0, 0.6)  # comes back already rising
	_hold(t, 0.0, 0.5)
	_check("rep interrupted by tracking loss is discarded", t.reps, 0)
	_rep(t)
	_check("counting resumes after recovery", t.reps, 1)
	_check("tracking signals true -> false -> true", changes, [true, false, true])

func _test_tracking_starts_at_bottom() -> void:
	var t := RepTrackerScript.new()
	_hold(t, 0.7, 0.5)  # first stable pose is the bottom
	_ramp(t, 0.7, 0.0, 0.6)
	_hold(t, 0.0, 0.3)
	_check("rising from a bottom start does not count", t.reps, 0)
	_rep(t)
	_check("next full rep counts after a bottom start", t.reps, 1)

func _test_jitter_at_top_does_not_count() -> void:
	var t := RepTrackerScript.new()
	_hold(t, 0.0, 0.5)
	var rng := RandomNumberGenerator.new()
	rng.seed = 85
	for i in 150:
		t.update_pose(rng.randf_range(-0.08, 0.12), 0.9, DT)
	_check("landmark jitter at the top does not count", t.reps, 0)

func _test_fast_reps_count() -> void:
	var t := RepTrackerScript.new()
	_hold(t, 0.0, 0.5)
	for i in 3:
		_ramp(t, 0.0, 0.7, 0.35)
		_hold(t, 0.7, 0.1)
		_ramp(t, 0.7, 0.0, 0.35)
		_hold(t, 0.0, 0.2)
	_check("fast reps (~1 s each) count", t.reps, 3)

# --- Pose geometry ----------------------------------------------------------------

func _landmarks(shoulder: Vector2, elbow: Vector2, wrist: Vector2, hip: Vector2, likelihood := 0.95, elbow_likelihood := 0.95) -> PackedFloat32Array:
	var p := PackedFloat32Array()
	p.resize(33 * 3)
	# Left side (11, 13, 15, 23) visible; right side hidden.
	for entry in [[11, shoulder, likelihood], [13, elbow, elbow_likelihood], [15, wrist, likelihood], [23, hip, likelihood]]:
		var i: int = entry[0]
		var v: Vector2 = entry[1]
		p[i * 3] = v.x
		p[i * 3 + 1] = v.y
		p[i * 3 + 2] = entry[2]
	return p

func _test_analyze_geometry() -> void:
	var top: Dictionary = PoseScript.analyze(_landmarks(Vector2(0.5, 0.30), Vector2(0.5, 0.45), Vector2(0.5, 0.60), Vector2(0.2, 0.36)))
	_check("top pose reason ok", top.reason, "ok")
	_check("top pose depth ~0", absf(top.depth) < 0.05, true)
	var bottom: Dictionary = PoseScript.analyze(_landmarks(Vector2(0.5, 0.52), Vector2(0.62, 0.52), Vector2(0.5, 0.60), Vector2(0.2, 0.55)))
	_check("bottom pose depth ~0.7", absf(bottom.depth - 0.70) < 0.05, true)
	var far: Dictionary = PoseScript.analyze(_landmarks(Vector2(0.5, 0.300), Vector2(0.5, 0.31), Vector2(0.5, 0.32), Vector2(0.45, 0.31)))
	_check("tiny body reports too_far", far.reason, "too_far")
	var hidden: Dictionary = PoseScript.analyze(_landmarks(Vector2(0.5, 0.3), Vector2(0.5, 0.45), Vector2(0.5, 0.6), Vector2(0.2, 0.36), 0.95, 0.1))
	_check("hidden elbow reports arm_hidden", hidden.reason, "arm_hidden")
	_check("hidden elbow gives low confidence", hidden.confidence < RepTrackerScript.LOST_CONFIDENCE, true)
	var empty: Dictionary = PoseScript.analyze(PackedFloat32Array())
	_check("no landmarks reports no_body", empty.reason, "no_body")
	_check("one-sided landmarks use the side view", top.front, false)
	_test_front_view_geometry()

## Facing the phone: shoulders 0.2 apart, hands 1.5 shoulder widths below.
func _front_landmarks(shoulder_y: float, hip_likelihood := 0.0) -> PackedFloat32Array:
	var p := PackedFloat32Array()
	p.resize(33 * 3)
	for entry in [[11, Vector2(0.4, shoulder_y)], [12, Vector2(0.6, shoulder_y)],
			[15, Vector2(0.4, 0.60)], [16, Vector2(0.6, 0.60)]]:
		var i: int = entry[0]
		var v: Vector2 = entry[1]
		p[i * 3] = v.x
		p[i * 3 + 1] = v.y
		p[i * 3 + 2] = 0.95
	p[23 * 3 + 2] = hip_likelihood
	p[24 * 3 + 2] = hip_likelihood
	return p

func _test_front_view_geometry() -> void:
	var top: Dictionary = PoseScript.analyze(_front_landmarks(0.30))
	_check("front top pose detected as front view", top.front, true)
	_check("front top pose ok without a visible hip", top.reason, "ok")
	_check("front top pose depth ~0", absf(top.depth) < 0.05, true)
	var bottom: Dictionary = PoseScript.analyze(_front_landmarks(0.51), true)
	_check("front bottom pose depth ~0.7", absf(bottom.depth - 0.70) < 0.05, true)
	_check("front view holds at the bottom (hysteresis)", bottom.front, true)
	var half: Dictionary = PoseScript.analyze(_front_landmarks(0.39), true)
	_check("front half rep (~0.3) stays under down_delta", half.depth - top.depth < RepTrackerScript.DEFAULT_DOWN_DELTA, true)
