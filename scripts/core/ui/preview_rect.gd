class_name PreviewRect extends TextureRect
## TextureRect that can flash-highlight a region of the displayed image,
## specified in image coordinates. Supports the two stretch modes the app
## uses (KEEP_ASPECT_CENTERED fit mode and KEEP 1:1 mode).

var highlight := Rect2i()                    # image-space; empty = none
var _highlight_until_msec := 0


func flash_highlight(rect: Rect2i, duration_msec: int = 7500) -> void:
	highlight = rect
	_highlight_until_msec = Time.get_ticks_msec() + duration_msec
	set_process(true)
	queue_redraw()


func clear_highlight() -> void:
	highlight = Rect2i()
	_highlight_until_msec = 0
	set_process(false)
	queue_redraw()


func _process(_delta: float) -> void:
	if Time.get_ticks_msec() > _highlight_until_msec:
		clear_highlight()
	else:
		queue_redraw()   # keep the pulse animating


func _draw() -> void:
	if texture == null or highlight.size == Vector2i.ZERO:
		return
	var r := _image_to_control(highlight)
	if r.size == Vector2.ZERO:
		return
	# Grow so tiny regions (a 4x4 tile at fit-downscale) stay visible.
	var expanded := r.grow(2.0)
	var pulse := 0.5 + 0.5 * sin(Time.get_ticks_msec() / 150.0)
	draw_rect(expanded, Color(1.0, 0.9, 0.2, 0.15), true)
	draw_rect(expanded, Color(1.0, 0.9, 0.2, 0.4 + 0.6 * pulse), false, 2.0)


func _image_to_control(rect: Rect2i) -> Rect2:
	var tex_size := texture.get_size()
	if tex_size == Vector2.ZERO:
		return Rect2()
	match stretch_mode:
		TextureRect.STRETCH_KEEP_ASPECT_CENTERED:
			var scale := minf(size.x / tex_size.x, size.y / tex_size.y)
			var offset := (size - tex_size * scale) * 0.5
			return Rect2(offset + Vector2(rect.position) * scale,
				Vector2(rect.size) * scale)
		TextureRect.STRETCH_KEEP:
			return Rect2(Vector2(rect.position), Vector2(rect.size))
		_:
			return Rect2()   # other stretch modes not used by the app
