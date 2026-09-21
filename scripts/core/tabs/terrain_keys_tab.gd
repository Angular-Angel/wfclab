class_name TerrainKeysTab extends Control
## Author the global terrain key: an ordered set of color-equivalence
## classes consumed by comparative constraint techniques (currently
## PixelOverlap), plus optional per-class tagging: a part whose
## non-transparent coverage of a class meets the class's minimum percentage
## gets that tag through the normal tag layer (explicitly, via
## "Apply Class Tags to Parts"). Disabling a class skips it in both
## extraction and tagging without deleting it.
## Edits are explicit ("Save Key") so AppData regenerates constraints once
## per save rather than per widget tweak.
const SWATCH := Vector2(34.0, 26.0)
const PALETTE_SWATCH := Vector2(30.0, 30.0)
const MAX_CLASS_COLORS := 8
var _editor_box: VBoxContainer
var _status: Label
var _classes_box: VBoxContainer
var _draft: Array = []   # working copy; pushed to AppData on Save
# --- palette popup (pick colors from tiles / source images) -------------------
var _palette_popup: PopupPanel
var _palette_source: OptionButton
var _palette_status: Label
var _palette_grid: GridContainer
var _all_palette_cache: Dictionary = {}
var _all_palette_valid := false
var _palette_target_ci := -1
func _ready() -> void:
	var scroll := ScrollContainer.new()
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	_editor_box = VBoxContainer.new()
	_editor_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_editor_box)
	# Popup lives on the tab root: _rebuild_editor() clears _editor_box's
	# children, and the popup must survive that.
	_palette_popup = _build_palette_popup()
	add_child(_palette_popup)
	AppData.terrain_key_changed.connect(_refresh)
	AppData.parts_changed.connect(func() -> void: _all_palette_valid = false)
	_refresh()
func _mk_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l
func _to_hex(c: Color) -> String:
	return "#%02x%02x%02x" % [
		int(round(c.r * 255.0)),
		int(round(c.g * 255.0)),
		int(round(c.b * 255.0))]
func _from_hex(s: String) -> Color:
	var t := s if s.begins_with("#") else "#" + s
	return Color(t) if Color.html_is_valid(t) else Color.WHITE
# --- Refresh -----------------------------------------------------------------
func _refresh() -> void:
	_draft = AppData.get_terrain_key().duplicate(true)
	_rebuild_editor()
	_update_status()
func _update_status() -> void:
	var active := 0
	for cls: Variant in _draft:
		if cls is Dictionary and bool((cls as Dictionary).get("enabled", true)):
			active += 1
	_status.text = "%d class(es), %d active" % [_draft.size(), active]
# --- Editor ----------------------------------------------------------------------
func _rebuild_editor() -> void:
	for child in _editor_box.get_children():
		child.queue_free()
	_editor_box.add_child(_mk_label("Terrain Key"))
	if _draft.is_empty():
		var empty := Label.new()
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		empty.text = ("No classes defined. Add a class, pick its colors, "
			+ "and Save Key to make terrain colors interchangeable in "
			+ "Pixel Overlap extraction.")
		_editor_box.add_child(empty)
	_classes_box = VBoxContainer.new()
	_editor_box.add_child(_classes_box)
	_rebuild_classes()
	var btn_row := HBoxContainer.new()
	_editor_box.add_child(btn_row)
	var add_class := Button.new()
	add_class.text = "+ class"
	add_class.pressed.connect(_on_add_class_pressed)
	btn_row.add_child(add_class)
	var save_btn := Button.new()
	save_btn.text = "Save Key"
	save_btn.pressed.connect(_on_save_pressed)
	btn_row.add_child(save_btn)
	var apply_btn := Button.new()
	apply_btn.text = "Apply Class Tags to Parts"
	apply_btn.pressed.connect(_on_apply_tags_pressed)
	btn_row.add_child(apply_btn)
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_editor_box.add_child(_status)
	var note := Label.new()
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.text = ("Saving regenerates constraints so stored relations reflect "
		+ "these classes. A pixel matching a class (any listed color within "
		+ "per-channel tolerance) compares as that class's first color; "
		+ "alpha is never changed; unclassed pixels keep their own colors. "
		+ "Keep each class's first color well away from other classes'. "
		+ "A class with a tag name tags parts at Apply time when at least "
		+ "Min % of their non-transparent pixels fall within the class.")
	_editor_box.add_child(note)
	_update_status()
func _rebuild_classes() -> void:
	for child in _classes_box.get_children():
		child.queue_free()
	for ci in _draft.size():
		_classes_box.add_child(_build_class_editor(ci, _draft[ci]))
