class_name DecompositionTab extends Control
## Configure a decomposition run (plus constraint extraction) and execute it.

var _technique_option: OptionButton
var _params_box: VBoxContainer
var _image_list: ItemList
var _run_button: Button
var _status: Label

var _param_values: Dictionary = {}     # decomposition params
var _current_technique: DecompositionTechnique

var _ct_enabled: Dictionary = {}       # constraint tech id -> bool
var _ct_values: Dictionary = {}        # constraint tech id -> params Dictionary


func _ready() -> void:
	var split := HSplitContainer.new()
	split.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(split)

	var left := VBoxContainer.new()
	left.custom_minimum_size = Vector2(320.0, 0.0)
	split.add_child(left)

	left.add_child(_mk_label("Technique"))
	_technique_option = OptionButton.new()
	for technique: DecompositionTechnique in TechniqueRegistry.get_decomposition_techniques():
		_technique_option.add_item(technique.get_display_name())
		_technique_option.set_item_metadata(_technique_option.item_count - 1, technique.get_id())
	_technique_option.item_selected.connect(_on_technique_selected)
	left.add_child(_technique_option)

	left.add_child(_mk_label("Parameters"))
	_params_box = VBoxContainer.new()
	left.add_child(_params_box)

	left.add_child(_mk_label("Constraint Extraction"))
	for ct: ConstraintTechnique in TechniqueRegistry.get_constraint_techniques():
		var check := CheckButton.new()
		check.text = ct.get_display_name()
		check.button_pressed = true
		check.toggled.connect(_on_ct_toggled.bind(ct.get_id()))
		left.add_child(check)
		var box := VBoxContainer.new()
		box.add_theme_constant_override("margin_left", 16)
		left.add_child(box)
		_ct_enabled[ct.get_id()] = true
		_ct_values[ct.get_id()] = {}
		_build_param_widgets(ct.get_parameter_specs(), _ct_values[ct.get_id()], box)

	left.add_child(_mk_label("Images (click to toggle inclusion)"))
	_image_list = ItemList.new()
	_image_list.select_mode = ItemList.SELECT_MULTI
	_image_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_image_list.custom_minimum_size = Vector2(0.0, 120.0)
	left.add_child(_image_list)
	AppData.images_changed.connect(_rebuild_image_list)
	_rebuild_image_list()

	_run_button = Button.new()
	_run_button.text = "Run Decomposition"
	_run_button.pressed.connect(_on_run_pressed)
	left.add_child(_run_button)

	_status = Label.new()
	_status.text = ""
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	left.add_child(_status)

	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.add_child(right)
	right.add_child(_mk_label("Last Run"))

	if _technique_option.item_count > 0:
		_technique_option.select(0)
		_on_technique_selected(0)


func _mk_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l


# --- Parameter widgets (generic, spec-driven) ------------------------------

func _build_param_widgets(specs: Array[Dictionary], values: Dictionary, box: Container) -> void:
	for spec: Dictionary in specs:
		values[spec["key"]] = spec["default"]
		var row := HBoxContainer.new()
		var label := _mk_label(spec["label"])
		label.custom_minimum_size = Vector2(110.0, 0.0)
		row.add_child(label)

		match spec["type"]:
			"int":
				var spin := SpinBox.new()
				spin.min_value = spec.get("min", 0)
				spin.max_value = spec.get("max", 9999)
				spin.value = spec["default"]
				spin.value_changed.connect(_set_int.bind(values, spec["key"]))
				row.add_child(spin)
			"vector2i":
				var spin_x := SpinBox.new()
				var spin_y := SpinBox.new()
				for spin: SpinBox in [spin_x, spin_y]:
					spin.min_value = spec.get("min", 0)
					spin.max_value = spec.get("max", 9999)
					spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				spin_x.value = spec["default"].x
				spin_y.value = spec["default"].y
				spin_x.value_changed.connect(_set_vec_x.bind(values, spec["key"]))
				spin_y.value_changed.connect(_set_vec_y.bind(values, spec["key"]))
				row.add_child(spin_x)
				row.add_child(spin_y)
			"bool":
				var check := CheckButton.new()
				check.button_pressed = spec["default"]
				check.toggled.connect(_set_bool.bind(values, spec["key"]))
				row.add_child(check)
			"enum":
				var option := OptionButton.new()
				for option_name: String in spec["options"]:
					option.add_item(option_name)
				option.selected = spec["default"]
				option.item_selected.connect(_set_enum.bind(values, spec["key"]))
				row.add_child(option)

		box.add_child(row)


