extends Control

const LEVELS := [
	{"goal": 5, "seconds": 30},
	{"goal": 8, "seconds": 35},
	{"goal": 12, "seconds": 45},
	{"goal": 16, "seconds": 55},
	{"goal": 20, "seconds": 60},
]
const SAVE_PATH := "user://push_up_battle.cfg"
const PORT := 27045
const INK := Color("101a1d")
const PANEL := Color("1a292c")
const MUTED := Color("9caeaa")
const LIME := Color("d5fa70")
const ORANGE := Color("ff895f")
## Screens that keep the pose camera running between them.
const CAMERA_SCREENS := ["calibration", "game", "pause", "result"]

## Seconds to get into position before a level or match (and after resuming).
const OFFLINE_GET_READY := 5.0
const ONLINE_GET_READY := 5.0
const RESUME_GET_READY := 3.0
## Give up on an unanswered join after this many seconds.
const CONNECT_TIMEOUT := 8.0
## ENet peer timeout (ms): a phone that drops off Wi-Fi is noticed within this.
const PEER_TIMEOUT_MIN_MS := 3000
const PEER_TIMEOUT_MAX_MS := 8000

## Overridable so tests never touch the player's real save.
var save_path := SAVE_PATH
## Overridable so tests can host on loopback only.
var host_bind_ip := "*"
## Tests only: shortens matches. 0 uses the level's time limit.
var match_seconds_override := 0.0
var highest_unlocked := 1
var sound_enabled := true
## Per-level campaign stats: level number -> {attempts, clears, best}.
var level_stats := {}
var current_level := 1
var mode := "offline"
var reps := 0
var remaining := 0.0
var elapsed := 0.0
var countdown := 0.0
var opponent_score := 0
var opponent_status := "Waiting for opponent"
var tracker_message := ""
var match_id := ""
var match_active := false
var match_finished := false
var peer_connected := false
## Host only: plausibility check for the guest's reported reps.
var score_validator := ScoreValidator.new()
## Guest-update rejections for the last match, as reported by the host.
var rejected_updates := 0
## Why the last online match ended early ("" if it finished normally).
var disconnect_reason := ""
var lobby_address: LineEdit
var host_button: Button
var lobby_status: Label
var current_content: VBoxContainer
var screen_name := "title"
var _rep_tracker := RepTracker.new()
var _sound_player: AudioStreamPlayer
var _last_countdown_tick := 0
var _grace_time := 0.0
var _connect_attempt := 0

func _ready() -> void:
	_load_save()
	get_tree().auto_accept_quit = false
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	_rep_tracker.rep_counted.connect(_on_detected_rep)
	_rep_tracker.tracking_changed.connect(_on_tracking_changed)
	Pose.pose_sample.connect(_on_pose_sample)
	_sound_player = AudioStreamPlayer.new()
	_sound_player.stream = _make_tone()
	add_child(_sound_player)
	_show_screen("title")

func _process(delta: float) -> void:
	if screen_name != "game" or not match_active:
		return
	if countdown > 0.0:
		countdown = maxf(0.0, countdown - delta)
		var tick := ceili(countdown)
		if tick != _last_countdown_tick:
			_last_countdown_tick = tick
			# Audible countdown: the player is on the floor, not watching the screen.
			_play_sound(1.9 if tick == 0 else 0.9)
		_refresh_game_labels()
		return
	if remaining > 0.0:
		remaining = maxf(0.0, remaining - delta)
		elapsed += delta
		if remaining <= 0.0:
			_play_sound(0.72)
		_refresh_game_labels()
	if remaining > 0.0:
		return
	if mode == "offline":
		_end_offline_challenge()
	elif multiplayer.is_server() and not match_finished:
		# Wait briefly for guest reps already in flight before deciding.
		_grace_time += delta
		if _grace_time >= ScoreValidator.LATE_GRACE_SECONDS:
			_finish_online_match()

func _unhandled_key_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		if screen_name not in ["title", "menu"]:
			_go_back()
		get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_SPACE and screen_name == "game":
		_log_rep()

