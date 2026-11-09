extends SceneTree

## Two-process Wi-Fi match test over loopback, driving the real game code.
## Start both at once (tests/run_online_test.ps1 does this):
##   godot --headless --path . --script res://tests/test_online_match.gd -- host
##   godot --headless --path . --script res://tests/test_online_match.gd -- guest
##
## Scenario:
##   1. Guest joins; both reach the positioning screen.
##   2. Match 1: host logs 3 reps, guest logs 4 then forges a jump to 50.
##      Host credits the guest 5 and flags 1 rejected update; both phones
##      must show the same score (guest 5, host 3).
##   3. Guest requests a rematch; both log 2 reps -> TIE on both phones.
##   4. Host starts match 3; guest leaves mid-match -> host shows "rival left".
##   5. Guest: invalid IP is rejected; joining a host that is gone fails cleanly.
##   Campaign unlocks never change.

const MATCH_SECONDS := 6.0
const REP_GAP := 0.8

var _failures := 0
var _completed := false
var _role := ""
var main: Control

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	_role = args[0] if args.size() > 0 else ""
	if _role not in ["host", "guest"]:
		print("FAIL  pass -- host or -- guest")
		quit(1)
		return
	await process_frame
	main = load("res://scenes/main.tscn").instantiate()
	main.save_path = "user://test_online_%s.cfg" % _role
	main.host_bind_ip = "127.0.0.1"
	main.match_seconds_override = MATCH_SECONDS
	root.add_child(main)
	await process_frame
	if _role == "host":
		await _run_host()
	else:
		await _run_guest()
	if not _completed:
		_failures += 1
		_log("FAIL  run aborted before finishing")
	_log("%s" % ("ALL TESTS PASSED" if _failures == 0 else "%d CHECK(S) FAILED" % _failures))
	main._return_to_menu()
	for path in [main.save_path, main.save_path + ".tmp"]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
	quit(1 if _failures > 0 else 0)

# --- Host ------------------------------------------------------------------------

func _run_host() -> void:
	main._show_lobby("", true)
	main._host_match()
	_check("hosting status shown", "Hosting" in main.opponent_status, true)
	_log("INFO  host would show: %s" % main.opponent_status)
	if not await _wait_until(func(): return main.peer_connected, 20.0, "guest to connect"):
		return
	_check("host on positioning screen", main.screen_name, "calibration")
	_check("host sees START MATCH", _has_button_text("Start match"), true)

	# Match 1
	main._start_challenge()
	if not await _play_reps(3):
		return
	if not await _wait_until(func(): return main.screen_name == "result", 15.0, "match 1 result"):
		return
	_check("match 1 host score", [main.reps, main.opponent_score], [3, 5])
	_check("match 1 host outcome", main.online_outcome(), "RIVAL WINS")
	_check("match 1 forged update flagged", main.rejected_updates, 1)

	# Match 2: guest requests the rematch.
	if not await _wait_until(func(): return main.screen_name == "game", 15.0, "guest rematch request"):
		return
	if not await _play_reps(2):
		return
	if not await _wait_until(func(): return main.screen_name == "result", 15.0, "match 2 result"):
		return
	_check("match 2 host score", [main.reps, main.opponent_score], [2, 2])
	_check("match 2 tie", main.online_outcome(), "TIE")

	# Match 3: guest leaves mid-match.
	main._restart_challenge()
	_check("host started match 3", main.screen_name, "game")
	if not await _wait_until(func(): return main.disconnect_reason != "", 30.0, "guest to leave"):
		return
	_check("host told rival left", main.disconnect_reason, "Your rival left the match.")
	_check("host on result after disconnect", main.screen_name, "result")
	_check("campaign untouched (host)", [main.highest_unlocked, main.level_stats.size()], [1, 0])
	_completed = true

# --- Guest -----------------------------------------------------------------------

