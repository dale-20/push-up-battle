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

# --- Design tokens ---------------------------------------------------------------
# Apple's dark-mode system palette: true-black canvas, graphite elevated surfaces,
# and three saturated signals that each mean one thing:
#   ACCENT (green)  you / go / success      WARN (amber)  needs your attention
#   RIVAL (pink)    the other player, and losing to them
const INK := Color("000000")          ## App background (systemBackground).
const SURFACE := Color("1c1c1e")      ## Grouped cards and list rows (secondarySystemBackground).
const FILL := Color("2c2c2e")         ## Secondary buttons, inputs, empty tracks (tertiary).
const SEPARATOR := Color("38383a")
const TEXT := Color("ffffff")
const MUTED := Color("98989f")        ## secondaryLabel.
const ACCENT := Color("30d158")       ## systemGreen.
const WARN := Color("ff9f0a")         ## systemOrange.
const RIVAL := Color("ff375f")        ## systemPink.
const DANGER := Color("ff453a")       ## systemRed: destructive actions only.

# Type scale. The viewport is 720 px wide (~2x a phone's points), so these are
# roughly Apple's text styles doubled: body 17pt -> 30, large title 34pt -> 60.
const FS_HERO := 200       ## Rep counter.
const FS_LARGE_TITLE := 60
const FS_TITLE := 44
const FS_HEADLINE := 30    ## Bold.
const FS_BODY := 30
const FS_SUBHEAD := 26
const FS_FOOTNOTE := 23
const FS_CAPTION := 21     ## Section headers, uppercase.

const GUTTER := 36
const RADIUS := 28
const BUTTON_HEIGHT := 100
const ROW_HEIGHT := 118

## Navigation depth: moving deeper slides in from the right, going back from the left,
## so every screen leaves the way it came.
const SCREEN_DEPTH := {
	"title": 0, "menu": 1, "mode": 2, "settings": 2, "credits": 2,
	"levels": 3, "lobby": 3, "hosting": 4, "calibration": 4, "game": 5, "pause": 6, "result": 6,
}
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
## Shown to rivals in their "Matches nearby" list. Saved on this device.
var player_name := ""
## Finds hosts on the same Wi-Fi or hotspot (guest) and answers probes (host).
var discovery := LanDiscovery.new()
var _nearby_list: VBoxContainer
var _manual_join: VBoxContainer
var _network_group: PanelContainer
var _network_signature := ""
var _network_check := 0.0
var current_content: VBoxContainer
var current_actions: VBoxContainer
var screen_name := "title"
var _rep_tracker := RepTracker.new()
var _sound_player: AudioStreamPlayer
var _last_countdown_tick := 0
var _grace_time := 0.0
var _connect_attempt := 0
var _first_screen := true
var _shown_reps := 0
var _font_regular: Font
var _font_bold: Font
var _font_display: Font
var _font_digits: Font

func _ready() -> void:
	_setup_theme()
	_load_save()
	if player_name.is_empty():
		player_name = "Player %d" % randi_range(10, 99)
	discovery.hosts_changed.connect(_refresh_nearby)
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
	discovery.poll(delta)
	if screen_name == "hosting":
		# The player may switch Wi-Fi or turn on their hotspot while waiting.
		_network_check += delta
		if _network_check >= 2.0:
			_network_check = 0.0
			_fill_network_group()
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

# --- Screens ---------------------------------------------------------------------

func _show_screen(which: String) -> void:
	var previous := screen_name
	screen_name = which
	if which not in CAMERA_SCREENS:
		Pose.stop()
	if which != "lobby":
		discovery.stop_browsing()
	for child in get_children():
		if child != _sound_player:
			child.queue_free()
	var background := ColorRect.new()
	background.color = INK
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(background)
	var insets := _safe_insets()
	var outer := MarginContainer.new()
	outer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	outer.add_theme_constant_override("margin_left", GUTTER)
	outer.add_theme_constant_override("margin_right", GUTTER)
	outer.add_theme_constant_override("margin_top", 20 + int(insets.x))
	outer.add_theme_constant_override("margin_bottom", 32 + int(insets.y))
	add_child(outer)
	var shell := VBoxContainer.new()
	shell.add_theme_constant_override("separation", 20)
	outer.add_child(shell)
	_build_nav_bar(shell)
	var heading := _screen_heading()
	if heading[0] != "":
		var title := _label(heading[0], FS_LARGE_TITLE, TEXT, _font_display)
		title.add_theme_constant_override("line_spacing", -6)
		shell.add_child(title)
	if heading[1] != "":
		shell.add_child(_label(heading[1], FS_SUBHEAD, MUTED))
	var scroller := ScrollContainer.new()
	scroller.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroller.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	# Touch-scrolls without a bar eating into the content width.
	scroller.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	shell.add_child(scroller)
	current_content = VBoxContainer.new()
	current_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	current_content.add_theme_constant_override("separation", 20)
	scroller.add_child(current_content)
	# Primary actions live at the bottom, in thumb reach, outside the scroll.
	current_actions = VBoxContainer.new()
	current_actions.add_theme_constant_override("separation", 14)
	shell.add_child(current_actions)
	match which:
		"title": _build_title()
		"menu": _build_menu()
		"mode": _build_mode()
		"levels": _build_levels()
		"lobby": _build_lobby()
		"hosting": _build_hosting()
		"calibration": _build_calibration()
		"game": _build_game()
		"pause": _build_pause()
		"result": _build_result()
		"settings": _build_settings()
		"credits": _build_credits()
	current_actions.visible = current_actions.get_child_count() > 0
	# Same-screen rebuilds (e.g. a status change) stay still; only real navigation moves.
	if _first_screen or previous != which:
		_animate_in(outer, previous, which)
	_first_screen = false

## [large title, subtitle] for the current screen; "" hides either.
func _screen_heading() -> Array:
	var data: Dictionary = LEVELS[current_level - 1]
	match screen_name:
		"menu": return ["Train", "Pick a mode, set your stance, get moving."]
		"mode": return ["Choose a mode", ""]
		"levels": return ["Campaign", "Clear a level to unlock the next one."]
		"lobby": return ["Wi-Fi duel", "Same Wi-Fi or hotspot. Most valid reps wins."]
		"hosting": return ["Waiting for a rival", "Your match is open. Keep this screen up."]
		"calibration":
			if mode == "online":
				return ["Get in position", "Wi-Fi match  ·  %d seconds" % data.seconds]
			return ["Level %d" % current_level, "%d reps in %d seconds" % [data.goal, data.seconds]]
		"pause": return ["Paused", "Take a breath. The clock is stopped."]
		"settings": return ["Settings", ""]
		"credits": return ["Credits", ""]
	return ["", ""]

