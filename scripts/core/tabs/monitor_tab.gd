class_name MonitorTab extends TabBase
## Inspector for technique runs: live progress for active runs and a
## permanent record of finished ones. Polls RunMonitor ~10x per second;
## the detail pane rebuilds only when the selected run's record changes.
##
## Copying: the report pane is a selectable RichTextLabel, with explicit
## copy buttons alongside. The buttons exist because Ctrl+C from a
## RichTextLabel is not dependable across Godot versions, and clicking
## any button would normally drop the selection before the pressed
## handler runs (see deselect_on_focus_loss_enabled below).

const POLL_SECONDS := 0.1

var _list: ItemList
var _detail_title: Label
var _detail_text: RichTextLabel
var _copy_report_button: Button
var _copy_selection_button: Button
var _copy_all_button: Button
var _row_ids: Array[int] = []
var _selected_id := -1
var _user_selected := false
var _detail_rev := -1
var _last_revision := -1
var _accum := 0.0
var _family_inspector: FamilyInspector = null


func _ready() -> void:
	super._ready()
	var split := _build_shell()

	var left := VBoxContainer.new()
	left.custom_minimum_size = Vector2(360.0, 0.0)
	split.add_child(left)
	left.add_child(UiKit.label("Runs (newest first)"))
	_list = ItemList.new()
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list.item_selected.connect(_on_item_selected.bind(true))
	left.add_child(_list)
	var button_row := HBoxContainer.new()
	left.add_child(button_row)
	_copy_all_button = UiKit.copy_button(_copy_all_text,
			"Copy All", "Copy a one-line summary of every run to the clipboard.")
	_copy_all_button.disabled = true
	button_row.add_child(_copy_all_button)
	button_row.add_child(_mk_button("Inspect Families",
            "Preview part families (with or without terrain merging) "
			+ "before running synthesis.",
			_open_family_inspector))
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button_row.add_child(spacer)
	button_row.add_child(_mk_button("Clear Finished", "",
			func() -> void: RunMonitor.clear_finished()))

	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_child(right)
	var header := HBoxContainer.new()
	right.add_child(header)
	_detail_title = Label.new()
	_detail_title.text = "No run selected."
	_detail_title.add_theme_font_size_override("font_size", 17)
	_detail_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_detail_title.clip_text = true
	header.add_child(_detail_title)
	_copy_report_button = UiKit.copy_button(_copy_report_text,
			"Copy Report", "Copy the full report of the selected run to the clipboard.",
			"No run selected")
	_copy_report_button.disabled = true
	header.add_child(_copy_report_button)
	_copy_selection_button = UiKit.copy_button(
			func() -> String: return _detail_text.get_selected_text(),
			"Copy Selection", "Copy the text currently selected in the report below.",
			"Nothing selected")
	_copy_selection_button.disabled = true
	header.add_child(_copy_selection_button)
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	right.add_child(scroll)
	_detail_text = RichTextLabel.new()
	_detail_text.bbcode_enabled = true
	_detail_text.selection_enabled = true
	# Clicking a Copy button moves focus off the label; without this the
	# selection is dropped before the button's pressed handler can read it.
	_detail_text.deselect_on_focus_loss_enabled = false
	_detail_text.fit_content = true
	_detail_text.scroll_active = false   # outer ScrollContainer scrolls
	_detail_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_detail_text.custom_minimum_size = Vector2(0.0, 40.0)
	scroll.add_child(_detail_text)


func _process(delta: float) -> void:
	_accum += delta
	if _accum < POLL_SECONDS:
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
	_retain_selection(_list, func() -> void:
		_list.clear()
		_row_ids.clear()
		for r: Dictionary in RunMonitor.get_run_list():
			var index := _list.add_item(_row_text(r))
			_row_ids.append(int(r["id"])))
	_copy_all_button.disabled = _row_ids.is_empty()


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
	var r := RunMonitor.get_run(_selected_id)
	if r.is_empty():
		_detail_rev = 0
		_detail_title.text = "No run selected."
		_detail_text.text = ""
		_copy_report_button.disabled = true
		_copy_selection_button.disabled = true
		return
	_detail_rev = int(r["rev"])
	_detail_title.text = "%s — #%d" % [r["title"], r["id"]]
	_copy_report_button.disabled = false
	_copy_selection_button.disabled = false
	_detail_text.text = _report_bbcode(r)


