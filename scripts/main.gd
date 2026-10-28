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

var highest_unlocked := 1
var sound_enabled := true
var current_level := 1
var mode := "offline"
var reps := 0
var remaining := 0.0
var elapsed := 0.0
var countdown := 0.0
var opponent_score := 0
var opponent_status := "Waiting for opponent"
var match_id := ""
var match_active := false
var match_finished := false
var peer_connected := false
var lobby_address: LineEdit
var host_button: Button
var lobby_status: Label
var current_content: VBoxContainer
var screen_name := "title"
var _rep_tracker := RepTracker.new()

func _ready() -> void:
	_load_save()
	get_tree().auto_accept_quit = false
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	_rep_tracker.rep_counted.connect(_on_detected_rep)
	_show_screen("title")

func _process(delta: float) -> void:
	if screen_name != "game" or not match_active:
		return
	if countdown > 0.0:
		countdown = maxf(0.0, countdown - delta)
		_refresh_game_labels()
		return
	remaining = maxf(0.0, remaining - delta)
	elapsed += delta
	_refresh_game_labels()
	if remaining <= 0.0:
		if mode == "offline":
			_end_offline_challenge()
		elif multiplayer.is_server() and not match_finished:
			_finish_online_match()

func _unhandled_key_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		if screen_name == "game":
			_pause_game()
		elif screen_name == "pause":
			_resume_game()
		elif screen_name not in ["title", "menu"]:
			_return_to_menu()
		get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_SPACE and screen_name == "game":
		_log_rep()

func _show_screen(which: String, heading := "", eyebrow := "") -> void:
	screen_name = which
	for child in get_children():
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
	if which not in ["title", "menu"]:
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
	current_content.add_child(_card("CAMERA PRIVACY", "Pose tracking is designed to run on your phone. Video is never sent with match scores."))

func _build_mode() -> void:
	current_content.add_child(_label("HOW DO YOU WANT TO PLAY?", 21, Color.WHITE))
	current_content.add_child(_button("PLAY OFFLINE", func():
		mode = "offline"
		_show_screen("levels", "Choose a level", "02 / Solo campaign")
	, true))
	current_content.add_child(_label("Five campaign levels. Your unlocks stay on this device.", 15, MUTED))
	current_content.add_child(_button("PLAY ONLINE", func():
		mode = "online"
		_show_screen("lobby", "Find your rival", "02 / Same Wi-Fi")
	, false))
	current_content.add_child(_label("Host a match or join a host by local IP address.", 15, MUTED))

func _build_levels() -> void:
	for i in range(LEVELS.size()):
		var level_num := i + 1
		var data: Dictionary = LEVELS[i]
		var locked := level_num > highest_unlocked
		var title := "LEVEL %02d     %s" % [level_num, "LOCKED" if locked else "READY"]
		var tile := _button("%s\n%d REPS  /  %d SEC" % [title, data.goal, data.seconds], func(): _prepare_level(level_num), not locked)
		tile.custom_minimum_size.y = 94
		tile.disabled = locked
		current_content.add_child(tile)
	current_content.add_child(_label("Clear a level to open the next one. Progress saves automatically.", 14, MUTED))

func _build_lobby() -> void:
	current_content.add_child(_label("TWO PLAYERS. SAME CHALLENGE.", 19, Color.WHITE))
	current_content.add_child(_label("Both phones must be on the same Wi-Fi. The host decides the result.", 14, MUTED))
	lobby_status = _label(opponent_status, 15, LIME)
	current_content.add_child(lobby_status)
	host_button = _button("HOST A MATCH", _host_match, true)
	current_content.add_child(host_button)
	current_content.add_child(_label("OR JOIN A HOST", 13, ORANGE))
	lobby_address = LineEdit.new()
	lobby_address.placeholder_text = "Host local IP  ·  e.g. 192.168.1.12"
	lobby_address.custom_minimum_size.y = 56
	lobby_address.add_theme_font_size_override("font_size", 16)
	current_content.add_child(lobby_address)
	current_content.add_child(_button("JOIN MATCH", _join_match, false))
	current_content.add_child(_label("Port %d  •  Only scores and match state are shared." % PORT, 12, MUTED))

