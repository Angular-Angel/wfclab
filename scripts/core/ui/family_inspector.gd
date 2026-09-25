class_name FamilyInspector extends PopupPanel
## Pre-synthesis family preview. Computes families on a THROWAWAY index
## (never the shared AppData one), so it cannot disturb a running session.
## Toggle "Merge Terrain-Equivalent Parts" here to preview the collapse the
## matching Synthesizers option will produce before spending a run on it.

var _merge_check: CheckButton
var _depth: SpinBox
var _status: Label
var _list: ItemList
var _info: Label
var _members_box: HBoxContainer
var _index: ConstraintIndex = null


func _ready() -> void:
    var box := VBoxContainer.new()
    box.custom_minimum_size = Vector2(760.0, 520.0)
    add_child(box)

    var cfg_row := HBoxContainer.new()
    box.add_child(cfg_row)
    _merge_check = CheckButton.new()
    _merge_check.text = "Merge Terrain-Equivalent Parts"
    _merge_check.tooltip_text = "Preview of the Synthesizers option: parts " \
        + "with equal tags and equal edge terrain combine their constraints."
    cfg_row.add_child(_merge_check)
    cfg_row.add_child(UiKit.label("Edge Depth"))
    _depth = SpinBox.new()
    _depth.min_value = 1
    _depth.max_value = 8
    _depth.value = 1
    cfg_row.add_child(_depth)
    var compute := Button.new()
    compute.text = "Compute"
    compute.pressed.connect(_compute)
    cfg_row.add_child(compute)
    _status = UiKit.status_label("Builds a throwaway index; safe during a run.")
    cfg_row.add_child(_status)

    var split := HSplitContainer.new()
    split.size_flags_vertical = Control.SIZE_EXPAND_FILL
    split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    box.add_child(split)
    _list = ItemList.new()
    _list.custom_minimum_size = Vector2(360.0, 0.0)
    _list.size_flags_vertical = Control.SIZE_EXPAND_FILL
    _list.item_selected.connect(_on_family_selected)
    split.add_child(_list)

    var right := VBoxContainer.new()
    right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    split.add_child(right)
    _info = UiKit.note("Select a family.")
    right.add_child(_info)
    var scroll := ScrollContainer.new()
    scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
    scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    right.add_child(scroll)
    _members_box = HBoxContainer.new()
    _members_box.add_theme_constant_override("separation", 3)
    scroll.add_child(_members_box)


func _compute() -> void:
    _list.clear()
    UiKit.clear_children(_members_box)
    _index = ConstraintIndex.build(AppData.get_part_list(),
            AppData.get_constraint_list(), AppData.tag_edits,
            AppData.get_rules())
    if _index.get_part_ids().is_empty():
        _status.text = "No enabled parts."
        _index = null
        return
    var t0 := Time.get_ticks_msec()
    var step := _index.derive_step()
    var deltas := _index.derive_deltas(step)
    _index.prepare(deltas, step, {
        "terrain_merge": _merge_check.button_pressed,
        "terrain_merge_depth": int(_depth.value),
    })
    var buckets := {"1": 0, "2-4": 0, "5-16": 0, "17+": 0}
    for fi in _index.family_count:
        var n := (_index.family_members[fi] as PackedInt32Array).size()
        if n == 1: buckets["1"] += 1
        elif n <= 4: buckets["2-4"] += 1
        elif n <= 16: buckets["5-16"] += 1
        else: buckets["17+"] += 1
    _status.text = "%d parts → %d families (largest %d) · %d ms · sizes 1: %d, 2-4: %d, 5-16: %d, 17+: %d" % [
        _index.part_ids.size(), _index.family_count,
        _index.largest_family_size, Time.get_ticks_msec() - t0,
        buckets["1"], buckets["2-4"], buckets["5-16"], buckets["17+"]]
    for fi in _index.family_count:
        var members: PackedInt32Array = _index.family_members[fi]
        var idx := _list.add_item("#%d  %s  ×%d  w=%.0f" % [fi,
                _index.family_ids[fi], members.size(),
                _index.family_weights[fi]])
        _list.set_item_metadata(idx, fi)


func _on_family_selected(index: int) -> void:
    if _index == null:
        return
    UiKit.clear_children(_members_box)
    var fi: int = _list.get_item_metadata(index)
    var members: PackedInt32Array = _index.family_members[fi]
    _info.text = "Family #%d — representative %s — %d member(s), weight %.0f" % [
            fi, _index.family_ids[fi], members.size(),
            _index.family_weights[fi]]
    const CAP := 64
    for i in mini(members.size(), CAP):
        var pid: String = _index.part_ids[members[i]]
        var part := _index.get_part(pid)
        if part == null:
            continue
        var t := UiKit.preview(Vector2(32.0, 32.0))
        t.texture = part.get_texture()
        t.tooltip_text = pid
        _members_box.add_child(t)
    if members.size() > CAP:
        _members_box.add_child(UiKit.label("…+%d more" % (members.size() - CAP)))