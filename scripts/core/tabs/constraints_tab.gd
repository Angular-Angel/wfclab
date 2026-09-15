class_name ConstraintsTab extends Control
## Constraint matrix with drill-down and editing.

signal occurrence_selected(image_id: String, position: Vector2i, size: Vector2i)

const MAX_MATRIX := 64
const CELL := Vector2(18.0, 18.0)
const HEADER := Vector2(24.0, 24.0)

var _grid: GridContainer
var _status: Label
var _pair_info: Label
var _preview_a: TextureRect
var _preview_b: TextureRect
var _constraint_list: ItemList
var _evidence_list: ItemList

var _c_enabled_check: CheckButton
var _c_override_check: CheckButton
var _c_weight_spin: SpinBox
var _editing_constraint_id := ""

var _matrix_parts: Array[Part] = []
var _pair_map: Dictionary = {}
var _selected_pair: Array[Part] = []
var _selected_constraints: Array[Constraint] = []
var _style_cache: Dictionary = {}


func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

	var split := HSplitContainer.new()
	split.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(split)

	# --- Left: matrix ---------------------------------------------------------
	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.add_child(left)

	_status = Label.new()
	left.add_child(_status)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	left.add_child(scroll)

	_grid = GridContainer.new()
	_grid.add_theme_constant_override("h_separation", 1)
	_grid.add_theme_constant_override("v_separation", 1)
	scroll.add_child(_grid)

	# --- Right: inspector -----------------------------------------------------
	var right := VBoxContainer.new()
	right.custom_minimum_size = Vector2(300.0, 0.0)
	split.add_child(right)

	right.add_child(_mk_label("Selected Pair"))
	var previews := HBoxContainer.new()
	right.add_child(previews)
	_preview_a = _mk_preview()
	_preview_b = _mk_preview()
	previews.add_child(_preview_a)
	previews.add_child(_preview_b)

	_pair_info = Label.new()
	_pair_info.text = "Click a matrix cell"
	_pair_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	right.add_child(_pair_info)

	right.add_child(_mk_label("Constraints"))
	_constraint_list = ItemList.new()
	_constraint_list.custom_minimum_size = Vector2(0.0, 100.0)
	_constraint_list.item_selected.connect(_on_constraint_selected)
	right.add_child(_constraint_list)

	right.add_child(_mk_label("Evidence"))
	_evidence_list = ItemList.new()
	_evidence_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_evidence_list.item_selected.connect(_on_evidence_selected)
	right.add_child(_evidence_list)

	right.add_child(_mk_label("Edit Constraint"))
	_c_enabled_check = CheckButton.new()
	_c_enabled_check.text = "Enabled"
	_c_enabled_check.toggled.connect(_on_c_enabled_toggled)
	right.add_child(_c_enabled_check)
	var weight_row := HBoxContainer.new()
	right.add_child(weight_row)
	_c_override_check = CheckButton.new()
	_c_override_check.text = "Weight override"
	_c_override_check.toggled.connect(_on_c_override_toggled)
	weight_row.add_child(_c_override_check)
	_c_weight_spin = SpinBox.new()
	_c_weight_spin.min_value = 0.0
	_c_weight_spin.max_value = 99999.0
	_c_weight_spin.value_changed.connect(_on_c_weight_changed)
	weight_row.add_child(_c_weight_spin)

	# Debounced refresh for edits (dragging a spin box shouldn't rebuild
	# the matrix 30 times a second).
	var edits_timer := Timer.new()
	edits_timer.one_shot = true
	edits_timer.wait_time = 0.3
	edits_timer.timeout.connect(_rebuild)
	add_child(edits_timer)
	AppData.edits_changed.connect(func() -> void: edits_timer.start())

	AppData.parts_changed.connect(_rebuild)
	AppData.constraints_changed.connect(_rebuild)
	_rebuild()


func _mk_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l


func _mk_preview() -> TextureRect:
	var t := TextureRect.new()
	t.custom_minimum_size = Vector2(96.0, 96.0)
	t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	t.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	return t


func _rebuild() -> void:
	_selected_pair = []
	_selected_constraints = []
	_pair_map = {}
	for child in _grid.get_children():
		child.free()
	_constraint_list.clear()
	_evidence_list.clear()
	_preview_a.texture = null
	_preview_b.texture = null
	_pair_info.text = "Click a matrix cell"
	_editing_constraint_id = ""
	_c_enabled_check.set_pressed_no_signal(false)
	_c_override_check.set_pressed_no_signal(false)

	for c: Constraint in AppData.get_constraint_list():
		if not c.enabled or c.participants.size() != 2:
			continue
		var ids := c.part_ids()
		ids.sort()
		var k := "%s|%s" % [ids[0], ids[1]]
		if not _pair_map.has(k):
			_pair_map[k] = {"weight": 0.0, "constraints": []}
		_pair_map[k]["weight"] += c.get_effective_weight()
		(_pair_map[k]["constraints"] as Array).append(c)

	var parts := AppData.get_part_list()
	if parts.is_empty():
		_status.text = "No parts. Run a decomposition first."
		return

	parts.sort_custom(func(a: Part, b: Part) -> bool:
		return a.occurrence_count() > b.occurrence_count())

	_matrix_parts = []
	for i in mini(parts.size(), MAX_MATRIX):
		_matrix_parts.append(parts[i])

	var n := _matrix_parts.size()
	var shown_caps := ""
	if parts.size() > MAX_MATRIX:
		shown_caps = " (showing %d most frequent)" % MAX_MATRIX
	_status.text = "%d parts, %d constraints%s" % [
		parts.size(), AppData.constraints.size(), shown_caps]

	var max_weight := 1.0
	for entry: Dictionary in _pair_map.values():
		max_weight = maxf(max_weight, entry["weight"])

	_grid.columns = n + 1
	var corner := Control.new()
	corner.custom_minimum_size = HEADER
	_grid.add_child(corner)
	for i in n:
		_grid.add_child(_mk_header_thumb(_matrix_parts[i]))
	for i in n:
		_grid.add_child(_mk_header_thumb(_matrix_parts[i]))
		for j in n:
			_grid.add_child(_mk_cell(i, j, max_weight))


