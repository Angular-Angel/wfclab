class_name PartsTab extends Control
## Browse the parts from the last run; inspect, edit, compare, and merge them.

signal occurrence_selected(image_id: String, position: Vector2i, size: Vector2i)

const THUMB := Vector2(72.0, 72.0)
const PREVIEW := Vector2(160.0, 160.0)
const MAX_SHOWN := 500

var _grid: GridContainer
var _grid_status: Label
var _preview: TextureRect
var _info: Label
var _occurrences: ItemList

var _enabled_check: CheckButton
var _transforms_box: VBoxContainer
var _transform_note: Label
var _transform_checks: Dictionary = {}
var _override_check: CheckButton
var _weight_spin: SpinBox
var _pin_button: Button
var _compare_box: VBoxContainer
var _cmp_pinned: TextureRect
var _cmp_selected: TextureRect
var _cmp_diff: TextureRect
var _cmp_label: Label
var _merge_button: Button

var _selected: Part = null
var _pinned: Part = null
var _occurrence_data: Array[Dictionary] = []
var _diff_count := 0

var _tags_box: VBoxContainer
var _tag_input: LineEdit
var _tag_filter: OptionButton

var _neighbors_box: VBoxContainer
const MAX_NEIGHBOR_OFFSETS := 12
const MAX_NEIGHBORS_PER_OFFSET := 24

var _auto_tag_box: VBoxContainer
var _auto_tag_status: Label
var _auto_editor: VBoxContainer
var _at_tag_input: LineEdit
var _at_colors_box: HBoxContainer
var _at_color_buttons: Array[ColorPickerButton] = []
var _at_tolerance: SpinBox
var _at_min_fraction: SpinBox
var _editing_tag_rule_id := ""
var _palette_popup: PopupPanel
var _palette_source: OptionButton
var _palette_status: Label
var _palette_grid: GridContainer
var _all_palette_cache: Dictionary = {}
var _all_palette_valid := false


