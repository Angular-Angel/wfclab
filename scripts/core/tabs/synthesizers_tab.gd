class_name SynthesizersTab extends Control
## Configure and run a synthesizer over the current materialized state.

var _technique_option: OptionButton
var _params_box: VBoxContainer
var _seed_spin: SpinBox
var _run_button: Button
var _status: Label

var _param_values: Dictionary = {}
var _current: Synthesizer = null


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

	_run_button = Button.new()
	_run_button.text = "Synthesize"
	_run_button.pressed.connect(_on_run_pressed)
	left.add_child(_run_button)

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	left.add_child(_status)

	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.add_child(right)
	right.add_child(_mk_label("Notes"))
	var notes := Label.new()
	notes.text = ("Synthesis consumes the materialized parts and constraints, "
		+ "including all manual edits — disable a part or reweight a "
		+ "constraint, re-synthesize, and see the difference.\n\n"
		+ "Output appears in the Outputs tab, which can re-run the same "
		+ "seed for exact reproduction.")
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
	var id: StringName = _technique_option.get_item_metadata(index)
	_current = TechniqueRegistry.get_synthesizer(id)
	for child in _params_box.get_children():
		child.free()
	_param_values = {}
	if _current != null:
		ParamBuilder.build(_current.get_parameter_specs(), _param_values, _params_box)


func _on_run_pressed() -> void:
	if _current == null:
		return
	var index := AppData.get_constraint_index()
	if index.get_part_ids().is_empty():
		_status.text = "No parts. Run a decomposition first."
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
