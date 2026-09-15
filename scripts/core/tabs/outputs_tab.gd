class_name OutputsTab extends Control
## Displays the last synthesis result; re-synthesizes with the same or a
## fresh seed without returning to the Synthesizers tab.

var _preview: TextureRect
var _scroll: ScrollContainer
var _fit_check: CheckButton
var _dims: Label
var _meta_label: Label
var _rerun_button: Button
var _newseed_button: Button


func _ready() -> void:
	var split := HSplitContainer.new()
	split.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(split)

	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.add_child(left)

	var toolbar := HBoxContainer.new()
	left.add_child(toolbar)
	_fit_check = CheckButton.new()
	_fit_check.text = "Fit to window"
	_fit_check.button_pressed = true
	_fit_check.toggled.connect(func(_p: bool) -> void: _apply_view_mode())
	toolbar.add_child(_fit_check)
	_dims = Label.new()
	toolbar.add_child(_dims)

	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left.add_child(_scroll)
	_preview = TextureRect.new()
	_preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_preview.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_preview.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_preview.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_scroll.add_child(_preview)

	var right := VBoxContainer.new()
	right.custom_minimum_size = Vector2(260.0, 0.0)
	split.add_child(right)

	right.add_child(_mk_label("Last Synthesis"))
	_meta_label = Label.new()
	_meta_label.text = "No synthesis yet.\nRun one from the Synthesizers tab."
	_meta_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	right.add_child(_meta_label)

	_rerun_button = Button.new()
	_rerun_button.text = "Re-synthesize (same seed)"
	_rerun_button.disabled = true
	_rerun_button.pressed.connect(func() -> void: _resynthesize(false))
	right.add_child(_rerun_button)
	_newseed_button = Button.new()
	_newseed_button.text = "Synthesize (new seed)"
	_newseed_button.disabled = true
	_newseed_button.pressed.connect(func() -> void: _resynthesize(true))
	right.add_child(_newseed_button)

	AppData.synthesis_changed.connect(_update)
	_update()


func _mk_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l


func _update() -> void:
	var s: Dictionary = AppData.last_synthesis
	var has_result := not s.is_empty() and s.has("image")
	_rerun_button.disabled = not has_result
	_newseed_button.disabled = not has_result
	if not has_result:
		_preview.texture = null
		_dims.text = ""
		return
	var image: Image = s["image"]
	_preview.texture = ImageTexture.create_from_image(image)
	_apply_view_mode()
	_dims.text = "%d × %d" % [image.get_width(), image.get_height()]
	var stats: Dictionary = s.get("stats", {})
	var meta: Dictionary = s.get("meta", {})
	_meta_label.text = "seed: %d\nsynthesizer: %s\nrestarts: %d\nelapsed: %d ms" % [
		meta.get("seed", 0), meta.get("synthesizer_id", "?"),
		stats.get("restarts", 0), stats.get("elapsed_ms", 0)]


func _apply_view_mode() -> void:
	if _fit_check.button_pressed:
		_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		_preview.custom_minimum_size = Vector2.ZERO
	else:
		_preview.stretch_mode = TextureRect.STRETCH_KEEP
		if _preview.texture != null:
			_preview.custom_minimum_size = _preview.texture.get_size()
	_apply_filter_mode()


func _apply_filter_mode() -> void:
	if _preview.texture == null:
		return
	var tex_size := _preview.texture.get_size()
	var view_size := get_viewport_rect().size
	if tex_size.x < view_size.x or tex_size.y < view_size.y:
		_preview.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	else:
		_preview.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR


func _resynthesize(new_seed: bool) -> void:
	var meta: Dictionary = AppData.last_synthesis.get("meta", {})
	if meta.is_empty():
		return
	var synth := TechniqueRegistry.get_synthesizer(
		StringName(String(meta.get("synthesizer_id", ""))))
	if synth == null:
		return
	var params: Dictionary = (meta.get("params", {}) as Dictionary).duplicate(true)
	var seed: int = meta.get("seed", 0)
	if new_seed:
		seed = randi() % 1000000
	var index := AppData.get_constraint_index()

	_rerun_button.disabled = true
	_newseed_button.disabled = true
	WorkerThreadPool.add_task(func() -> void:
		var rng := RandomNumberGenerator.new()
		rng.seed = seed
		var no_progress := func(_f: float) -> void: pass
		var result: Dictionary = synth.synthesize(index, params, rng, no_progress)
		_publish.call_deferred(result, synth, params, seed)
	)


func _publish(result: Dictionary, synth: Synthesizer, params: Dictionary,
		seed: int) -> void:
	if result.is_empty():
		_meta_label.text = "Synthesis failed (see console)."
		_update()   # re-enables buttons, keeps last good image
		return
	AppData.set_synthesis(result["image"], result["stats"], {
		"synthesizer_id": String(synth.get_id()),
		"params": params,
		"seed": seed,
	})