func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

	var split := HSplitContainer.new()
	split.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(split)

	# --- Left: parts grid ---------------------------------------------------
	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.add_child(left)

	_grid_status = Label.new()
	var filter_row := HBoxContainer.new()
	left.add_child(filter_row)
	filter_row.add_child(_mk_label("Tag filter:"))
	_tag_filter = OptionButton.new()
	_tag_filter.item_selected.connect(func(_i: int) -> void: _rebuild())
	filter_row.add_child(_tag_filter)
	filter_row.add_child(_grid_status)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	left.add_child(scroll)

	_grid = GridContainer.new()
	_grid.columns = 8
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid.add_theme_constant_override("h_separation", 4)
	_grid.add_theme_constant_override("v_separation", 4)
	scroll.add_child(_grid)

	# --- Right: inspector (scrollable) -------------------------------------
	var right_scroll := ScrollContainer.new()
	right_scroll.custom_minimum_size = Vector2(320.0, 0.0)
	right_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	right_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	split.add_child(right_scroll)

	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_scroll.add_child(right)

	right.add_child(_mk_label("Selected Part"))
	_preview = TextureRect.new()
	_preview.custom_minimum_size = PREVIEW
	_preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	right.add_child(_preview)

	_info = Label.new()
	_info.text = "Nothing selected"
	right.add_child(_info)

	_enabled_check = CheckButton.new()
	_enabled_check.text = "Enabled"
	_enabled_check.toggled.connect(_on_enabled_toggled)
	right.add_child(_enabled_check)
	
	right.add_child(_mk_label("Tags"))
	_tag_input = LineEdit.new()
	_tag_input.placeholder_text = "New tag + Enter"
	_tag_input.text_submitted.connect(_on_tag_submitted)
	right.add_child(_tag_input)
	_tags_box = VBoxContainer.new()
	right.add_child(_tags_box)
	
	right.add_child(_mk_label("Auto-Tag Rules"))
	_auto_tag_status = Label.new()
	_auto_tag_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	right.add_child(_auto_tag_status)
	_auto_tag_box = VBoxContainer.new()
	right.add_child(_auto_tag_box)
	var apply_row := HBoxContainer.new()
	right.add_child(apply_row)
	var apply_btn := Button.new()
	apply_btn.text = "Apply all rules"
	apply_btn.pressed.connect(_on_apply_tagging_rules)
	apply_row.add_child(apply_btn)
	var add_btn := Button.new()
	add_btn.text = "Add rule…"
	add_btn.pressed.connect(_on_add_tag_rule_pressed)
	apply_row.add_child(add_btn)
	_auto_editor = _build_tag_rule_editor()
	_auto_editor.visible = false
	right.add_child(_auto_editor)
	_palette_popup = _build_palette_popup()
	right.add_child(_palette_popup)
	AppData.parts_changed.connect(func() -> void: _all_palette_valid = false)
	AppData.tagging_rules_changed.connect(_refresh_tag_rules, CONNECT_DEFERRED)
	_refresh_tag_rules()

	right.add_child(_mk_label("Transforms for source part"))
	_transforms_box = VBoxContainer.new()
	right.add_child(_transforms_box)
	for transform_key: String in ["rot90", "rot180", "rot270", "flip_h", "flip_v"]:
		var check := CheckButton.new()
		check.text = _transform_label(transform_key)
		check.toggled.connect(_on_transform_toggled.bind(transform_key))
		_transforms_box.add_child(check)
		_transform_checks[transform_key] = check
	_transform_note = Label.new()
	_transform_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_transforms_box.add_child(_transform_note)

	var weight_row := HBoxContainer.new()
	right.add_child(weight_row)
	_override_check = CheckButton.new()
	_override_check.text = "Weight override"
	_override_check.toggled.connect(_on_override_toggled)
	weight_row.add_child(_override_check)
	_weight_spin = SpinBox.new()
	_weight_spin.min_value = 0.0
	_weight_spin.max_value = 99999.0
	_weight_spin.value_changed.connect(_on_weight_changed)
	weight_row.add_child(_weight_spin)

	_pin_button = Button.new()
	_pin_button.text = "Pin for comparison"
	_pin_button.pressed.connect(_on_pin_pressed)
	right.add_child(_pin_button)

	_compare_box = VBoxContainer.new()
	right.add_child(_compare_box)
	_compare_box.add_child(_mk_label("Comparison: pinned vs selected"))
	var cmp_row := HBoxContainer.new()
	_compare_box.add_child(cmp_row)
	_cmp_pinned = _mk_cmp_preview()
	_cmp_selected = _mk_cmp_preview()
	_cmp_diff = _mk_cmp_preview()
	cmp_row.add_child(_cmp_pinned)
	cmp_row.add_child(_cmp_selected)
	cmp_row.add_child(_cmp_diff)
	_cmp_label = Label.new()
	_compare_box.add_child(_cmp_label)
	_merge_button = Button.new()
	_merge_button.text = "Merge selected INTO pinned"
	_merge_button.pressed.connect(_on_merge_pressed)
	_compare_box.add_child(_merge_button)
	_compare_box.visible = false
	
	right.add_child(_mk_label("Neighbors"))
	_neighbors_box = VBoxContainer.new()
	right.add_child(_neighbors_box)

	right.add_child(_mk_label("Occurrences"))
	_occurrences = ItemList.new()
	_occurrences.custom_minimum_size = Vector2(0.0, 160.0)
	_occurrences.item_selected.connect(_on_occurrence_selected)
	right.add_child(_occurrences)

	# Edits refresh is debounced: dragging a weight spin box fires many
	# edits per second, and each would otherwise rebuild the whole grid.
	var edits_timer := Timer.new()
	edits_timer.one_shot = true
	edits_timer.wait_time = 0.3
	edits_timer.timeout.connect(_rebuild)
	add_child(edits_timer)
	AppData.edits_changed.connect(func() -> void: edits_timer.start())
	AppData.constraints_changed.connect(func() -> void: edits_timer.start())

	AppData.parts_changed.connect(_rebuild)
	_rebuild()


