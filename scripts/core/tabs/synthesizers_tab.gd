class_name SynthesizersTab extends TabBase
## Configure and run a synthesizer over the current materialized state.
## Interactive sessions can be stepped, played, and hand-edited: click a
## slot (or cursor onto it with arrows) to see its candidates and pin one.

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

var _pane: PreviewPane
var _overlay: SlotOverlay
var _entropy_check: CheckButton
var _picker: SlotPicker

var _param_values: Dictionary = {}
var _current: Synthesizer = null
var _session: SynthesisSession = null
var _playing := false
var _accum := 0.0
var _cursor_slot := -1

var _monitor_run_id := -1
var _steps := 0
var _last_monitor_push := 0


func _ready() -> void:
	super._ready()
	var split := _build_shell()

	var left := UiKit.scroll_panel(split, 320.0)

	left.add_child(UiKit.label("Synthesizer"))
	_technique_option = OptionButton.new()
	for s: Synthesizer in TechniqueRegistry.get_synthesizer_techniques():
		_technique_option.add_item(s.get_display_name())
		_technique_option.set_item_metadata(_technique_option.item_count - 1, s.get_id())
	_technique_option.item_selected.connect(_on_technique_selected)
	left.add_child(_technique_option)

	left.add_child(UiKit.label("Parameters"))
	_params_box = VBoxContainer.new()
	left.add_child(_params_box)

	var seed_row := HBoxContainer.new()
	left.add_child(seed_row)
	var seed_label := UiKit.label("Seed")
	seed_label.custom_minimum_size = Vector2(UiKit.PARAM_LABEL_W, 0.0)
	seed_row.add_child(seed_label)
	_seed_spin = SpinBox.new()
	_seed_spin.min_value = 0
	_seed_spin.max_value = 999999
	_seed_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	seed_row.add_child(_seed_spin)
	seed_row.add_child(UiKit.button("Random",
			func() -> void: _seed_spin.value = randi() % 1000000))

	_interactive = CheckButton.new()
	_interactive.text = "Interactive (step through)"
	_interactive.tooltip_text = "Runs on the main thread with Step/Play controls" \
		+ " instead of the worker thread. Same seed, same result."
	left.add_child(_interactive)

	_run_button = UiKit.button("Synthesize", _on_run_pressed)
	left.add_child(_run_button)

	_session_box = VBoxContainer.new()
	_session_box.visible = false
	left.add_child(_session_box)

	var step_row := HBoxContainer.new()
	_session_box.add_child(step_row)
	_step_button = UiKit.button("Step", _on_step_pressed)
	step_row.add_child(_step_button)
	_micro_check = CheckButton.new()
	_micro_check.text = "Micro-step"
	_micro_check.tooltip_text = "Off: one observation + full propagation.\n" \
		+ "On: one observation OR one propagation queue entry."
	step_row.add_child(_micro_check)

	var play_row := HBoxContainer.new()
	_session_box.add_child(play_row)
	_play_button = UiKit.button("Play", _on_play_pressed)
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
	_restart_button = UiKit.button("Restart", _start_session,
			"Start over with the current seed.")
	ctl_row.add_child(_restart_button)
	_cancel_button = UiKit.button("Close", _stop_session)
	ctl_row.add_child(_cancel_button)

	var status_row := UiKit.status_copy_row(
			func() -> String: return _status.text)
	_status = status_row.status
	left.add_child(status_row)
	left.add_child(_set_empty_state("No parts. Run a decomposition first."))
	AppData.parts_changed.connect(_update_empty_hint)
	_update_empty_hint()

	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.add_child(right)
	right.add_child(UiKit.label("Live Preview"))

	_pane = PreviewPane.new()
	right.add_child(_pane)
	_entropy_check = CheckButton.new()
	_entropy_check.text = "Entropy view"
	_entropy_check.toggled.connect(func(_p: bool) -> void: _update_session_ui())
	_pane.toolbar.add_child(_entropy_check)
	var hint := Label.new()
	hint.text = "Click a slot to place/clear · Arrows move · Enter picks"
	hint.modulate = Color(1.0, 1.0, 1.0, UiKit.HINT_ALPHA)
	_pane.toolbar.add_child(hint)

	_overlay = SlotOverlay.new()
	_overlay._tab = self
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_pane.preview.add_child(_overlay)
	_pane.preview.resized.connect(_overlay.queue_redraw)
	_pane.view_changed.connect(_overlay.queue_redraw)
	_pane.preview.focus_mode = Control.FOCUS_ALL
	_pane.preview.gui_input.connect(_on_preview_input)

	_picker = SlotPicker.new()
	_picker.picked.connect(_on_picker_picked)
	_picker.clear_requested.connect(_on_picker_cleared)
	add_child(_picker)

	right.add_child(UiKit.label("Notes"))
	right.add_child(UiKit.note(
		"Synthesis consumes the materialized parts and constraints, "
		+ "including all manual edits — disable a part or reweight a "
		+ "constraint, re-synthesize, and see the difference.\n\n"
		+ "Interactive mode steps the algorithm on the main thread: watch "
		+ "observations collapse slots and propagation cascade outward; choose "
		+ "whether contradictions stop, restart, or backtrack.\n\n"
		+ "While a run is active, click a slot (or arrow onto it and press "
		+ "Enter) to see its candidate tiles and pin one; propagation ripples "
		+ "from your edit. Edits that contradict neighbors are rejected."))

	if _technique_option.item_count > 0:
		_technique_option.select(0)
		_on_technique_selected(0)


