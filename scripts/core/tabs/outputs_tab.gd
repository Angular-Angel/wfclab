class_name OutputsTab extends TabBase
## Displays the last synthesis result; re-synthesizes with the same or a
## fresh seed without returning to the Synthesizers tab.

var _preview: TextureRect
var _scroll: ScrollContainer
var _fit_check: CheckButton
var _dims: Label
var _meta_label: Label
var _rerun_button: Button
var _newseed_button: Button
var _save_button: Button
var _output_list: ItemList
var _discard_button: Button
var _active_output_id := ""
var _save_png_dialog: FileDialog


func _ready() -> void:
	super._ready()
	var split := _build_shell()

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
	_dims = UiKit.label("")
	toolbar.add_child(_dims)

	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left.add_child(_scroll)
	_preview = UiKit.preview(Vector2.ZERO, false)
	_preview.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_preview.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_preview)

	var right := UiKit.scroll_panel(split, 260.0)

	right.add_child(UiKit.label("Last Synthesis"))
	_output_list = ItemList.new()
	_output_list.custom_minimum_size = Vector2(0.0, 160.0)
	_output_list.fixed_icon_size = Vector2i(96, 96)
	_output_list.item_selected.connect(_on_output_selected)
	right.add_child(_output_list)
	_discard_button = UiKit.button("Discard Selected Output", _discard_selected_output)
	_discard_button.disabled = true
	right.add_child(_discard_button)
	_meta_label = UiKit.status_label("No synthesis yet.\nRun one from the Synthesizers tab.")
	right.add_child(_meta_label)
	right.add_child(_set_empty_state("No outputs yet. Run a synthesis."))

	_rerun_button = UiKit.button("Re-synthesize (same seed)",
			func() -> void: _resynthesize(false))
	_rerun_button.disabled = true
	right.add_child(_rerun_button)
	_newseed_button = UiKit.button("Synthesize (new seed)",
			func() -> void: _resynthesize(true))
	_newseed_button.disabled = true
	right.add_child(_newseed_button)

	_save_button = UiKit.button("Save as PNG...", _on_save_png_pressed)
	_save_button.disabled = true
	right.add_child(_save_button)

	_save_png_dialog = UiKit.file_dialog(FileDialog.FILE_MODE_SAVE_FILE,
			["*.png ; PNG images"], _on_save_png)
	add_child(_save_png_dialog)

	_bind_run_lock([_discard_button, _rerun_button, _newseed_button])
	AppData.synthesis_changed.connect(_update)
	AppData.outputs_changed.connect(_rebuild_output_list)
	_rebuild_output_list()
	_update()


func _update() -> void:
	var last_id: String = AppData.last_synthesis.get("output_id", "")
	if not last_id.is_empty() and AppData.get_output(last_id).is_empty() == false:
		_active_output_id = last_id
		_select_output(last_id)
	_show_active_output()


func _rebuild_output_list() -> void:
	_retain_selection(_output_list, _fill_output_list)
	if AppData.get_output_list().is_empty():
		_set_empty_state("No outputs yet. Run a synthesis.")
	else:
		_clear_empty_state()
	_discard_button.disabled = _active_output_id.is_empty()


func _fill_output_list() -> void:
	_output_list.clear()
	for output: Dictionary in AppData.get_output_list():
		var asset: ImageAssetData = output["asset"]
		var index := _output_list.add_icon_item(asset.thumb)
		_output_list.set_item_text(index, asset.name)
		_output_list.set_item_metadata(index, asset.id)


func _on_output_selected(index: int) -> void:
	_active_output_id = _output_list.get_item_metadata(index)
	_show_active_output()


func _select_output(output_id: String) -> void:
	var index := _find_by_metadata(_output_list, output_id)
	if index != -1:
		_output_list.select(index)