func _run_guest() -> void:
	main._show_lobby("", true)
	await create_timer(1.0).timeout  # let the host open its port
	main.lobby_address.text = "127.0.0.1"
	main._join_match()
	if not await _wait_until(func(): return main.screen_name == "calibration", 20.0, "connection to host"):
		return
	_check("guest waits for host (no start button)", _has_button_text("Start match"), false)

	# Match 1
	if not await _wait_until(func(): return main.screen_name == "game", 20.0, "host to start match 1"):
		return
	if not await _play_reps(4):
		return
	main.rpc_id(1, "submit_score", 50, main.match_id)  # forged report
	if not await _wait_until(func(): return main.screen_name == "result", 15.0, "match 1 result"):
		return
	_check("match 1 guest score", [main.reps, main.opponent_score], [5, 3])
	_check("match 1 guest outcome", main.online_outcome(), "YOU WIN")
	_check("match 1 rejection shown to guest", main.rejected_updates, 1)

	# Match 2: guest asks for the rematch.
	main._restart_challenge()
	if not await _wait_until(func(): return main.screen_name == "game", 10.0, "rematch to start"):
		return
	if not await _play_reps(2):
		return
	if not await _wait_until(func(): return main.screen_name == "result", 15.0, "match 2 result"):
		return
	_check("match 2 guest score", [main.reps, main.opponent_score], [2, 2])
	_check("match 2 tie", main.online_outcome(), "TIE")

	# Match 3: leave mid-match.
	if not await _wait_until(func(): return main.screen_name == "game", 15.0, "host to start match 3"):
		return
	await _wait_until(func(): return main.countdown <= 0.0, 10.0, "match 3 countdown")
	main._log_rep()
	main._return_to_menu()
	_check("guest left to menu", [main.screen_name, main.multiplayer.multiplayer_peer == null], ["menu", true])
	_check("campaign untouched (guest)", [main.highest_unlocked, main.level_stats.size()], [1, 0])

	# Bad input and an unreachable host.
	main._show_lobby("", true)
	main.lobby_address.text = "banana"
	main._join_match()
	_check("invalid IP rejected", "isn't an IPv4 address" in main.opponent_status, true)
	await create_timer(3.0).timeout  # host process closes its server
	main.lobby_address.text = "127.0.0.1"
	var started := Time.get_ticks_msec()
	main._join_match()
	if not await _wait_until(func(): return main.multiplayer.multiplayer_peer == null, main.CONNECT_TIMEOUT + 4.0, "unreachable host to fail"):
		return
	var waited := (Time.get_ticks_msec() - started) / 1000.0
	_log("INFO  unreachable host gave up after %.1f s: %s" % [waited, main.opponent_status])
	_check("unreachable host explained", "No host answered" in main.opponent_status or "could not be reached" in main.opponent_status, true)
	_check("still on lobby screen", main.screen_name, "lobby")
	_completed = true

# --- Helpers -----------------------------------------------------------------------

func _play_reps(count: int) -> bool:
	if not await _wait_until(func(): return main.screen_name == "game" and main.countdown <= 0.0, 12.0, "countdown"):
		return false
	for i in count:
		await create_timer(REP_GAP).timeout
		main._log_rep()
	return true

func _wait_until(condition: Callable, timeout: float, what: String) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout * 1000.0)
	while not condition.call():
		if Time.get_ticks_msec() > deadline:
			_failures += 1
			_log("FAIL  timed out waiting for %s (screen=%s, status=%s)" % [what, main.screen_name, main.opponent_status])
			return false
		await process_frame
	return true

func _has_button_text(fragment: String) -> bool:
	for node in main.find_children("*", "Button", true, false):
		var live := true
		var current: Node = node
		while current != null and current != main:
			if current.is_queued_for_deletion():
				live = false
				break
			current = current.get_parent()
		if live and fragment in (node as Button).text:
			return true
	return false

func _check(name: String, actual, expected) -> void:
	if actual == expected:
		_log("PASS  %s" % name)
	else:
		_failures += 1
		_log("FAIL  %s: expected %s, got %s" % [name, expected, actual])

func _log(line: String) -> void:
	print("[%s] %s" % [_role.to_upper(), line])
