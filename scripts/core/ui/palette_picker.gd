class_name PalettePicker extends PopupPanel
## The palette popup shared by the Parts and Terrain Keys tabs: source
## selector, status line, swatch grid, and the cached "All tiles" palette
## (invalidated on AppData.parts_changed). Picked colors are reported via
## color_picked; pick guards (color caps, already-present) stay with the
## owning tab, which surfaces failures through set_status().

signal color_picked(hex: String)

const POPUP_SIZE := Vector2i(360, 440)
const BUCKET_BITS := 4
const CAP := 64

var _sources: Array = []
var _cached_index := -1
var _cache: Dictionary = {}
var _cache_valid := false
var _source_button := OptionButton.new()
var _status := UiKit.status_label("")
var _grid := GridContainer.new()


func _init() -> void:
	AppData.parts_changed.connect(func() -> void: _cache_valid = false)


## Each source: {label: String, images: Callable -> Array[Image],
## empty: String = status shown when the source yields no images}.
## cached_index is the source whose palette is cached across opens.
func setup(sources: Array, cached_index := -1,
		hint := "Click swatches to pick colors; close when done.") -> void:
	_sources = sources
	_cached_index = cached_index
	var box := VBoxContainer.new()
	add_child(box)
	var head := HBoxContainer.new()
	box.add_child(head)
	var source_label := Label.new()
	source_label.text = "Source"
	head.add_child(source_label)
	for s: Dictionary in sources:
		_source_button.add_item(String(s["label"]))
	_source_button.item_selected.connect(func(_i: int) -> void: _populate())
	head.add_child(_source_button)
	head.add_child(_status)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(320.0, 320.0)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(scroll)
	_grid.columns = 8
	_grid.add_theme_constant_override("h_separation", 3)
	_grid.add_theme_constant_override("v_separation", 3)
	scroll.add_child(_grid)
	box.add_child(UiKit.note(hint))


## Opens centered. initial >= 0 pre-selects that source (programmatically,
## so no item_selected signal); otherwise the previous selection is kept.
func open(initial := -1) -> void:
	if initial >= 0:
		_source_button.select(initial)
	_populate()
	popup_centered(POPUP_SIZE)


## Lets the owning tab surface guard failures where the user is looking.
func set_status(text: String) -> void:
	_status.text = text


static func all_tile_images() -> Array[Image]:
	var images: Array[Image] = []
	for p: Part in AppData.get_part_list():
		if p.pixel_data != null:
			images.append(p.pixel_data)
	return images


func _populate() -> void:
	# Smoke check (R9): this was queue_free; the grid is only rebuilt from
	# open()/source changes — never inside a swatch's own signal — so free()
	# is safe here.
	UiKit.clear_children(_grid)
	var idx := _source_button.selected
	if idx < 0:
		# Nothing selected yet (first open): behave like the last source,
		# matching the old if/else branches that treated -1 as "else".
		idx = _sources.size() - 1
	var src: Dictionary = _sources[idx]
	var images: Array = src["images"].call()
	if images.is_empty():
		_status.text = String(src.get("empty", "No tiles to sample."))
		return
	var result: Dictionary
	if idx == _cached_index and _cache_valid:
		result = _cache
	else:
		result = PaletteExtractor.palette_of_images(images, BUCKET_BITS, CAP)
		if idx == _cached_index:
			_cache = result
			_cache_valid = true
	var entries: Array = result["entries"]
	var total := int(result["total"])
	if entries.is_empty():
		_status.text = "No opaque pixels found."
		return
	if total <= entries.size():
		_status.text = "%d color(s)" % total
	else:
		_status.text = "%d distinct colors — showing top %d by frequency" % [
			total, entries.size()]
	for e: Dictionary in entries:
		var swatch := Button.new()
		swatch.custom_minimum_size = UiKit.SWATCH_SQUARE
		swatch.focus_mode = Control.FOCUS_NONE
		var sb := StyleBoxFlat.new()
		sb.bg_color = e["color"]
		swatch.add_theme_stylebox_override("normal", sb)
		swatch.add_theme_stylebox_override("hover", sb)
		swatch.add_theme_stylebox_override("pressed", sb)
		swatch.tooltip_text = "#%s  — %s px" % [e["hex"], e["count"]]
		swatch.pressed.connect(color_picked.emit.bind(String(e["hex"])))
		_grid.add_child(swatch)
