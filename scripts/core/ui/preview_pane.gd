class_name PreviewPane extends VBoxContainer
## Fit/1:1 image viewer shared by the Images, Outputs, and Synthesizers
## tabs: a toolbar row (Fit-to-window check, info label, then any caller
## extras), a scrollable PreviewRect, and the view-mode logic that used
## to be copy-pasted per tab — KEEP_ASPECT_CENTERED fit vs 1:1 KEEP with
## a texture-sized minimum, NEAREST filtering while the texture is
## upscaled / LINEAR while downscaled, and the occurrence-jump
## scroll_to_region helper. `view_changed` fires on every mode switch
## (the Synthesizers overlay redraws on it).

signal view_changed

var toolbar: HBoxContainer
var fit_check: CheckButton
var info_label: Label
var scroll: ScrollContainer
var preview: PreviewRect


func _init() -> void:
	toolbar = HBoxContainer.new()
	add_child(toolbar)
	fit_check = CheckButton.new()
	fit_check.text = "Fit to window"
	fit_check.button_pressed = true
	fit_check.toggled.connect(func(_p: bool) -> void: _apply_view_mode())
	toolbar.add_child(fit_check)
	info_label = UiKit.label("")
	toolbar.add_child(info_label)

	scroll = ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(scroll)
	preview = PreviewRect.new()
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	preview.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	preview.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.add_child(preview)


## Swap the image and re-apply the view mode: a size change can flip the
## upscale/downscale filter, and 1:1 mode re-anchors the minimum size to
## the new texture.
func show_texture(texture: Texture2D) -> void:
	preview.texture = texture
	_apply_view_mode()


func fit_active() -> bool:
	return fit_check.button_pressed


## Center a pixel region in 1:1 mode; fit mode needs no scrolling.
func scroll_to_region(region: Rect2i) -> void:
	if fit_check.button_pressed:
		return
	var view := scroll.size
	scroll.scroll_horizontal = maxi(0, int(region.position.x - view.x * 0.5))
	scroll.scroll_vertical = maxi(0, int(region.position.y - view.y * 0.5))


func _apply_view_mode() -> void:
	if fit_check.button_pressed:
		preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		preview.custom_minimum_size = Vector2.ZERO
	else:
		preview.stretch_mode = TextureRect.STRETCH_KEEP
		preview.custom_minimum_size = preview.texture.get_size() \
				if preview.texture != null else Vector2.ZERO
	_apply_filter_mode()
	view_changed.emit()


func _apply_filter_mode() -> void:
	if preview.texture == null:
		return
	var tex_size := preview.texture.get_size()
	var view_size := get_viewport_rect().size
	var upscaled := tex_size.x < view_size.x or tex_size.y < view_size.y
	preview.texture_filter = (
		CanvasItem.TEXTURE_FILTER_NEAREST if upscaled
		else CanvasItem.TEXTURE_FILTER_LINEAR
	)