func _build_tag_rule_editor() -> VBoxContainer:
	var box := VBoxContainer.new()
	var tag_row := HBoxContainer.new()
	box.add_child(tag_row)
	tag_row.add_child(_mk_label("Tag"))
	_at_tag_input = LineEdit.new()
	_at_tag_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tag_row.add_child(_at_tag_input)
	var colors_head := HBoxContainer.new()
	box.add_child(colors_head)
	colors_head.add_child(_mk_label("Target colors"))
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	colors_head.add_child(spacer)
	var pick := Button.new()
	pick.text = "Pick from tiles…"
	pick.pressed.connect(_open_palette_popup)
	colors_head.add_child(pick)
	_at_colors_box = HBoxContainer.new()
	box.add_child(_at_colors_box)
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
	_at_tolerance = SpinBox.new()
	_at_tolerance.min_value = 0
	_at_tolerance.max_value = 255
	_at_tolerance.value = 16
	_at_tolerance.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tol_row.add_child(_at_tolerance)
	var frac_row := HBoxContainer.new()
	box.add_child(frac_row)
	frac_row.add_child(_mk_label("Min coverage %"))
	_at_min_fraction = SpinBox.new()
	_at_min_fraction.min_value = 0.0
	_at_min_fraction.max_value = 100.0
	_at_min_fraction.step = 0.5
	_at_min_fraction.value = 10.0
	_at_min_fraction.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	frac_row.add_child(_at_min_fraction)
	var btn_row := HBoxContainer.new()
	box.add_child(btn_row)
	var save := Button.new()
	save.text = "Save rule"
	save.pressed.connect(_on_tag_rule_save)
	btn_row.add_child(save)
	var cancel := Button.new()
	cancel.text = "Cancel"
	cancel.pressed.connect(_on_tag_rule_cancel)
	btn_row.add_child(cancel)
	var note := Label.new()
	note.text = ("A part gets the tag when at least the coverage fraction of its " \
		+ "non-transparent pixels sit within tolerance (per channel) of ANY " \
		+ "target color. Transparent pixels are ignored entirely. " \
		+ "Use Apply all rules to (re-)tag; Strip removes the tag everywhere.")
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(note)
	return box


func _reset_color_buttons(n: int) -> void:
	while _at_color_buttons.size() > n:
		var b: ColorPickerButton = _at_color_buttons.pop_back()
		_at_colors_box.remove_child(b)
		b.queue_free()
	while _at_color_buttons.size() < n:
		_on_add_color_pressed()


func _on_add_color_pressed() -> void:
	if _at_color_buttons.size() >= 8:
		return
	var b := ColorPickerButton.new()
	b.custom_minimum_size = Vector2(36.0, 28.0)
	b.color = Color.WHITE
	_at_color_buttons.append(b)
	_at_colors_box.add_child(b)


func _on_remove_color_pressed() -> void:
	if _at_color_buttons.is_empty():
		return
	var b: ColorPickerButton = _at_color_buttons.pop_back()
	_at_colors_box.remove_child(b)
	b.queue_free()


func _mk_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l


func _mk_cmp_preview() -> TextureRect:
	var t := TextureRect.new()
	t.custom_minimum_size = PREVIEW
	t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	t.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	return t


func _build_palette_popup() -> PopupPanel:
	var popup := PopupPanel.new()
	var box := VBoxContainer.new()
	popup.add_child(box)
	var head := HBoxContainer.new()
	box.add_child(head)
	head.add_child(_mk_label("Source"))
	_palette_source = OptionButton.new()
	_palette_source.add_item("Selected tile")
	_palette_source.add_item("All tiles")
	_palette_source.item_selected.connect(func(_i: int) -> void: _populate_palette())
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
	hint.text = "Click swatches to add them to the rule; close when done."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(hint)
	return popup


func _open_palette_popup() -> void:
	_palette_source.select(0 if _selected != null else 1)
	_populate_palette()
	_palette_popup.popup_centered(Vector2i(360, 440))