func _build_nav_bar(shell: VBoxContainer) -> void:
	if screen_name == "title":
		return
	var nav := HBoxContainer.new()
	nav.custom_minimum_size.y = 72
	shell.add_child(nav)
	if screen_name in ["mode", "levels", "lobby", "hosting", "settings", "credits"] or (screen_name == "calibration" and mode == "offline"):
		var back := _button("‹  Back", _navigate_back, "plain")
		back.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		back.custom_minimum_size = Vector2(0, 72)
		back.alignment = HORIZONTAL_ALIGNMENT_LEFT
		nav.add_child(back)
	elif screen_name == "game":
		var where := "Wi-Fi match" if mode == "online" else "Level %d" % current_level
		var label := _label(where, FS_HEADLINE, MUTED, _font_bold)
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.autowrap_mode = TextServer.AUTOWRAP_OFF
		nav.add_child(label)
		if mode == "offline":
			# No pause online: it would desynchronize the two match clocks.
			var pause := _button("Pause", _pause_game, "plain")
			pause.size_flags_horizontal = Control.SIZE_SHRINK_END
			pause.custom_minimum_size = Vector2(150, 72)
			pause.alignment = HORIZONTAL_ALIGNMENT_RIGHT
			nav.add_child(pause)

func _build_title() -> void:
	current_content.alignment = BoxContainer.ALIGNMENT_CENTER
	current_content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var eyebrow := _section("A bodyweight arcade game")
	eyebrow.add_theme_color_override("font_color", ACCENT)
	current_content.add_child(eyebrow)
	var title := _label("Push-up\nBattle", 84, TEXT, _font_display)
	title.add_theme_constant_override("line_spacing", -14)
	current_content.add_child(title)
	current_content.add_child(_label("Your next rep is the next level.", FS_BODY, MUTED))
	current_content.add_child(_spacer(16))
	var features := _group()
	_group_add(features, _info_row("Five levels", "Start at 5 reps in 30 seconds. Clear each one to unlock the next."))
	_group_add(features, _info_row("Wi-Fi duel", "Race a friend on the same network, rep for rep."))
	_group_add(features, _info_row("Private by design", "Pose tracking runs on your phone. Video is never saved or sent."))
	current_content.add_child(features)
	current_actions.add_child(_button("Get started", func(): _show_screen("menu"), "primary"))

func _build_menu() -> void:
	var progress_card := _card_panel()
	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 14)
	progress_card.add_child(stack)
	var line := HBoxContainer.new()
	stack.add_child(line)
	var name_label := _label("Campaign", FS_HEADLINE, TEXT, _font_bold)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.add_child(name_label)
	var count_label := _label("%d of %d unlocked" % [highest_unlocked, LEVELS.size()], FS_SUBHEAD, MUTED)
	count_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	line.add_child(count_label)
	stack.add_child(_progress_bar(float(highest_unlocked) / LEVELS.size()))
	current_content.add_child(progress_card)
	var group := _group()
	_group_add(group, _row("Settings", "Sound and preferences", func(): _show_screen("settings")))
	_group_add(group, _row("Credits", "Team, assets and licenses", func(): _show_screen("credits")))
	current_content.add_child(group)
	current_content.add_child(_footnote("Pose tracking runs on your phone. Video is never saved or sent; matches share only rep counts."))
	current_actions.add_child(_button("Play", func(): _show_screen("mode"), "primary"))

func _build_mode() -> void:
	var group := _group()
	_group_add(group, _row("Solo campaign", "Five levels  ·  progress saves on this device", func():
		mode = "offline"
		_show_screen("levels")
	, _badge("1", ACCENT, INK)))
	_group_add(group, _row("Wi-Fi duel", "Race a friend on the same Wi-Fi or hotspot", func():
		mode = "online"
		_show_lobby("Host a match, or join one below.", true)
	, _badge("2", RIVAL, TEXT)))
	current_content.add_child(group)
	current_content.add_child(_footnote("Online results never change your campaign unlocks."))

func _build_levels() -> void:
	var group := _group()
	for i in range(LEVELS.size()):
		var level_num := i + 1
		var data: Dictionary = LEVELS[i]
		var locked := level_num > highest_unlocked
		var stats := get_level_stats(level_num)
		var cleared: bool = stats.clears > 0
		var detail := "%d reps in %d seconds" % [data.goal, data.seconds]
		if stats.attempts > 0:
			detail += "  ·  best %d" % stats.best
		var trailing := "Locked" if locked else ("Cleared" if cleared else "›")
		var badge := _badge(str(level_num), ACCENT if cleared else FILL, INK if cleared else (MUTED if locked else TEXT))
		var row := _row("Level %d" % level_num, detail, func(): _prepare_level(level_num), badge, trailing)
		row.disabled = locked
		if locked:
			row.modulate.a = 0.45
		_group_add(group, row)
	current_content.add_child(group)
	current_content.add_child(_footnote("Progress saves automatically."))

func _build_lobby() -> void:
	lobby_status = _status_pill(current_content, opponent_status, true)
	lobby_status.name = "LobbyStatus"
	current_content.add_child(_spacer(4))
	host_button = _button("Host a match", _host_match, "primary")
	current_content.add_child(host_button)
	current_content.add_child(_spacer(8))
	current_content.add_child(_section("Matches nearby"))
	_nearby_list = VBoxContainer.new()
	_nearby_list.add_theme_constant_override("separation", 12)
	current_content.add_child(_nearby_list)
	_refresh_nearby()
	current_content.add_child(_spacer(8))
	var manual_group := _group()
	_group_add(manual_group, _row("Enter IP manually", "If a match doesn't show up", func():
		_manual_join.visible = not _manual_join.visible
	))
	current_content.add_child(manual_group)
	_manual_join = VBoxContainer.new()
	_manual_join.add_theme_constant_override("separation", 14)
	_manual_join.visible = false
	current_content.add_child(_manual_join)
	lobby_address = _text_field("Host IP, e.g. 192.168.1.12")
	lobby_address.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_NUMBER_DECIMAL
	lobby_address.text_submitted.connect(func(_text: String): _join_match())
	_manual_join.add_child(lobby_address)
	_manual_join.add_child(_button("Join match", _join_match, "secondary"))
	current_content.add_child(_footnote("Only rep counts and match state are shared."))
	if discovery.start_browsing() != OK:
		_set_lobby_status("Can't search this network. Enter the host's IP manually.", false)