# --- Clipboard -------------------------------------------------------------------

func _copy_report_text() -> String:
	var r := RunMonitor.get_run(_selected_id)
	return "" if r.is_empty() else _plain_report(r)


func _copy_all_text() -> String:
	var parts := PackedStringArray()
	var runs := RunMonitor.get_run_list()
	parts.append("WFCLab runs (%d, newest first)" % runs.size())
	for r: Dictionary in runs:
		parts.append(_row_text(r))
	return "\n".join(parts)


# --- Report building ---------------------------------------------------------------
## One builder feeds both outputs: the clipboard gets the raw plain text,
## and the detail pane escapes it into BBCode (monospace + heading colors).

func _plain_report(r: Dictionary) -> String:
	var parts := PackedStringArray()
	parts.append("%s — #%d" % [r["title"], r["id"]])
	for line: Array in _build_report(r):
		parts.append(String(line[0]))
	return "\n".join(parts)


func _report_bbcode(r: Dictionary) -> String:
	var parts := PackedStringArray()
	for line: Array in _build_report(r):
		var text := _esc(String(line[0]))
		if bool(line[1]):
			text = "[color=#%s]%s[/color]" % [UiKit.HEADING_COLOR.to_html(false), text]
		parts.append(text)
	return "[code]%s[/code]" % "\n".join(parts)


func _build_report(r: Dictionary) -> Array:
	## One run as [line, is_heading] pairs.
	var lines: Array = []
	var status_line := String(r["status"])
	if not String(r["error"]).is_empty():
		status_line += " — " + String(r["error"])
	_kv(lines, "Kind", String(r["kind"]))
	_kv(lines, "Technique", String(r["technique_id"]))
	_kv(lines, "Thread", "worker thread" if r["thread"] == "worker"
			else "main thread")
	_kv(lines, "Status", status_line)
	_kv(lines, "Progress", "%d%%" % int(round(float(r["progress"]) * 100.0)))
	_kv(lines, "Elapsed", _fmt_ms(_elapsed_ms(r)))

	_section(lines, "Inputs")
	var inputs: Array = r["inputs"]
	if inputs.is_empty():
		lines.append(["  (none recorded)", false])
	for item: Variant in inputs:
		lines.append(["  · %s" % str(item), false])

	_section(lines, "Parameters")
	var params: Dictionary = r["params"]
	if params.is_empty():
		lines.append(["  (none)", false])
	for key: String in params:
		lines.append(["  %s = %s" % [key, _fmt_value(params[key])], false])

	if String(r["kind"]) == "session":
		_section(lines, "Live State")
		_kv(lines, "Status", String(r["live_status"]))
		_kv(lines, "Steps", str(r["steps"]))
	else:
		_section(lines, "Stages")
		for s: Dictionary in r["stages"]:
			lines.append(["  " + _stage_text(s), false])

	_section(lines, "Result")
	if not String(r["summary"]).is_empty():
		lines.append(["  " + String(r["summary"]), false])
	var stats: Dictionary = r["stats"]
	for key: String in stats:
		lines.append(["  %s: %s" % [key, _fmt_stat(stats[key])], false])
	return lines


func _kv(lines: Array, key: String, value: String) -> void:
	lines.append([(key + ":").rpad(14) + value, false])


func _section(lines: Array, title: String) -> void:
	lines.append(["", false])
	lines.append([title, true])


func _esc(s: String) -> String:
	## Escape BBCode delimiters; [lb]/[rb] render as literal brackets.
	return s.replace("[", "[lb]").replace("]", "[rb]")


# --- Formatting helpers -------------------------------------------------------------

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


func _mk_button(label: String, tooltip: String, handler: Callable) -> Button:
	var b := Button.new()
	b.text = label
	b.set_meta("label", label)
	if not tooltip.is_empty():
		b.tooltip_text = tooltip
	b.pressed.connect(handler)
	return b


func _open_family_inspector() -> void:
	if _family_inspector == null:
		_family_inspector = FamilyInspector.new()
		add_child(_family_inspector)
	_family_inspector.popup_centered(Vector2i(800, 580))
