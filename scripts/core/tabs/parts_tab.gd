class_name PartsTab extends Control
## Browse the parts from the last decomposition run. Minimal phase-1 version:
## thumbnail grid + inspector with occurrence list.

const THUMB := Vector2(72.0, 72.0)
const MAX_SHOWN := 500   # naive grid; revisit if real corpora need virtualization

signal occurrence_selected(image_id: String, position: Vector2i, size: Vector2i)

var _grid: GridContainer
var _grid_status: Label
var _preview: TextureRect
var _info: Label
var _occurrences: ItemList
var _selected: Part = null
var _occurrence_data: Array[Dictionary] = []


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

	# --- Right: inspector ---------------------------------------------------
	var right := VBoxContainer.new()
	right.custom_minimum_size = Vector2(280.0, 0.0)
	split.add_child(right)

	right.add_child(_mk_label("Selected Part"))
	_preview = TextureRect.new()
	_preview.custom_minimum_size = Vector2(256.0, 256.0)
	_preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_preview.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	right.add_child(_preview)

	_info = Label.new()
	_info.text = "Nothing selected"
	right.add_child(_info)

	right.add_child(_mk_label("Occurrences"))
	_occurrences = ItemList.new()
	_occurrences.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_occurrences.item_selected.connect(_on_occurrence_selected)
	right.add_child(_occurrences)

	AppData.parts_changed.connect(_rebuild)
	_rebuild()


func _mk_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l


func _rebuild() -> void:
	_selected = null
	for child in _grid.get_children():
		child.queue_free()
	_occurrences.clear()
	_preview.texture = null
	_info.text = "Nothing selected"

	var parts: Array[Part] = AppData.get_part_list()
	if parts.is_empty():
		_grid_status.text = "No parts. Run a decomposition first."
		return

	# Most-seen first — the interesting parts rise to the top.
	parts.sort_custom(func(a: Part, b: Part) -> bool:
		return a.occurrence_count() > b.occurrence_count())

	var stats: Dictionary = AppData.last_run_stats
	_grid_status.text = "%d parts (%d tiles extracted, %d ms)" % [
		parts.size(), stats.get("total_tiles", 0), stats.get("elapsed_ms", 0)]

	for i in mini(parts.size(), MAX_SHOWN):
		_add_part_button(parts[i])
	if parts.size() > MAX_SHOWN:
		_grid_status.text += "  — showing first %d" % MAX_SHOWN
	#_audit_parts()
	#_dump_near_duplicate_evidence()


func _add_part_button(part: Part) -> void:
	var button := Button.new()
	button.custom_minimum_size = THUMB
	button.icon = part.get_texture()
	button.expand_icon = true
	button.tooltip_text = "%s\n%d occurrence(s)" % [part.id, part.occurrence_count()]
	button.pressed.connect(_on_part_selected.bind(part))
	_grid.add_child(button)


func _on_part_selected(part: Part) -> void:
	_selected = part
	_preview.texture = part.get_texture()
	_info.text = "%s\n%d × %d\noccurrences: %d\nweight: %s" % [
		part.id, part.size.x, part.size.y,
		part.occurrence_count(), part.get_effective_weight()]

	_occurrence_data = part.occurrences.duplicate()
	_occurrences.clear()
	for occ: Dictionary in part.occurrences:
		var pos: Vector2i = occ["position"]
		_occurrences.add_item("%s  (%d, %d)" % [
			AppData.image_name(occ["image_id"]), pos.x, pos.y])


func _on_occurrence_selected(index: int) -> void:
	if index < 0 or index >= _occurrence_data.size() or _selected == null:
		return
	var occ: Dictionary = _occurrence_data[index]
	occurrence_selected.emit(occ["image_id"], occ["position"], _selected.size)


func _audit_parts() -> void:
	var parts: Array[Part] = AppData.get_part_list()
	print("audit: %d parts" % parts.size())

	# Would parts merge if alpha were ignored?
	var by_rgb: Dictionary = {}
	for p: Part in parts:
		var copy := p.pixel_data.duplicate()
		copy.convert(Image.FORMAT_RGB8)
		var h := PixelHash.of(copy)
		by_rgb[h] = by_rgb.get(h, 0) + 1
	print("audit: ignoring alpha -> %d unique" % by_rgb.size())

	# How many pairs are near-identical (any channel diff <= 2)?
	var near := 0
	for i in parts.size():
		for j in range(i + 1, parts.size()):
			var a: Image = parts[i].pixel_data
			var b: Image = parts[j].pixel_data
			if a.get_size() != b.get_size() or a.get_format() != b.get_format():
				continue
			if _max_diff(a, b) <= 2:
				near += 1
	print("audit: near-duplicate pairs: %d" % near)
	
func _dump_near_duplicate_evidence() -> void:
	var parts: Array[Part] = AppData.get_part_list()

	# --- Self-test 1: is the hasher deterministic and consistent? ----------
	var any_part: Part = parts[0]
	var h1 := PixelHash.of(any_part.pixel_data)
	var h2 := PixelHash.of(any_part.pixel_data)
	print("self-test: hash stable: ", h1 == h2,
		"  matches stored: ", h1 == any_part.canonical_hash)

	# --- Self-test 2: does a part equal the source region it came from? ----
	var occ: Dictionary = any_part.occurrences[0]
	var asset: ImageAssetData = AppData.images[occ["image_id"]]
	var pos: Vector2i = occ["position"]
	var re_extracted := asset.image.get_region(
		Rect2i(pos, any_part.pixel_data.get_size()))
	print("self-test: re-extraction identical: ",
		PixelHash.of(re_extracted) == any_part.canonical_hash)

	# --- Evidence dump: first near-duplicate pair ---------------------------
	for i in parts.size():
		for j in range(i + 1, parts.size()):
			var a: Image = parts[i].pixel_data
			var b: Image = parts[j].pixel_data
			if a.get_size() != b.get_size() or a.get_format() != b.get_format():
				continue
			if _max_diff(a, b) > 2:
				continue

			print("--- pair: %s vs %s ---" % [parts[i].id, parts[j].id])
			print("format: %d   size: %s" % [a.get_format(), a.get_size()])
			print("occ a: %s" % str(parts[i].occurrences[0]["position"]))
			print("occ b: %s" % str(parts[j].occurrences[0]["position"]))
			var diffs := 0
			for y in a.get_height():
				for x in a.get_width():
					var ca := a.get_pixel(x, y)
					var cb := b.get_pixel(x, y)
					if ca != cb:
						diffs += 1
						if diffs <= 8:   # cap the spam
							print("  (%d,%d)  a=(%.3f,%.3f,%.3f,%.3f)  b=(%.3f,%.3f,%.3f,%.3f)"
								% [x, y, ca.r, ca.g, ca.b, ca.a, cb.r, cb.g, cb.b, cb.a])
			print("  total differing pixels: %d of %d" % [diffs, a.get_width() * a.get_height()])
			return   # first pair only


func _max_diff(a: Image, b: Image) -> int:
	var pa := a.get_data()
	var pb := b.get_data()
	var worst := 0
	for k in pa.size():
		worst = maxi(worst, absi(pa[k] - pb[k]))
		if worst > 2:
			return worst   # early out
	return worst
