extends Node

## Autoload "Pose". Bridges the PushUpPose Android plugin (CameraX + bundled
## ML Kit pose detection, all on-device) to the game. The plugin returns only
## landmark coordinates and a small preview thumbnail for local display;
## frames are never saved or sent over the network.

signal pose_sample(depth: float, confidence: float, dt: float)
signal landmarks_updated(points: PackedFloat32Array, aspect: float)
signal preview_updated(texture: Texture2D)
signal status_changed(message: String)

const PLUGIN_NAME := "PushUpPose"
const LANDMARK_COUNT := 33
const SHOULDER := [11, 12]
const ELBOW := [13, 14]
const WRIST := [15, 16]
const HIP := [23, 24]
const MIN_LIKELIHOOD := 0.35
## Exponential smoothing weight for the newest depth sample.
const SMOOTHING := 0.5

var available := false
var running := false
## "ok", "no_body", "arm_hidden" or "too_far" for the latest frame.
var last_reason := "no_body"
var status := ""
var landmarks := PackedFloat32Array()
var aspect := 0.75
var preview_texture: ImageTexture

var _plugin: Object
var _smoothed := NAN
var _last_ms := 0
var _permission_pending := false

func _ready() -> void:
	if Engine.has_singleton(PLUGIN_NAME):
		_plugin = Engine.get_singleton(PLUGIN_NAME)
		available = true
		_plugin.connect("pose_frame", _on_pose_frame)
		_plugin.connect("preview_frame", _on_preview_frame)
		_plugin.connect("camera_status", _on_camera_status)
		get_tree().on_request_permissions_result.connect(_on_permission_result)
	else:
		_set_status("Pose tracking runs in the Android build. Use the practice input here.")

func start() -> void:
	if not available or running:
		return
	if OS.request_permission("android.permission.CAMERA"):
		_start_plugin()
	else:
		_permission_pending = true
		_set_status("Allow camera access so the phone can count your reps. Video stays on this phone.")

func stop() -> void:
	_permission_pending = false
	if not available or not running:
		return
	running = false
	_plugin.call("stop")
	_reset_signal()

## Converts one frame of landmarks into a depth signal.
## [param points] holds 33 * (x, y, likelihood); x and y are in units of image
## height with y pointing down. Depth is the fraction of arm length the
## shoulder has dropped toward the wrist: ~0 at the top, ~0.7 at the bottom.
static func analyze(points: PackedFloat32Array) -> Dictionary:
	var result := {"depth": NAN, "confidence": 0.0, "reason": "no_body"}
	if points.size() < LANDMARK_COUNT * 3:
		return result
	var best_side := -1
	var best_conf := 0.0
	for side in 2:
		var conf := minf(
			minf(_likelihood(points, SHOULDER[side]), _likelihood(points, ELBOW[side])),
			minf(_likelihood(points, WRIST[side]), _likelihood(points, HIP[side])))
		if conf > best_conf:
			best_conf = conf
			best_side = side
	var shoulder_seen := maxf(_likelihood(points, SHOULDER[0]), _likelihood(points, SHOULDER[1])) >= MIN_LIKELIHOOD
	if best_side < 0 or best_conf < MIN_LIKELIHOOD:
		result.confidence = best_conf
		result.reason = "arm_hidden" if shoulder_seen else "no_body"
		return result
	var shoulder := _point(points, SHOULDER[best_side])
	var elbow := _point(points, ELBOW[best_side])
	var wrist := _point(points, WRIST[best_side])
	var arm := shoulder.distance_to(elbow) + elbow.distance_to(wrist)
	if arm < 0.04:
		result.confidence = best_conf
		result.reason = "too_far"
		return result
	result.depth = clampf(1.0 - (wrist.y - shoulder.y) / arm, -0.3, 1.3)
	result.confidence = best_conf
	result.reason = "ok"
	return result

static func reason_hint(reason: String) -> String:
	match reason:
		"arm_hidden":
			return "Your arm is out of view. Turn side-on to the phone, then hold the top position."
		"too_far":
			return "You are too far away. Move closer so your upper body fills the guide."
		_:
			return "No body detected. Get back into the frame side-on, then hold the top position."

static func _likelihood(points: PackedFloat32Array, index: int) -> float:
	return points[index * 3 + 2]

static func _point(points: PackedFloat32Array, index: int) -> Vector2:
	return Vector2(points[index * 3], points[index * 3 + 1])

func _start_plugin() -> void:
	_permission_pending = false
	_reset_signal()
	running = bool(_plugin.call("start", true, true))
	if not running:
		_set_status("The camera could not start. Close other camera apps and try again.")

func _reset_signal() -> void:
	_smoothed = NAN
	_last_ms = 0
	last_reason = "no_body"
	landmarks = PackedFloat32Array()

func _on_permission_result(permission: String, granted: bool) -> void:
	if not _permission_pending or permission != "android.permission.CAMERA":
		return
	if granted:
		_start_plugin()
	else:
		_permission_pending = false
		_set_status("Camera permission was declined. Allow it in app settings to count reps.")

func _on_pose_frame(points: PackedFloat32Array, width: int, height: int) -> void:
	if not running:
		return
	var now := Time.get_ticks_msec()
	var dt := 0.0 if _last_ms == 0 else clampf((now - _last_ms) / 1000.0, 0.0, 0.25)
	_last_ms = now
	landmarks = points
	if height > 0:
		aspect = float(width) / float(height)
	var result := analyze(points)
	last_reason = result.reason
	if result.reason == "ok":
		_smoothed = result.depth if is_nan(_smoothed) else lerpf(_smoothed, result.depth, SMOOTHING)
	else:
		_smoothed = NAN
	pose_sample.emit(_smoothed, result.confidence, dt)
	landmarks_updated.emit(landmarks, aspect)

func _on_preview_frame(rgba: PackedByteArray, width: int, height: int) -> void:
	if not running or rgba.size() != width * height * 4:
		return
	var image := Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, rgba)
	if preview_texture == null or preview_texture.get_size() != Vector2(width, height):
		preview_texture = ImageTexture.create_from_image(image)
	else:
		preview_texture.update(image)
	preview_updated.emit(preview_texture)

func _on_camera_status(message: String) -> void:
	match message:
		"started":
			_set_status("Camera on. Get side-on so your shoulder, arm and hip are visible.")
		"permission_missing":
			running = false
			_set_status("Camera permission is needed to count reps.")
		_:
			running = false
			_set_status("Camera problem: %s" % message)

func _set_status(message: String) -> void:
	status = message
	status_changed.emit(message)
