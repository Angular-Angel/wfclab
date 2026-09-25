class_name ConstraintsTab extends TabBase
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
var _override_row: WeightOverrideEditor
var _editing_constraint_id := ""

var _matrix_parts: Array[Part] = []
var _pair_map: Dictionary = {}
var _selected_pair: Array[Part] = []
var _selected_constraints: Array[Constraint] = []
var _style_cache: Dictionary = {}

var _rules_box: VBoxContainer
var _rules_status: Label
var _add_rule_button: Button
var _rule_editor: VBoxContainer
var _re_tag_a: OptionButton
var _re_tag_b: OptionButton
var _re_distance: SpinBox
var _re_metric: OptionButton
var _editing_rule_id := ""


func _ready() -> void:
	super._ready()
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

	var split := _build_shell()

	# --- Left: matrix ---------------------------------------------------------
	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.add_child(left)

	_status = UiKit.status_label("")
	left.add_child(_status)
	left.add_child(_set_empty_state("No parts. Run a decomposition first."))

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

	right.add_child(UiKit.label("Selected Pair"))
	var previews := HBoxContainer.new()
	right.add_child(previews)
	_preview_a = _mk_preview()
	_preview_b = _mk_preview()
	previews.add_child(_preview_a)
	previews.add_child(_preview_b)

	_pair_info = UiKit.status_label("Click a matrix cell")
	right.add_child(_pair_info)

	right.add_child(UiKit.label("Constraints"))
	_constraint_list = ItemList.new()
	_constraint_list.custom_minimum_size = Vector2(0.0, 100.0)
	_constraint_list.item_selected.connect(_on_constraint_selected)
	right.add_child(_constraint_list)

	right.add_child(UiKit.label("Evidence"))
	_evidence_list = ItemList.new()
	_evidence_list.custom_minimum_size = Vector2(0.0, 160.0)
	_evidence_list.item_selected.connect(_on_evidence_selected)
	right.add_child(_evidence_list)

	right.add_child(UiKit.label("Edit Constraint"))
	_c_enabled_check = CheckButton.new()
	_c_enabled_check.text = "Enabled"
	_c_enabled_check.toggled.connect(_on_c_enabled_toggled)
	right.add_child(_c_enabled_check)
	_override_row = WeightOverrideEditor.new()
	right.add_child(_override_row)
	_override_row.override_changed.connect(_on_c_override_changed)

	right.add_child(UiKit.label("Authored Rules"))
	_rules_status = UiKit.status_label("")
	right.add_child(_rules_status)
	_rules_box = VBoxContainer.new()
	right.add_child(_rules_box)
	_add_rule_button = Button.new()
	_add_rule_button.text = "Add exclusion rule…"
	_add_rule_button.pressed.connect(_on_add_rule_pressed)
	right.add_child(_add_rule_button)
	_rule_editor = _build_rule_editor()
	_rule_editor.visible = false
	right.add_child(_rule_editor)
	_bind_run_lock([_add_rule_button])
	RunMonitor.busy_changed.connect(_refresh_rules)
	AppData.rules_changed.connect(_refresh_rules, CONNECT_DEFERRED)
	_refresh_rules()

	# One debounced rebuild for ALL change sources. A decomposition run emits
	# parts_changed and constraints_changed back to back; a single rebuild
	# 0.3 s later covers both, off the run pipeline's critical path — instead
	# of two full synchronous walks inside set_parts/set_constraints.
	AppData.edits_changed.connect(func() -> void: _debounce_rebuild(_rebuild))
	AppData.parts_changed.connect(func() -> void: _debounce_rebuild(_rebuild))
	AppData.constraints_changed.connect(func() -> void: _debounce_rebuild(_rebuild))
	_rebuild()


func _mk_preview() -> TextureRect:
	return UiKit.preview(UiKit.PREVIEW_SMALL)


