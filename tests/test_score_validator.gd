extends SceneTree

## Unit checks for the host's guest-score plausibility rules. Run with:
##   godot --headless --path . --script res://tests/test_score_validator.gd

const Validator := preload("res://scripts/score_validator.gd")
var _failures := 0

func _initialize() -> void:
	var v := Validator.new()
	# Honest guest: one rep per second for 10 s.
	for i in range(1, 11):
		v.submit(i, float(i), 30.0)
	_check("honest 1 rep/s fully accepted", [v.accepted, v.rejected], [10, 0])

	v = Validator.new()
	_check("forged jump to 50 credits only one rep", [v.submit(50, 5.0, 30.0), v.accepted, v.rejected], [false, 1, 1])

	v = Validator.new()
	for i in range(1, 21):
		v.submit(i, 1.0, 30.0)  # 20 reps claimed within 1 s
	_check("burst capped at rate limit (1 s -> 3)", v.accepted, 3)
	_check("burst excess flagged", v.rejected, 17)

	v = Validator.new()
	v.submit(1, 0.4, 30.0)
	v.submit(2, 0.5, 30.0)
	_check("Wi-Fi bunching of 2 early reps tolerated", [v.accepted, v.rejected], [2, 0])

	v = Validator.new()
	_check("report during host countdown rejected", [v.submit(1, -2.0, 30.0), v.rejected], [false, 1])
	_check("report just before host clock starts tolerated", v.submit(1, -0.1, 30.0), true)

	v = Validator.new()
	for i in range(1, 6):
		v.submit(i, float(i), 30.0)
	_check("report within late grace accepted", v.submit(6, 30.5, 30.0), true)
	_check("report after grace rejected", v.submit(7, 31.0, 30.0), false)

	v = Validator.new()
	v.submit(1, 1.0, 30.0)
	_check("duplicate report is ignored, not flagged", [v.submit(1, 1.2, 30.0), v.accepted, v.rejected], [false, 1, 0])

	print("\n%s" % ("ALL TESTS PASSED" if _failures == 0 else "%d CHECK(S) FAILED" % _failures))
	quit(1 if _failures > 0 else 0)

func _check(name: String, actual, expected) -> void:
	if actual == expected:
		print("PASS  %s" % name)
	else:
		_failures += 1
		print("FAIL  %s: expected %s, got %s" % [name, expected, actual])