func _show_screen(which: String, heading := "", eyebrow := "") -> void:
	screen_name = which
	if which not in CAMERA_SCREENS:
		Pose.stop()
	for child in get_children():
		if child != _sound_player:
			child.queue_free()
	var background := ColorRect.new()
	background.color = INK
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(background)
	var outer := MarginContainer.new()
	outer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	outer.add_theme_constant_override("margin_left", 32)
	outer.add_theme_constant_override("margin_right", 32)
	outer.add_theme_constant_override("margin_top", 30)
	outer.add_theme_constant_override("margin_bottom", 28)
	add_child(outer)
	var shell := VBoxContainer.new()
	shell.add_theme_constant_override("separation", 20)
	outer.add_child(shell)
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 8)
	shell.add_child(top)
	var brand := _label("UP / DOWN", 15, LIME)
	brand.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(brand)
	if which not in ["title", "menu"] and not (mode == "online" and which == "game"):
		var back := _button("‹  BACK", Callable(self, "_return_to_menu"), false)
		back.custom_minimum_size = Vector2(100, 48)
		top.add_child(back)
	if eyebrow != "":
		shell.add_child(_label(eyebrow.to_upper(), 14, ORANGE))
	if heading != "":
		shell.add_child(_label(heading, 34, Color.WHITE))
	var panel := PanelContainer.new()
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var style := StyleBoxFlat.new()
	style.bg_color = PANEL
	style.set_corner_radius_all(22)
	style.content_margin_left = 24
	style.content_margin_right = 24
	style.content_margin_top = 24
	style.content_margin_bottom = 24
	panel.add_theme_stylebox_override("panel", style)
	shell.add_child(panel)
	var scroller := ScrollContainer.new()
	scroller.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_child(scroller)
	current_content = VBoxContainer.new()
	current_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	current_content.add_theme_constant_override("separation", 16)
	scroller.add_child(current_content)
	match which:
		"title": _build_title()
		"menu": _build_menu()
		"mode": _build_mode()
		"levels": _build_levels()
		"lobby": _build_lobby()
		"calibration": _build_calibration()
		"game": _build_game()
		"pause": _build_pause()
		"result": _build_result()
		"settings": _build_settings()
		"credits": _build_credits()
	var footer := _label("A BODYWEIGHT ARCADE GAME   •   PORTRAIT MODE", 12, MUTED)
	footer.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	shell.add_child(footer)

func _build_title() -> void:
	current_content.add_child(_label("YOUR NEXT\nREP IS THE\nNEXT LEVEL.", 38, Color.WHITE))
	current_content.add_child(_label("Five levels. One clean rep at a time.", 17, MUTED))
	var card := _card("THE CHALLENGE", "Start with 5 reps in 30 seconds. Clear each level to unlock the next.")
	current_content.add_child(card)
	current_content.add_child(_button("TAP TO START  →", func(): _show_screen("menu", "Push-up Battle", "Your training floor"), true))
	current_content.add_child(_label("OFFLINE CAMPAIGN  /  WI-FI DUEL", 13, LIME))

func _build_menu() -> void:
	current_content.add_child(_label("TRAIN YOUR WAY.", 31, Color.WHITE))
	current_content.add_child(_label("Pick a mode. Set your stance. Get moving.", 16, MUTED))
	current_content.add_child(_button("PLAY", func(): _show_screen("mode", "Choose your arena", "01 / Select mode"), true))
	current_content.add_child(_button("SETTINGS", func(): _show_screen("settings", "Your preferences", "02 / Settings")))
	current_content.add_child(_button("CREDITS", func(): _show_screen("credits", "Made to move", "03 / Credits")))
	current_content.add_child(_card("CAMERA PRIVACY", "Pose tracking runs on your phone. Video is never saved or sent; matches share only rep counts."))

func _build_mode() -> void:
	current_content.add_child(_label("HOW DO YOU WANT TO PLAY?", 21, Color.WHITE))
	current_content.add_child(_button("PLAY OFFLINE", func():
		mode = "offline"
		_show_screen("levels", "Choose a level", "02 / Solo campaign")
	, true))
	current_content.add_child(_label("Five campaign levels. Your unlocks stay on this device.", 15, MUTED))
	current_content.add_child(_button("PLAY ONLINE", func():
		mode = "online"
		_show_lobby("Host a match, or enter the host phone's IP to join.", true)
	, false))
	current_content.add_child(_label("Same Wi-Fi duel. Online results never change campaign unlocks.", 15, MUTED))

func _build_levels() -> void:
	for i in range(LEVELS.size()):
		var level_num := i + 1
		var data: Dictionary = LEVELS[i]
		var locked := level_num > highest_unlocked
		var stats := get_level_stats(level_num)
		var state := "LOCKED" if locked else ("CLEARED" if stats.clears > 0 else "READY")
		var title := "LEVEL %02d     %s" % [level_num, state]
		var detail := "%d REPS  /  %d SEC" % [data.goal, data.seconds]
		if stats.attempts > 0:
			detail += "  •  BEST %d" % stats.best
		var tile := _button("%s\n%s" % [title, detail], func(): _prepare_level(level_num), not locked)
		tile.custom_minimum_size.y = 94
		tile.disabled = locked
		current_content.add_child(tile)
	current_content.add_child(_label("Clear a level to open the next one. Progress saves automatically.", 14, MUTED))