func _rebuild() -> void:
	_selected_pair = []
	_selected_constraints = []
	_pair_map = {}
	UiKit.clear_children(_grid)
	_constraint_list.clear()
	_evidence_list.clear()
	_preview_a.texture = null
	_preview_b.texture = null
	_pair_info.text = "Click a matrix cell"
	_editing_constraint_id = ""
	_c_enabled_check.set_pressed_no_signal(false)
	_override_row.set_enabled_silent(false)

	var parts := AppData.get_part_list()
	if parts.is_empty():
		_set_empty_state("No parts. Run a decomposition first.")
		return

	_clear_empty_state()

	# Pick the matrix parts FIRST, then gate the constraint walk by
	# membership: two Dictionary lookups per constraint before any string
	# building, so a 500k-constraint model costs a light scan instead of
	# 500k key formats. Pairs outside the matrix were never displayed, and
	# per-pair constraint lists for matrix pairs stay complete.
	parts.sort_custom(func(a: Part, b: Part) -> bool:
		return a.occurrence_count() > b.occurrence_count())
	_matrix_parts = []
	for i in mini(parts.size(), MAX_MATRIX):
		_matrix_parts.append(parts[i])
	var member: Dictionary = {}
	for p: Part in _matrix_parts:
		member[p.id] = true

	for c: Constraint in AppData.get_constraint_list():
		if not c.enabled:
			continue
		var ps: Array = c.participants
		if ps.size() != 2:
			continue
		var id_a: String = ps[0]["part_id"]
		var id_b: String = ps[1]["part_id"]
		if not member.has(id_a) or not member.has(id_b):
			continue
		var first := id_a
		var second := id_b
		if second < first:
			first = id_b
			second = id_a
		var k := "%s|%s" % [first, second]
		var entry: Dictionary = _pair_map.get(k, {})
		if entry.is_empty():
			entry = {"weight": 0.0, "constraints": []}
			_pair_map[k] = entry
		entry["weight"] += c.get_effective_weight()
		(entry["constraints"] as Array).append(c)

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
	var t := UiKit.preview(HEADER)
	t.texture = part.get_texture()
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
	_override_row.set_silent(c.weight_override != null, c.get_effective_weight())
	for e_index in c.evidence.size():
		var ev: Dictionary = c.evidence[e_index]
		_evidence_list.add_item(_evidence_text(ev))
		if (ev.get("positions", []) as Array).size() < 2:
			_evidence_list.set_item_disabled(_evidence_list.item_count - 1, true)


func _evidence_text(ev: Dictionary) -> String:
	var positions: Array = ev.get("positions", [])
	if positions.size() < 2:
		## Non-spatial evidence (e.g. pixel-overlap compatibility facts):
		## no source occurrence exists to display or navigate to.
		return "%s  (compatibility — no source occurrence)" % AppData.image_name(ev.get("image_id", "?"))
	var p0: Vector2i = positions[0]
	var p1: Vector2i = positions[1]
	return "%s  (%d,%d)→(%d,%d)" % [
		AppData.image_name(ev["image_id"]), p0.x, p0.y, p1.x, p1.y]


func _on_c_enabled_toggled(pressed: bool) -> void:
	if _editing_constraint_id.is_empty():
		return
	AppData.edit_constraint(_editing_constraint_id, "enabled", pressed)


func _on_c_override_changed(enabled: bool, value: float) -> void:
	if _editing_constraint_id.is_empty():
		return
	AppData.edit_constraint(_editing_constraint_id, "weight_override",
			value if enabled else null)


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
	var positions: Array = ev.get("positions", [])
	if positions.size() < 2:
		return   # synthetic row; nothing to navigate to
	var p0: Vector2i = positions[0]
	var p1: Vector2i = positions[1]
	var size: Vector2i = _selected_pair[0].size
	var min_p := Vector2i(mini(p0.x, p1.x), mini(p0.y, p1.y))
	var max_p := Vector2i(maxi(p0.x, p1.x), maxi(p0.y, p1.y))
	occurrence_selected.emit(ev["image_id"], min_p, max_p + size - min_p)


func _build_rule_editor() -> VBoxContainer:
	var box := VBoxContainer.new()
	var row_a := HBoxContainer.new()
	box.add_child(row_a)
	row_a.add_child(UiKit.label("Tag A"))
	_re_tag_a = OptionButton.new()
	_re_tag_a.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row_a.add_child(_re_tag_a)
	var row_b := HBoxContainer.new()
	box.add_child(row_b)
	row_b.add_child(UiKit.label("Tag B"))
	_re_tag_b = OptionButton.new()
	_re_tag_b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row_b.add_child(_re_tag_b)
	var row_d := HBoxContainer.new()
	box.add_child(row_d)
	row_d.add_child(UiKit.label("Exclusion radius"))
	_re_distance = SpinBox.new()
	_re_distance.min_value = 1
	_re_distance.max_value = 12
	_re_distance.tooltip_text = "Cost of exclusion grows with radius squared. Keep <= ~8 on large maps."
	_re_distance.value = 3
	_re_distance.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row_d.add_child(_re_distance)
	var row_m := HBoxContainer.new()
	box.add_child(row_m)
	row_m.add_child(UiKit.label("Metric"))
	_re_metric = OptionButton.new()
	for m: String in ["chebyshev", "euclidean", "manhattan"]:
		_re_metric.add_item(m)
	_re_metric.select(0)
	row_m.add_child(_re_metric)
	var btn_row := HBoxContainer.new()
	box.add_child(btn_row)
	var apply := Button.new()
	apply.text = "Apply"
	apply.pressed.connect(_on_rule_apply)
	btn_row.add_child(apply)
	var cancel := Button.new()
	cancel.text = "Cancel"
	cancel.pressed.connect(_on_rule_cancel)
	btn_row.add_child(cancel)
	box.add_child(UiKit.note(
			"Slot units, inclusive. Applied at synthesis time; takes effect on the next run."))
	return box


