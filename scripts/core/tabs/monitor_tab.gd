class_name MonitorTab extends Control
## Inspector for technique runs: live progress for active runs and a
## permanent record of finished ones. Polls RunMonitor ~10x per second;
## the detail pane rebuilds only when the selected run's record changes.

var _list: ItemList
var _detail_box: VBoxContainer
var _row_ids: Array[int] = []
var _selected_id := -1
var _user_selected := false
var _detail_rev := -1
var _last_revision := -1
var _accum := 0.0


func _ready() -> void:
	var split := HSplitContainer.new()
	split.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(split)

	var left := VBoxContainer.new()
	left.custom_minimum_size = Vector2(360.0, 0.0)
	split.add_child(left)
	left.add_child(_mk_label("Runs (newest first)"))
	_list = ItemList.new()
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list.item_selected.connect(_on_item_selected.bind(true))
	left.add_child(_list)
	var clear_button := Button.new()
	clear_button.text = "Clear Finished"
	clear_button.pressed.connect(func() -> void: RunMonitor.clear_finished())
	left.add_child(clear_button)

	var right_scroll := ScrollContainer.new()
	right_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	right_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	split.add_child(right_scroll)
	_detail_box = VBoxContainer.new()
	_detail_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_detail_box.add_theme_constant_override("separation", 4)
	right_scroll.add_child(_detail_box)
	_rebuild_detail()


func _process(delta: float) -> void:
	_accum += delta
	if _accum < 0.1:
		return
	_accum = 0.0
	if RunMonitor.revision == _last_revision:
		return
	_last_revision = RunMonitor.revision
	_rebuild_list()
	if _row_ids.is_empty():
		if _selected_id != -1:
			_selected_id = -1
			_detail_rev = -1
			_rebuild_detail()
		return
	# Auto-follow the newest run until the user picks one explicitly.
	if not _user_selected or _row_ids.find(_selected_id) == -1:
		_list.select(0)
		_on_item_selected(0, false)
		return
	_rebuild_detail_if_changed()


func _rebuild_list() -> void:
	var keep := _selected_id
	_list.clear()
	_row_ids.clear()
	for r: Dictionary in RunMonitor.get_run_list():
		var index := _list.add_item(_row_text(r))
		_row_ids.append(int(r["id"]))
		if int(r["id"]) == keep:
			_list.select(index)


func _row_text(r: Dictionary) -> String:
	var pct := "%d%%" % int(round(float(r["progress"]) * 100.0))
	return "#%d  %s  ·  %s · %s · %s" % [
		r["id"], r["title"], r["status"], pct, _fmt_ms(_elapsed_ms(r))]


func _on_item_selected(index: int, user: bool) -> void:
	if index < 0 or index >= _row_ids.size():
		return
	_selected_id = _row_ids[index]
	_user_selected = user
	_detail_rev = -1
	_rebuild_detail()


func _rebuild_detail_if_changed() -> void:
	var r := RunMonitor.get_run(_selected_id)
	if r.is_empty() or int(r["rev"]) == _detail_rev:
		return
	_rebuild_detail()