func _build_lobby() -> void:
	current_content.add_child(_label("TWO PLAYERS. SAME CHALLENGE.", 19, Color.WHITE))
	current_content.add_child(_label("Both phones must be on the same Wi-Fi. Most valid reps when time runs out wins.", 14, MUTED))
	lobby_status = _label(opponent_status, 15, LIME)
	lobby_status.name = "LobbyStatus"
	current_content.add_child(lobby_status)
	host_button = _button("HOST A MATCH", _host_match, true)
	current_content.add_child(host_button)
	current_content.add_child(_label("OR JOIN A HOST", 13, ORANGE))
	lobby_address = LineEdit.new()
	lobby_address.placeholder_text = "Host local IP  ·  e.g. 192.168.1.12"
	lobby_address.custom_minimum_size.y = 56
	lobby_address.add_theme_font_size_override("font_size", 16)
	lobby_address.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_NUMBER_DECIMAL
	lobby_address.text_submitted.connect(func(_text: String): _join_match())
	current_content.add_child(lobby_address)
	current_content.add_child(_button("JOIN MATCH", _join_match, false))
	current_content.add_child(_label("Port %d  •  Only rep counts and match state are shared." % PORT, 12, MUTED))

func _build_calibration() -> void:
	var data: Dictionary = LEVELS[current_level - 1]
	if mode == "online":
		var is_host := multiplayer.multiplayer_peer != null and multiplayer.is_server()
		current_content.add_child(_label("WI-FI MATCH  /  %d SECONDS" % data.seconds, 24, LIME))
		current_content.add_child(_label("Most valid reps when time runs out wins.", 16, ORANGE))
		current_content.add_child(preload("res://scripts/camera_preview.gd").new())
		current_content.add_child(_card("POSITIONING", "Prop the phone in portrait mode at a side angle. Keep your shoulder, arm and hip in the guide."))
		if is_host:
			current_content.add_child(_label("Guest connected. Both phones start together.", 15, LIME))
			current_content.add_child(_button("MATCH LENGTH  ·  %d SEC" % data.seconds, _cycle_match_length, false))
			current_content.add_child(_button("START MATCH  →", _start_challenge, true))
		else:
			current_content.add_child(_label("Connected. Get into position — the host starts the match.", 15, LIME))
		current_content.add_child(_button("LEAVE MATCH", _return_to_menu, false))
		return
	current_content.add_child(_label("LEVEL %02d  /  %d REPS" % [current_level, data.goal], 24, LIME))
	current_content.add_child(_label("TIME LIMIT   %d SECONDS" % data.seconds, 16, ORANGE))
	current_content.add_child(preload("res://scripts/camera_preview.gd").new())
	current_content.add_child(_card("POSITIONING", "Prop the phone in portrait mode at a side angle. Fit shoulders, hips and knees in the guide. Keep the phone stable and the floor clear."))
	current_content.add_child(_label("READY CHECK", 14, MUTED))
	current_content.add_child(_label("☐  Phone stable   ☐  Full body in frame   ☐  Clear floor", 15, Color.WHITE))
	current_content.add_child(_button("I'M READY  →", _start_challenge, true))
	current_content.add_child(_button("BACK TO LEVELS", func(): _show_screen("levels", "Choose a level", "02 / Solo campaign"), false))

func _build_game() -> void:
	var seconds: int = LEVELS[current_level - 1].seconds
	if mode == "online":
		current_content.add_child(_label("WI-FI MATCH  /  MOST REPS IN %d SEC" % seconds, 16, MUTED))
	else:
		current_content.add_child(_label("LEVEL %02d  /  TARGET %d" % [current_level, LEVELS[current_level - 1].goal], 16, MUTED))
	var count := _label("%02d" % reps, 82, LIME)
	count.name = "RepValue"
	count.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	current_content.add_child(count)
	current_content.add_child(_label("VALID REPS", 14, MUTED))
	var timer_label := _label(_timer_text(), 38, Color.WHITE)
	timer_label.name = "TimerValue"
	timer_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	current_content.add_child(timer_label)
	if mode == "online":
		var rival := _label(_rival_text(), 16, ORANGE)
		rival.name = "OpponentValue"
		current_content.add_child(rival)
	else:
		current_content.add_child(_label("STEADY DOWN. FULL RETURN.", 14, MUTED))
	if tracker_message == "":
		tracker_message = _default_tracker_message()
	var tracking_label := _label(tracker_message, 13, ORANGE if not _rep_tracker.tracked else LIME)
	tracking_label.name = "TrackingStatus"
	current_content.add_child(tracking_label)
	if Pose.available:
		var preview := preload("res://scripts/camera_preview.gd").new()
		preview.preview_height = 200.0
		preview.show_title = false
		current_content.add_child(preview)
	else:
		current_content.add_child(_button("LOG PRACTICE REP  +1", _log_rep, true))
		current_content.add_child(_label("Practice input: this build has no pose tracker, so reps are logged by hand.", 12, MUTED))
	if mode == "online":
		# No pause online: it would desynchronize the two match clocks.
		current_content.add_child(_button("LEAVE MATCH", _return_to_menu, false))
	else:
		current_content.add_child(_button("PAUSE", _pause_game, false))