func _build_calibration() -> void:
	var data: Dictionary = LEVELS[current_level - 1]
	current_content.add_child(_label("LEVEL %02d  /  %d REPS" % [current_level, data.goal], 24, LIME))
	current_content.add_child(_label("TIME LIMIT   %d SECONDS" % data.seconds, 16, ORANGE))
	current_content.add_child(_card("CAMERA SETUP", "Prop your phone in portrait mode. Fit your shoulders, hips and knees inside the frame. The camera integration is not connected in this build; use the practice rep button during play."))
	current_content.add_child(_label("READY CHECK", 14, MUTED))
	current_content.add_child(_label("☐  Phone stable   ☐  Full body in frame   ☐  Clear floor", 15, Color.WHITE))
	current_content.add_child(_button("I'M READY  →", _start_challenge, true))
	current_content.add_child(_button("BACK TO LEVELS", func(): _show_screen("levels", "Choose a level", "02 / Solo campaign"), false))

func _build_game() -> void:
	current_content.add_child(_label("LEVEL %02d  /  TARGET %d" % [current_level, LEVELS[current_level - 1].goal], 16, MUTED))
	var count := _label("%02d" % reps, 82, LIME)
	count.name = "RepValue"
	count.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	current_content.add_child(count)
	current_content.add_child(_label("VALID REPS", 14, MUTED))
	var timer_label := _label("START IN %d" % ceili(countdown) if countdown > 0.0 else "%02d SEC" % ceili(remaining), 38, Color.WHITE)
	timer_label.name = "TimerValue"
	timer_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	current_content.add_child(timer_label)
	if mode == "online":
		var rival := _label("RIVAL   %02d   •   %s" % [opponent_score, opponent_status], 16, ORANGE)
		rival.name = "OpponentValue"
		current_content.add_child(rival)
	else:
		current_content.add_child(_label("STEADY DOWN. FULL RETURN.", 14, MUTED))
	current_content.add_child(_button("LOG PRACTICE REP  +1", _log_rep, true))
	current_content.add_child(_label("Practice input for this prototype. Connect the local pose adapter to count movement.", 12, MUTED))
	current_content.add_child(_button("PAUSE", _pause_game, false))

func _build_pause() -> void:
	current_content.add_child(_label("TAKE A BREATH.", 28, Color.WHITE))
	current_content.add_child(_button("RESUME", _resume_game, true))
	current_content.add_child(_button("RESTART", _restart_challenge, false))
	current_content.add_child(_button("SOUND  ·  %s" % ("ON" if sound_enabled else "OFF"), _toggle_sound, false))
	current_content.add_child(_button("QUIT TO MENU", _return_to_menu, false))

func _build_result() -> void:
	var goal: int = LEVELS[current_level - 1].goal
	var cleared := reps >= goal
	current_content.add_child(_label("LEVEL %02d" % current_level, 15, MUTED))
	if mode == "online":
		current_content.add_child(_label("MATCH COMPLETE", 34, LIME))
		current_content.add_child(_card("MATCH RESULT", "You: %d   /   Rival: %d\n%s   •   %.1f sec" % [reps, opponent_score, _online_outcome(), elapsed]))
	else:
		current_content.add_child(_label("LEVEL CLEARED" if cleared else "TRY AGAIN", 34, LIME if cleared else ORANGE))
		current_content.add_child(_card("YOUR RESULT", "%d / %d valid reps   •   %.1f sec elapsed" % [reps, goal, elapsed]))
	current_content.add_child(_button("RETRY", _restart_challenge, true))
	if cleared and mode == "offline" and current_level < LEVELS.size():
		current_content.add_child(_button("NEXT LEVEL  →", func(): _prepare_level(current_level + 1), false))
	current_content.add_child(_button("MENU", _return_to_menu, false))

func _build_settings() -> void:
	current_content.add_child(_label("SOUND", 18, Color.WHITE))
	current_content.add_child(_button("SOUND  ·  %s" % ("ON" if sound_enabled else "OFF"), _toggle_sound, true))
	current_content.add_child(_label("Orientation is fixed to portrait. Sound preference saves on this device.", 14, MUTED))
	current_content.add_child(_button("DONE", func(): _show_screen("menu", "Push-up Battle", "Your training floor"), false))