func _populate_palette() -> void:
	for child in _palette_grid.get_children():
		child.free()
	var images: Array[Image] = []
	if _palette_source.selected == 0:
		if _selected == null or _selected.pixel_data == null:
			_palette_status.text = "No tile selected."
			return
		images.append(_selected.pixel_data)
	else:
		for p: Part in AppData.get_part_list():
			if p.pixel_data != null:
				images.append(p.pixel_data)
	if images.is_empty():
		_palette_status.text = "No tiles to sample."
		return
	var result: Dictionary
	if _palette_source.selected == 0:
		result = PaletteExtractor.palette_of_images(images, 4, 64)
	else:
		if not _all_palette_valid:
			_all_palette_cache = PaletteExtractor.palette_of_images(images, 4, 64)
			_all_palette_valid = true
		result = _all_palette_cache
	var entries: Array = result["entries"]
	var total := int(result["total"])
	if entries.is_empty():
		_palette_status.text = "No opaque pixels found."
		return
	if total <= entries.size():
		_palette_status.text = "%d color(s)" % total
	else:
		_palette_status.text = "%d distinct colors — showing top %d by frequency" % [
			total, entries.size()]
	for e: Dictionary in entries:
		var swatch := Button.new()
		swatch.custom_minimum_size = Vector2(30.0, 30.0)
		swatch.focus_mode = Control.FOCUS_NONE
		var sb := StyleBoxFlat.new()
		sb.bg_color = e["color"]
		swatch.add_theme_stylebox_override("normal", sb)
		swatch.add_theme_stylebox_override("hover", sb)
		swatch.add_theme_stylebox_override("pressed", sb)
		swatch.tooltip_text = "#%s  — %s px" % [e["hex"], e["count"]]
		swatch.pressed.connect(_on_swatch_pressed.bind(String(e["hex"])))
		_palette_grid.add_child(swatch)


func _on_swatch_pressed(hex: String) -> void:
	if _at_color_buttons.size() >= 8:
		_palette_status.text = "Rule color limit (8) reached — remove one first."
		return
	var b := ColorPickerButton.new()
	b.custom_minimum_size = Vector2(36.0, 28.0)
	b.color = Color(hex)
	_at_color_buttons.append(b)
	_at_colors_box.add_child(b)


# --- Grid ----------------------------------------------------------------------

func _rebuild() -> void:
	# Preserve selection/pin across rebuilds (by id, since objects are
	# re-materialized clones).
	var selected_id := _selected.id if _selected != null else ""
	var pinned_id := _pinned.id if _pinned != null else ""

	for child in _grid.get_children():
		child.free()
	_occurrences.clear()
	_occurrence_data = []

	var parts := AppData.get_part_list()
	_refresh_tag_filter()
	var tag_filter := _selected_tag_filter()
	var total_parts := parts.size()
	if tag_filter != "":
		var filtered: Array[Part] = []
		for p: Part in parts:
			if AppData.get_tags(p.id).has(tag_filter):
				filtered.append(p)
		parts = filtered

	if parts.is_empty():
		_selected = null
		_pinned = AppData.parts.get(pinned_id)
		if tag_filter != "":
			_grid_status.text = "No parts tagged \"%s\"." % tag_filter
		else:
			_grid_status.text = "No parts. Run a decomposition first."
		_preview.texture = null
		_info.text = "Nothing selected"
		_refresh_tags()
		_update_pin_button()
		_refresh_compare()
		_refresh_neighbors()
		return

	parts.sort_custom(func(a: Part, b: Part) -> bool:
		return a.occurrence_count() > b.occurrence_count())

	var stats: Dictionary = AppData.last_run_stats
	_grid_status.text = "%s parts (%s tiles extracted, %s ms)" % [
		parts.size(), stats.get("total_tiles", 0), stats.get("elapsed_ms", 0)]
	if tag_filter != "":
		_grid_status.text += "  — %s of %s tagged \"%s\"" % [
			parts.size(), total_parts, tag_filter]

	for i in mini(parts.size(), MAX_SHOWN):
		_add_part_button(parts[i])
	if parts.size() > MAX_SHOWN:
		_grid_status.text += "  — showing first %s" % MAX_SHOWN

	_pinned = AppData.parts.get(pinned_id) if pinned_id != "" else null
	if selected_id != "" and AppData.parts.has(selected_id):
		_show_part(AppData.parts[selected_id])
	else:
		_selected = null
		_preview.texture = null
		_info.text = "Nothing selected"
		_refresh_tags()
	_update_pin_button()
	_refresh_compare()
	_refresh_neighbors()