func _show_active_output() -> void:
	var s := AppData.get_output(_active_output_id)
	var has_result := not s.is_empty()
	var locked := RunMonitor.has_running()
	_rerun_button.disabled = not has_result or locked
	_newseed_button.disabled = not has_result or locked
	_discard_button.disabled = not has_result or locked
	_save_button.disabled = not has_result
	if not has_result:
		_preview.texture = null
		_dims.text = ""
		_meta_label.text = "No synthesis yet.\nRun one from the Synthesizers tab."
		return
	var asset: ImageAssetData = s["asset"]
	_preview.texture = asset.texture
	_apply_view_mode()
	_dims.text = "%d × %d" % [asset.image.get_width(), asset.image.get_height()]
	var stats: Dictionary = s.get("stats", {})
	var meta: Dictionary = s.get("meta", {})
	_meta_label.text = "seed: %d\nsynthesizer: %s\nrestarts: %d\nelapsed: %d ms" % [
		meta.get("seed", 0), meta.get("synthesizer_id", "?"),
		stats.get("restarts", 0), stats.get("elapsed_ms", 0)]


func _discard_selected_output() -> void:
	if _active_output_id.is_empty():
		return
	var discarded_id := _active_output_id
	var asset: ImageAssetData = AppData.get_output(discarded_id).get("asset")
	var name := asset.name if asset != null else discarded_id
	UiKit.confirm(self, "Discard Output",
			"Discard \"%s\"?\n\nThe output is removed from the project. "
			+ "This cannot be undone." % name,
			"Discard", func() -> void:
				_active_output_id = ""
				AppData.remove_output(discarded_id)
				_show_active_output()
	).popup_centered()


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
	var meta: Dictionary = AppData.get_output(_active_output_id).get("meta", {})
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

	# The re-run is registered with RunMonitor so the Monitor tab shows it
	# like any other synthesis (the other tabs' runs were always recorded).
	var spec := RunExecutor.RunSpec.new("synthesis",
			"%s — re-synthesize (seed %d)" % [synth.get_display_name(), seed],
			String(synth.get_id()), params, [],
			[{"key": "synthesize", "label": "Synthesize"},
			 {"key": "publish", "label": "Publish"}])
	# The run lock (bound in _ready) drives these buttons: this run is
	# registered in RunMonitor, so has_running() covers it too.
	RunExecutor.launch(self, [], null, spec,
		func(run_id: int) -> Dictionary:
			var rng := RandomNumberGenerator.new()
			rng.seed = seed
			RunMonitor.begin_stage(run_id, "synthesize", "Synthesize",
					Time.get_ticks_msec())
			var result: Dictionary = synth.synthesize(index, params, rng,
					RunMonitor.make_recorder(run_id, "synthesize"))
			RunMonitor.end_stage(run_id, "synthesize", "", Time.get_ticks_msec())
			return result,
		func(result: Dictionary, run_id: int) -> void:
			_publish(result, synth, params, seed, run_id))


func _publish(result: Dictionary, synth: Synthesizer, params: Dictionary,
		seed: int, run_id: int) -> void:
	if result.is_empty():
		_meta_label.text = "Synthesis failed (see console)."
		RunExecutor.fail([], run_id, "synthesize() returned no result.")
		_update()   # re-enables buttons, keeps last good image
		return
	var t0 := Time.get_ticks_msec()
	RunMonitor.begin_stage(run_id, "publish", "Publish", t0)
	AppData.set_synthesis(result["image"], result["stats"], {
		"synthesizer_id": String(synth.get_id()),
		"params": params,
		"seed": seed,
	})
	var t_end := Time.get_ticks_msec()
	RunMonitor.end_stage(run_id, "publish",
			"set_synthesis %d ms" % (t_end - t0), t_end)
	RunExecutor.complete([], run_id, result["stats"],
			"Re-synthesized: %d restarts" %
					int(result["stats"].get("restarts", 0)))


func _on_save_png_pressed() -> void:
	var asset: ImageAssetData = AppData.get_output(_active_output_id).get("asset")
	if asset == null:
		return
	_save_png_dialog.current_file = "%s.png" % asset.name.to_lower().replace(" ", "_")
	_save_png_dialog.popup_centered_ratio(UiKit.POPUP_RATIO)


func _on_save_png(path: String) -> void:
	var asset: ImageAssetData = AppData.get_output(_active_output_id).get("asset")
	if asset == null:
		return
	var err := asset.image.save_png(path)
	if err != OK:
		push_error("Failed to save PNG: %s (error %d)" % [path, err])
