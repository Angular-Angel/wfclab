class_name TagRuleEditor extends VBoxContainer
## The Auto-Tag Rules section of the Parts tab: the rules list with
## enable/edit/strip/delete rows, the apply button, and the rule editor
## (tag, target colors via PalettePicker, tolerance, min coverage).
## Status lines are reported through status_message; the owning tab owns
## the visible status label. Tag CRUD itself lives in AppData.

signal status_message(text: String)

var _rules_box: VBoxContainer
var _editor_box: VBoxContainer
var _tag_input: LineEdit
var _colors: ColorListEditor
var _tolerance: SpinBox
var _min_fraction: SpinBox
var _editing_rule_id := ""
var _palette: PalettePicker
var _selected_images: Callable
var _has_selection: Callable


## selected_images: Callable -> Array[Image] (the tab's selected tile);
## has_selection: Callable -> bool (drives the picker's initial source).
func setup(selected_images: Callable, has_selection: Callable) -> void:
	_selected_images = selected_images
	_has_selection = has_selection


func _init() -> void:
	AppData.tagging_rules_changed.connect(refresh_rules, CONNECT_DEFERRED)


func _ready() -> void:
	_rules_box = VBoxContainer.new()
	add_child(_rules_box)
	var apply_row := HBoxContainer.new()
	add_child(apply_row)
	var apply_btn := Button.new()
	apply_btn.text = "Apply all rules"
	apply_btn.pressed.connect(_on_apply_tagging_rules)
	apply_row.add_child(apply_btn)
	var add_btn := Button.new()
	add_btn.text = "Add rule…"
	add_btn.pressed.connect(_on_add_tag_rule_pressed)
	apply_row.add_child(add_btn)
	_editor_box = _build_editor()
	_editor_box.visible = false
	add_child(_editor_box)
	_palette = PalettePicker.new()
	_palette.setup([
		{"label": "Selected tile", "empty": "No tile selected.",
				"images": _selected_images},
		{"label": "All tiles", "empty": "No tiles to sample.",
				"images": PalettePicker.all_tile_images},
	], 1, "Click swatches to add them to the rule; close when done.")
	_palette.color_picked.connect(_on_palette_color_picked)
	add_child(_palette)
	refresh_rules()


func refresh_rules() -> void:
	UiKit.clear_children(_rules_box)
	var all_rules := AppData.get_tagging_rules()
	if all_rules.is_empty():
		status_message.emit("No auto-tag rules.")
	else:
		status_message.emit("%d auto-tag rule(s)." % all_rules.size())
	for r: Dictionary in all_rules:
		var id := String(r.get("id", ""))
		var row := HBoxContainer.new()
		_rules_box.add_child(row)
		var check := CheckButton.new()
		check.set_pressed_no_signal(bool(r.get("enabled", true)))
		check.toggled.connect(_on_rule_enabled.bind(id))
		row.add_child(check)
		var label := UiKit.status_label(_rule_summary(r))
		row.add_child(label)
		var edit := Button.new()
		edit.text = "Edit"
		edit.pressed.connect(_on_edit_rule_pressed.bind(id))
		row.add_child(edit)
		var strip := Button.new()
		strip.text = "Strip"
		strip.tooltip_text = "Remove this tag from every part."
		strip.pressed.connect(_on_strip_tag.bind(String(r.get("tag", ""))))
		row.add_child(strip)
		var del := Button.new()
		del.text = "×"
		del.pressed.connect(_on_rule_delete.bind(id))
		row.add_child(del)