func _add_part_button(part: Part) -> void:
	var button := Button.new()
	button.custom_minimum_size = THUMB
	button.icon = part.get_texture()
	button.expand_icon = true
	var tags := AppData.get_tags(part.id)
	var tag_line := "" if tags.is_empty() else "\ntags: %s" % ", ".join(tags)
	button.tooltip_text = "%s\n%s occurrence(s)%s%s" % [
		"%s (%s)" % [part.id, _transform_label(part.transform_key)],
		part.occurrence_count(),
		"" if part.enabled else "\n[disabled]",
		tag_line]
	if not part.enabled:
		button.modulate = Color(1.0, 1.0, 1.0, 0.35)
	button.pressed.connect(_show_part.bind(part))
	_grid.add_child(button)


func _part_info_text(part: Part) -> String:
	var tags := AppData.get_tags(part.id)
	var tag_line := "" if tags.is_empty() else "  |  tags: %s" % ", ".join(tags)
	return "%s\n%s  |  %s × %s  |  occurrences: %s  |  weight: %s%s%s" % [
		part.id, _transform_label(part.transform_key), part.size.x, part.size.y,
		part.occurrence_count(), part.get_effective_weight(),
		"" if part.enabled else "  [disabled]", tag_line]


# --- Inspector -------------------------------------------------------------------

func _show_part(part: Part) -> void:
	_selected = part
	_preview.texture = part.get_texture()
	_info.text = _part_info_text(part)
	_enabled_check.set_pressed_no_signal(part.enabled)
	_refresh_transform_controls(part)
	_override_check.set_pressed_no_signal(part.weight_override != null)
	_weight_spin.set_value_no_signal(part.get_effective_weight())

	_occurrence_data = part.occurrences.duplicate()
	_occurrences.clear()
	for occ: Dictionary in part.occurrences:
		var pos: Vector2i = occ["position"]
		_occurrences.add_item("%s  (%s, %s)" % [
			AppData.image_name(occ["image_id"]), pos.x, pos.y])
	_refresh_compare()
	_refresh_neighbors()
	_refresh_tags()


func _transform_label(key: String) -> String:
	match key:
		"rot90": return "rotation 90°"
		"rot180": return "rotation 180°"
		"rot270": return "rotation 270°"
		"flip_h": return "horizontal reflection"
		"flip_v": return "vertical reflection"
	return "rotation 0°"


func _refresh_transform_controls(part: Part) -> void:
	var canonical: Part = AppData.get_canonical_part(part.canonical_id)
	if canonical == null:
		for check: CheckButton in _transform_checks.values():
			check.disabled = true
		_transform_note.text = "Transform source is unavailable."
		return
	var notes: Array[String] = []
	for transform_key: String in _transform_checks:
		var check: CheckButton = _transform_checks[transform_key]
		var unavailable := (transform_key == "rot90" or transform_key == "rot270") \
				and canonical.size.x != canonical.size.y
		check.set_pressed_no_signal(AppData.is_transform_enabled(canonical.id, transform_key))
		# A transform with identical pixels may still produce distinct transformed
		# constraint offsets, so it remains independently selectable.
		check.disabled = unavailable
		if unavailable:
			notes.append("90° rotations require a square source part.")
		elif PixelHash.of(GridTiles.transform_image(canonical.pixel_data, transform_key),
				AppData.get_dedupe_tolerance()) == PixelHash.of(canonical.pixel_data,
				AppData.get_dedupe_tolerance()):
			notes.append("%s has identical pixels, but can add transformed constraint evidence." %
				_transform_label(transform_key))
	_transform_note.text = "\n".join(notes)


