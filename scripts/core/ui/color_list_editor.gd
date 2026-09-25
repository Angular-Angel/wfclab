class_name ColorListEditor extends HBoxContainer
## Swatch-list editor shared by the Terrain Keys class editor and the
## auto-tag rule editor: one ColorPickerButton per color plus
## "+ color"/"− color" buttons. The widget owns its swatches and reports
## changes as a hex array ("rrggbb", the unified save format — decoders
## also accept "#rrggbb", so old saves keep loading).

signal colors_changed(colors: Array)

const MAX_COLORS := 8
const LIMIT_TEXT := "Color limit (8) reached — remove one first."

var _colors_box := HBoxContainer.new()
var _buttons: Array[ColorPickerButton] = []
var _colors: Array = []


func _init() -> void:
	add_child(_colors_box)
	var add_btn := Button.new()
	add_btn.text = "+ color"
	add_btn.pressed.connect(func() -> void: add_color(Color.WHITE))
	add_child(add_btn)
	var del_btn := Button.new()
	del_btn.text = "− color"
	del_btn.pressed.connect(_on_remove_pressed)
	add_child(del_btn)


## Current colors as hex strings (no "#"). Treat as read-only.
func colors() -> Array:
	return _colors.duplicate()


## Refresh from stored hex strings; never emits. Invalid entries fall
## back to white, matching the tabs' old from-hex behavior.
func set_colors(hex_colors: Array) -> void:
	for b: ColorPickerButton in _buttons:
		_colors_box.remove_child(b)
		b.free()
	_buttons.clear()
	_colors.clear()
	for c: Variant in hex_colors:
		var col := to_color(String(c))
		_buttons.append(_make_swatch(col))
		_colors.append(col.to_html(false))


## Programmatic add (the palette-pick path). False when at the cap —
## the caller surfaces ColorListEditor.LIMIT_TEXT.
func add_color(c: Color) -> bool:
	if _buttons.size() >= MAX_COLORS:
		return false
	_buttons.append(_make_swatch(c))
	_colors.append(c.to_html(false))
	colors_changed.emit(colors())
	return true


static func to_color(s: String) -> Color:
	var t := s if s.begins_with("#") else "#" + s
	return Color(t) if Color.html_is_valid(t) else Color.WHITE


func _make_swatch(c: Color) -> ColorPickerButton:
	var b := ColorPickerButton.new()
	b.custom_minimum_size = UiKit.SWATCH
	b.color = c
	b.color_changed.connect(func(col: Color) -> void:
		_colors[b.get_index()] = col.to_html(false)
		colors_changed.emit(colors()))
	_colors_box.add_child(b)
	return b


func _on_remove_pressed() -> void:
	if _buttons.is_empty():
		return
	var b: ColorPickerButton = _buttons.pop_back()
	_colors.pop_back()
	_colors_box.remove_child(b)
	b.free()
	colors_changed.emit(colors())