func _build_editor() -> VBoxContainer:
	var box := VBoxContainer.new()
	var tag_row := HBoxContainer.new()
	box.add_child(tag_row)
	tag_row.add_child(UiKit.label("Tag"))
	_tag_input = LineEdit.new()
	_tag_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tag_row.add_child(_tag_input)
	var colors_head := HBoxContainer.new()
	box.add_child(colors_head)
	colors_head.add_child(UiKit.label("Target colors"))
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	colors_head.add_child(spacer)
	var pick := Button.new()
	pick.text = "Pick from tiles…"
	pick.pressed.connect(_open_palette)
	colors_head.add_child(pick)
	_colors = ColorListEditor.new()
	box.add_child(_colors)
	var tol_row := HBoxContainer.new()
	box.add_child(tol_row)
	tol_row.add_child(UiKit.label("Per-channel tolerance"))
	_tolerance = SpinBox.new()
	_tolerance.min_value = 0
	_tolerance.max_value = 255
	_tolerance.value = 16
	_tolerance.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tol_row.add_child(_tolerance)
	var frac_row := HBoxContainer.new()
	box.add_child(frac_row)
	frac_row.add_child(UiKit.label("Min coverage %"))
	_min_fraction = SpinBox.new()
	_min_fraction.min_value = 0.0
	_min_fraction.max_value = 100.0
	_min_fraction.step = 0.5
	_min_fraction.value = 10.0
	_min_fraction.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	frac_row.add_child(_min_fraction)
	var btn_row := HBoxContainer.new()
	box.add_child(btn_row)
	var save := Button.new()
	save.text = "Save rule"
	save.pressed.connect(_on_rule_save)
	btn_row.add_child(save)
	var cancel := Button.new()
	cancel.text = "Cancel"
	cancel.pressed.connect(_on_rule_cancel)
	btn_row.add_child(cancel)
	box.add_child(UiKit.note(
		"A part gets the tag when at least the coverage fraction of its " \
		+ "non-transparent pixels sit within tolerance (per channel) of ANY " \
		+ "target color. Transparent pixels are ignored entirely. " \
		+ "Use Apply all rules to (re-)tag; Strip removes the tag everywhere."))
	return box


func _rule_summary(r: Dictionary) -> String:
	var colors: Array = r.get("colors", [])
	var swatches: Array[String] = []
	for c: Variant in colors:
		swatches.append(String(c))
	return "\"%s\" ← [%s], tol %d, ≥ %.1f%%" % [
		String(r.get("tag", "")), ", ".join(swatches),
		int(r.get("tolerance", 16)), float(r.get("min_fraction", 0.1)) * 100.0]


func _on_rule_enabled(pressed: bool, id: String) -> void:
	AppData.update_tagging_rule(id, {"enabled": pressed})


func _on_rule_delete(id: String) -> void:
	if _editing_rule_id == id:
		_on_rule_cancel()
	AppData.remove_tagging_rule(id)


func _on_strip_tag(tag: String) -> void:
	AppData.strip_tag_everywhere(tag)


func _on_apply_tagging_rules() -> void:
	var report := AppData.apply_tagging_rules()
	status_message.emit(
			"Applied: %d part(s) newly tagged." % int(report.get("tagged_parts", 0)))


func _on_add_tag_rule_pressed() -> void:
	_editing_rule_id = ""
	_tag_input.text = ""
	_colors.set_colors(["ffffff"])
	_tolerance.set_value_no_signal(16)
	_min_fraction.set_value_no_signal(10.0)
	_editor_box.visible = true


func _on_edit_rule_pressed(id: String) -> void:
	for r: Dictionary in AppData.get_tagging_rules():
		if String(r.get("id", "")) != id:
			continue
		_editing_rule_id = id
		_tag_input.text = String(r.get("tag", ""))
		var colors: Array = r.get("colors", [])
		if colors.is_empty():
			colors = ["ffffff"]
		_colors.set_colors(colors.slice(0, ColorListEditor.MAX_COLORS))
		_tolerance.set_value_no_signal(float(r.get("tolerance", 16)))
		_min_fraction.set_value_no_signal(float(r.get("min_fraction", 0.1)) * 100.0)
		_editor_box.visible = true
		return


func _on_rule_save() -> void:
	var tag := _tag_input.text.strip_edges()
	if tag.is_empty():
		status_message.emit("Enter a tag name.")
		return
	var colors: Array = _colors.colors()
	if colors.is_empty():
		status_message.emit("Add at least one target color.")
		return
	var fields := {
		"tag": tag,
		"colors": colors,
		"tolerance": int(_tolerance.value),
		"min_fraction": _min_fraction.value / 100.0,
	}
	if _editing_rule_id.is_empty():
		AppData.add_tagging_rule(fields)
	else:
		AppData.update_tagging_rule(_editing_rule_id, fields)
	_editor_box.visible = false


func _on_rule_cancel() -> void:
	_editor_box.visible = false
	_editing_rule_id = ""


func _open_palette() -> void:
	_palette.open(0 if _has_selection.call() else 1)


func _on_palette_color_picked(hex: String) -> void:
	if not _colors.add_color(Color(hex)):
		_palette.set_status(ColorListEditor.LIMIT_TEXT)
