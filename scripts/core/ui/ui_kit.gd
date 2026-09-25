class_name UiKit extends RefCounted
## Shared UI constants and widget factories. Static-only: the UI-side
## counterpart of the util/ classes, replacing the per-site magic numbers
## and copy-pasted construction boilerplate across the tabs.

const THUMB := Vector2(72, 72)
const PREVIEW := Vector2(160, 160)
const PREVIEW_SMALL := Vector2(96, 96)
const SWATCH := Vector2(34, 26)
const SWATCH_SQUARE := Vector2(30, 30)

## BBCode heading tint in the Monitor report (consume via to_html(false)).
const HEADING_COLOR := Color("#8fa8bf")
const DIFF_RED := Color(1.0, 0.25, 0.25)
const HIGHLIGHT_AMBER := Color(1.0, 0.9, 0.2)
const HIGHLIGHT_AMBER_CURSOR := Color(1.0, 0.9, 0.3)
const HINT_ALPHA := 0.6

const PARAM_LABEL_W := 110.0
const POPUP_RATIO := 0.7
const DEBOUNCE_S := 0.3
const INDENT := 16.0


static func label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l


## Text button wired to its handler; the caller adds it to the layout
## and sets any extras (disabled state, min size) on the return value.
static func button(text: String, handler: Callable, tooltip := "") -> Button:
	var b := Button.new()
	b.text = text
	if not tooltip.is_empty():
		b.tooltip_text = tooltip
	b.pressed.connect(handler)
	return b


## GridContainer configured for thumbnail cells: one shared spacing
## policy for the parts grid, palette swatches, neighbor strips, and the
## slot picker.
static func thumb_grid(columns: int, hsep := 4, vsep := 4) -> GridContainer:
	var g := GridContainer.new()
	g.columns = columns
	g.add_theme_constant_override("h_separation", hsep)
	g.add_theme_constant_override("v_separation", vsep)
	return g


## Status line + Copy button in one row (the run tabs' pattern). The
## label is `row.status`; `get_text` is evaluated lazily on click.
static func status_copy_row(get_text: Callable,
		tooltip := "Copy the run status line to the clipboard.") -> StatusRow:
	var row := StatusRow.new()
	row.status = status_label("")
	row.status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(row.status)
	row.add_child(copy_button(get_text, "Copy", tooltip))
	return row


class StatusRow extends HBoxContainer:
	var status: Label


## A wrapping status line. Horizontal EXPAND_FILL is visually neutral
## inside VBoxContainers and lets HBox-housed lines (palette headers, rule
## rows) take the leftover width, matching today's per-site flags.
static func status_label(text: String) -> Label:
	var l := label(text)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return l


## A longer explanatory note: plain wrapping label, same look as today.
static func note(text: String) -> Label:
	var l := label(text)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return l


## Scroll + content box. The factory adds the ScrollContainer to `parent`
## and returns the inner VBox (the scroll is reachable as its parent).
## min_width == 0 anchors the scroll FULL_RECT (root-hosted case);
## otherwise the scroll gets that minimum width and vertical expand.
static func scroll_panel(parent: Control, min_width := 0.0) -> VBoxContainer:
	var scroll := ScrollContainer.new()
	if min_width > 0.0:
		scroll.custom_minimum_size = Vector2(min_width, 0.0)
		scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	else:
		scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	parent.add_child(scroll)
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(box)
	return box


## The tab-root HSplitContainer shell.
static func split_shell() -> HSplitContainer:
	var split := HSplitContainer.new()
	split.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	return split


## Image preview: ignore-size expand + nearest filtering, keep-aspect fit
## unless keep_aspect is false (fill). Callers add textures/size flags/
## input wiring per site after the factory returns.
static func preview(min_size: Vector2, keep_aspect := true) -> TextureRect:
	var t := TextureRect.new()
	if min_size != Vector2.ZERO:
		t.custom_minimum_size = min_size
	t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	t.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	t.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED if keep_aspect \
			else TextureRect.STRETCH_SCALE
	return t


## Free all children now. Only for rebuild paths that run OUTSIDE the
## cleared container's own signal callbacks — free() during signal
## emission is refused by the engine (queue_free there instead).
static func clear_children(node: Node) -> void:
	for child in node.get_children():
		child.free()


## Filesystem FileDialog. OPEN_FILES wires files_selected (the callable
## receives a PackedStringArray); every other mode wires file_selected
## (a single path String). Caller adds the dialog to the tree.
static func file_dialog(mode: FileDialog.FileMode, filters: PackedStringArray,
		on_selected: Callable) -> FileDialog:
	var dialog := FileDialog.new()
	dialog.file_mode = mode
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.filters = filters
	if mode == FileDialog.FILE_MODE_OPEN_FILES:
		dialog.files_selected.connect(on_selected)
	else:
		dialog.file_selected.connect(on_selected)
	return dialog


## ConfirmationDialog builder; caller pops it via popup_centered().
static func confirm(owner: Node, title: String, text: String,
		ok_text: String, on_confirmed: Callable) -> ConfirmationDialog:
	var dialog := ConfirmationDialog.new()
	dialog.title = title
	dialog.dialog_text = text
	dialog.ok_button_text = ok_text
	dialog.confirmed.connect(on_confirmed)
	owner.add_child(dialog)
	return dialog


## Copy-to-clipboard button (Monitor's pattern, shared): copies
## get_text()'s result and swaps the label to "Copied ✓" briefly. An
## empty result copies nothing and flashes empty_text instead.
static func copy_button(get_text: Callable, label := "Copy",
		tooltip := "Copy to the clipboard.",
		empty_text := "Nothing to copy") -> Button:
	var b := Button.new()
	b.text = label
	b.set_meta("label", label)
	b.tooltip_text = tooltip
	b.pressed.connect(func() -> void:
		var text: String = get_text.call()
		if text.is_empty():
			_flash_button(b, empty_text)
			return
		DisplayServer.clipboard_set(text)
		_flash_button(b, "Copied ✓"))
	return b


static func _flash_button(button: Button, feedback: String) -> void:
	## Swap in feedback text briefly, then restore the canonical label.
	button.text = feedback
	var tree := button.get_tree()
	if tree == null:
		button.text = String(button.get_meta("label"))
		return
	await tree.create_timer(1.2).timeout
	if is_instance_valid(button):
		button.text = String(button.get_meta("label"))