func _build_pause() -> void:
	current_content.add_child(_label("TAKE A BREATH.", 28, Color.WHITE))
	current_content.add_child(_button("RESUME", _resume_game, true))
	current_content.add_child(_button("RESTART", _restart_challenge, false))
	current_content.add_child(_button("SOUND  ·  %s" % ("ON" if sound_enabled else "OFF"), _toggle_sound, false))
	current_content.add_child(_button("QUIT TO MENU", _return_to_menu, false))

func _build_result() -> void:
	if mode == "online":
		_build_online_result()
		return
	var goal: int = LEVELS[current_level - 1].goal
	var cleared := reps >= goal
	current_content.add_child(_label("LEVEL %02d" % current_level, 15, MUTED))
	var campaign_done := cleared and current_level == LEVELS.size()
	var headline := "CAMPAIGN COMPLETE" if campaign_done else ("LEVEL CLEARED" if cleared else "TRY AGAIN")
	current_content.add_child(_label(headline, 34, LIME if cleared else ORANGE))
	var stats := get_level_stats(current_level)
	current_content.add_child(_card("YOUR RESULT", "%d / %d valid reps   •   %.1f sec elapsed\nBest %d   •   Attempt %d" % [reps, goal, elapsed, stats.best, stats.attempts]))
	if campaign_done:
		current_content.add_child(_card("ALL FIVE LEVELS", "You cleared the full campaign. Replay any level to beat your best."))
	elif not cleared:
		current_content.add_child(_label("Need %d more. Go all the way down and fully back up for each rep." % (goal - reps), 14, MUTED))
	current_content.add_child(_button("RETRY", _restart_challenge, true))
	if cleared and current_level < LEVELS.size():
		current_content.add_child(_button("NEXT LEVEL  →", func(): _prepare_level(current_level + 1), false))
	current_content.add_child(_button("MENU", _return_to_menu, false))

func _build_online_result() -> void:
	current_content.add_child(_label("WI-FI MATCH  /  %d SEC" % LEVELS[current_level - 1].seconds, 15, MUTED))
	if disconnect_reason != "":
		current_content.add_child(_label("MATCH ENDED", 34, ORANGE))
		current_content.add_child(_card("DISCONNECTED", disconnect_reason + " No campaign progress was changed."))
		current_content.add_child(_button("BACK TO MENU", _return_to_menu, true))
		return
	var outcome := online_outcome()
	current_content.add_child(_label(outcome, 34, LIME if outcome != "RIVAL WINS" else ORANGE))
	var result_card := _card("MATCH RESULT", "You: %d   /   Rival: %d" % [reps, opponent_score])
	result_card.name = "MatchResult"
	current_content.add_child(result_card)
	if rejected_updates > 0:
		current_content.add_child(_label("The host ignored %d implausible guest score update(s)." % rejected_updates, 13, ORANGE))
	current_content.add_child(_label("Online results don't change campaign unlocks.", 13, MUTED))
	if peer_connected:
		current_content.add_child(_button("REMATCH", _restart_challenge, true))
		current_content.add_child(_label("Either player can start a rematch; both phones count down together.", 12, MUTED))
	else:
		current_content.add_child(_label("Your rival has left, so a rematch isn't available.", 14, ORANGE))
	current_content.add_child(_button("LEAVE MATCH", _return_to_menu, false))

func _build_settings() -> void:
	current_content.add_child(_label("SOUND", 18, Color.WHITE))
	current_content.add_child(_button("SOUND  ·  %s" % ("ON" if sound_enabled else "OFF"), _toggle_sound, true))
	current_content.add_child(_label("Orientation is fixed to portrait. Sound preference saves on this device.", 14, MUTED))
	current_content.add_child(_button("DONE", func(): _show_screen("menu", "Push-up Battle", "Your training floor"), false))

func _build_credits() -> void:
	current_content.add_child(_label("PUSH-UP BATTLE", 26, LIME))
	current_content.add_child(_label("A bodyweight arcade prototype for the ITSD 85 mobile-game lab.", 16, Color.WHITE))
	current_content.add_child(_card("ASSETS & LICENSES", "Interface, copy and vector icon are original project assets. Pose tracking uses Google ML Kit Pose Detection and AndroidX CameraX; see docs/CREDITS.md."))
	current_content.add_child(_card("TEAM", "Add team names and roles to docs/CREDITS.md."))
	current_content.add_child(_button("DONE", func(): _show_screen("menu", "Push-up Battle", "Your training floor"), false))

