extends Control

func _draw() -> void:
	var bounds := Rect2(Vector2(20, 18), size - Vector2(40, 36))
	draw_rect(bounds, Color(0.19, 0.82, 0.35, 0.85), false, 3.0, true)
	var y := bounds.position.y + bounds.size.y * 0.43
	draw_line(Vector2(bounds.position.x, y), Vector2(bounds.end.x, y), Color(1, 1, 1, 0.3), 1.0)