func _build_class_editor(ci: int, cls: Dictionary) -> VBoxContainer:
	var box := VBoxContainer.new()
	var head := HBoxContainer.new()
	box.add_child(head)
	var enabled_check := CheckButton.new()
	enabled_check.button_pressed = bool(cls.get("enabled", true))
	enabled_check.tooltip_text = "Off: skipped by extraction and tagging."
	enabled_check.toggled.connect(_on_class_enabled_toggled.bind(ci))
	head.add_child(enabled_check)
	head.add_child(_mk_label("Name"))
	var name_input := LineEdit.new()
	name_input.text = String(cls.get("name", ""))
	name_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_input.text_changed.connect(_on_class_name_changed.bind(ci))
	head.add_child(name_input)
	head.add_child(_mk_label("Tolerance"))
	var tol := SpinBox.new()
	tol.min_value = 0
	tol.max_value = 255
	tol.value = int(cls.get("tolerance", 0))
	tol.value_changed.connect(_on_class_tolerance_changed.bind(ci))
	head.add_child(tol)
	var del_class := Button.new()
	del_class.text = "− class"
	del_class.pressed.connect(_on_remove_class_pressed.bind(ci))
	head.add_child(del_class)
	var colors_row := HBoxContainer.new()
	box.add_child(colors_row)
	colors_row.add_child(_mk_label("Colors"))
	var pick := Button.new()
	pick.text = "Pick from tiles…"
	pick.pressed.connect(_open_palette_popup.bind(ci))
	colors_row.add_child(pick)
	var colors: Array = cls.get("colors", [])
	for j in colors.size():
		var btn := ColorPickerButton.new()
		btn.custom_minimum_size = SWATCH
		btn.color = _from_hex(String(colors[j]))
		btn.color_changed.connect(_on_class_color_changed.bind(ci, j))
		colors_row.add_child(btn)
	var add_color := Button.new()
	add_color.text = "+ color"
	add_color.pressed.connect(_on_add_color_pressed.bind(ci))
	colors_row.add_child(add_color)
	var del_color := Button.new()
	del_color.text = "− color"
	del_color.pressed.connect(_on_remove_color_pressed.bind(ci))
	colors_row.add_child(del_color)
	var tag_row := HBoxContainer.new()
	box.add_child(tag_row)
	tag_row.add_child(_mk_label("Tag parts as"))
	var tag_input := LineEdit.new()
	tag_input.text = String(cls.get("tag", ""))
	tag_input.placeholder_text = "(no tagging)"
	tag_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tag_input.text_changed.connect(_on_class_tag_changed.bind(ci))
	tag_row.add_child(tag_input)
	tag_row.add_child(_mk_label("Min %"))
	var minf := SpinBox.new()
	minf.min_value = 0.0
	minf.max_value = 100.0
	minf.step = 0.5
	minf.value = float(cls.get("min_fraction", 0.1)) * 100.0
	minf.value_changed.connect(_on_class_min_fraction_changed.bind(ci))
	tag_row.add_child(minf)
	return box
# --- Draft mutators (no AppData traffic until Save) ----------------------------
func _on_class_enabled_toggled(on: bool, ci: int) -> void:
	if ci < _draft.size():
		(_draft[ci] as Dictionary)["enabled"] = on
func _on_class_name_changed(text: String, ci: int) -> void:
	if ci < _draft.size():
		(_draft[ci] as Dictionary)["name"] = text
func _on_class_tolerance_changed(value: float, ci: int) -> void:
	if ci < _draft.size():
		(_draft[ci] as Dictionary)["tolerance"] = int(value)
func _on_class_color_changed(color: Color, ci: int, j: int) -> void:
	if ci >= _draft.size():
		return
	var colors: Array = (_draft[ci] as Dictionary).get("colors", [])
	if j < colors.size():
		colors[j] = _to_hex(color)
func _on_class_tag_changed(text: String, ci: int) -> void:
	if ci < _draft.size():
		(_draft[ci] as Dictionary)["tag"] = text
func _on_class_min_fraction_changed(value: float, ci: int) -> void:
	if ci < _draft.size():
		(_draft[ci] as Dictionary)["min_fraction"] = value / 100.0
func _on_add_color_pressed(ci: int) -> void:
	if ci >= _draft.size():
		return
	var cls := _draft[ci] as Dictionary
	var colors: Array = cls.get("colors", [])
	if colors.size() >= MAX_CLASS_COLORS:
		return
	colors.append("#ffffff")
	cls["colors"] = colors
	_rebuild_classes()
func _on_remove_color_pressed(ci: int) -> void:
	if ci >= _draft.size():
		return
	var cls := _draft[ci] as Dictionary
	var colors: Array = cls.get("colors", [])
	if not colors.is_empty():
		colors.pop_back()
		cls["colors"] = colors
		_rebuild_classes()
