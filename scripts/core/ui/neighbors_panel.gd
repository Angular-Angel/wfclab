class_name NeighborsPanel extends VBoxContainer
## The Neighbors section of the Parts tab: per-offset neighbor thumbnails
## from the current ConstraintIndex, capped for readability. Clicking a
## neighbor emits part_selected for the tab's click-through.

signal part_selected(part: Part)

const MAX_NEIGHBOR_OFFSETS := 12
const MAX_NEIGHBORS_PER_OFFSET := 24


func show_part(part: Part) -> void:
	UiKit.clear_children(self)
	if part == null or AppData.parts.is_empty():
		return

	var index := AppData.get_constraint_index()
	var offsets := index.get_offsets()
	if offsets.is_empty():
		var none := Label.new()
		none.text = "No constraints extracted."
		add_child(none)
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
		var nb: Dictionary = index.get_neighbors(part.id, off)
		if nb.is_empty():
			continue
		shown_offsets += 1

		# Strongest neighbors first.
		var ids: Array = nb.keys()
		ids.sort_custom(func(a: String, b: String) -> bool:
			return nb[a] > nb[b])

		var header := Label.new()
		header.text = "offset (%s, %s) — %s part(s)" % [off.x, off.y, ids.size()]
		add_child(header)

		var grid := GridContainer.new()
		grid.columns = 8
		grid.add_theme_constant_override("h_separation", 2)
		grid.add_theme_constant_override("v_separation", 2)
		add_child(grid)

		for i in mini(ids.size(), MAX_NEIGHBORS_PER_OFFSET):
			var nb_part: Part = index.get_part(ids[i])
			if nb_part == null:
				continue
			var button := Button.new()
			button.custom_minimum_size = Vector2(40.0, 40.0)
			button.icon = nb_part.get_texture()
			button.expand_icon = true
			button.tooltip_text = "%s\nweight: %s" % [nb_part.id, nb[ids[i]]]
			button.pressed.connect(part_selected.emit.bind(nb_part))
			grid.add_child(button)

		if ids.size() > MAX_NEIGHBORS_PER_OFFSET:
			var more := Label.new()
			more.text = "  … and %s more" % (ids.size() - MAX_NEIGHBORS_PER_OFFSET)
			add_child(more)