# --- Challenge flow ------------------------------------------------------------

func _prepare_level(level_num: int) -> void:
	if level_num > highest_unlocked:
		return
	current_level = level_num
	mode = "offline"
	_show_screen("calibration", "Set your position", "03 / Prepare")

func _start_challenge() -> void:
	if mode == "online" and not peer_connected:
		_show_lobby("Your rival is no longer connected. Host or join again.", false)
		return
	reps = 0
	opponent_score = 0
	opponent_status = "Ready"
	remaining = match_seconds()
	elapsed = 0.0
	countdown = ONLINE_GET_READY if mode == "online" else OFFLINE_GET_READY
	_last_countdown_tick = ceili(countdown)
	_grace_time = 0.0
	match_finished = false
	match_active = true
	rejected_updates = 0
	disconnect_reason = ""
	score_validator.reset()
	_rep_tracker.reset()
	tracker_message = ""
	if mode == "online" and multiplayer.is_server():
		match_id = str(Time.get_ticks_usec())
		rpc("begin_remote_match", current_level, match_id)
	_show_screen("game", "Challenge on", "04 / Move")

@rpc("authority", "call_remote", "reliable")
func begin_remote_match(level_num: int, id: String) -> void:
	current_level = clampi(level_num, 1, LEVELS.size())
	match_id = id
	mode = "online"
	_start_challenge()

func _log_rep() -> void:
	_try_add_rep(reps + 1)

func _on_detected_rep(total: int) -> void:
	if total > reps:
		_try_add_rep(total)

## Reps only count while the clock is running: not during the countdown,
## not after time is up, and not while paused.
func _try_add_rep(total: int) -> void:
	if not match_active or screen_name != "game" or countdown > 0.0 or remaining <= 0.0:
		return
	reps = total
	_play_sound(1.0)
	_refresh_game_labels()
	if mode == "online" and multiplayer.multiplayer_peer != null and peer_connected:
		if multiplayer.is_server():
			rpc("receive_score", reps, match_id)
		else:
			rpc_id(1, "submit_score", reps, match_id)
	if mode == "offline" and reps >= LEVELS[current_level - 1].goal:
		_end_offline_challenge()

## Guest -> host: the guest's own rep count. Validated before it counts.
@rpc("any_peer", "call_remote", "reliable")
func submit_score(score: int, id: String) -> void:
	if not multiplayer.is_server() or multiplayer.get_remote_sender_id() == 1:
		return
	if id != match_id or match_finished:
		return
	var match_clock := elapsed - countdown  # Negative while the host is still counting down.
	score_validator.submit(score, match_clock, match_seconds())
	opponent_score = score_validator.accepted
	opponent_status = "Playing"
	_refresh_game_labels()

## Host -> guest: the host's rep count for the live rival display.
@rpc("authority", "call_remote", "reliable")
func receive_score(score: int, id: String) -> void:
	if id != match_id or match_finished:
		return
	opponent_score = maxi(0, score)
	opponent_status = "Playing"
	_refresh_game_labels()

func _on_pose_sample(depth: float, confidence: float, dt: float) -> void:
	if screen_name != "game" or not match_active or countdown > 0.0:
		return
	_rep_tracker.update_pose(depth, confidence, dt)

func _default_tracker_message() -> String:
	if Pose.available:
		return "Get side-on to the phone and hold the top position to start counting."
	return "No pose tracker in this build. Use the practice input."

func _on_tracking_changed(is_tracking: bool) -> void:
	if is_tracking:
		tracker_message = "Body tracked. Complete a full down-and-up rep."
	else:
		tracker_message = "Counting paused. " + Pose.reason_hint(Pose.last_reason)
	var tracking_label := find_child("TrackingStatus", true, false) as Label
	if tracking_label:
		tracking_label.text = tracker_message
		tracking_label.add_theme_color_override("font_color", LIME if is_tracking else ORANGE)

func _timer_text() -> String:
	if countdown > 0.0:
		return "START IN %d" % ceili(countdown)
	if remaining <= 0.0:
		return "TIME!" if mode == "offline" or multiplayer.multiplayer_peer == null or multiplayer.is_server() else "TIME!  WAITING FOR HOST"
	return "%02d SEC" % ceili(remaining)

func _rival_text() -> String:
	return "RIVAL   %02d   •   %s" % [opponent_score, opponent_status]