## Rebuilds only the nearby list, so typing in the IP field isn't interrupted.
func _refresh_nearby() -> void:
	if screen_name != "lobby" or not is_instance_valid(_nearby_list):
		return
	for child in _nearby_list.get_children():
		child.queue_free()
	if discovery.hosts.is_empty():
		var empty := _group()
		_group_add(empty, _info_row("Looking for matches…", "Your rival taps Host a match on the same Wi-Fi. No Wi-Fi? They turn on Mobile Hotspot and you connect to it."))
		_nearby_list.add_child(empty)
		return
	var group := _group()
	var ips := discovery.hosts.keys()
	ips.sort()
	for ip: String in ips:
		var host: Dictionary = discovery.hosts[ip]
		_group_add(group, _row(host.name, ip, func(): _join_address(ip), _badge(host.name.left(1).to_upper(), RIVAL, TEXT), "Join  ›"))
	_nearby_list.add_child(group)

func _build_hosting() -> void:
	lobby_status = _status_pill(current_content, opponent_status, true)
	lobby_status.name = "LobbyStatus"
	var pulse := lobby_status.create_tween().set_loops().set_trans(Tween.TRANS_SINE)
	pulse.tween_property(lobby_status, "modulate:a", 0.45, 0.9)
	pulse.tween_property(lobby_status, "modulate:a", 1.0, 0.9)
	current_content.add_child(_spacer(4))
	current_content.add_child(_section("Your name"))
	var name_field := _text_field("Your name")
	name_field.text = player_name
	name_field.max_length = LanDiscovery.MAX_NAME
	name_field.text_changed.connect(_set_player_name)
	name_field.text_submitted.connect(func(_text: String): _save_data())
	name_field.focus_exited.connect(_save_data)
	current_content.add_child(name_field)
	current_content.add_child(_footnote("Rivals see this in their Matches nearby list."))
	current_content.add_child(_spacer(8))
	current_content.add_child(_section("Hosting on"))
	_network_group = _group()
	current_content.add_child(_network_group)
	_network_signature = ""
	_network_check = 0.0
	_fill_network_group()
	current_content.add_child(_spacer(8))
	current_content.add_child(_section("How your rival joins"))
	var tips := _group()
	_group_add(tips, _info_row("Same Wi-Fi", "They open Wi-Fi duel and tap your name under Matches nearby."))
	_group_add(tips, _info_row("No Wi-Fi?", "Turn on Mobile Hotspot in your phone's Settings, then have your rival connect to it. Mobile data isn't used for the match."))
	current_content.add_child(tips)
	current_actions.add_child(_button("Cancel hosting", _cancel_hosting, "destructive"))

## Lists this phone's Wi-Fi / hotspot addresses; only rebuilds when they change.
func _fill_network_group() -> void:
	if not is_instance_valid(_network_group):
		return
	var networks := LanDiscovery.describe_networks(IP.get_local_interfaces())
	var signature := str(networks)
	if signature == _network_signature:
		return
	_network_signature = signature
	var stack := _network_group.get_child(0)
	for child in stack.get_children():
		child.queue_free()
	if networks.is_empty():
		_group_add(_network_group, _info_row("No network", "Connect to Wi-Fi, or turn on Mobile Hotspot."))
		_set_lobby_status("Hosting, but this phone isn't on Wi-Fi or sharing a hotspot yet.", false)
		return
	for network: Dictionary in networks:
		var kind := "Your hotspot" if network.hotspot else "Wi-Fi"
		_group_add(_network_group, _info_row(kind, "%s  ·  manual join address" % network.address))
	if opponent_status.begins_with("Hosting, but this phone isn't"):
		_set_lobby_status("Waiting for a rival to join…", true)

func _set_player_name(text: String) -> void:
	var cleaned := LanDiscovery.clean_name(text)
	player_name = cleaned if not cleaned.is_empty() else "Player"
	discovery.advertised_name = player_name

func _cancel_hosting() -> void:
	_save_data()
	_disconnect_peer()
	_show_lobby("Hosting cancelled. Host a match, or join one below.", true)

## Rounded single-line text input.
func _text_field(placeholder: String) -> LineEdit:
	var field := LineEdit.new()
	field.placeholder_text = placeholder
	field.custom_minimum_size.y = BUTTON_HEIGHT
	field.add_theme_font_size_override("font_size", FS_BODY)
	field.add_theme_color_override("font_color", TEXT)
	field.add_theme_color_override("font_placeholder_color", Color(MUTED, 0.7))
	field.add_theme_color_override("caret_color", ACCENT)
	var normal := _box(FILL, 22, 28, 0)
	field.add_theme_stylebox_override("normal", normal)
	var focused := normal.duplicate() as StyleBoxFlat
	focused.set_border_width_all(3)
	focused.border_color = Color(ACCENT, 0.8)
	field.add_theme_stylebox_override("focus", focused)
	return field

func _build_calibration() -> void:
	var data: Dictionary = LEVELS[current_level - 1]
	if mode == "online":
		var is_host := multiplayer.multiplayer_peer != null and multiplayer.is_server()
		var message := "Guest connected. Both phones start together." if is_host else "Connected. The host starts the match."
		_status_pill(current_content, message, true)
		current_content.add_child(_camera_preview(680.0))
		current_content.add_child(_tips())
		if is_host:
			current_actions.add_child(_button("Match length  ·  %d s" % data.seconds, _cycle_match_length, "secondary"))
			current_actions.add_child(_button("Start match", _start_challenge, "primary"))
		current_actions.add_child(_button("Leave match", _return_to_menu, "destructive"))
		return
	current_content.add_child(_camera_preview(680.0))
	current_content.add_child(_tips())
	current_actions.add_child(_button("I'm ready", _start_challenge, "primary"))