func _build_credits() -> void:
	current_content.add_child(_label("PUSH-UP BATTLE", 26, LIME))
	current_content.add_child(_label("A bodyweight arcade prototype for the ITSD 85 mobile-game lab.", 16, Color.WHITE))
	current_content.add_child(_card("ASSETS & LICENSES", "Interface, copy and vector icon are original project assets. No third-party audio or artwork is bundled."))
	current_content.add_child(_card("TEAM", "Add team names, roles and any later model/plugin credits to docs/CREDITS.md."))
	current_content.add_child(_button("DONE", func(): _show_screen("menu", "Push-up Battle", "Your training floor"), false))

func _prepare_level(level_num: int) -> void:
	if level_num > highest_unlocked:
		return
	current_level = level_num
	mode = "offline"
	_show_screen("calibration", "Set your position", "03 / Prepare")

func _start_challenge() -> void:
	var data: Dictionary = LEVELS[current_level - 1]
	reps = 0
	opponent_score = 0
	opponent_status = "Ready"
	remaining = data.seconds
	elapsed = 0.0
	countdown = 3.0 if mode == "online" else 0.0
	match_finished = false
	match_active = true
	_rep_tracker.reset()
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
	if not match_active or screen_name != "game":
		return
	reps += 1
	_refresh_game_labels()
	if mode == "online" and multiplayer.multiplayer_peer != null:
		if multiplayer.is_server():
			rpc("receive_score", reps, match_id)
		else:
			rpc_id(1, "submit_score", reps, match_id)
	if mode == "offline" and reps >= LEVELS[current_level - 1].goal:
		_end_offline_challenge()

@rpc("any_peer", "call_remote", "reliable")
func submit_score(score: int, id: String) -> void:
	if not multiplayer.is_server() or not match_active or id != match_id:
		return
	if multiplayer.get_remote_sender_id() != 1:
		opponent_score = maxi(opponent_score, clampi(score, 0, LEVELS[current_level - 1].goal))
		opponent_status = "Playing"
		rpc("receive_score", reps, match_id)

@rpc("authority", "call_remote", "reliable")
func receive_score(score: int, id: String) -> void:
	if id != match_id or not match_active:
		return
	if multiplayer.is_server():
		opponent_score = clampi(score, 0, LEVELS[current_level - 1].goal)
	else:
		opponent_score = clampi(score, 0, LEVELS[current_level - 1].goal)
	opponent_status = "Playing"
	_refresh_game_labels()

func _on_detected_rep(total: int) -> void:
	if match_active and total > reps:
		reps = total
		_refresh_game_labels()

func _refresh_game_labels() -> void:
	var rep_label := find_child("RepValue", true, false) as Label
	var timer_label := find_child("TimerValue", true, false) as Label
	var opponent_label := find_child("OpponentValue", true, false) as Label
	if rep_label:
		rep_label.text = "%02d" % reps
	if timer_label:
		timer_label.text = "START IN %d" % ceili(countdown) if countdown > 0.0 else "%02d SEC" % ceili(remaining)
	if opponent_label:
		opponent_label.text = "RIVAL   %02d   •   %s" % [opponent_score, opponent_status]

func _end_offline_challenge() -> void:
	match_active = false
	remaining = maxf(0.0, remaining)
	if reps >= LEVELS[current_level - 1].goal:
		highest_unlocked = mini(LEVELS.size(), maxi(highest_unlocked, current_level + 1))
		_save_data()
	_show_screen("result", "Your result", "05 / Score")

func _finish_online_match() -> void:
	if match_finished:
		return
	match_finished = true
	match_active = false
	var winner := "TIE"
	if reps > opponent_score:
		winner = "HOST WINS"
	elif opponent_score > reps:
		winner = "GUEST WINS"
	rpc("show_online_result", reps, opponent_score, winner, match_id)
	_show_screen("result", "Match complete", "05 / Score")

@rpc("authority", "call_remote", "reliable")
func show_online_result(host_score: int, guest_score: int, winner: String, id: String) -> void:
	if id != match_id:
		return
	match_finished = true
	match_active = false
	if multiplayer.is_server():
		opponent_score = guest_score
	else:
		# Host score is displayed as the rival's score on the joining phone.
		opponent_score = host_score
		reps = guest_score
		_remote_winner = "TIE" if winner == "TIE" else ("RIVAL WINS" if winner == "HOST WINS" else "YOU WIN")
	if multiplayer.is_server():
		_remote_winner = winner
	_show_screen("result", "Match complete", "05 / Score")

var _remote_winner := ""

func _online_outcome() -> String:
	if _remote_winner != "":
		return _remote_winner
	if reps == opponent_score:
		return "TIE"
	return "YOU WIN" if reps > opponent_score else "RIVAL WINS"

