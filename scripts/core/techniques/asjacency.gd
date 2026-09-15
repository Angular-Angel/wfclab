class_name AdjacencyExtractor extends ConstraintTechnique
## Adjacency constraints: two parts observed next to each other in an image,
## at a fixed grid step. Assumes the decomposition was a grid with
## stride == tile size; for overlapping grids use Custom Step = stride.

enum StepMode { TILE_SIZE, CUSTOM }


func get_id() -> StringName:
	return &"adjacency"


func get_display_name() -> String:
	return "Adjacency"


func get_parameter_specs() -> Array[Dictionary]:
	return [
		{
			"key": "neighborhood", "label": "Neighborhood", "type": "enum",
			"default": 0, "options": ["N4", "N8"],
		},
		{
			"key": "directional", "label": "Directional", "type": "bool",
			"default": true,
		},
		{
			"key": "step_mode", "label": "Grid Step", "type": "enum",
			"default": StepMode.TILE_SIZE, "options": ["Tile Size", "Custom"],
		},
		{
			"key": "custom_step", "label": "Custom Step", "type": "vector2i",
			"default": Vector2i(8, 8), "min": 1, "max": 64,
		},
	]


func extract(parts: Array[Part], images: Array[ImageAssetData],
		params: Dictionary, report_progress: Callable) -> Array[Constraint]:
	var result: Array[Constraint] = []
	if parts.is_empty():
		return result

	var directional: bool = params.get("directional", true)
	var use_n8: bool = params.get("neighborhood", 0) == 1
	var step: Vector2i
	if int(params.get("step_mode", StepMode.TILE_SIZE)) == StepMode.CUSTOM:
		var cs: Vector2i = params.get("custom_step", Vector2i(8, 8))
		step = Vector2i(maxi(1, cs.x), maxi(1, cs.y))
	else:
		step = parts[0].size   # grid tiles are uniform; see class comment

	# Position lookup: image_id -> {Vector2i -> part_id}
	var by_image: Dictionary = {}
	for part: Part in parts:
		for occ: Dictionary in part.occurrences:
			var img_id: String = occ["image_id"]
			if not by_image.has(img_id):
				by_image[img_id] = {}
			by_image[img_id][occ["position"]] = part.id

	# Positive-x offsets only: each adjacent pair is visited exactly once
	# with a canonical direction, so no double counting.
	var offsets: Array[Vector2i] = [
		Vector2i(step.x, 0),
		Vector2i(0, step.y),
	]
	if use_n8:
		offsets.append(Vector2i(step.x, step.y))
		offsets.append(Vector2i(step.x, -step.y))

	var aggregate: Dictionary = {}   # key String -> Constraint

	var image_ids: Array = by_image.keys()
	image_ids.sort()
	for img_index in image_ids.size():
		var img_id: String = image_ids[img_index]
		var grid: Dictionary = by_image[img_id]

		# Deterministic position order: row-major.
		var positions: Array[Vector2i] = []
		positions.assign(grid.keys())
		positions.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
			if a.y != b.y:
				return a.y < b.y
			return a.x < b.x)

		for pos: Vector2i in positions:
			var a_id: String = grid[pos]
			for offset: Vector2i in offsets:
				var npos := pos + offset
				if not grid.has(npos):
					continue
				var b_id: String = grid[npos]
				var c := _get_or_create(aggregate, directional, a_id, b_id, offset)
				c.evidence.append({
					"image_id": img_id,
					"positions": [pos, npos],
				})

		report_progress.call(float(img_index + 1) / image_ids.size())

	var list: Array = aggregate.values()
	list.sort_custom(func(a: Constraint, b: Constraint) -> bool:
		return a.id < b.id)
	result.assign(list)
	for c: Constraint in result:
		c.weight = c.evidence.size()
	return result


func _get_or_create(aggregate: Dictionary, directional: bool,
		a_id: String, b_id: String, offset: Vector2i) -> Constraint:
	var first := a_id
	var second := b_id
	var key: String
	if directional:
		key = "adj|%s>%s|%d,%d" % [a_id, b_id, offset.x, offset.y]
	else:
		if b_id < a_id:
			first = b_id
			second = a_id
		key = "adj|%s|%s" % [first, second]

	if aggregate.has(key):
		return aggregate[key]

	var c := Constraint.new()
	c.type = &"adjacency"
	c.params = {"offset": offset}
	c.participants = [
		{"part_id": first, "role": "a"},
		{"part_id": second, "role": "b"},
	]
	# Readable id built from participants + offset: debuggable by eye.
	c.id = "c_%s_%s_%d_%d" % [
		first.substr(2, 6), second.substr(2, 6), offset.x, offset.y]
	aggregate[key] = c
	return c