func _on_technique_selected(index: int) -> void:
	_stop_session()
	var id: StringName = _technique_option.get_item_metadata(index)
	_current = TechniqueRegistry.get_synthesizer(id)
	UiKit.clear_children(_params_box)
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
		_update_empty_hint()   # the standardized hint carries the message
		return
	if _interactive.button_pressed and _current.supports_stepping():
		_start_session()
		return
	var synth := _current
	var params := _param_values.duplicate(true)
	var seed := int(_seed_spin.value)

	var spec := RunExecutor.RunSpec.new("synthesis",
			"%s — batch (seed %d)" % [synth.get_display_name(), seed],
			String(synth.get_id()), params, _synth_inputs(index),
			[{"key": "synthesize", "label": "Synthesize"},
			 {"key": "publish", "label": "Publish"}])
	RunExecutor.launch(self, [_run_button], _status, spec,
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


func _update_empty_hint() -> void:
	if AppData.get_constraint_index().get_part_ids().is_empty():
		_set_empty_state("No parts. Run a decomposition first.")
	else:
		_clear_empty_state()


func _synth_inputs(index: ConstraintIndex) -> Array:
	var parts := index.get_part_ids().size()
	var text := "%d parts · %d offsets" % [parts, index.get_offsets().size()]
	if index.family_count > 0 and index.family_count < parts:
		text = "%d parts → %d families · %d offsets" % [
				parts, index.family_count, index.get_offsets().size()]
	return [text]


func _publish(result: Dictionary, synth: Synthesizer, params: Dictionary,
		seed: int, run_id: int) -> void:
	if result.is_empty():
		_status.text = "Synthesis failed (see console)."
		RunExecutor.fail([_run_button], run_id, "synthesize() returned no result.")
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
	RunExecutor.complete([_run_button], run_id, result["stats"],
			"Done (%d restarts)" % int(result["stats"].get("restarts", 0)))
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
	_steps = 0
	_last_monitor_push = 0
	_monitor_run_id = RunMonitor.begin_run("session",
			"%s — interactive (seed %d)" % [_current.get_display_name(),
			int(_seed_spin.value)], String(_current.get_id()),
			_param_values.duplicate(true),
			_synth_inputs(_session.get_source_index()), "main")
	_update_session_ui()


func _stop_session() -> void:
	if _monitor_run_id != -1:
		var rec := RunMonitor.get_run(_monitor_run_id)
		if not rec.is_empty() and String(rec.get("status", "")) == "running":
			RunMonitor.cancel_run(_monitor_run_id)
		_monitor_run_id = -1
	_picker.hide()
	_session = null
	_playing = false
	_cursor_slot = -1
	_session_box.visible = false
	_run_button.disabled = false
	_pane.show_texture(null)
	_pane.info_label.text = ""
	_overlay.queue_redraw()


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
	_steps += 1
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
	if _monitor_run_id != -1:
		if result.is_empty():
			RunMonitor.fail_run(_monitor_run_id, _session.get_status())
		else:
			RunMonitor.finish_run(_monitor_run_id, result["stats"],
					_session.get_status())
		_monitor_run_id = -1
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
		_pane.show_texture(ImageTexture.create_from_image(img))
	if _pane.preview.texture != null:
		var sz := _pane.preview.texture.get_size()
		_pane.info_label.text = "%d × %d" % [int(sz.x), int(sz.y)]
	else:
		_pane.info_label.text = ""
	_status.text = _session.get_status()
	_overlay.queue_redraw()
	if _monitor_run_id != -1 \
			and Time.get_ticks_msec() - _last_monitor_push >= 100:
		_last_monitor_push = Time.get_ticks_msec()
		RunMonitor.update_session(_monitor_run_id, _session.get_status(),
				_session.get_progress(), _steps)


# --- Slot cursor & manual editing ------------------------------------------------

func _on_preview_input(event: InputEvent) -> void:
	if _session == null:
		return
	if event is InputEventMouseButton \
			and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			var slot := _session.pixel_to_slot(_ctrl_to_tex(event.position))
			if slot != -1:
				_cursor_slot = slot
				_overlay.queue_redraw()
				_pane.preview.accept_event()
				_open_picker()
		return
	if event is InputEventMouseMotion and not _playing:
		var slot := _session.pixel_to_slot(_ctrl_to_tex(event.position))
		if slot != -1 and slot != _cursor_slot:
			_cursor_slot = slot
			_overlay.queue_redraw()
		return
	if event is InputEventKey and event.pressed:
		if event.is_action_pressed("ui_left", true):
			_move_cursor(Vector2i(-1, 0))
		elif event.is_action_pressed("ui_right", true):
			_move_cursor(Vector2i(1, 0))
		elif event.is_action_pressed("ui_up", true):
			_move_cursor(Vector2i(0, -1))
		elif event.is_action_pressed("ui_down", true):
			_move_cursor(Vector2i(0, 1))
		elif event.is_action_pressed("ui_accept") and not event.is_echo():
			_open_picker()
		else:
			return
		_pane.preview.accept_event()


func _preview_xform() -> Transform2D:
	## Texture-pixel space -> preview control space for the current mode.
	if _pane.preview.texture == null:
		return Transform2D()
	var ts := _pane.preview.texture.get_size()
	if _pane.fit_active():
		var cs := _pane.preview.size
		if ts.x <= 0.0 or ts.y <= 0.0 or cs.x <= 0.0 or cs.y <= 0.0:
			return Transform2D()
		var s := minf(cs.x / ts.x, cs.y / ts.y)
		return Transform2D(0.0, Vector2(s, s), 0.0, (cs - ts * s) * 0.5)
	return Transform2D()   # 1:1 inside the scroll container


func _ctrl_to_tex(local: Vector2) -> Vector2i:
	var p := _preview_xform().affine_inverse() * local
	return Vector2i(floori(p.x), floori(p.y))


@warning_ignore("integer_division")
func _move_cursor(d: Vector2i) -> void:
	if _session == null:
		return
	var dims := _session.get_slot_dims()
	if dims == Vector2i.ZERO:
		return
	var pos: Vector2i
	if _cursor_slot == -1:
		pos = Vector2i(dims.x / 2, dims.y / 2)
	else:
		pos = Vector2i(_cursor_slot % dims.x, _cursor_slot / dims.x) + d
	pos.x = clampi(pos.x, 0, dims.x - 1)
	pos.y = clampi(pos.y, 0, dims.y - 1)
	_cursor_slot = pos.y * dims.x + pos.x
	_overlay.queue_redraw()


@warning_ignore("integer_division")
func _slot_coords(slot: int) -> Vector2i:
	var d := _session.get_slot_dims()
	return Vector2i(slot % d.x, slot / d.x)


func _open_picker() -> void:
	if _session == null or _cursor_slot == -1:
		return
	if _session.is_finished():
		_status.text = "Run finished — restart to edit slots."
		return
	if _playing:
		_on_play_pressed()   # don't race the picker
	var domain := _session.get_slot_domain(_cursor_slot)
	if domain.is_empty():
		_status.text = "No candidates at %s." % _slot_coords(_cursor_slot)
		return
	_picker.open(_slot_coords(_cursor_slot),
			_session.get_slot_assignment(_cursor_slot),
			domain, _session.get_source_index())


func _on_picker_picked(part_id: String) -> void:
	if _session == null or _cursor_slot == -1:
		return
	var slot := _cursor_slot
	var ok := _session.try_assign(slot, part_id)
	_update_session_ui()
	if ok:
		_status.text = "Placed %s at %s" % [part_id, _slot_coords(slot)]
	else:
		_status.text = "Rejected: %s at %s — %s" % [
				part_id, _slot_coords(slot), _session.last_rejection]


func _on_picker_cleared() -> void:
	if _session == null or _cursor_slot == -1:
		return
	var slot := _cursor_slot
	var ok := _session.try_clear(slot)
	_update_session_ui()
	_status.text = ("Cleared %s" if ok else "Nothing to clear at %s") \
			% _slot_coords(slot)


class SlotOverlay extends Control:
	## Draws the slot grid and cursor highlight over the live preview, in
	## texture-pixel space mapped through the preview's stretch transform.

	var _tab: SynthesizersTab


	func _draw() -> void:
		if _tab == null or _tab._session == null or _tab._pane.preview.texture == null:
			return
		var sess := _tab._session
		var size_px := sess.get_render_size()
		if size_px.x <= 0 or size_px.y <= 0 or _tab._pane.preview.size.x <= 0.0:
			return
		draw_set_transform_matrix(_tab._preview_xform())
		var dims := sess.get_slot_dims()
		var step := sess.get_slot_step()
		var grid_col := Color(1.0, 1.0, 1.0, 0.10)
		for c in dims.x + 1:
			var x := float(mini(c * step.x, size_px.x))
			draw_line(Vector2(x, 0.0), Vector2(x, size_px.y), grid_col)
		for r in dims.y + 1:
			var y := float(mini(r * step.y, size_px.y))
			draw_line(Vector2(0.0, y), Vector2(size_px.x, y), grid_col)
		if _tab._cursor_slot >= 0:
			var rect := Rect2(sess.slot_rect(_tab._cursor_slot))
			draw_rect(rect, Color(UiKit.HIGHLIGHT_AMBER_CURSOR, 0.18), true)
			draw_rect(rect, Color(UiKit.HIGHLIGHT_AMBER_CURSOR, 0.95), false, 1.0)


class SlotPicker extends PopupPanel:
	## Chooses among a slot's candidate tiles. The grid buttons take focus
	## on open; arrow keys walk between them (default focus neighbors),
	## Enter picks, Esc closes.

	signal picked(part_id: String)
	signal clear_requested


	func open(slot_pos: Vector2i, current: String, domain: Dictionary,
			index: ConstraintIndex) -> void:
		UiKit.clear_children(self)
		var box := VBoxContainer.new()
		box.add_theme_constant_override("separation", 6)
		add_child(box)

		var title := Label.new()
		title.text = ("Slot %s — current: %s" % [slot_pos, current]) \
				if current != "" else "Slot %s — empty" % slot_pos
		box.add_child(title)

		var scroll := ScrollContainer.new()
		scroll.custom_minimum_size = Vector2(4 * 76 + 16, 240)
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		box.add_child(scroll)
		var grid := UiKit.thumb_grid(4)
		scroll.add_child(grid)

		var first: Button = null
		for id: String in domain:
			var b := _tile_button(id, index)
			if first == null:
				first = b
			b.pressed.connect(func() -> void:
				picked.emit(id)
				hide())
			grid.add_child(b)
		if first == null:
			var none := Label.new()
			none.text = "No candidates."
			grid.add_child(none)

		var foot := HBoxContainer.new()
		box.add_child(foot)
		var clear_b := Button.new()
		clear_b.text = "Unset"
		clear_b.disabled = current == ""
		clear_b.pressed.connect(func() -> void:
			clear_requested.emit()
			hide())
		foot.add_child(clear_b)
		var spacer := Control.new()
		spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		foot.add_child(spacer)
		var cancel := Button.new()
		cancel.text = "Cancel"
		cancel.pressed.connect(hide)
		foot.add_child(cancel)

		var hint := Label.new()
		hint.text = "Arrows: move focus · Enter: choose · Esc: close"
		hint.modulate = Color(1.0, 1.0, 1.0, UiKit.HINT_ALPHA)
		box.add_child(hint)

		popup_centered()
		if first != null:
			first.grab_focus()
		else:
			cancel.grab_focus()


	func _tile_button(id: String, index: ConstraintIndex) -> Button:
		var b := Button.new()
		b.custom_minimum_size = UiKit.THUMB
		var fi := index.family_of_part_id(id)
		var fsize := 0 if fi < 0 \
				else (index.family_members[fi] as PackedInt32Array).size()
		if fsize > 1:
			b.tooltip_text = "%s\nfamily of %d · weight %.2f" % [
					id, fsize, index.family_weights[fi]]
		else:
			b.tooltip_text = "%s\nweight: %.2f" % [id, index.get_weight(id)]
		var img := ImageOps.to_rgba8(index.get_part(id).pixel_data)
		var tr := UiKit.preview(Vector2.ZERO)
		tr.texture = ImageTexture.create_from_image(img)
		tr.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		tr.mouse_filter = Control.MOUSE_FILTER_IGNORE   # clicks go to the button
		b.add_child(tr)
		return b