func _tips() -> Control:
	var wrap := VBoxContainer.new()
	wrap.add_theme_constant_override("separation", 12)
	wrap.add_child(_section("Before you start"))
	var group := _group()
	_group_add(group, _info_row("Prop the phone up", "Portrait, steady, on the floor in front of you."))
	_group_add(group, _info_row("Fit in the guide", "Head, both shoulders and both hands inside the frame."))
	_group_add(group, _info_row("Clear the floor", "Room to go all the way down."))
	wrap.add_child(group)
	return wrap

func _build_game() -> void:
	var goal: int = LEVELS[current_level - 1].goal
	_shown_reps = reps
	var hero := _card_panel(36)
	current_content.add_child(hero)
	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 6)
	hero.add_child(stack)
	var count := _label(str(reps), FS_HERO, ACCENT, _font_digits)
	count.name = "RepValue"
	count.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	count.autowrap_mode = TextServer.AUTOWRAP_OFF
	count.resized.connect(func(): count.pivot_offset = count.size / 2.0)
	stack.add_child(count)
	var caption := _label("your reps" if mode == "online" else "of %d reps" % goal, FS_SUBHEAD, MUTED)
	caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	stack.add_child(caption)
	stack.add_child(_spacer(14))
	if mode == "offline":
		var bar := _progress_bar(float(reps) / goal)
		bar.name = "RepProgress"
		stack.add_child(bar)
		stack.add_child(_spacer(10))
	var timer_label := _label(_timer_text(), FS_TITLE, TEXT, _font_digits)
	timer_label.name = "TimerValue"
	timer_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	stack.add_child(timer_label)
	if mode == "online":
		var rival := _label(_rival_text(), FS_HEADLINE, RIVAL, _font_bold)
		rival.name = "OpponentValue"
		rival.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		stack.add_child(rival)
	if tracker_message == "":
		tracker_message = _default_tracker_message()
	var tracking_label := _status_pill(current_content, tracker_message, _rep_tracker.tracked)
	tracking_label.name = "TrackingStatus"
	if Pose.available:
		# The self-view takes all space left under the counter; the scroller
		# stretches content flagged EXPAND to its full height.
		current_content.size_flags_vertical = Control.SIZE_EXPAND_FILL
		current_content.add_child(_camera_preview(480.0, false, true))
	else:
		current_actions.add_child(_button("Log practice rep  +1", _log_rep, "primary"))
	if mode == "online":
		current_actions.add_child(_button("Leave match", _return_to_menu, "destructive"))
	else:
		current_content.add_child(_footnote("Steady down. Full return."))

func _build_pause() -> void:
	var group := _group()
	_group_add(group, _switch_row("Sound", sound_enabled, _toggle_sound))
	current_content.add_child(group)
	current_actions.add_child(_button("Resume", _resume_game, "primary"))
	current_actions.add_child(_button("Restart", _restart_challenge, "secondary"))
	current_actions.add_child(_button("Quit to menu", _return_to_menu, "destructive"))

func _build_result() -> void:
	if mode == "online":
		_build_online_result()
		return
	var goal: int = LEVELS[current_level - 1].goal
	var cleared := reps >= goal
	var campaign_done := cleared and current_level == LEVELS.size()
	var stats := get_level_stats(current_level)
	current_content.add_child(_spacer(24))
	current_content.add_child(_section("Level %d" % current_level))
	var headline := "Campaign complete" if campaign_done else ("Level cleared" if cleared else "Try again")
	current_content.add_child(_label(headline, FS_LARGE_TITLE, ACCENT if cleared else WARN, _font_display))
	if campaign_done:
		current_content.add_child(_label("You cleared all five levels. Replay any level to beat your best.", FS_BODY, MUTED))
	elif cleared:
		current_content.add_child(_label("Level %d is open." % (current_level + 1), FS_BODY, MUTED))
	else:
		current_content.add_child(_label("Need %d more. Go all the way down and fully back up for each rep." % (goal - reps), FS_BODY, MUTED))
	current_content.add_child(_spacer(8))
	var tiles := HBoxContainer.new()
	tiles.add_theme_constant_override("separation", 14)
	tiles.add_child(_stat_tile("%d/%d" % [reps, goal], "Reps", ACCENT if cleared else TEXT))
	tiles.add_child(_stat_tile("%.1fs" % elapsed, "Time", TEXT))
	tiles.add_child(_stat_tile(str(stats.best), "Best", TEXT))
	current_content.add_child(tiles)
	current_content.add_child(_footnote("Attempt %d" % stats.attempts))
	if cleared and current_level < LEVELS.size():
		current_actions.add_child(_button("Next level  ›", func(): _prepare_level(current_level + 1), "primary"))
		current_actions.add_child(_button("Retry", _restart_challenge, "secondary"))
	else:
		current_actions.add_child(_button("Retry", _restart_challenge, "primary"))
	current_actions.add_child(_button("Menu", _return_to_menu, "plain"))

func _build_online_result() -> void:
	current_content.add_child(_spacer(24))
	current_content.add_child(_section("Wi-Fi match  ·  %d s" % LEVELS[current_level - 1].seconds))
	if disconnect_reason != "":
		current_content.add_child(_label("Match ended", FS_LARGE_TITLE, WARN, _font_display))
		current_content.add_child(_label(disconnect_reason + " No campaign progress was changed.", FS_BODY, MUTED))
		current_actions.add_child(_button("Back to menu", _return_to_menu, "primary"))
		return
	var outcome := online_outcome()
	var display := {"YOU WIN": "You win", "RIVAL WINS": "Rival wins", "TIE": "It's a tie"}
	current_content.add_child(_label(display.get(outcome, outcome), FS_LARGE_TITLE, ACCENT if outcome != "RIVAL WINS" else RIVAL, _font_display))
	current_content.add_child(_spacer(8))
	var tiles := HBoxContainer.new()
	tiles.name = "MatchResult"
	tiles.add_theme_constant_override("separation", 14)
	tiles.add_child(_stat_tile(str(reps), "You", ACCENT if reps >= opponent_score else TEXT))
	tiles.add_child(_stat_tile(str(opponent_score), "Rival", RIVAL if opponent_score > reps else TEXT))
	current_content.add_child(tiles)
	if rejected_updates > 0:
		current_content.add_child(_footnote("The host ignored %d implausible guest score update(s)." % rejected_updates, WARN))
	current_content.add_child(_footnote("Online results don't change campaign unlocks."))
	if peer_connected:
		current_actions.add_child(_button("Rematch", _restart_challenge, "primary"))
		current_content.add_child(_footnote("Either player can start a rematch; both phones count down together."))
	else:
		current_content.add_child(_footnote("Your rival has left, so a rematch isn't available.", WARN))
	current_actions.add_child(_button("Leave match", _return_to_menu, "destructive" if peer_connected else "secondary"))

