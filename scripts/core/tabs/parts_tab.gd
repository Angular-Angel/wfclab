class_name PartsTab extends TabBase
## Browse the parts from the last run; inspect, edit, compare, and merge them.

signal occurrence_selected(image_id: String, position: Vector2i, size: Vector2i)

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
var _override_row: WeightOverrideEditor
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
var _auto_tag_status: Label
var _tag_rules: TagRuleEditor
var _neighbors: NeighborsPanel


func _ready() -> void:
	super._ready()
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

	var split := _build_shell()

	# --- Left: parts grid ---------------------------------------------------
	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.add_child(left)

	_grid_status = UiKit.status_label("")
	var filter_row := HBoxContainer.new()
	left.add_child(filter_row)
	filter_row.add_child(UiKit.label("Tag filter:"))
	_tag_filter = OptionButton.new()
	_tag_filter.item_selected.connect(func(_i: int) -> void: _rebuild())
	filter_row.add_child(_tag_filter)
	filter_row.add_child(_grid_status)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	left.add_child(scroll)

	_grid = UiKit.thumb_grid(8)
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_grid)

	left.add_child(_set_empty_state("No parts. Run a decomposition first."))

	# --- Right: inspector (scrollable) -------------------------------------
	var right := UiKit.scroll_panel(split, 320.0)

	right.add_child(UiKit.label("Selected Part"))
	_preview = UiKit.preview(UiKit.PREVIEW)
	right.add_child(_preview)

	_info = Label.new()
	_info.text = "Nothing selected"
	right.add_child(_info)

	_enabled_check = CheckButton.new()
	_enabled_check.text = "Enabled"
	_enabled_check.toggled.connect(_on_enabled_toggled)
	right.add_child(_enabled_check)
	
	right.add_child(UiKit.label("Tags"))
	_tag_input = LineEdit.new()
	_tag_input.placeholder_text = "New tag + Enter"
	_tag_input.text_submitted.connect(_on_tag_submitted)
	right.add_child(_tag_input)
	_tags_box = VBoxContainer.new()
	right.add_child(_tags_box)

	right.add_child(UiKit.label("Auto-Tag Rules"))
	_auto_tag_status = UiKit.status_label("")
	right.add_child(_auto_tag_status)
	_tag_rules = TagRuleEditor.new()
	_tag_rules.setup(_selected_tile_images, func() -> bool: return _selected != null)
	_tag_rules.status_message.connect(
			func(text: String) -> void: _auto_tag_status.text = text)
	right.add_child(_tag_rules)

	right.add_child(UiKit.label("Transforms for source part"))
	_transforms_box = VBoxContainer.new()
	right.add_child(_transforms_box)
	for transform_key: String in ["rot90", "rot180", "rot270", "flip_h", "flip_v"]:
		var check := CheckButton.new()
		check.text = _transform_label(transform_key)
		check.toggled.connect(_on_transform_toggled.bind(transform_key))
		_transforms_box.add_child(check)
		_transform_checks[transform_key] = check
	_transform_note = UiKit.status_label("")
	_transforms_box.add_child(_transform_note)

	_override_row = WeightOverrideEditor.new()
	right.add_child(_override_row)
	_override_row.override_changed.connect(_on_override_changed)

	_pin_button = UiKit.button("Pin for comparison", _on_pin_pressed)
	right.add_child(_pin_button)

	_compare_box = VBoxContainer.new()
	right.add_child(_compare_box)
	_compare_box.add_child(UiKit.label("Comparison: pinned vs selected"))
	var cmp_row := HBoxContainer.new()
	_compare_box.add_child(cmp_row)
	_cmp_pinned = UiKit.preview(UiKit.PREVIEW)
	_cmp_selected = UiKit.preview(UiKit.PREVIEW)
	_cmp_diff = UiKit.preview(UiKit.PREVIEW)
	cmp_row.add_child(_cmp_pinned)
	cmp_row.add_child(_cmp_selected)
	cmp_row.add_child(_cmp_diff)
	_cmp_label = Label.new()
	_compare_box.add_child(_cmp_label)
	_merge_button = UiKit.button("Merge selected INTO pinned", _on_merge_pressed)
	_compare_box.add_child(_merge_button)
	_compare_box.visible = false
	
	right.add_child(UiKit.label("Neighbors"))
	_neighbors = NeighborsPanel.new()
	_neighbors.part_selected.connect(_show_part)
	right.add_child(_neighbors)

	right.add_child(UiKit.label("Occurrences"))
	_occurrences = ItemList.new()
	_occurrences.custom_minimum_size = Vector2(0.0, 160.0)
	_occurrences.item_selected.connect(_on_occurrence_selected)
	right.add_child(_occurrences)

	# Edits refresh is debounced: dragging a weight spin box fires many
	# edits per second, and each would otherwise rebuild the whole grid.
	AppData.edits_changed.connect(func() -> void: _debounce_rebuild(_rebuild))
	AppData.constraints_changed.connect(func() -> void: _debounce_rebuild(_rebuild))

	_bind_run_lock([_merge_button])
	RunMonitor.busy_changed.connect(func() -> void:
		var busy: bool = RunMonitor.has_running()
		_override_row.set_locked(busy)
		_refresh_tag_widgets_lock(busy))

	AppData.parts_changed.connect(_rebuild)
	_rebuild()


