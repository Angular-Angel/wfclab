class_name SynthesizersTab extends Control
## Configure and run a synthesizer over the current materialized state.
## Synthesizers that support it can run interactively: step, play, watch.

var _technique_option: OptionButton
var _params_box: VBoxContainer
var _seed_spin: SpinBox
var _run_button: Button
var _status: Label
var _interactive: CheckButton

var _session_box: VBoxContainer
var _step_button: Button
var _micro_check: CheckButton
var _play_button: Button
var _speed: OptionButton
var _restart_button: Button
var _cancel_button: Button

var _preview: TextureRect
var _fit_check: CheckButton
var _entropy_check: CheckButton
var _dims: Label

var _param_values: Dictionary = {}
var _current: Synthesizer = null
var _session: SynthesisSession = null
var _playing := false
var _accum := 0.0


func _ready() -> void:
	var split := HSplitContainer.new()
	split.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(split)

	var left_scroll := ScrollContainer.new()
	left_scroll.custom_minimum_size = Vector2(320.0, 0.0)
	left_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	split.add_child(left_scroll)

	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left_scroll.add_child(left)

	left.add_child(_mk_label("Synthesizer"))
	_technique_option = OptionButton.new()
	for s: Synthesizer in TechniqueRegistry.get_synthesizer_techniques():
		_technique_option.add_item(s.get_display_name())
		_technique_option.set_item_metadata(_technique_option.item_count - 1, s.get_id())
	_technique_option.item_selected.connect(_on_technique_selected)
	left.add_child(_technique_option)

	left.add_child(_mk_label("Parameters"))
	_params_box = VBoxContainer.new()
	left.add_child(_params_box)

	var seed_row := HBoxContainer.new()
	left.add_child(seed_row)
	var seed_label := _mk_label("Seed")
	seed_label.custom_minimum_size = Vector2(110.0, 0.0)
	seed_row.add_child(seed_label)
	_seed_spin = SpinBox.new()
	_seed_spin.min_value = 0
	_seed_spin.max_value = 999999
	_seed_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	seed_row.add_child(_seed_spin)
	var random_seed := Button.new()
	random_seed.text = "Random"
	random_seed.pressed.connect(
		func() -> void: _seed_spin.value = randi() % 1000000)
	seed_row.add_child(random_seed)

	_interactive = CheckButton.new()
	_interactive.text = "Interactive (step through)"
	_interactive.tooltip_text = "Runs on the main thread with Step/Play controls" \
		+ " instead of the worker thread. Same seed, same result."
	left.add_child(_interactive)

	_run_button = Button.new()
	_run_button.text = "Synthesize"
	_run_button.pressed.connect(_on_run_pressed)
	left.add_child(_run_button)

	_session_box = VBoxContainer.new()
	_session_box.visible = false
	left.add_child(_session_box)

	var step_row := HBoxContainer.new()
	_session_box.add_child(step_row)
	_step_button = Button.new()
	_step_button.text = "Step"
	_step_button.pressed.connect(_on_step_pressed)
	step_row.add_child(_step_button)
	_micro_check = CheckButton.new()
	_micro_check.text = "Micro-step"
	_micro_check.tooltip_text = "Off: one observation + full propagation.\n" \
		+ "On: one observation OR one propagation queue entry."
	step_row.add_child(_micro_check)

	var play_row := HBoxContainer.new()
	_session_box.add_child(play_row)
	_play_button = Button.new()
	_play_button.text = "Play"
	_play_button.pressed.connect(_on_play_pressed)
	play_row.add_child(_play_button)
	_speed = OptionButton.new()
	var speeds: Array = [["1/s", 1.0], ["4/s", 4.0], ["15/s", 15.0],
		["60/s", 60.0], ["Max", -1.0]]
	for item: Array in speeds:
		_speed.add_item(item[0])
		_speed.set_item_metadata(_speed.item_count - 1, item[1])
	_speed.select(2)
	play_row.add_child(_speed)

	var ctl_row := HBoxContainer.new()
	_session_box.add_child(ctl_row)
	_restart_button = Button.new()
	_restart_button.text = "Restart"
	_restart_button.tooltip_text = "Start over with the current seed."
	_restart_button.pressed.connect(_start_session)
	ctl_row.add_child(_restart_button)
	_cancel_button = Button.new()
	_cancel_button.text = "Close"
	_cancel_button.pressed.connect(_stop_session)
	ctl_row.add_child(_cancel_button)

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	left.add_child(_status)

	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.add_child(right)
	right.add_child(_mk_label("Live Preview"))
	var view_row := HBoxContainer.new()
	right.add_child(view_row)
	_fit_check = CheckButton.new()
	_fit_check.text = "Fit"
	_fit_check.button_pressed = true
	_fit_check.toggled.connect(func(_p: bool) -> void: _apply_view_mode())
	view_row.add_child(_fit_check)
	_entropy_check = CheckButton.new()
	_entropy_check.text = "Entropy view"
	_entropy_check.toggled.connect(func(_p: bool) -> void: _update_session_ui())
	view_row.add_child(_entropy_check)
	_dims = Label.new()
	view_row.add_child(_dims)

	var preview_scroll := ScrollContainer.new()
	preview_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	preview_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	right.add_child(preview_scroll)
	_preview = TextureRect.new()
	_preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_preview.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_preview.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_preview.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	preview_scroll.add_child(_preview)

	right.add_child(_mk_label("Notes"))
	var notes := Label.new()
	notes.text = ("Synthesis consumes the materialized parts and constraints, "
		+ "including all manual edits — disable a part or reweight a "
		+ "constraint, re-synthesize, and see the difference.\n\n"
		+ "Interactive mode steps the algorithm on the main thread: watch "
		+ "observations collapse slots and propagation cascade outward; a "
		+ "contradiction visibly wipes the board and restarts.\n\n"
		+ "Finished runs are published to the Outputs tab exactly like batch "
		+ "runs; the same seed reproduces the same output either way.")
	notes.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	right.add_child(notes)

	if _technique_option.item_count > 0:
		_technique_option.select(0)
		_on_technique_selected(0)