func _build_settings() -> void:
	var group := _group()
	_group_add(group, _switch_row("Sound", sound_enabled, _toggle_sound))
	current_content.add_child(group)
	current_content.add_child(_footnote("Countdown beeps and rep sounds. Saved on this device. Orientation is fixed to portrait."))

func _build_credits() -> void:
	var card := _card_panel()
	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 8)
	card.add_child(stack)
	stack.add_child(_label("Push-up Battle", FS_TITLE, ACCENT, _font_display))
	stack.add_child(_label("A bodyweight arcade prototype for the ITSD 85 mobile-game lab.", FS_BODY, TEXT))
	current_content.add_child(card)
	current_content.add_child(_card("Assets & licenses", "Interface, copy and vector icon are original project assets. Pose tracking uses Google ML Kit Pose Detection and AndroidX CameraX; see docs/CREDITS.md."))
	current_content.add_child(_card("Team", "Add team names and roles to docs/CREDITS.md."))

# --- Challenge flow ------------------------------------------------------------

func _prepare_level(level_num: int) -> void:
	if level_num > highest_unlocked:
		return
	current_level = level_num
	mode = "offline"
	_show_screen("calibration")

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
	_show_screen("game")

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
		return "Face the phone and hold the top position to start counting."
	return "No pose tracker in this build. Use the practice input."

func _on_tracking_changed(is_tracking: bool) -> void:
	if is_tracking:
		tracker_message = "Body tracked. Complete a full down-and-up rep."
	else:
		tracker_message = "Counting paused. " + Pose.reason_hint(Pose.last_reason)
	var tracking_label := find_child("TrackingStatus", true, false) as Label
	if tracking_label:
		tracking_label.text = tracker_message
		_paint_status(tracking_label, is_tracking)

func _timer_text() -> String:
	if countdown > 0.0:
		return "Starts in %d" % ceili(countdown)
	if remaining <= 0.0:
		return "Time!" if mode == "offline" or multiplayer.multiplayer_peer == null or multiplayer.is_server() else "Time!  Waiting for host…"
	var seconds := ceili(remaining)
	return "%d:%02d" % [seconds / 60, seconds % 60]

func _rival_text() -> String:
	return "Rival  %d  ·  %s" % [opponent_score, opponent_status]

func _refresh_game_labels() -> void:
	var rep_label := find_child("RepValue", true, false) as Label
	var timer_label := find_child("TimerValue", true, false) as Label
	var opponent_label := find_child("OpponentValue", true, false) as Label
	var tracking_label := find_child("TrackingStatus", true, false) as Label
	var progress := find_child("RepProgress", true, false) as ProgressBar
	if rep_label:
		rep_label.text = str(reps)
		if reps != _shown_reps:
			_shown_reps = reps
			_pop(rep_label)
	if progress:
		_tween_to(progress, "value", clampf(float(reps) / LEVELS[current_level - 1].goal, 0.0, 1.0), 0.35)
	if timer_label:
		timer_label.text = _timer_text()
		# The last five seconds warm up so the player feels the clock without hunting for it.
		var urgent := countdown <= 0.0 and remaining > 0.0 and remaining <= 5.0
		timer_label.add_theme_color_override("font_color", WARN if urgent else TEXT)
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
	_show_screen("result")

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
	_show_screen("result")

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
	_show_screen("result")

func match_seconds() -> float:
	return match_seconds_override if match_seconds_override > 0.0 else float(LEVELS[current_level - 1].seconds)

func online_outcome() -> String:
	if reps == opponent_score:
		return "TIE"
	return "YOU WIN" if reps > opponent_score else "RIVAL WINS"

func _cycle_match_length() -> void:
	current_level = current_level % LEVELS.size() + 1
	_show_screen("calibration")

func _pause_game() -> void:
	if screen_name != "game" or mode == "online":
		return
	match_active = false
	_show_screen("pause")

func _resume_game() -> void:
	if screen_name != "pause":
		return
	match_active = true
	# Give the player time to get back into position before the clock runs.
	countdown = RESUME_GET_READY
	_last_countdown_tick = ceili(countdown)
	_show_screen("game")

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

## Flips in place: the switch animates instead of the whole screen rebuilding.
func _toggle_sound() -> void:
	sound_enabled = not sound_enabled
	_save_data()
	var switch := find_child("SoundSwitch", true, false) as Panel
	if switch:
		_set_switch(switch, sound_enabled, true)

func _return_to_menu() -> void:
	match_active = false
	_disconnect_peer()
	_show_screen("menu")

func _show_lobby(message: String, positive: bool) -> void:
	mode = "online"
	opponent_status = message
	_show_screen("lobby")
	_set_lobby_status(message, positive)

func _host_match() -> void:
	_disconnect_peer()
	var peer := ENetMultiplayerPeer.new()
	peer.set_bind_ip(host_bind_ip)
	var error := peer.create_server(PORT, 1)
	if error != OK:
		_set_lobby_status("Could not host on port %d. Another app may be using it; check Wi-Fi or your hotspot and try again." % PORT, false)
		return
	multiplayer.multiplayer_peer = peer
	mode = "online"
	current_level = 1
	peer_connected = false
	match_active = false
	_show_waiting_room()

## The host's "Waiting for a rival" page, advertised to nearby guests.
func _show_waiting_room() -> void:
	if discovery.start_advertising(player_name, PORT, host_bind_ip) != OK:
		opponent_status = "Hosting, but nearby phones can't see this match. Your rival can enter your address manually."
	else:
		opponent_status = "Waiting for a rival to join…"
	_show_screen("hosting")

