extends VBoxContainer

## Camera preview with pose skeleton. On Android with the PushUpPose plugin the
## preview comes from the same on-device camera session that tracks the pose.
## Without the plugin it falls back to a plain Godot CameraServer preview.
## Frames are displayed locally only; they are never saved or transmitted.

const INK := Color("101a1d")
const MUTED := Color("9caeaa")
const ORANGE := Color("ff895f")
const LIME := Color("d5fa70")

## Set before adding to the tree to make a smaller in-game preview.
var preview_height := 290.0
var show_title := true

var _preview: Control
var _texture_rect: TextureRect
var _overlay: Control
var _status: Label
var _camera_texture: CameraTexture
var _permission_pending := false

func _ready() -> void:
	add_theme_constant_override("separation", 10)
	if show_title:
		var title := Label.new()
		title.text = "LIVE CAMERA PREVIEW"
		title.add_theme_font_size_override("font_size", 13)
		title.add_theme_color_override("font_color", ORANGE)
		add_child(title)
	_preview = Control.new()
	_preview.custom_minimum_size = Vector2(0, preview_height)
	_preview.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_preview.clip_contents = true
	add_child(_preview)
	var placeholder := ColorRect.new()
	placeholder.color = INK
	placeholder.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_preview.add_child(placeholder)
	_texture_rect = TextureRect.new()
	_texture_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_texture_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_texture_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_texture_rect.visible = false
	_preview.add_child(_texture_rect)
	var guide := preload("res://scripts/camera_guide.gd").new()
	guide.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	guide.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_preview.add_child(guide)
	_overlay = preload("res://scripts/pose_overlay.gd").new()
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_preview.add_child(_overlay)
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_font_size_override("font_size", 14)
	_status.add_theme_color_override("font_color", MUTED)
	add_child(_status)
	if Pose.available:
		_use_pose_plugin()
	elif OS.get_name() == "Android":
		_status.text = "Pose plugin missing from this build. Showing camera only."
		Engine.get_main_loop().on_request_permissions_result.connect(_on_permission_result)
		_request_camera()
	else:
		_status.text = "Live preview and pose tracking are available in the Android build."

# --- Pose plugin path -------------------------------------------------------

func _use_pose_plugin() -> void:
	Pose.preview_updated.connect(_on_pose_preview)
	Pose.landmarks_updated.connect(_on_pose_landmarks)
	Pose.status_changed.connect(_on_pose_status)
	_status.text = Pose.status if Pose.status != "" else "Starting camera…"
	if Pose.preview_texture != null:
		_on_pose_preview(Pose.preview_texture)
	Pose.start()

func _on_pose_preview(texture: Texture2D) -> void:
	if _texture_rect.texture != texture:
		_texture_rect.texture = texture
	_texture_rect.visible = true

func _on_pose_landmarks(points: PackedFloat32Array, aspect: float) -> void:
	_overlay.set_landmarks(points, aspect)
	if Pose.last_reason == "ok":
		_status.text = "Body tracked. Hold the top position, then do full reps."
		_status.add_theme_color_override("font_color", LIME)
	else:
		_status.text = Pose.reason_hint(Pose.last_reason)
		_status.add_theme_color_override("font_color", ORANGE)

func _on_pose_status(message: String) -> void:
	_status.text = message
	_status.add_theme_color_override("font_color", MUTED)

# --- CameraServer fallback (no pose plugin) ---------------------------------

func _request_camera() -> void:
	_permission_pending = true
	if OS.request_permission("android.permission.CAMERA"):
		_permission_pending = false
		_start_camera_feed()

func _on_permission_result(permission: String, granted: bool) -> void:
	if not _permission_pending or permission != "android.permission.CAMERA":
		return
	_permission_pending = false
	if granted:
		_start_camera_feed()
	else:
		_status.text = "Camera permission was declined. Allow it in app settings, then reopen positioning."

func _start_camera_feed() -> void:
	if not CameraServer.camera_feeds_updated.is_connected(_on_camera_feeds_updated):
		CameraServer.camera_feeds_updated.connect(_on_camera_feeds_updated)
	CameraServer.monitoring_feeds = true
	_on_camera_feeds_updated()

func _on_camera_feeds_updated() -> void:
	if not is_inside_tree() or _camera_texture != null:
		return
	var feeds := CameraServer.feeds()
	if feeds.is_empty():
		_status.text = "No camera feed is available. Check camera permission and reopen positioning."
		return
	var selected: CameraFeed = feeds[0]
	for feed: CameraFeed in feeds:
		if feed.get_position() == CameraFeed.FEED_FRONT:
			selected = feed
			break
	_camera_texture = CameraTexture.new()
	_camera_texture.camera_feed_id = selected.get_id()
	_texture_rect.texture = _camera_texture
	_camera_texture.camera_is_active = true
	_texture_rect.visible = true

func _exit_tree() -> void:
	if Pose.available:
		# The game screens keep the pose camera running; main.gd stops it.
		Pose.preview_updated.disconnect(_on_pose_preview)
		Pose.landmarks_updated.disconnect(_on_pose_landmarks)
		Pose.status_changed.disconnect(_on_pose_status)
		return
	if CameraServer.camera_feeds_updated.is_connected(_on_camera_feeds_updated):
		CameraServer.camera_feeds_updated.disconnect(_on_camera_feeds_updated)
	if _camera_texture != null:
		_camera_texture.camera_is_active = false
	if OS.get_name() == "Android":
		CameraServer.monitoring_feeds = false