func _mk_header_thumb(part: Part) -> TextureRect:
	var t := TextureRect.new()
	t.custom_minimum_size = HEADER
	t.texture = part.get_texture()
	t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	t.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	t.tooltip_text = part.id
	return t


func _mk_cell(i: int, j: int, max_weight: float) -> Button:
	var a: Part = _matrix_parts[i]
	var b: Part = _matrix_parts[j]
	var button := Button.new()
	button.custom_minimum_size = CELL
	button.focus_mode = Control.FOCUS_NONE
	var entry := _pair_entry(a.id, b.id)
	if entry.is_empty():
		button.disabled = true
	else:
		var w: float = entry["weight"]
		var bucket := int(round(8.0 * log(w + 1.0) / log(max_weight + 1.0)))
		var style := _bucket_style(bucket)
		button.add_theme_stylebox_override("normal", style)
		button.add_theme_stylebox_override("hover", style)
		button.add_theme_stylebox_override("pressed", style)
		button.tooltip_text = "%s\n%s\nweight: %d" % [a.id, b.id, int(w)]
		button.pressed.connect(_on_cell_selected.bind(i, j))
	return button


func _pair_entry(id_a: String, id_b: String) -> Dictionary:
	var ids := [id_a, id_b]
	ids.sort()
	return _pair_map.get("%s|%s" % [ids[0], ids[1]], {})


func _bucket_style(bucket: int) -> StyleBoxFlat:
	if _style_cache.has(bucket):
		return _style_cache[bucket]
	var sb := StyleBoxFlat.new()
	var t := float(bucket) / 8.0
	sb.bg_color = Color(0.25, 0.55, 1.0, 0.10 + 0.90 * t)
	sb.content_margin_left = 0.0
	sb.content_margin_right = 0.0
	sb.content_margin_top = 0.0
	sb.content_margin_bottom = 0.0
	_style_cache[bucket] = sb
	return sb


func _on_cell_selected(i: int, j: int) -> void:
	var a: Part = _matrix_parts[i]
	var b: Part = _matrix_parts[j]
	_selected_pair = [a, b]
	_preview_a.texture = a.get_texture()
	_preview_b.texture = b.get_texture()

	var entry := _pair_entry(a.id, b.id)
	_selected_constraints = []
	var constraints: Array = entry.get("constraints", [])
	_selected_constraints.assign(constraints)

	_pair_info.text = "%s\n%s\naggregate weight: %d" % [
		a.id, b.id, int(entry.get("weight", 0.0))]

	_constraint_list.clear()
	_evidence_list.clear()
	for index in _selected_constraints.size():
		var c: Constraint = _selected_constraints[index]
		var offset: Vector2i = c.params.get("offset", Vector2i())
		_constraint_list.add_item(
			"%s  offset (%d, %d)  w=%d  n=%d" % [
				String(c.type), offset.x, offset.y,
				int(c.get_effective_weight()), c.evidence.size()])
	if _constraint_list.item_count > 0:
		_constraint_list.select(0)
		_on_constraint_selected(0)


func _on_constraint_selected(index: int) -> void:
	_evidence_list.clear()
	if index < 0 or index >= _selected_constraints.size():
		return
	var c: Constraint = _selected_constraints[index]
	_editing_constraint_id = c.id
	_c_enabled_check.set_pressed_no_signal(c.enabled)
	_c_override_check.set_pressed_no_signal(c.weight_override != null)
	_c_weight_spin.set_value_no_signal(c.get_effective_weight())
	for e_index in c.evidence.size():
		var ev: Dictionary = c.evidence[e_index]
		var p0: Vector2i = ev["positions"][0]
		var p1: Vector2i = ev["positions"][1]
		_evidence_list.add_item("%s  (%d,%d)→(%d,%d)" % [
			AppData.image_name(ev["image_id"]), p0.x, p0.y, p1.x, p1.y])


func _on_c_enabled_toggled(pressed: bool) -> void:
	if _editing_constraint_id.is_empty():
		return
	AppData.edit_constraint(_editing_constraint_id, "enabled", pressed)


func _on_c_override_toggled(pressed: bool) -> void:
	if _editing_constraint_id.is_empty():
		return
	AppData.edit_constraint(_editing_constraint_id, "weight_override",
		_c_weight_spin.value if pressed else null)


func _on_c_weight_changed(value: float) -> void:
	if _editing_constraint_id.is_empty() or not _c_override_check.button_pressed:
		return
	AppData.edit_constraint(_editing_constraint_id, "weight_override", value)


func _on_evidence_selected(index: int) -> void:
	if index < 0 or _selected_constraints.is_empty() or _selected_pair.is_empty():
		return
	var selected := _constraint_list.get_selected_items()
	if selected.is_empty():
		return
	var c: Constraint = _selected_constraints[selected[0]]
	if index >= c.evidence.size():
		return
	var ev: Dictionary = c.evidence[index]
	var p0: Vector2i = ev["positions"][0]
	var p1: Vector2i = ev["positions"][1]
	var size: Vector2i = _selected_pair[0].size
	var min_p := Vector2i(mini(p0.x, p1.x), mini(p0.y, p1.y))
	var max_p := Vector2i(maxi(p0.x, p1.x), maxi(p0.y, p1.y))
	occurrence_selected.emit(ev["image_id"], min_p, max_p + size - min_p)