func _join_match() -> void:
	var address := lobby_address.text.strip_edges() if is_instance_valid(lobby_address) else ""
	if address.is_empty():
		_set_lobby_status("Enter the IP shown on the host phone.", false)
		return
	if not address.is_valid_ip_address() or ":" in address:
		_set_lobby_status("\"%s\" isn't an IPv4 address. It looks like 192.168.1.12." % address, false)
		return
	_join_address(address)

func _join_address(address: String) -> void:
	_disconnect_peer()
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
	_set_lobby_status("No host answered at %s. Check that the other phone is still hosting and that you're on the same Wi-Fi or their hotspot (guest networks often block this)." % address, false)

## Private IPv4 addresses this phone can be reached at on Wi-Fi or its hotspot.
static func local_ipv4_addresses() -> PackedStringArray:
	return LanDiscovery.usable_ipv4_addresses(IP.get_local_interfaces())

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
	discovery.stop_advertising()  # One guest per match: stop showing up in lists.
	peer_connected = true
	opponent_status = "Connected"
	mode = "online"
	_show_screen("calibration")

func _on_connected_to_server() -> void:
	_configure_peer_timeout(1)
	peer_connected = true
	opponent_status = "Connected"
	mode = "online"
	_show_screen("calibration")

func _on_peer_disconnected(_id: int) -> void:
	peer_connected = false
	opponent_status = "Disconnected"
	if screen_name in ["game", "pause"] and not match_finished:
		_end_match_early("Your rival left the match.")
	elif screen_name == "result":
		_show_screen("result")
	elif mode == "online" and multiplayer.multiplayer_peer != null:
		# Still hosting: back to the waiting room so another phone can join.
		_show_waiting_room()
		_set_lobby_status("Your guest left. Still hosting — another phone can join.", false)

func _on_connection_failed() -> void:
	_disconnect_peer()
	_set_lobby_status("Host could not be reached. Check that both phones are on the same Wi-Fi or hotspot.", false)

func _on_server_disconnected() -> void:
	_disconnect_peer()
	if screen_name in ["game", "pause"] and not match_finished:
		_end_match_early("Lost connection to the host.")
	elif screen_name == "result":
		_show_screen("result")
	else:
		_show_lobby("The host closed the match. Host or join again.", false)

func _end_match_early(reason: String) -> void:
	match_active = false
	match_finished = true
	disconnect_reason = reason
	_show_screen("result")

func _set_lobby_status(message: String, positive: bool) -> void:
	opponent_status = message
	if is_instance_valid(lobby_status):
		lobby_status.text = message
		_paint_status(lobby_status, positive)

func _disconnect_peer() -> void:
	_connect_attempt += 1
	discovery.stop_advertising()
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
		# Online: ignored so a stray back press can't abandon a match. Use Leave match.
	elif screen_name == "pause":
		_resume_game()
	elif screen_name in ["title", "menu"]:
		_save_data()
		_disconnect_peer()
		get_tree().quit()
	else:
		_navigate_back()

## One level up the hierarchy, matching the on-screen Back button.
func _navigate_back() -> void:
	match screen_name:
		"levels", "lobby":
			_disconnect_peer()
			_show_screen("mode")
		"hosting":
			_cancel_hosting()
		"calibration":
			if mode == "online":
				_return_to_menu()
			else:
				_show_screen("levels")
		_:
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
	player_name = LanDiscovery.clean_name(str(cfg.get_value("settings", "player_name", "")))
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
	cfg.set_value("settings", "player_name", player_name)
	for level_num in level_stats:
		cfg.set_value("stats", "level_%d" % level_num, get_level_stats(level_num))
	# Write to a temp file then swap it in, so a crash mid-save can't corrupt progress.
	var temp_path := save_path + ".tmp"
	if cfg.save(temp_path) == OK:
		DirAccess.rename_absolute(temp_path, save_path)

# --- Sound -----------------------------------------------------------------------

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

# --- Theme & motion --------------------------------------------------------------

## System UI font (SF on Apple, Roboto on Android, Segoe on Windows) with a bold
## weight, a tightly tracked display cut for large titles, and tabular digits
## so the counter and clock don't jitter as numbers change.
func _setup_theme() -> void:
	var names := PackedStringArray(["SF Pro Text", "Roboto", "Inter", "Segoe UI", "Helvetica Neue", "sans-serif"])
	var regular := SystemFont.new()
	regular.font_names = names
	var bold := SystemFont.new()
	bold.font_names = names
	bold.font_weight = 700
	_font_regular = regular
	_font_bold = bold
	var display := FontVariation.new()
	display.base_font = bold
	display.spacing_glyph = -1  # Large text reads loose; pull it in.
	_font_display = display
	var digits := FontVariation.new()
	digits.base_font = bold
	digits.spacing_glyph = -2
	digits.opentype_features = {TextServerManager.get_primary_interface().name_to_tag("tnum"): 1}
	_font_digits = digits
	var ui_theme := Theme.new()
	ui_theme.default_font = regular
	ui_theme.default_font_size = FS_BODY
	ui_theme.set_constant("line_spacing", "Label", 4)
	theme = ui_theme

## Status-bar and gesture-bar insets in viewport pixels (mobile only).
func _safe_insets() -> Vector2:
	if not OS.has_feature("mobile"):
		return Vector2.ZERO
	var window := DisplayServer.window_get_size()
	if window.y <= 0:
		return Vector2.ZERO
	var safe := DisplayServer.get_display_safe_area()
	var scale_y := get_viewport_rect().size.y / float(window.y)
	return Vector2(safe.position.y * scale_y, maxf(0.0, window.y - safe.end.y) * scale_y)

## Screens arrive along the axis of navigation: deeper from the right, back from the left.
## Ease-out with no overshoot (the tween equivalent of a critically damped spring).
func _animate_in(node: Control, previous: String, which: String) -> void:
	var direction := 1.0 if int(SCREEN_DEPTH.get(which, 0)) >= int(SCREEN_DEPTH.get(previous, 0)) else -1.0
	node.modulate.a = 0.0
	node.position.x = 36.0 * direction
	var tween := node.create_tween().set_parallel().set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
	tween.tween_property(node, "position:x", 0.0, 0.42)
	tween.tween_property(node, "modulate:a", 1.0, 0.24)

