extends Control

func _draw() -> void:
	var bounds := Rect2(Vector2(20, 18), size - Vector2(40, 36))
	draw_rect(bounds, Color(0.84, 0.98, 0.44, 0.8), false, 2.0, true)
	var y := bounds.position.y + bounds.size.y * 0.43
	draw_line(Vector2(bounds.position.x, y), Vector2(bounds.end.x, y), Color(0.84, 0.98, 0.44, 0.42), 1.0)