func _on_transform_toggled(pressed: bool, transform_key: String) -> void:
	if _selected == null:
		return
	AppData.set_transform_enabled(_selected.canonical_id, transform_key, pressed)


func _on_enabled_toggled(pressed: bool) -> void:
	if _selected == null:
		return
	AppData.edit_part(_selected.id, "enabled", pressed)
	_info.text = _part_info_text(_selected)


func _on_override_toggled(pressed: bool) -> void:
	if _selected == null:
		return
	AppData.edit_part(_selected.id, "weight_override",
		_weight_spin.value if pressed else null)


func _on_weight_changed(value: float) -> void:
	if _selected == null or not _override_check.button_pressed:
		return
	AppData.edit_part(_selected.id, "weight_override", value)


func _refresh_tags() -> void:
	for child in _tags_box.get_children():
		child.free()
	_tag_input.editable = _selected != null
	if _selected == null:
		return
	var tags := AppData.get_tags(_selected.id)
	if tags.is_empty():
		var none := Label.new()
		none.text = "(none)"
		_tags_box.add_child(none)
	for tag: String in tags:
		var row := HBoxContainer.new()
		_tags_box.add_child(row)
		var label := Label.new()
		label.text = tag
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(label)
		var remove := Button.new()
		remove.text = "×"
		remove.focus_mode = Control.FOCUS_NONE
		# Bind the id, not the Part: rows can outlive a re-materialization.
		remove.pressed.connect(_on_tag_remove.bind(_selected.id, tag))
		row.add_child(remove)


func _refresh_tag_rules() -> void:
	for child in _auto_tag_box.get_children():
		child.free()
	var all_rules := AppData.get_tagging_rules()
	if all_rules.is_empty():
		_auto_tag_status.text = "No auto-tag rules."
	else:
		_auto_tag_status.text = "%d auto-tag rule(s)." % all_rules.size()
	for r: Dictionary in all_rules:
		var id := String(r.get("id", ""))
		var row := HBoxContainer.new()
		_auto_tag_box.add_child(row)
		var check := CheckButton.new()
		check.set_pressed_no_signal(bool(r.get("enabled", true)))
		check.toggled.connect(_on_tag_rule_enabled.bind(id))
		row.add_child(check)
		var label := Label.new()
		label.text = _tag_rule_summary(r)
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		row.add_child(label)
		var edit := Button.new()
		edit.text = "Edit"
		edit.pressed.connect(_on_edit_tag_rule_pressed.bind(id))
		row.add_child(edit)
		var strip := Button.new()
		strip.text = "Strip"
		strip.tooltip_text = "Remove this tag from every part."
		strip.pressed.connect(_on_strip_tag.bind(String(r.get("tag", ""))))
		row.add_child(strip)
		var del := Button.new()
		del.text = "×"
		del.pressed.connect(_on_tag_rule_delete.bind(id))
		row.add_child(del)


func _tag_rule_summary(r: Dictionary) -> String:
	var colors: Array = r.get("colors", [])
	var swatches: Array[String] = []
	for c: Variant in colors:
		swatches.append(String(c))
	return "\"%s\" ← [%s], tol %d, ≥ %.1f%%" % [
		String(r.get("tag", "")), ", ".join(swatches),
		int(r.get("tolerance", 16)), float(r.get("min_fraction", 0.1)) * 100.0]


func _on_tag_rule_enabled(pressed: bool, id: String) -> void:
	AppData.update_tagging_rule(id, {"enabled": pressed})


func _on_tag_rule_delete(id: String) -> void:
	if _editing_tag_rule_id == id:
		_on_tag_rule_cancel()
	AppData.remove_tagging_rule(id)