## Retargetable tween: kills the previous one on this property and starts from the
## live value, so rapid input never jumps or waits for an animation to finish.
func _tween_to(node: Node, property: String, target: Variant, seconds: float, trans := Tween.TRANS_QUART) -> void:
	var key := "tween_" + property.replace(":", "_")
	if node.has_meta(key):
		var old: Variant = node.get_meta(key)
		if old is Tween and (old as Tween).is_valid():
			(old as Tween).kill()
	var tween := node.create_tween().set_trans(trans).set_ease(Tween.EASE_OUT)
	tween.tween_property(node, property, target, seconds)
	node.set_meta(key, tween)

## A counted rep is a physical event, so it earns a little overshoot.
func _pop(label: Control) -> void:
	label.scale = Vector2.ONE * 1.14
	_tween_to(label, "scale", Vector2.ONE, 0.45, Tween.TRANS_BACK)

## Feedback on touch-down, not release: shrink instantly, settle back on lift.
func _add_press_feedback(button: BaseButton) -> void:
	button.resized.connect(func(): button.pivot_offset = button.size / 2.0)
	button.button_down.connect(func(): _tween_to(button, "scale", Vector2.ONE * 0.97, 0.08))
	button.button_up.connect(func(): _tween_to(button, "scale", Vector2.ONE, 0.32))

# --- Components ------------------------------------------------------------------

func _box(color: Color, radius := RADIUS, pad_x := 28, pad_y := 24) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.set_corner_radius_all(radius)
	style.corner_detail = 12
	style.anti_aliasing = true
	style.content_margin_left = pad_x
	style.content_margin_right = pad_x
	style.content_margin_top = pad_y
	style.content_margin_bottom = pad_y
	return style

## kind: "primary" (filled accent), "secondary" (filled neutral), "plain" (text only),
## "destructive" (text only, orange).
func _button(text: String, action: Callable, kind := "secondary") -> Button:
	var button := Button.new()
	button.text = text
	button.focus_mode = Control.FOCUS_NONE
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.add_theme_font_override("font", _font_bold)
	button.add_theme_font_size_override("font_size", FS_HEADLINE)
	var filled := kind in ["primary", "secondary"]
	button.custom_minimum_size = Vector2(0, BUTTON_HEIGHT if filled else 84)
	var fg := INK if kind == "primary" else (TEXT if kind == "secondary" else (DANGER if kind == "destructive" else ACCENT))
	for state in ["font_color", "font_hover_color", "font_focus_color", "font_hover_pressed_color"]:
		button.add_theme_color_override(state, fg)
	button.add_theme_color_override("font_pressed_color", fg if filled else Color(fg, 0.5))
	button.add_theme_color_override("font_disabled_color", Color(fg, 0.4))
	if filled:
		var bg := ACCENT if kind == "primary" else FILL
		var normal := _box(bg, RADIUS, 28, 0)
		var pressed := _box(bg.darkened(0.14) if kind == "primary" else bg.lightened(0.07), RADIUS, 28, 0)
		button.add_theme_stylebox_override("normal", normal)
		button.add_theme_stylebox_override("hover", normal)
		button.add_theme_stylebox_override("pressed", pressed)
		button.add_theme_stylebox_override("hover_pressed", pressed)
		button.add_theme_stylebox_override("disabled", _box(Color(bg, 0.35), RADIUS, 28, 0))
	else:
		for state in ["normal", "hover", "pressed", "hover_pressed", "disabled"]:
			button.add_theme_stylebox_override(state, StyleBoxEmpty.new())
	button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	_add_press_feedback(button)
	button.pressed.connect(_play_button_sound)
	button.pressed.connect(action)
	return button

func _label(text: String, size: int, color: Color, font: Font = null) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	if font != null:
		label.add_theme_font_override("font", font)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return label

## Grouped-list section header: small, uppercase, quiet.
func _section(text: String) -> Label:
	return _label(text.to_upper(), FS_CAPTION, MUTED, _font_bold)

func _footnote(text: String, color := MUTED) -> Label:
	return _label(text, FS_FOOTNOTE, color)

func _spacer(height: int) -> Control:
	var spacer := Control.new()
	spacer.custom_minimum_size.y = height
	return spacer

func _card_panel(pad := 28) -> PanelContainer:
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", _box(SURFACE, RADIUS, pad, pad))
	return card

## Header above, body inside — the grouped-list pattern.
func _card(title: String, body: String) -> VBoxContainer:
	var wrap := VBoxContainer.new()
	wrap.add_theme_constant_override("separation", 12)
	wrap.add_child(_section(title))
	var card := _card_panel()
	card.add_child(_label(body, FS_BODY, TEXT))
	wrap.add_child(card)
	return wrap

## Rounded container for list rows. Rows are separated by inset hairlines.
func _group() -> PanelContainer:
	var group := PanelContainer.new()
	group.add_theme_stylebox_override("panel", _box(SURFACE, RADIUS, 0, 0))
	group.clip_children = CanvasItem.CLIP_CHILDREN_AND_DRAW
	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 0)
	group.add_child(stack)
	return group

func _group_add(group: PanelContainer, row: Control) -> void:
	var stack := group.get_child(0) as VBoxContainer
	if stack.get_child_count() > 0:
		var line := MarginContainer.new()
		line.add_theme_constant_override("margin_left", 28)
		var rule := ColorRect.new()
		rule.color = SEPARATOR
		rule.custom_minimum_size.y = 2
		line.add_child(rule)
		stack.add_child(line)
	stack.add_child(row)

## Tappable list row: optional leading badge, title + detail, trailing value or chevron.
func _row(title: String, detail: String, action: Callable, badge: Control = null, trailing := "›") -> Button:
	var row := Button.new()
	row.focus_mode = Control.FOCUS_NONE
	row.custom_minimum_size.y = ROW_HEIGHT
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for state in ["normal", "hover", "disabled", "focus"]:
		row.add_theme_stylebox_override(state, StyleBoxEmpty.new())
	var highlight := StyleBoxFlat.new()
	highlight.bg_color = Color(1, 1, 1, 0.06)
	row.add_theme_stylebox_override("pressed", highlight)
	row.add_theme_stylebox_override("hover_pressed", highlight)
	var content := _row_content(title, detail, badge)
	if trailing != "":
		var tail := _label(trailing, FS_TITLE if trailing == "›" else FS_SUBHEAD, MUTED)
		tail.autowrap_mode = TextServer.AUTOWRAP_OFF
		tail.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		content.get_child(0).add_child(tail)
	row.add_child(content)
	row.pressed.connect(_play_button_sound)
	row.pressed.connect(action)
	return row