func _refresh_game_labels() -> void:
	var rep_label := find_child("RepValue", true, false) as Label
	var timer_label := find_child("TimerValue", true, false) as Label
	var opponent_label := find_child("OpponentValue", true, false) as Label
	var tracking_label := find_child("TrackingStatus", true, false) as Label
	if rep_label:
		rep_label.text = "%02d" % reps
	if timer_label:
		timer_label.text = _timer_text()
	if opponent_label:
		opponent_label.text = _rival_text()
	if tracking_label:
		tracking_label.text = tracker_message

func _end_offline_challenge() -> void:
	match_active = false
	remaining = maxf(0.0, remaining)
	var cleared: bool = reps >= LEVELS[current_level - 1].goal
	var stats := get_level_stats(current_level)
	stats.attempts += 1
	stats.best = maxi(stats.best, reps)
	if cleared:
		stats.clears += 1
		highest_unlocked = mini(LEVELS.size(), maxi(highest_unlocked, current_level + 1))
	level_stats[current_level] = stats
	_save_data()
	_play_sound(1.45 if cleared else 0.72)
	_show_screen("result", "Your result", "05 / Score")

# --- Online match ----------------------------------------------------------------

## Host decides the final scores and sends the same numbers to both phones;
## each phone derives its outcome from them, so the results always agree.
func _finish_online_match() -> void:
	if match_finished:
		return
	match_finished = true
	match_active = false
	opponent_score = score_validator.accepted
	rejected_updates = score_validator.rejected
	rpc("show_online_result", reps, opponent_score, rejected_updates, match_id)
	_play_sound(1.45 if reps >= opponent_score else 0.72)
	_show_screen("result", "Match complete", "05 / Score")

@rpc("authority", "call_remote", "reliable")
func show_online_result(host_score: int, guest_score: int, rejected: int, id: String) -> void:
	if id != match_id:
		return
	match_finished = true
	match_active = false
	# The host's verdict replaces the guest's local count.
	reps = guest_score
	opponent_score = host_score
	rejected_updates = rejected
	_play_sound(1.45 if reps >= opponent_score else 0.72)
	_show_screen("result", "Match complete", "05 / Score")

func match_seconds() -> float:
	return match_seconds_override if match_seconds_override > 0.0 else float(LEVELS[current_level - 1].seconds)

func online_outcome() -> String:
	if reps == opponent_score:
		return "TIE"
	return "YOU WIN" if reps > opponent_score else "RIVAL WINS"

func _cycle_match_length() -> void:
	current_level = current_level % LEVELS.size() + 1
	_show_screen("calibration", "Set your position", "03 / Host match")

func _pause_game() -> void:
	if screen_name != "game" or mode == "online":
		return
	match_active = false
	_show_screen("pause", "Paused", "Workout on hold")

func _resume_game() -> void:
	if screen_name != "pause":
		return
	match_active = true
	# Give the player time to get back into position before the clock runs.
	countdown = RESUME_GET_READY
	_last_countdown_tick = ceili(countdown)
	_show_screen("game", "Challenge on", "04 / Move")

func _restart_challenge() -> void:
	if mode == "online":
		if not peer_connected:
			_show_lobby("Your rival is no longer connected. Host or join again.", false)
		elif multiplayer.is_server():
			_start_challenge()
		else:
			rpc_id(1, "request_rematch", match_id)
			opponent_status = "Rematch requested"
		return
	_start_challenge()

@rpc("any_peer", "call_remote", "reliable")
func request_rematch(id: String) -> void:
	if not multiplayer.is_server() or match_active or id != match_id:
		return
	_start_challenge()

func _toggle_sound() -> void:
	sound_enabled = not sound_enabled
	_save_data()
	if screen_name == "settings":
		_show_screen("settings", "Your preferences", "02 / Settings")
	elif screen_name == "pause":
		_show_screen("pause", "Paused", "Workout on hold")

func _return_to_menu() -> void:
	match_active = false
	_disconnect_peer()
	_show_screen("menu", "Push-up Battle", "Your training floor")

func _show_lobby(message: String, positive: bool) -> void:
	mode = "online"
	opponent_status = message
	_show_screen("lobby", "Find your rival", "02 / Same Wi-Fi")
	_set_lobby_status(message, positive)

func _host_match() -> void:
	_disconnect_peer()
	var peer := ENetMultiplayerPeer.new()
	peer.set_bind_ip(host_bind_ip)
	var error := peer.create_server(PORT, 1)
	if error != OK:
		_set_lobby_status("Could not host on port %d. Another app may be using it; check Wi-Fi and try again." % PORT, false)
		return
	multiplayer.multiplayer_peer = peer
	mode = "online"
	current_level = 1
	peer_connected = false
	match_active = false
	var addresses := local_ipv4_addresses()
	if addresses.is_empty():
		_set_lobby_status("Hosting, but no Wi-Fi address was found. Connect this phone to Wi-Fi.", false)
	else:
		_set_lobby_status("Hosting. On the other phone, join:  %s" % "  or  ".join(addresses), true)

