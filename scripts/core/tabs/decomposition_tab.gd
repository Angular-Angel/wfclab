class_name DecompositionTab extends Control
## Configure a decomposition run and execute it. Parameter widgets are built
## generically from the technique's parameter specs.

var _technique_option: OptionButton
var _params_box: VBoxContainer
var _image_list: ItemList
var _run_button: Button
var _status: Label

var _param_values: Dictionary = {}    # key -> current value
var _param_widgets: Dictionary = {}   # key -> {type, widgets: Array}
var _current_technique: DecompositionTechnique


func _ready() -> void:
	var split := HSplitContainer.new()
	split.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(split)

	# --- Left: controls -----------------------------------------------------
	var left := VBoxContainer.new()
	left.custom_minimum_size = Vector2(320.0, 0.0)
	split.add_child(left)

	left.add_child(_label("Technique"))
	_technique_option = OptionButton.new()
	for technique: DecompositionTechnique in TechniqueRegistry.get_decomposition_techniques():
		_technique_option.add_item(technique.get_display_name())
		_technique_option.set_item_metadata(_technique_option.item_count - 1, technique.get_id())
	_technique_option.item_selected.connect(_on_technique_selected)
	left.add_child(_technique_option)

	left.add_child(_label("Parameters"))
	_params_box = VBoxContainer.new()
	left.add_child(_params_box)

	left.add_child(_label("Images (check to include)"))
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

	# --- Right: last run stats ----------------------------------------------
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.add_child(right)
	right.add_child(_label("Last Run"))

	if _technique_option.item_count > 0:
		_technique_option.select(0)
		_on_technique_selected(0)


func _label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l


func _on_technique_selected(index: int) -> void:
	var id: StringName = _technique_option.get_item_metadata(index)
	_current_technique = TechniqueRegistry.get_decomposition(id)
	_rebuild_param_ui()


func _rebuild_param_ui() -> void:
	for child in _params_box.get_children():
		child.queue_free()
	_param_values = {}
	_param_widgets = {}

	for spec: Dictionary in _current_technique.get_parameter_specs():
		_param_values[spec["key"]] = spec["default"]
		var row := HBoxContainer.new()
		var label := _label(spec["label"])
		label.custom_minimum_size = Vector2(110.0, 0.0)
		row.add_child(label)

		match spec["type"]:
			"int":
				var spin := SpinBox.new()
				spin.min_value = spec.get("min", 0)
				spin.max_value = spec.get("max", 9999)
				spin.value = spec["default"]
				spin.value_changed.connect(_on_param_int.bind(spec["key"]))
				row.add_child(spin)
				_param_widgets[spec["key"]] = {"type": "int", "widgets": [spin]}
			"vector2i":
				var spin_x := SpinBox.new()
				var spin_y := SpinBox.new()
				for spin: SpinBox in [spin_x, spin_y]:
					spin.min_value = spec.get("min", 0)
					spin.max_value = spec.get("max", 9999)
					spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				spin_x.value = spec["default"].x
				spin_y.value = spec["default"].y
				spin_x.value_changed.connect(
					_on_param_vec_x.bind(spec["key"]))
				spin_y.value_changed.connect(
					_on_param_vec_y.bind(spec["key"], spin_y))
				row.add_child(spin_x)
				row.add_child(spin_y)
				_param_widgets[spec["key"]] = {"type": "vector2i", "widgets": [spin_x, spin_y]}
			"bool":
				var check := CheckButton.new()
				check.button_pressed = spec["default"]
				check.toggled.connect(_on_param_bool.bind(spec["key"]))
				row.add_child(check)
				_param_widgets[spec["key"]] = {"type": "bool", "widgets": [check]}
			"enum":
				var option := OptionButton.new()
				for option_name: String in spec["options"]:
					option.add_item(option_name)
				option.selected = spec["default"]
				option.item_selected.connect(_on_param_enum.bind(spec["key"]))
				row.add_child(option)
				_param_widgets[spec["key"]] = {"type": "enum", "widgets": [option]}

		_params_box.add_child(row)


func _on_param_int(value: float, key: String) -> void:
	_param_values[key] = int(value)


func _on_param_vec_x(value: float, key: String) -> void:
	_param_values[key] = Vector2i(int(value), _param_values[key].y)


func _on_param_vec_y(value: float, key: String, _other: SpinBox) -> void:
	_param_values[key] = Vector2i(_param_values[key].x, int(value))


func _on_param_bool(pressed: bool, key: String) -> void:
	_param_values[key] = pressed


func _on_param_enum(index: int, key: String) -> void:
	_param_values[key] = index

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


func _on_run_pressed() -> void:
	var images := _selected_images()
	if images.is_empty():
		_status.text = "No images selected."
		return
	var technique := _current_technique
	var params := _param_values.duplicate(true)

	_run_button.disabled = true
	_status.text = "Running..."

	WorkerThreadPool.add_task(func() -> void:
		var no_progress := func(_fraction: float) -> void: pass
		var result: Dictionary = technique.decompose(images, params, no_progress)
		_publish_result.call_deferred(result)
	)


func _publish_result(result: Dictionary) -> void:
	_run_button.disabled = false
	if result.is_empty():
		_status.text = "Run failed (see console)."
		return

	var stats: Dictionary = result["stats"]
	AppData.set_parts(result["parts"], stats)
	_status.text = "Done: %d tiles → %d parts (%d ms)" % [
		stats["total_tiles"], stats["part_count"], stats["elapsed_ms"]]

	# Jump to the results.
	var tabs := get_parent() as TabContainer
	if tabs != null:
		var parts_tab := tabs.get_node_or_null("Parts")
		if parts_tab != null:
			tabs.current_tab = tabs.get_tab_idx_from_control(parts_tab)