func _row_content(title: String, detail: String, badge: Control) -> MarginContainer:
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_theme_constant_override("margin_left", 28)
	margin.add_theme_constant_override("margin_right", 28)
	var hbox := HBoxContainer.new()
	hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_theme_constant_override("separation", 24)
	margin.add_child(hbox)
	if badge != null:
		badge.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		hbox.add_child(badge)
	var text := VBoxContainer.new()
	text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text.alignment = BoxContainer.ALIGNMENT_CENTER
	text.add_theme_constant_override("separation", 2)
	hbox.add_child(text)
	var title_label := _label(title, FS_HEADLINE, TEXT, _font_bold)
	title_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	text.add_child(title_label)
	if detail != "":
		var detail_label := _label(detail, FS_FOOTNOTE, MUTED)
		detail_label.autowrap_mode = TextServer.AUTOWRAP_OFF
		detail_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		detail_label.clip_text = true
		text.add_child(detail_label)
	return margin

## Row with an on/off switch; tapping anywhere on the row flips it.
func _switch_row(title: String, on: bool, action: Callable) -> Button:
	var row := _row(title, "", action, null, "")
	var hbox := row.get_child(0).get_child(0) as HBoxContainer
	var track := Panel.new()
	track.name = "SoundSwitch"
	track.custom_minimum_size = Vector2(102, 62)
	track.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	track.mouse_filter = Control.MOUSE_FILTER_IGNORE
	track.add_theme_stylebox_override("panel", _box(FILL, 31, 0, 0))
	var knob := Panel.new()
	knob.name = "Knob"
	knob.size = Vector2(54, 54)
	knob.position.y = 4
	knob.mouse_filter = Control.MOUSE_FILTER_IGNORE
	knob.add_theme_stylebox_override("panel", _box(Color.WHITE, 27, 0, 0))
	track.add_child(knob)
	hbox.add_child(track)
	_set_switch(track, on, false)
	return row

func _set_switch(track: Panel, on: bool, animate: bool) -> void:
	var knob := track.get_node("Knob") as Panel
	var style := track.get_theme_stylebox("panel") as StyleBoxFlat
	var knob_x := 44.0 if on else 4.0
	var color := ACCENT if on else FILL
	if animate:
		_tween_to(knob, "position:x", knob_x, 0.3)
		var tween := track.create_tween().set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
		tween.tween_property(style, "bg_color", color, 0.25)
	else:
		knob.position.x = knob_x
		style.bg_color = color

## Non-interactive row for explanations.
func _info_row(title: String, detail: String) -> MarginContainer:
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 28)
	margin.add_theme_constant_override("margin_right", 28)
	margin.add_theme_constant_override("margin_top", 22)
	margin.add_theme_constant_override("margin_bottom", 22)
	var text := VBoxContainer.new()
	text.add_theme_constant_override("separation", 4)
	margin.add_child(text)
	text.add_child(_label(title, FS_HEADLINE, TEXT, _font_bold))
	text.add_child(_label(detail, FS_FOOTNOTE, MUTED))
	return margin

func _badge(text: String, bg: Color, fg: Color) -> PanelContainer:
	var badge := PanelContainer.new()
	badge.custom_minimum_size = Vector2(64, 64)
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	badge.add_theme_stylebox_override("panel", _box(bg, 32, 0, 0))
	var label := _label(text, FS_HEADLINE, fg, _font_digits)
	label.autowrap_mode = TextServer.AUTOWRAP_OFF
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	badge.add_child(label)
	return badge

func _progress_bar(value: float) -> ProgressBar:
	var bar := ProgressBar.new()
	bar.min_value = 0.0
	bar.max_value = 1.0
	bar.step = 0.0
	bar.value = clampf(value, 0.0, 1.0)
	bar.show_percentage = false
	bar.custom_minimum_size.y = 14
	bar.add_theme_stylebox_override("background", _box(FILL, 7, 0, 0))
	bar.add_theme_stylebox_override("fill", _box(ACCENT, 7, 0, 0))
	return bar

func _stat_tile(value: String, caption: String, color: Color) -> PanelContainer:
	var tile := _card_panel(24)
	tile.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 2)
	tile.add_child(stack)
	var number := _label(value, FS_TITLE, color, _font_digits)
	number.autowrap_mode = TextServer.AUTOWRAP_OFF
	stack.add_child(number)
	stack.add_child(_section(caption))
	return tile

## Capsule with a colored dot; returns its label so callers can update the text.
func _status_pill(parent: Control, text: String, positive: bool) -> Label:
	var pill := PanelContainer.new()
	pill.add_theme_stylebox_override("panel", _box(SURFACE, 24, 24, 16))
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 16)
	pill.add_child(hbox)
	var dot := Panel.new()
	dot.custom_minimum_size = Vector2(16, 16)
	dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	dot.add_theme_stylebox_override("panel", _box(ACCENT, 8, 0, 0))
	hbox.add_child(dot)
	var label := _label(text, FS_FOOTNOTE, TEXT)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(label)
	parent.add_child(pill)
	_paint_status(label, positive)
	return label

## Lime dot when things are fine; orange dot and text when the player needs to act.
func _paint_status(label: Label, positive: bool) -> void:
	label.add_theme_color_override("font_color", TEXT if positive else WARN)
	var hbox := label.get_parent()
	if hbox == null or hbox.get_child_count() == 0:
		return
	var dot := hbox.get_child(0) as Panel
	if dot:
		(dot.get_theme_stylebox("panel") as StyleBoxFlat).bg_color = ACCENT if positive else WARN

func _camera_preview(height: float, titled := true, fill := false) -> Control:
	var preview := preload("res://scripts/camera_preview.gd").new()
	preview.preview_height = height
	preview.show_title = titled
	preview.fill = fill
	return preview
