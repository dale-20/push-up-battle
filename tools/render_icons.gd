extends SceneTree

## Renders the app icon PNGs from assets/icon/logo_figure.svg.
## Run after editing the logo:
##   godot --headless --path . --script res://tools/render_icons.gd
##
## Outputs (all in assets/icon/):
##   icon_1024.png               full icon (iOS, store listings)
##   icon_192.png                Android legacy launcher icon
##   adaptive_foreground.png     Android adaptive layer, 432 px, mark inside the safe circle
##   adaptive_background.png     Android adaptive layer, 432 px
##   adaptive_monochrome.png     Android 13+ themed icon, white mark on transparent
##   splash.png                  boot splash (mark only, transparent)
## The project icon res://icon.svg is the same artwork on the dark tile; keep it in sync.

const DIR := "res://assets/icon/"
const BG_TOP := Color("1c1c1e")
const BG_BOTTOM := Color("000000")
const GREEN := "#30d158"
## Android masks adaptive icons to a circle 66/108 of the layer; keep the mark inside it.
const ADAPTIVE_SCALE := 0.8
## Boot splash: the mark alone, shown on the black splash background.
const SPLASH_SCALE := 0.55

func _initialize() -> void:
	var svg := FileAccess.get_file_as_string(DIR + "logo_figure.svg")
	if svg.is_empty():
		push_error("logo_figure.svg not found")
		quit(1)
		return
	_save(_full_icon(svg, 1024), "icon_1024.png")
	_save(_full_icon(svg, 192), "icon_192.png")
	_save(_mark(svg, 432, ADAPTIVE_SCALE), "adaptive_foreground.png")
	_save(_background(432), "adaptive_background.png")
	var mono := svg.replace(GREEN, "#ffffff").replace("opacity=\"0.35\"", "opacity=\"0.5\"")
	_save(_mark(mono, 432, ADAPTIVE_SCALE), "adaptive_monochrome.png")
	_save(_mark(svg, 1024, SPLASH_SCALE), "splash.png")
	print("Icons written to ", ProjectSettings.globalize_path(DIR))
	quit(0)

## Rounded dark tile with the mark on top. Launchers that mask the icon
## crop the corners, the rest show the rounded tile.
func _full_icon(svg: String, size: int) -> Image:
	var image := _background(size)
	var corner := size * 0.22
	for y in size:
		for x in size:
			if not _inside_rounded(x + 0.5, y + 0.5, size, corner):
				image.set_pixel(x, y, Color(0, 0, 0, 0))
	image.blend_rect(_mark(svg, size, 1.0), Rect2i(0, 0, size, size), Vector2i.ZERO)
	return image

func _mark(svg: String, size: int, scale: float) -> Image:
	var mark := Image.new()
	mark.load_svg_from_string(svg, size / 512.0 * scale)
	mark.convert(Image.FORMAT_RGBA8)
	var canvas := Image.create_empty(size, size, false, Image.FORMAT_RGBA8)
	var offset := Vector2i((size - mark.get_width()) / 2, (size - mark.get_height()) / 2)
	canvas.blend_rect(mark, Rect2i(Vector2i.ZERO, mark.get_size()), offset)
	return canvas

func _background(size: int) -> Image:
	var image := Image.create_empty(size, size, false, Image.FORMAT_RGBA8)
	for y in size:
		var row := BG_TOP.lerp(BG_BOTTOM, float(y) / (size - 1))
		for x in size:
			image.set_pixel(x, y, row)
	return image

func _inside_rounded(x: float, y: float, size: int, r: float) -> bool:
	var cx := clampf(x, r, size - r)
	var cy := clampf(y, r, size - r)
	return Vector2(x - cx, y - cy).length() <= r

func _save(image: Image, file: String) -> void:
	var err := image.save_png(DIR + file)
	if err != OK:
		push_error("could not write %s (%d)" % [file, err])
