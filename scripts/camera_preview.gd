extends VBoxContainer

## Android camera preview for the positioning screen. Displays a live local
## feed only; it does not capture, save, or transmit frames.

const INK := Color("101a1d")
const MUTED := Color("9caeaa")
const ORANGE := Color("ff895f")

var _preview: Control
var _texture_rect: TextureRect
var _status: Label
var _camera_texture: CameraTexture
var _permission_pending := false

func _ready() -> void:
	add_theme_constant_override("separation", 10)
	var title := Label.new()
	title.text = "LIVE CAMERA PREVIEW"
	title.add_theme_font_size_override("font_size", 13)
	title.add_theme_color_override("font_color", ORANGE)
	add_child(title)
	_preview = Control.new()
	_preview.custom_minimum_size = Vector2(0, 290)
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
	_status = Label.new()
	_status.text = "Camera starts when you enter this setup screen."
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_font_size_override("font_size", 14)
	_status.add_theme_color_override("font_color", MUTED)
	add_child(_status)
	if OS.get_name() == "Android":
		Engine.get_main_loop().on_request_permissions_result.connect(_on_permission_result)
		_request_camera()
	else:
		_status.text = "Live preview is available in the Android build. Pose detection will be connected after the camera provider is selected."

func _request_camera() -> void:
	if OS.get_name() != "Android":
		return
	_permission_pending = true
	_status.text = "Allow camera access to show your position preview. Video stays on this phone."
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
	if not is_inside_tree():
		return
	var feeds := CameraServer.feeds()
	if feeds.is_empty():
		_status.text = "No camera feed is available. Check camera permission and reopen positioning."
		return
	if _camera_texture != null:
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
	_status.text = "Frame shoulders, hips and knees inside the guide. Pose tracking is not connected yet."

func _exit_tree() -> void:
	if CameraServer.camera_feeds_updated.is_connected(_on_camera_feeds_updated):
		CameraServer.camera_feeds_updated.disconnect(_on_camera_feeds_updated)
	if _camera_texture != null:
		_camera_texture.camera_is_active = false
	if OS.get_name() == "Android":
		CameraServer.monitoring_feeds = false