func _selected_tile_images() -> Array[Image]:
	if _selected == null or _selected.pixel_data == null:
		return []
	return [_selected.pixel_data]


# --- Grid ----------------------------------------------------------------------

func _rebuild() -> void:
	# Preserve selection/pin across rebuilds (by id, since objects are
	# re-materialized clones).
	var selected_id := _selected.id if _selected != null else ""
	var pinned_id := _pinned.id if _pinned != null else ""

	UiKit.clear_children(_grid)
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
			_clear_empty_state()   # parts exist; the filter just hid them
		else:
			_set_empty_state("No parts. Run a decomposition first.")
		_preview.texture = null
		_info.text = "Nothing selected"
		_refresh_tags()
		_update_pin_button()
		_refresh_compare()
		_neighbors.show_part(null)
		return

	parts.sort_custom(func(a: Part, b: Part) -> bool:
		return a.occurrence_count() > b.occurrence_count())

	_clear_empty_state()
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
	_neighbors.show_part(null)


func _add_part_button(part: Part) -> void:
	var button := Button.new()
	button.custom_minimum_size = UiKit.THUMB
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
	_override_row.set_silent(part.weight_override != null,
			part.get_effective_weight())

	_occurrence_data = part.occurrences.duplicate()
	_occurrences.clear()
	for occ: Dictionary in part.occurrences:
		var pos: Vector2i = occ["position"]
		_occurrences.add_item("%s  (%s, %s)" % [
			AppData.image_name(occ["image_id"]), pos.x, pos.y])
	_refresh_compare()
	_neighbors.show_part(part)
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


func _on_override_changed(enabled: bool, value: float) -> void:
	if _selected == null:
		return
	AppData.edit_part(_selected.id, "weight_override",
			value if enabled else null)


func _refresh_tags() -> void:
	UiKit.clear_children(_tags_box)
	_refresh_tag_widgets_lock(RunMonitor.has_running())
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
		# Bind the id, not the Part: rows can outlive a re-materialization.
		var remove := UiKit.button("×", _on_tag_remove.bind(_selected.id, tag))
		remove.focus_mode = Control.FOCUS_NONE
		remove.disabled = RunMonitor.has_running()
		row.add_child(remove)


## The tag input + per-tag remove buttons are rebuilt on every refresh,
## so their run-lock state is applied at refresh time instead of via the
## static _bind_run_lock list.
func _refresh_tag_widgets_lock(busy: bool) -> void:
	_tag_input.editable = _selected != null and not busy


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
				img.set_pixel(x, y, UiKit.DIFF_RED)
				_diff_count += 1
	return img


func _on_merge_pressed() -> void:
	if _pinned == null or _selected == null or _pinned.id == _selected.id:
		return
	var selected_id := _selected.id
	var pinned_id := _pinned.id
	# parts_changed fires from the re-materialization; _rebuild restores the
	# pin by id. The merged-away part's selection clears (it no longer exists).
	UiKit.confirm(self, "Merge Parts",
			"Merge \"%s\" INTO \"%s\"?\n\nThe selected part is removed and its "
			+ "occurrences are attributed to the pinned part. There is no "
			+ "per-merge undo: the only way back is Clear All Edits, which "
			+ "also discards every other manual edit." % [selected_id, pinned_id],
			"Merge", func() -> void:
				AppData.merge_parts(selected_id, pinned_id)
	).popup_centered()


# --- Occurrences --------------------------------------------------------------------

func _on_occurrence_selected(index: int) -> void:
	if index < 0 or index >= _occurrence_data.size() or _selected == null:
		return
	var occ: Dictionary = _occurrence_data[index]
	occurrence_selected.emit(occ["image_id"], occ["position"], _selected.size)