func _mk_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l


func _on_technique_selected(index: int) -> void:
	_stop_session()
	var id: StringName = _technique_option.get_item_metadata(index)
	_current = TechniqueRegistry.get_synthesizer(id)
	for child in _params_box.get_children():
		child.free()
	_param_values = {}
	var steppable := _current != null and _current.supports_stepping()
	_interactive.disabled = not steppable
	if not steppable:
		_interactive.button_pressed = false
	if _current != null:
		ParamBuilder.build(_current.get_parameter_specs(), _param_values, _params_box)


func _on_run_pressed() -> void:
	if _current == null:
		return
	var index := AppData.get_constraint_index()
	if index.get_part_ids().is_empty():
		_status.text = "No parts. Run a decomposition first."
		return
	if _interactive.button_pressed and _current.supports_stepping():
		_start_session()
		return
	var synth := _current
	var params := _param_values.duplicate(true)
	var seed := int(_seed_spin.value)

	_run_button.disabled = true
	_status.text = "Synthesizing..."

	WorkerThreadPool.add_task(func() -> void:
		var rng := RandomNumberGenerator.new()
		rng.seed = seed
		var no_progress := func(_f: float) -> void: pass
		var result: Dictionary = synth.synthesize(index, params, rng, no_progress)
		_publish.call_deferred(result, synth, params, seed)
	)


func _publish(result: Dictionary, synth: Synthesizer, params: Dictionary,
		seed: int) -> void:
	_run_button.disabled = false
	if result.is_empty():
		_status.text = "Synthesis failed (see console)."
		return
	AppData.set_synthesis(result["image"], result["stats"], {
		"synthesizer_id": String(synth.get_id()),
		"params": params,
		"seed": seed,
	})
	var stats: Dictionary = result["stats"]
	_status.text = "Done (%d restarts, %d ms)" % [
		stats.get("restarts", 0), stats.get("elapsed_ms", 0)]

	var tabs := get_parent() as TabContainer
	if tabs != null:
		var target := tabs.get_node_or_null("Outputs")
		if target != null:
			tabs.current_tab = tabs.get_tab_idx_from_control(target)


# --- Interactive session --------------------------------------------------------

func _start_session() -> void:
	_stop_session()
	if _current == null or not _current.supports_stepping():
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = int(_seed_spin.value)
	_session = _current.create_session(
			AppData.get_constraint_index(),
			_param_values.duplicate(true), rng)
	if _session == null:
		_status.text = "This synthesizer does not support stepping."
		return
	_session_box.visible = true
	_run_button.disabled = true
	_play_button.text = "Play"
	_playing = false
	_accum = 0.0
	_update_session_ui()


func _stop_session() -> void:
	_session = null
	_playing = false
	_session_box.visible = false
	_run_button.disabled = false
	_preview.texture = null
	_dims.text = ""


func _process(delta: float) -> void:
	if _session == null or not _playing or _session.is_finished():
		return
	var sps := float(_speed.get_selected_metadata())
	if sps < 0.0:   # Max: run inside a frame-time budget
		var t0 := Time.get_ticks_msec()
		while not _session.is_finished() and Time.get_ticks_msec() - t0 < 8:
			_do_step()
	else:
		_accum += delta * sps
		while _accum >= 1.0 and not _session.is_finished():
			_accum -= 1.0
			_do_step()
	if _session.is_finished():
		_finish_session()
	else:
		_update_session_ui()


func _on_step_pressed() -> void:
	if _session == null or _session.is_finished():
		return
	_do_step()
	if _session.is_finished():
		_finish_session()
	else:
		_update_session_ui()


func _do_step() -> void:
	if _micro_check.button_pressed:
		_session.micro_step()
	else:
		_session.step()


func _on_play_pressed() -> void:
	if _session == null or _session.is_finished():
		return
	_playing = not _playing
	_play_button.text = "Pause" if _playing else "Play"
	_accum = 0.0


func _finish_session() -> void:
	_playing = false
	_play_button.text = "Play"
	_update_session_ui()   # final render; also disables step/play
	var result := _session.get_result()
	if result.is_empty():
		_status.text = _session.get_status()
		return
	AppData.set_synthesis(result["image"], result["stats"], {
		"synthesizer_id": String(_current.get_id()),
		"params": _param_values.duplicate(true),
		"seed": int(_seed_spin.value),
	})
	_status.text = _session.get_status() + " — published to Outputs."


func _update_session_ui() -> void:
	if _session == null:
		return
	var finished := _session.is_finished()
	_step_button.disabled = finished
	_play_button.disabled = finished
	var img: Image = null
	if _entropy_check.button_pressed:
		img = _session.get_entropy_image()
	else:
		img = _session.get_preview()
	if img != null:
		_preview.texture = ImageTexture.create_from_image(img)
		_apply_view_mode()
	if _preview.texture != null:
		var sz := _preview.texture.get_size()
		_dims.text = "%d × %d" % [int(sz.x), int(sz.y)]
	else:
		_dims.text = ""
	_status.text = _session.get_status()


func _apply_view_mode() -> void:
	if _fit_check.button_pressed:
		_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		_preview.custom_minimum_size = Vector2.ZERO
	else:
		_preview.stretch_mode = TextureRect.STRETCH_KEEP
		if _preview.texture != null:
			_preview.custom_minimum_size = _preview.texture.get_size()
		else:
			_preview.custom_minimum_size = Vector2.ZERO
