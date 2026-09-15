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

var _neighbors_box: VBoxContainer
const MAX_NEIGHBOR_OFFSETS := 12
const MAX_NEIGHBORS_PER_OFFSET := 24


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
	left.add_child(_grid_status)

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
	if parts.is_empty():
		_selected = null
		_pinned = AppData.parts.get(pinned_id)
		_grid_status.text = "No parts. Run a decomposition first."
		_preview.texture = null
		_info.text = "Nothing selected"
		_update_pin_button()
		_refresh_compare()
		_refresh_neighbors()
		return

	parts.sort_custom(func(a: Part, b: Part) -> bool:
		return a.occurrence_count() > b.occurrence_count())

	var stats: Dictionary = AppData.last_run_stats
	_grid_status.text = "%s parts (%s tiles extracted, %s ms)" % [
		parts.size(), stats.get("total_tiles", 0), stats.get("elapsed_ms", 0)]

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
	_update_pin_button()
	_refresh_compare()
	_refresh_neighbors()


func _add_part_button(part: Part) -> void:
	var button := Button.new()
	button.custom_minimum_size = THUMB
	button.icon = part.get_texture()
	button.expand_icon = true
	button.tooltip_text = "%s\n%s occurrence(s)%s" % [
		"%s (%s)" % [part.id, _transform_label(part.transform_key)], part.occurrence_count(),
		"" if part.enabled else "\n[disabled]"]
	if not part.enabled:
		button.modulate = Color(1.0, 1.0, 1.0, 0.35)
	button.pressed.connect(_show_part.bind(part))
	_grid.add_child(button)


# --- Inspector -------------------------------------------------------------------

func _show_part(part: Part) -> void:
	_selected = part
	_preview.texture = part.get_texture()
	_info.text = _part_info_text(part)
	_enabled_check.set_pressed_no_signal(part.enabled)
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


func _part_info_text(part: Part) -> String:
	return "%s\n%s  |  %s × %s  |  occurrences: %s  |  weight: %s%s" % [
		part.id, _transform_label(part.transform_key), part.size.x, part.size.y, part.occurrence_count(),
		part.get_effective_weight(),
		"" if part.enabled else "  [disabled]"]


func _transform_label(key: String) -> String:
	match key:
		"rot90": return "rotation 90°"
		"rot180": return "rotation 180°"
		"rot270": return "rotation 270°"
		"flip_h": return "horizontal reflection"
		"flip_v": return "vertical reflection"
	return "rotation 0°"


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