func _join_match() -> void:
	_disconnect_peer()
	var address := lobby_address.text.strip_edges() if is_instance_valid(lobby_address) else ""
	if address.is_empty():
		_set_lobby_status("Enter the IP shown on the host phone.", false)
		return
	if not address.is_valid_ip_address() or ":" in address:
		_set_lobby_status("\"%s\" isn't an IPv4 address. It looks like 192.168.1.12." % address, false)
		return
	var peer := ENetMultiplayerPeer.new()
	var error := peer.create_client(address, PORT)
	if error != OK:
		_set_lobby_status("Could not reach that address. Check the IP and Wi-Fi.", false)
		return
	multiplayer.multiplayer_peer = peer
	mode = "online"
	_connect_attempt += 1
	var attempt := _connect_attempt
	_set_lobby_status("Connecting to %s…" % address, true)
	get_tree().create_timer(CONNECT_TIMEOUT).timeout.connect(func(): _on_connect_timeout(attempt, address))

func _on_connect_timeout(attempt: int, address: String) -> void:
	if attempt != _connect_attempt or peer_connected or multiplayer.multiplayer_peer == null:
		return
	if multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTING:
		return
	_disconnect_peer()
	_set_lobby_status("No host answered at %s. Check the IP, that the other phone tapped HOST, and that both are on the same Wi-Fi (guest networks often block this)." % address, false)

## Private IPv4 addresses this phone can be reached at on the local network.
static func local_ipv4_addresses() -> PackedStringArray:
	var found := PackedStringArray()
	for address in IP.get_local_addresses():
		if ":" in address or not address.is_valid_ip_address():
			continue
		if address.begins_with("192.168.") or address.begins_with("10."):
			found.append(address)
		elif address.begins_with("172."):
			var second := address.split(".")[1].to_int()
			if second >= 16 and second <= 31:
				found.append(address)
	return found

func _configure_peer_timeout(id: int) -> void:
	var enet := multiplayer.multiplayer_peer as ENetMultiplayerPeer
	if enet == null:
		return
	var packet_peer := enet.get_peer(id)
	if packet_peer != null:
		packet_peer.set_timeout(32, PEER_TIMEOUT_MIN_MS, PEER_TIMEOUT_MAX_MS)

func _on_peer_connected(id: int) -> void:
	if not multiplayer.is_server():
		return
	_configure_peer_timeout(id)
	peer_connected = true
	opponent_status = "Connected"
	mode = "online"
	_show_screen("calibration", "Set your position", "03 / Host match")

func _on_connected_to_server() -> void:
	_configure_peer_timeout(1)
	peer_connected = true
	opponent_status = "Connected"
	mode = "online"
	_show_screen("calibration", "Set your position", "03 / Join match")

func _on_peer_disconnected(_id: int) -> void:
	peer_connected = false
	opponent_status = "Disconnected"
	if screen_name in ["game", "pause"] and not match_finished:
		_end_match_early("Your rival left the match.")
	elif screen_name == "result":
		_show_screen("result", "Match complete", "05 / Score")
	elif mode == "online" and multiplayer.multiplayer_peer != null:
		# Still hosting: a new guest can join.
		_show_lobby("Your guest left. Still hosting — another phone can join.", false)
		var addresses := local_ipv4_addresses()
		if not addresses.is_empty():
			_set_lobby_status("Your guest left. Still hosting at  %s" % "  or  ".join(addresses), false)

func _on_connection_failed() -> void:
	_disconnect_peer()
	_set_lobby_status("Host could not be reached. Check the IP and that both phones are on the same Wi-Fi.", false)

func _on_server_disconnected() -> void:
	_disconnect_peer()
	if screen_name in ["game", "pause"] and not match_finished:
		_end_match_early("Lost connection to the host.")
	elif screen_name == "result":
		_show_screen("result", "Match complete", "05 / Score")
	else:
		_show_lobby("The host closed the match. Host or join again.", false)

func _end_match_early(reason: String) -> void:
	match_active = false
	match_finished = true
	disconnect_reason = reason
	_show_screen("result", "Match ended", "Connection lost")

func _set_lobby_status(message: String, positive: bool) -> void:
	opponent_status = message
	if is_instance_valid(lobby_status):
		lobby_status.text = message
		lobby_status.add_theme_color_override("font_color", LIME if positive else ORANGE)

func _disconnect_peer() -> void:
	_connect_attempt += 1
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = null
	peer_connected = false

