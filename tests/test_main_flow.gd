extends SceneTree

## Headless test of the offline campaign without the pose plugin. Run with:
##   godot --headless --path . --script res://tests/test_main_flow.gd
## Uses its own save file, never the player's.

const TEST_SAVE := "user://test_campaign_save.cfg"

var _failures := 0
var _completed := false
# Loaded at runtime (not preload) so the Pose autoload exists when main.gd compiles.
var _main_scene: PackedScene

func _initialize() -> void:
	_remove_save()
	await process_frame
	_main_scene = load("res://scenes/main.tscn")
	await _run()
	_remove_save()
	if not _completed:
		_failures += 1
		print("FAIL  test run aborted before finishing (see script errors above)")
	print("\n%s" % ("ALL TESTS PASSED" if _failures == 0 else "%d CHECK(S) FAILED" % _failures))
	quit(1 if _failures > 0 else 0)

func _run() -> void:
	var main := _new_main()
	await process_frame
	_check("Pose autoload present", root.has_node("Pose"), true)
	_check("no plugin on desktop", root.get_node("Pose").available, false)
	_check("fresh save starts at level 1", main.highest_unlocked, 1)

	# Locked levels cannot be opened.
	main._prepare_level(3)
	_check("locked level 3 refused", main.screen_name != "calibration", true)

	# Countdown blocks reps, then Level 1 clears and unlocks Level 2.
	main._prepare_level(1)
	_check("calibration screen", main.screen_name, "calibration")
	main._start_challenge()
	_check("game screen", main.screen_name, "game")
	_check("practice button shown without plugin", _has_button_text(main, "LOG PRACTICE REP"), true)
	_check("offline get-ready countdown", main.countdown, main.OFFLINE_GET_READY)
	main._log_rep()
	_check("reps ignored during countdown", main.reps, 0)
	_skip_countdown(main)
	for i in 5:
		main._log_rep()
	_check("level 1 ends on goal", main.screen_name, "result")
	_check("level 2 unlocked", main.highest_unlocked, 2)
	_check("level 1 stats", main.get_level_stats(1), {"attempts": 1, "clears": 1, "best": 5})
	_check("next level button offered", _has_button_text(main, "NEXT LEVEL"), true)

	# Timer runs out on Level 2: no unlock, attempt recorded.
	main._prepare_level(2)
	main._start_challenge()
	_skip_countdown(main)
	for i in 3:
		main._log_rep()
	# Pause freezes the timer.
	var before: float = main.remaining
	main._go_back()
	_check("back button pauses a level", main.screen_name, "pause")
	main._process(5.0)
	_check("timer frozen while paused", main.remaining, before)
	main._go_back()
	_check("back on pause resumes", main.screen_name, "game")
	_check("resume gives a get-ready countdown", main.countdown, main.RESUME_GET_READY)
	_skip_countdown(main)
	main._process(main.remaining + 0.1)
	_check("time-out shows result", main.screen_name, "result")
	_check("level 3 still locked after failing level 2", main.highest_unlocked, 2)
	_check("level 2 stats", main.get_level_stats(2), {"attempts": 1, "clears": 0, "best": 3})
	_check("no next level after a fail", _has_button_text(main, "NEXT LEVEL"), false)

	# Sound preference and progress survive a restart.
	main._toggle_sound()
	main.queue_free()
	await process_frame
	var reopened := _new_main()
	await process_frame
	_check("unlock survives restart", reopened.highest_unlocked, 2)
	_check("stats survive restart", reopened.get_level_stats(1).clears, 1)
	_check("sound setting survives restart", reopened.sound_enabled, false)

	# Clearing level 5 completes the campaign without offering a level 6.
	reopened.highest_unlocked = 5
	reopened._prepare_level(5)
	reopened._start_challenge()
	_skip_countdown(reopened)
	for i in 20:
		reopened._log_rep()
	_check("campaign complete headline", _has_label_text(reopened, "CAMPAIGN COMPLETE"), true)
	_check("no next level after level 5", _has_button_text(reopened, "NEXT LEVEL"), false)
	_check("unlock capped at 5", reopened.highest_unlocked, 5)
	reopened._go_back()
	_check("back from result returns to menu", reopened.screen_name, "menu")
	reopened.queue_free()
	await process_frame

	# A corrupted save file falls back to defaults instead of crashing.
	var f := FileAccess.open(TEST_SAVE, FileAccess.WRITE)
	f.store_string("[progress]\nhighest_unlocked=\"banana\"\n[stats]\nlevel_1=42\n")
	f.close()
	var corrupted := _new_main()
	await process_frame
	_check("corrupt unlock clamps to 1", corrupted.highest_unlocked, 1)
	_check("corrupt stats ignored", corrupted.get_level_stats(1).attempts, 0)
	corrupted.queue_free()
	await process_frame
	_completed = true

func _new_main() -> Control:
	var main: Control = _main_scene.instantiate()
	main.save_path = TEST_SAVE
	root.add_child(main)
	return main

func _skip_countdown(main: Control) -> void:
	main._process(main.countdown + 0.01)

func _remove_save() -> void:
	for path in [TEST_SAVE, TEST_SAVE + ".tmp"]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)

func _has_button_text(main: Control, fragment: String) -> bool:
	for node in main.find_children("*", "Button", true, false):
		if fragment in (node as Button).text and _is_live(node, main):
			return true
	return false

func _has_label_text(main: Control, fragment: String) -> bool:
	for node in main.find_children("*", "Label", true, false):
		if fragment in (node as Label).text and _is_live(node, main):
			return true
	return false

## Screens are replaced with queue_free, so ignore nodes under a screen that is
## already queued for deletion but not yet freed.
func _is_live(node: Node, main: Node) -> bool:
	var current := node
	while current != null and current != main:
		if current.is_queued_for_deletion():
			return false
		current = current.get_parent()
	return true

func _check(name: String, actual, expected) -> void:
	if actual == expected:
		print("PASS  %s" % name)
	else:
		_failures += 1
		print("FAIL  %s: expected %s, got %s" % [name, expected, actual])