func _populate_tag_options() -> void:
	# Populated on every open, so tags created in the Parts tab appear.
	var tags := AppData.get_all_tags()
	for ob: OptionButton in [_re_tag_a, _re_tag_b]:
		ob.clear()
		for tag: String in tags:
			ob.add_item(tag)


func _select_tag(ob: OptionButton, tag: String) -> void:
	for i in ob.item_count:
		if ob.get_item_text(i) == tag:
			ob.select(i)
			return
	if ob.item_count > 0:
		ob.select(0)


func _on_add_rule_pressed() -> void:
	_editing_rule_id = ""
	_populate_tag_options()
	if _re_tag_a.item_count > 0:
		_re_tag_a.select(0)
	if _re_tag_b.item_count > 1:
		_re_tag_b.select(1)   # default to a different tag than A
	_re_distance.set_value_no_signal(3)
	_re_metric.select(0)
	_rule_editor.visible = true


func _on_edit_rule_pressed(id: String) -> void:
	for r: Dictionary in AppData.get_rules():
		if String(r.get("id", "")) != id:
			continue
		_editing_rule_id = id
		_populate_tag_options()
		_select_tag(_re_tag_a, String(r.get("tag_a", "")))
		_select_tag(_re_tag_b, String(r.get("tag_b", "")))
		_re_distance.set_value_no_signal(float(r.get("distance", 3)))
		var metric := String(r.get("metric", "chebyshev"))
		for i in _re_metric.item_count:
			if _re_metric.get_item_text(i) == metric:
				_re_metric.select(i)
		_rule_editor.visible = true
		return


func _on_rule_apply() -> void:
	var tag_a := _re_tag_a.get_item_text(_re_tag_a.selected) if _re_tag_a.item_count > 0 else ""
	var tag_b := _re_tag_b.get_item_text(_re_tag_b.selected) if _re_tag_b.item_count > 0 else ""
	if tag_a.is_empty() or tag_b.is_empty():
		_rules_status.text = "Both tags must be chosen. Tag some parts in the Parts tab first."
		return
	var fields := {
		"type": "exclusion",
		"tag_a": tag_a,
		"tag_b": tag_b,
		"distance": int(_re_distance.value),
		"metric": _re_metric.get_item_text(_re_metric.selected),
	}
	if _editing_rule_id.is_empty():
		AppData.add_rule(fields)
	else:
		AppData.update_rule(_editing_rule_id, fields)
	_rule_editor.visible = false


func _on_rule_cancel() -> void:
	_rule_editor.visible = false
	_editing_rule_id = ""


func _on_rule_delete(id: String) -> void:
	if _editing_rule_id == id:
		_on_rule_cancel()
	AppData.remove_rule(id)


func _on_rule_enabled_toggled(pressed: bool, id: String) -> void:
	AppData.update_rule(id, {"enabled": pressed})


func _refresh_rules() -> void:
	UiKit.clear_children(_rules_box)
	var all_rules := AppData.get_rules()
	if all_rules.is_empty():
		_rules_status.text = "No authored rules."
	else:
		var enabled_count := 0
		for r: Dictionary in all_rules:
			if bool(r.get("enabled", true)):
				enabled_count += 1
		_rules_status.text = "%d rule(s), %d enabled — applied at synthesis time." % [
			all_rules.size(), enabled_count]
	var locked := RunMonitor.has_running()
	for r: Dictionary in all_rules:
		var id := String(r.get("id", ""))
		var row := HBoxContainer.new()
		_rules_box.add_child(row)
		var check := CheckButton.new()
		check.disabled = locked
		check.set_pressed_no_signal(bool(r.get("enabled", true)))
		check.toggled.connect(_on_rule_enabled_toggled.bind(id))
		row.add_child(check)
		var label := UiKit.status_label(_rule_summary(r))
		row.add_child(label)
		var edit := Button.new()
		edit.disabled = locked
		edit.text = "Edit"
		edit.pressed.connect(_on_edit_rule_pressed.bind(id))
		row.add_child(edit)
		var del := Button.new()
		del.disabled = locked
		del.text = "×"
		del.pressed.connect(_on_rule_delete.bind(id))
		row.add_child(del)


func _rule_summary(r: Dictionary) -> String:
	return "no \"%s\" within %d (%s) of \"%s\"" % [
		String(r.get("tag_a", "")), int(r.get("distance", 1)),
		String(r.get("metric", "chebyshev")), String(r.get("tag_b", ""))]