func _on_strip_tag(tag: String) -> void:
	AppData.strip_tag_everywhere(tag)


func _on_apply_tagging_rules() -> void:
	var report := AppData.apply_tagging_rules()
	_auto_tag_status.text = "Applied: %d part(s) newly tagged." % int(report.get("tagged_parts", 0))


func _on_tag_submitted(text: String) -> void:
	if _selected == null:
		return
	AppData.add_part_tag(_selected.id, text)
	_tag_input.clear()
	_refresh_tags()   # immediate feedback; debounced _rebuild reconciles the grid


func _on_tag_remove(part_id: String, tag: String) -> void:
	AppData.remove_part_tag(part_id, tag)


func _refresh_tag_filter() -> void:
	var prev := _selected_tag_filter()
	_tag_filter.clear()
	_tag_filter.add_item("All parts")
	_tag_filter.set_item_metadata(0, "")
	for tag: String in AppData.get_all_tags():
		_tag_filter.add_item(tag)
		_tag_filter.set_item_metadata(_tag_filter.item_count - 1, tag)
	for i in _tag_filter.item_count:
		if _tag_filter.get_item_metadata(i) == prev:
			_tag_filter.select(i)
			return
	_tag_filter.select(0)


func _selected_tag_filter() -> String:
	var meta: Variant = _tag_filter.get_selected_metadata()
	return meta if meta is String else ""


func _on_add_tag_rule_pressed() -> void:
	_editing_tag_rule_id = ""
	_at_tag_input.text = ""
	_reset_color_buttons(1)
	_at_tolerance.set_value_no_signal(16)
	_at_min_fraction.set_value_no_signal(10.0)
	_auto_editor.visible = true


func _on_edit_tag_rule_pressed(id: String) -> void:
	for r: Dictionary in AppData.get_tagging_rules():
		if String(r.get("id", "")) != id:
			continue
		_editing_tag_rule_id = id
		_at_tag_input.text = String(r.get("tag", ""))
		var colors: Array = r.get("colors", [])
		_reset_color_buttons(clampi(colors.size(), 1, 8))
		for i in mini(colors.size(), _at_color_buttons.size()):
			var s := String(colors[i])
			if not s.begins_with("#"):
				s = "#" + s
			if Color.html_is_valid(s):
				_at_color_buttons[i].color = Color(s)
		_at_tolerance.set_value_no_signal(float(r.get("tolerance", 16)))
		_at_min_fraction.set_value_no_signal(float(r.get("min_fraction", 0.1)) * 100.0)
		_auto_editor.visible = true
		return


func _on_tag_rule_save() -> void:
	var tag := _at_tag_input.text.strip_edges()
	if tag.is_empty():
		_auto_tag_status.text = "Enter a tag name."
		return
	var colors: Array = []
	for b: ColorPickerButton in _at_color_buttons:
		colors.append(b.color.to_html(false))
	if colors.is_empty():
		_auto_tag_status.text = "Add at least one target color."
		return
	var fields := {
		"tag": tag,
		"colors": colors,
		"tolerance": int(_at_tolerance.value),
		"min_fraction": _at_min_fraction.value / 100.0,
	}
	if _editing_tag_rule_id.is_empty():
		AppData.add_tagging_rule(fields)
	else:
		AppData.update_tagging_rule(_editing_tag_rule_id, fields)
	_auto_editor.visible = false


func _on_tag_rule_cancel() -> void:
	_auto_editor.visible = false
	_editing_tag_rule_id = ""


# --- Pin / compare / merge ---------------------------------------------------------

func _on_pin_pressed() -> void:
	if _selected == null:
		return
	if _pinned != null and _pinned.id == _selected.id:
		_pinned = null
	else:
		_pinned = _selected
	_update_pin_button()
	_refresh_compare()


func _update_pin_button() -> void:
	_pin_button.text = "Unpin" if _pinned != null else "Pin for comparison"