func _rebuild_detail() -> void:
	for child in _detail_box.get_children():
		child.free()
	var r := RunMonitor.get_run(_selected_id)
	if r.is_empty():
		_detail_rev = 0
		_detail_box.add_child(_mk_label("No run selected."))
		return
	_detail_rev = int(r["rev"])

	var header := _mk_label("%s — #%d" % [r["title"], r["id"]])
	header.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	header.add_theme_font_size_override("font_size", 17)
	_detail_box.add_child(header)
	_add_kv("Kind", String(r["kind"]))
	_add_kv("Technique", String(r["technique_id"]))
	_add_kv("Thread", "worker thread" if r["thread"] == "worker"
			else "main thread")
	var status_line := String(r["status"])
	if not String(r["error"]).is_empty():
		status_line += " — " + String(r["error"])
	_add_kv("Status", status_line)
	_add_kv("Progress", "%d%%" % int(round(float(r["progress"]) * 100.0)))
	_add_kv("Elapsed", _fmt_ms(_elapsed_ms(r)))

	_mk_heading("Inputs")
	var inputs: Array = r["inputs"]
	if inputs.is_empty():
		_detail_box.add_child(_mk_label("  (none recorded)"))
	for item: Variant in inputs:
		_detail_box.add_child(_mk_label("  · %s" % str(item)))

	_mk_heading("Parameters")
	var params: Dictionary = r["params"]
	if params.is_empty():
		_detail_box.add_child(_mk_label("  (none)"))
	for key: String in params:
		_detail_box.add_child(_mk_label(
				"  %s = %s" % [key, _fmt_value(params[key])]))

	if String(r["kind"]) == "session":
		_mk_heading("Live State")
		_add_kv("Status", String(r["live_status"]))
		_add_kv("Steps", str(r["steps"]))
	else:
		_mk_heading("Stages")
		for s: Dictionary in r["stages"]:
			_detail_box.add_child(_mk_label("  " + _stage_text(s)))

	_mk_heading("Result")
	if not String(r["summary"]).is_empty():
		_detail_box.add_child(_mk_label("  " + String(r["summary"])))
	var stats: Dictionary = r["stats"]
	for key: String in stats:
		_detail_box.add_child(_mk_label(
				"  %s: %s" % [key, _fmt_stat(stats[key])]))


func _stage_text(s: Dictionary) -> String:
	var label := String(s["label"])
	match String(s["status"]):
		"pending":
			return "· %s — pending" % label
		"running":
			var pct := int(round(float(s["fraction"]) * 100.0))
			var rate := _stage_rate(s)
			var rate_text := "" if rate <= 0.05 else " · %.1f%%/s" % rate
			return "▶ %s — %d%%%s · %s" % [label, pct, rate_text,
					_fmt_ms(_stage_elapsed(s))]
		"done":
			var note := String(s["note"])
			var suffix := "" if note.is_empty() else " — " + note
			return "✓ %s — %s%s" % [label, _fmt_ms(_stage_elapsed(s)), suffix]
		"failed":
			return "✗ %s — failed" % label
		"canceled":
			return "⏹ %s — canceled" % label
	return label


func _elapsed_ms(r: Dictionary) -> int:
	var start := int(r["started_ms"])
	if start <= 0:
		return 0
	var stop := int(r["ended_ms"])
	var now := stop if stop > 0 else Time.get_ticks_msec()
	return now - start


func _stage_elapsed(s: Dictionary) -> int:
	var start := int(s["started_ms"])
	if start <= 0:
		return 0
	var stop := int(s["ended_ms"])
	var now := stop if stop > 0 else Time.get_ticks_msec()
	return now - start


func _stage_rate(s: Dictionary) -> float:
	var ms := _stage_elapsed(s)
	if ms <= 0:
		return 0.0
	return float(s["fraction"]) / (float(ms) / 1000.0)


func _fmt_ms(ms: int) -> String:
	if ms < 1000:
		return "%d ms" % ms
	return "%.1f s" % (ms / 1000.0)


func _fmt_value(v: Variant) -> String:
	if v is bool:
		return "on" if v else "off"
	return str(v)


func _fmt_stat(v: Variant) -> String:
	var text := ("%.2f" % v) if v is float else str(v)
	if text.length() > 120:
		text = text.substr(0, 117) + "..."
	return text


func _add_kv(key: String, value: String) -> void:
	var row := HBoxContainer.new()
	var k := _mk_label(key)
	k.custom_minimum_size = Vector2(110.0, 0.0)
	k.modulate = Color(1.0, 1.0, 1.0, 0.6)
	row.add_child(k)
	var v := _mk_label(value)
	v.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(v)
	_detail_box.add_child(row)


func _mk_heading(text: String) -> void:
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0.0, 6.0)
	_detail_box.add_child(spacer)
	var l := _mk_label(text)
	l.modulate = Color(1.0, 1.0, 1.0, 0.75)
	_detail_box.add_child(l)


func _mk_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l