func _on_add_class_pressed() -> void:
	_draft.append({"name": "class %d" % (_draft.size() + 1),
		"colors": ["#ffffff"], "tolerance": 0, "enabled": true,
		"tag": "", "min_fraction": 0.1})
	_rebuild_classes()
func _on_remove_class_pressed(ci: int) -> void:
	if ci < _draft.size():
		_draft.remove_at(ci)
		_rebuild_classes()
func _on_save_pressed() -> void:
	AppData.set_terrain_key(_draft)
func _on_apply_tags_pressed() -> void:
	var report: Dictionary = AppData.apply_terrain_key_tags()
	if (report["per_class"] as Dictionary).is_empty():
		_status.text = "No classes define a tag; nothing applied."
		return
	_status.text = "Tagged %d part(s)  %s" % [
		report["tagged_parts"], report["per_class"]]
# --- Palette popup ---------------------------------------------------------------
func _build_palette_popup() -> PopupPanel:
	var popup := PopupPanel.new()
	var box := VBoxContainer.new()
	popup.add_child(box)
	var head := HBoxContainer.new()
	box.add_child(head)
	head.add_child(_mk_label("Source"))
	_palette_source = OptionButton.new()
	# No selected-part context in this tab, so the tagging editor's
	# "Selected tile" source becomes "Source images" here.
	_palette_source.add_item("All tiles")
	_palette_source.add_item("Source images")
	_palette_source.item_selected.connect(
		func(_i: int) -> void: _populate_palette())
	head.add_child(_palette_source)
	_palette_status = Label.new()
	_palette_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_palette_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(_palette_status)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(320.0, 320.0)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(scroll)
	_palette_grid = GridContainer.new()
	_palette_grid.columns = 8
	_palette_grid.add_theme_constant_override("h_separation", 3)
	_palette_grid.add_theme_constant_override("v_separation", 3)
	scroll.add_child(_palette_grid)
	var hint := Label.new()
	hint.text = "Click swatches to add them to the class; close when done."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(hint)
	return popup
func _open_palette_popup(ci: int) -> void:
	_palette_target_ci = ci
	_populate_palette()
	_palette_popup.popup_centered(Vector2i(360, 440))
func _populate_palette() -> void:
	for child in _palette_grid.get_children():
		child.queue_free()
	var images: Array[Image] = []
	if _palette_source.selected == 0:
		for p: Part in AppData.get_part_list():
			if p.pixel_data != null:
				images.append(p.pixel_data)
	else:
		for asset: ImageAssetData in AppData.get_image_list():
			if asset.image != null:
				images.append(asset.image)
	if images.is_empty():
		_palette_status.text = "No tiles/images to sample."
		return
	var result: Dictionary
	if _palette_source.selected == 0:
		if not _all_palette_valid:
			_all_palette_cache = PaletteExtractor.palette_of_images(
				images, 4, 64)
			_all_palette_valid = true
		result = _all_palette_cache
	else:
		result = PaletteExtractor.palette_of_images(images, 4, 64)
	var entries: Array = result["entries"]
	var total := int(result["total"])
	if entries.is_empty():
		_palette_status.text = "No opaque pixels found."
		return
	if total <= entries.size():
		_palette_status.text = "%d color(s)" % total
	else:
		_palette_status.text = "%d distinct colors — showing top %d by " \
			+ "frequency" % [total, entries.size()]
	for e: Dictionary in entries:
		var swatch := Button.new()
		swatch.custom_minimum_size = PALETTE_SWATCH
		swatch.focus_mode = Control.FOCUS_NONE
		var sb := StyleBoxFlat.new()
		sb.bg_color = e["color"]
		swatch.add_theme_stylebox_override("normal", sb)
		swatch.add_theme_stylebox_override("hover", sb)
		swatch.add_theme_stylebox_override("pressed", sb)
		swatch.tooltip_text = "#%s  — %s px" % [e["hex"], e["count"]]
		swatch.pressed.connect(_on_palette_swatch_pressed.bind(String(e["hex"])))
		_palette_grid.add_child(swatch)
func _on_palette_swatch_pressed(hex: String) -> void:
	if _palette_target_ci < 0 or _palette_target_ci >= _draft.size():
		return
	var cls := _draft[_palette_target_ci] as Dictionary
	var colors: Array = cls.get("colors", [])
	if colors.size() >= MAX_CLASS_COLORS:
		_palette_status.text = "Class color limit (%d) reached — remove one first." \
			% MAX_CLASS_COLORS
		return
	if colors.has(hex):
		_palette_status.text = "Color already in this class."
		return
	colors.append(hex)
	cls["colors"] = colors
	_rebuild_classes()