func _refresh_compare() -> void:
	var active := _pinned != null and _selected != null and _pinned.id != _selected.id
	_compare_box.visible = active
	if not active:
		return
	_cmp_pinned.texture = _pinned.get_texture()
	_cmp_selected.texture = _selected.get_texture()
	if _pinned.size == _selected.size:
		var diff := _make_diff_image(_pinned.pixel_data, _selected.pixel_data)
		_cmp_diff.texture = ImageTexture.create_from_image(diff)
		_cmp_label.text = "%s of %s pixels differ" % [
			_diff_count, _pinned.size.x * _pinned.size.y]
	else:
		_cmp_diff.texture = null
		_cmp_label.text = "Sizes differ — merge anyway?"


func _refresh_neighbors() -> void:
	for child in _neighbors_box.get_children():
		child.free()
	if _selected == null or AppData.parts.is_empty():
		return

	var index := AppData.get_constraint_index()
	var offsets := index.get_offsets()
	if offsets.is_empty():
		var none := Label.new()
		none.text = "No constraints extracted."
		_neighbors_box.add_child(none)
		return

	# Deterministic, readable ordering: near offsets first, row-major.
	offsets.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		var da := a.x * a.x + a.y * a.y
		var db := b.x * b.x + b.y * b.y
		if da != db:
			return da < db
		if a.y != b.y:
			return a.y < b.y
		return a.x < b.x)

	var shown_offsets := 0
	for off: Vector2i in offsets:
		if shown_offsets >= MAX_NEIGHBOR_OFFSETS:
			break
		var nb: Dictionary = index.get_neighbors(_selected.id, off)
		if nb.is_empty():
			continue
		shown_offsets += 1

		# Strongest neighbors first.
		var ids: Array = nb.keys()
		ids.sort_custom(func(a: String, b: String) -> bool:
			return nb[a] > nb[b])

		var header := Label.new()
		header.text = "offset (%s, %s) — %s part(s)" % [off.x, off.y, ids.size()]
		_neighbors_box.add_child(header)

		var grid := GridContainer.new()
		grid.columns = 8
		grid.add_theme_constant_override("h_separation", 2)
		grid.add_theme_constant_override("v_separation", 2)
		_neighbors_box.add_child(grid)

		for i in mini(ids.size(), MAX_NEIGHBORS_PER_OFFSET):
			var part: Part = index.get_part(ids[i])
			if part == null:
				continue
			var button := Button.new()
			button.custom_minimum_size = Vector2(40.0, 40.0)
			button.icon = part.get_texture()
			button.expand_icon = true
			button.tooltip_text = "%s\nweight: %s" % [part.id, nb[ids[i]]]
			button.pressed.connect(_show_part.bind(part))
			grid.add_child(button)

		if ids.size() > MAX_NEIGHBORS_PER_OFFSET:
			var more := Label.new()
			more.text = "  … and %s more" % (ids.size() - MAX_NEIGHBORS_PER_OFFSET)
			_neighbors_box.add_child(more)


func _make_diff_image(a: Image, b: Image) -> Image:
	var img := Image.create_empty(a.get_width(), a.get_height(), false, Image.FORMAT_RGBA8)
	_diff_count = 0
	for y in a.get_height():
		for x in a.get_width():
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			if ca == cb:
				img.set_pixel(x, y, Color(ca.r, ca.g, ca.b, 0.30))
			else:
				img.set_pixel(x, y, Color(1.0, 0.25, 0.25))
				_diff_count += 1
	return img


func _on_merge_pressed() -> void:
	if _pinned == null or _selected == null or _pinned.id == _selected.id:
		return
	# parts_changed fires from the re-materialization; _rebuild restores the
	# pin by id. The merged-away part's selection clears (it no longer exists).
	AppData.merge_parts(_selected.id, _pinned.id)


# --- Occurrences --------------------------------------------------------------------

func _on_occurrence_selected(index: int) -> void:
	if index < 0 or index >= _occurrence_data.size() or _selected == null:
		return
	var occ: Dictionary = _occurrence_data[index]
	occurrence_selected.emit(occ["image_id"], occ["position"], _selected.size)