func _pause_game() -> void:
	if screen_name != "game":
		return
	match_active = false
	_show_screen("pause", "Paused", "Workout on hold")

func _resume_game() -> void:
	if screen_name != "pause":
		return
	match_active = true
	_show_screen("game", "Challenge on", "04 / Move")

func _restart_challenge() -> void:
	if mode == "online" and not multiplayer.is_server():
		rpc_id(1, "request_rematch", match_id)
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

func _host_match() -> void:
	_disconnect_peer()
	var peer := ENetMultiplayerPeer.new()
	var error := peer.create_server(PORT, 1)
	if error != OK:
		_set_lobby_status("Could not host on this network. Check Wi-Fi and try again.", false)
		return
	multiplayer.multiplayer_peer = peer
	mode = "online"
	peer_connected = false
	match_active = false
	opponent_status = "Waiting for player"
	_set_lobby_status("Host ready on port %d. Share your local IP." % PORT, true)

func _join_match() -> void:
	_disconnect_peer()
	var address := lobby_address.text.strip_edges() if lobby_address else ""
	if address.is_empty():
		_set_lobby_status("Enter the host phone's local IP address.", false)
		return
	var peer := ENetMultiplayerPeer.new()
	var error := peer.create_client(address, PORT)
	if error != OK:
		_set_lobby_status("Could not reach that address. Check the IP and Wi-Fi.", false)
		return
	multiplayer.multiplayer_peer = peer
	mode = "online"
	opponent_status = "Connecting"
	_set_lobby_status("Connecting to %s…" % address, true)

func _on_peer_connected(_id: int) -> void:
	peer_connected = true
	opponent_status = "Connected"
	if multiplayer.is_server():
		current_level = 1
		_show_screen("calibration", "Set your position", "03 / Host match")
		current_content.add_child(_label("Guest connected. Both players will start together.", 15, LIME))
		current_content.add_child(_button("START MATCH", _start_challenge, true))
	else:
		_set_lobby_status("Connected. Waiting for host to start.", true)

func _on_connected_to_server() -> void:
	peer_connected = true
	opponent_status = "Connected"
	_set_lobby_status("Connected. Waiting for host to start.", true)

func _on_peer_disconnected(_id: int) -> void:
	peer_connected = false
	if screen_name == "game" or screen_name == "pause":
		match_active = false
		match_finished = true
		_show_screen("result", "Match ended", "Connection lost")
		current_content.add_child(_card("DISCONNECTED", "Your opponent left the match. No campaign progress was changed."))
		current_content.add_child(_button("BACK TO MENU", _return_to_menu, true))
	else:
		_set_lobby_status("Player disconnected. You can host or join again.", false)
		opponent_status = "Disconnected"

func _on_connection_failed() -> void:
	_disconnect_peer()
	_set_lobby_status("Host could not be reached. Check both phones are on the same Wi-Fi.", false)

func _on_server_disconnected() -> void:
	match_active = false
	match_finished = true
	_disconnect_peer()
	if screen_name in ["game", "pause"]:
		_show_screen("result", "Match ended", "Connection lost")
		current_content.add_child(_card("DISCONNECTED", "Host connection lost. No campaign progress was changed."))
		current_content.add_child(_button("BACK TO MENU", _return_to_menu, true))
	else:
		_set_lobby_status("Host disconnected. Return to menu and try again.", false)

func _set_lobby_status(message: String, positive: bool) -> void:
	opponent_status = message
	if is_instance_valid(lobby_status):
		lobby_status.text = message
		lobby_status.add_theme_color_override("font_color", LIME if positive else ORANGE)

func _disconnect_peer() -> void:
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = null
	peer_connected = false
	match_finished = false
	_remote_winner = ""

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_save_data()
		_disconnect_peer()
		get_tree().quit()

func _load_save() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) == OK:
		highest_unlocked = clampi(int(cfg.get_value("progress", "highest_unlocked", 1)), 1, LEVELS.size())
		sound_enabled = bool(cfg.get_value("settings", "sound_enabled", true))

func _save_data() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("progress", "highest_unlocked", highest_unlocked)
	cfg.set_value("settings", "sound_enabled", sound_enabled)
	cfg.save(SAVE_PATH)

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
	button.pressed.connect(action)
	return button

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
