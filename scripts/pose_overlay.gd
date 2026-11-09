extends Control

## Draws the tracked shoulder-arm-hip skeleton over the camera preview so the
## player can see what the rep counter sees.

const BONES := [
	[11, 12], [11, 13], [13, 15], [12, 14], [14, 16],
	[11, 23], [12, 24], [23, 24], [23, 25], [24, 26],
]
const MIN_LIKELIHOOD := 0.35
const LINE_COLOR := Color(0.19, 0.82, 0.35, 0.95)
const JOINT_COLOR := Color(1.0, 1.0, 1.0, 1.0)

var points := PackedFloat32Array()
var aspect := 0.75

func set_landmarks(new_points: PackedFloat32Array, new_aspect: float) -> void:
	points = new_points
	aspect = new_aspect
	queue_redraw()

func _draw() -> void:
	if points.size() < 33 * 3 or aspect <= 0.0:
		return
	# Matches TextureRect.STRETCH_KEEP_ASPECT_COVERED: landmark units are image heights.
	var scale_px := maxf(size.x / aspect, size.y)
	var offset := (size - Vector2(aspect * scale_px, scale_px)) * 0.5
	for bone in BONES:
		var a: int = bone[0]
		var b: int = bone[1]
		if points[a * 3 + 2] < MIN_LIKELIHOOD or points[b * 3 + 2] < MIN_LIKELIHOOD:
			continue
		draw_line(_to_local(a, scale_px, offset), _to_local(b, scale_px, offset), LINE_COLOR, 4.0, true)
	for i in [11, 12, 13, 14, 15, 16, 23, 24]:
		if points[i * 3 + 2] >= MIN_LIKELIHOOD:
			draw_circle(_to_local(i, scale_px, offset), 6.0, JOINT_COLOR)

func _to_local(index: int, scale_px: float, offset: Vector2) -> Vector2:
	return offset + Vector2(points[index * 3], points[index * 3 + 1]) * scale_px
