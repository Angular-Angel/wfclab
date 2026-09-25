class_name TagRuleEditor extends VBoxContainer
## The Auto-Tag Rules section of the Parts tab: the rules list with
## enable/edit/strip/delete rows, the apply button, and the rule editor
## (tag, target colors via PalettePicker, tolerance, min coverage).
## Status lines are reported through status_message; the owning tab owns
## the visible status label. Tag CRUD itself lives in AppData.

signal status_message(text: String)

const MAX_RULE_COLORS := 8

var _rules_box: VBoxContainer
var _editor_box: VBoxContainer
var _tag_input: LineEdit
var _colors_box: HBoxContainer
var _color_buttons: Array[ColorPickerButton] = []
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
	for child in _rules_box.get_children():
		child.free()
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
		var label := Label.new()
		label.text = _rule_summary(r)
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
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
	tag_row.add_child(_mk_label("Tag"))
	_tag_input = LineEdit.new()
	_tag_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tag_row.add_child(_tag_input)
	var colors_head := HBoxContainer.new()
	box.add_child(colors_head)
	colors_head.add_child(_mk_label("Target colors"))
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	colors_head.add_child(spacer)
	var pick := Button.new()
	pick.text = "Pick from tiles…"
	pick.pressed.connect(_open_palette)
	colors_head.add_child(pick)
	_colors_box = HBoxContainer.new()
	box.add_child(_colors_box)
	var color_btns := HBoxContainer.new()
	box.add_child(color_btns)
	var add_color := Button.new()
	add_color.text = "+ color"
	add_color.pressed.connect(_on_add_color_pressed)
	color_btns.add_child(add_color)
	var del_color := Button.new()
	del_color.text = "− color"
	del_color.pressed.connect(_on_remove_color_pressed)
	color_btns.add_child(del_color)
	var tol_row := HBoxContainer.new()
	box.add_child(tol_row)
	tol_row.add_child(_mk_label("Per-channel tolerance"))
	_tolerance = SpinBox.new()
	_tolerance.min_value = 0
	_tolerance.max_value = 255
	_tolerance.value = 16
	_tolerance.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tol_row.add_child(_tolerance)
	var frac_row := HBoxContainer.new()
	box.add_child(frac_row)
	frac_row.add_child(_mk_label("Min coverage %"))
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
	var note := Label.new()
	note.text = ("A part gets the tag when at least the coverage fraction of its " \
		+ "non-transparent pixels sit within tolerance (per channel) of ANY " \
		+ "target color. Transparent pixels are ignored entirely. " \
		+ "Use Apply all rules to (re-)tag; Strip removes the tag everywhere.")
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(note)
	return box


func _mk_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l


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
	_reset_color_buttons(1)
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
		_reset_color_buttons(clampi(colors.size(), 1, MAX_RULE_COLORS))
		for i in mini(colors.size(), _color_buttons.size()):
			var s := String(colors[i])
			if not s.begins_with("#"):
				s = "#" + s
			if Color.html_is_valid(s):
				_color_buttons[i].color = Color(s)
		_tolerance.set_value_no_signal(float(r.get("tolerance", 16)))
		_min_fraction.set_value_no_signal(float(r.get("min_fraction", 0.1)) * 100.0)
		_editor_box.visible = true
		return


func _on_rule_save() -> void:
	var tag := _tag_input.text.strip_edges()
	if tag.is_empty():
		status_message.emit("Enter a tag name.")
		return
	var colors: Array = []
	for b: ColorPickerButton in _color_buttons:
		colors.append(b.color.to_html(false))
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


func _reset_color_buttons(n: int) -> void:
	while _color_buttons.size() > n:
		var b: ColorPickerButton = _color_buttons.pop_back()
		_colors_box.remove_child(b)
		b.queue_free()
	while _color_buttons.size() < n:
		_on_add_color_pressed()


func _on_add_color_pressed() -> void:
	if _color_buttons.size() >= MAX_RULE_COLORS:
		return
	_mk_color_button(Color.WHITE)


func _on_remove_color_pressed() -> void:
	if _color_buttons.is_empty():
		return
	var b: ColorPickerButton = _color_buttons.pop_back()
	_colors_box.remove_child(b)
	b.queue_free()


func _mk_color_button(c: Color) -> ColorPickerButton:
	var b := ColorPickerButton.new()
	b.custom_minimum_size = Vector2(36.0, 28.0)
	b.color = c
	_color_buttons.append(b)
	_colors_box.add_child(b)
	return b


func _open_palette() -> void:
	_palette.open(0 if _has_selection.call() else 1)


func _on_palette_color_picked(hex: String) -> void:
	if _color_buttons.size() >= MAX_RULE_COLORS:
		_palette.set_status(
				"Rule color limit (8) reached — remove one first.")
		return
	_mk_color_button(Color(hex))