func _notification(what: int) -> void:
	match what:
		NOTIFICATION_WM_CLOSE_REQUEST:
			_save_data()
			_disconnect_peer()
			get_tree().quit()
		NOTIFICATION_APPLICATION_PAUSED, NOTIFICATION_APPLICATION_FOCUS_OUT:
			# A call or app switch must not burn the level timer.
			if screen_name == "game" and mode == "offline":
				_pause_game()
			_save_data()
		NOTIFICATION_WM_GO_BACK_REQUEST:
			_go_back()

## Android back button / Escape: pause a level, step back from a screen, or quit from the menu.
func _go_back() -> void:
	if screen_name == "game":
		if mode == "offline":
			_pause_game()
		# Online: ignored so a stray back press can't abandon a match. Use LEAVE MATCH.
	elif screen_name == "pause":
		_resume_game()
	elif screen_name in ["title", "menu"]:
		_save_data()
		_disconnect_peer()
		get_tree().quit()
	else:
		_return_to_menu()

# --- Save data -------------------------------------------------------------------

func get_level_stats(level_num: int) -> Dictionary:
	var stats: Dictionary = level_stats.get(level_num, {})
	return {
		"attempts": int(stats.get("attempts", 0)),
		"clears": int(stats.get("clears", 0)),
		"best": int(stats.get("best", 0)),
	}

func _load_save() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(save_path) != OK:
		return
	highest_unlocked = clampi(int(cfg.get_value("progress", "highest_unlocked", 1)), 1, LEVELS.size())
	sound_enabled = bool(cfg.get_value("settings", "sound_enabled", true))
	level_stats.clear()
	for level_num in range(1, LEVELS.size() + 1):
		var key := "level_%d" % level_num
		if cfg.has_section_key("stats", key) and cfg.get_value("stats", key) is Dictionary:
			level_stats[level_num] = cfg.get_value("stats", key)
			level_stats[level_num] = get_level_stats(level_num)

func _save_data() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("progress", "highest_unlocked", highest_unlocked)
	cfg.set_value("settings", "sound_enabled", sound_enabled)
	for level_num in level_stats:
		cfg.set_value("stats", "level_%d" % level_num, get_level_stats(level_num))
	# Write to a temp file then swap it in, so a crash mid-save can't corrupt progress.
	var temp_path := save_path + ".tmp"
	if cfg.save(temp_path) == OK:
		DirAccess.rename_absolute(temp_path, save_path)

# --- UI helpers ------------------------------------------------------------------

func _button(text: String, action: Callable, primary := false) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(0, 64)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.add_theme_font_size_override("font_size", 17)
	button.add_theme_color_override("font_color", INK if primary else Color.WHITE)
	button.add_theme_color_override("font_hover_color", INK if primary else LIME)
	var normal := StyleBoxFlat.new()
	normal.bg_color = LIME if primary else Color("26373a")
	normal.set_corner_radius_all(15)
	normal.content_margin_left = 18
	normal.content_margin_right = 18
	button.add_theme_stylebox_override("normal", normal)
	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = Color("e1ff98") if primary else Color("31474a")
	button.add_theme_stylebox_override("hover", hover)
	button.add_theme_stylebox_override("pressed", hover)
	button.add_theme_stylebox_override("disabled", normal)
	button.pressed.connect(_play_button_sound)
	button.pressed.connect(action)
	return button

func _play_button_sound() -> void:
	_play_sound(1.15)

func _play_sound(pitch: float) -> void:
	if not sound_enabled or not is_instance_valid(_sound_player):
		return
	_sound_player.pitch_scale = pitch
	_sound_player.play()

func _make_tone() -> AudioStreamWAV:
	const SAMPLE_RATE := 22050
	const FRAME_COUNT := 2205
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = SAMPLE_RATE
	wav.stereo = false
	var samples := PackedByteArray()
	samples.resize(FRAME_COUNT * 2)
	for frame in range(FRAME_COUNT):
		var envelope := 1.0 - float(frame) / FRAME_COUNT
		var sample := sin(TAU * 660.0 * float(frame) / SAMPLE_RATE) * envelope * 0.18
		samples.encode_s16(frame * 2, int(sample * 32767.0))
	wav.data = samples
	return wav

func _label(text: String, size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return label

func _card(title: String, body: String) -> PanelContainer:
	var card := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color("223336")
	style.set_corner_radius_all(15)
	style.content_margin_left = 18
	style.content_margin_right = 18
	style.content_margin_top = 16
	style.content_margin_bottom = 16
	card.add_theme_stylebox_override("panel", style)
	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 7)
	card.add_child(stack)
	stack.add_child(_label(title, 13, ORANGE))
	stack.add_child(_label(body, 15, Color.WHITE))
	return card