func _set_int(value: float, values: Dictionary, key: String) -> void:
	values[key] = int(value)


func _set_vec_x(value: float, values: Dictionary, key: String) -> void:
	var cur: Vector2i = values.get(key, Vector2i())
	values[key] = Vector2i(int(value), cur.y)


func _set_vec_y(value: float, values: Dictionary, key: String) -> void:
	var cur: Vector2i = values.get(key, Vector2i())
	values[key] = Vector2i(cur.x, int(value))


func _set_bool(pressed: bool, values: Dictionary, key: String) -> void:
	values[key] = pressed


func _set_enum(index: int, values: Dictionary, key: String) -> void:
	values[key] = index


func _on_ct_toggled(pressed: bool, tech_id: StringName) -> void:
	_ct_enabled[tech_id] = pressed


# --- Technique / image list handling ----------------------------------------

func _on_technique_selected(index: int) -> void:
	var id: StringName = _technique_option.get_item_metadata(index)
	_current_technique = TechniqueRegistry.get_decomposition(id)
	for child in _params_box.get_children():
		child.queue_free()
	_param_values = {}
	_build_param_widgets(_current_technique.get_parameter_specs(), _param_values, _params_box)


func _rebuild_image_list() -> void:
	_image_list.clear()
	for asset: ImageAssetData in AppData.get_image_list():
		var index := _image_list.add_item(asset.name)
		_image_list.set_item_metadata(index, asset.id)
		_image_list.select(index)   # default: everything participates


func _selected_images() -> Array[ImageAssetData]:
	var selected: Array[ImageAssetData] = []
	for index in _image_list.get_selected_items():
		selected.append(AppData.images[_image_list.get_item_metadata(index)])
	return selected


# --- Run ---------------------------------------------------------------------

func _on_run_pressed() -> void:
	var images := _selected_images()
	if images.is_empty():
		_status.text = "No images selected."
		return

	# Snapshots: the worker must not read widgets the user can still touch.
	var technique := _current_technique
	var params := _param_values.duplicate(true)
	var ct_jobs: Array = []   # [{technique, params}]
	for ct: ConstraintTechnique in TechniqueRegistry.get_constraint_techniques():
		if _ct_enabled.get(ct.get_id(), false):
			ct_jobs.append({
				"technique": ct,
				"params": (_ct_values[ct.get_id()] as Dictionary).duplicate(true),
			})

	_run_button.disabled = true
	_status.text = "Running..."

	WorkerThreadPool.add_task(func() -> void:
		var no_progress := func(_fraction: float) -> void: pass
		var result: Dictionary = technique.decompose(images, params, no_progress)
		var parts: Array[Part] = result["parts"]

		var all_constraints: Array[Constraint] = []
		for job: Dictionary in ct_jobs:
			var cs: Array[Constraint] = (job["technique"] as ConstraintTechnique).extract(
				parts, images, job["params"], no_progress)
			all_constraints.append_array(cs)

		_publish_result.call_deferred(result, all_constraints)
	)


func _publish_result(result: Dictionary, all_constraints: Array[Constraint]) -> void:
	_run_button.disabled = false
	if result.is_empty():
		_status.text = "Run failed (see console)."
		return

	var stats: Dictionary = result["stats"]
	AppData.set_parts(result["parts"], stats)
	AppData.set_constraints(all_constraints)
	_status.text = "Done: %d tiles → %d parts, %d constraints (%d ms)" % [
		stats["total_tiles"], stats["part_count"],
		all_constraints.size(), stats["elapsed_ms"]]

	var tabs := get_parent() as TabContainer
	if tabs != null:
		var target := tabs.get_node_or_null("Constraints")
		if target != null:
			tabs.current_tab = tabs.get_tab_idx_from_control(target)
