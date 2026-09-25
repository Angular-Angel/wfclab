class_name AdjacencyExtractor extends ConstraintTechnique
## Adjacency constraints: two parts observed next to each other in an image,
## at a fixed grid step. Assumes the decomposition was a grid with
## stride == tile size; for overlapping grids use Custom Step = stride.

enum StepMode { TILE_SIZE, CUSTOM }
enum EdgeEvidence { IGNORE, WRAP, BORDER }


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
		{
			"key": "edge_evidence", "label": "Image Edge Evidence", "type": "enum",
			"default": EdgeEvidence.IGNORE,
			"options": ["Ignore", "Wrap (tiling)", "Border-anchored"],
		},
	]


func extract(parts: Array[Part], images: Array[ImageAssetData],
		params: Dictionary, report_progress: Callable,
		_terrain_classes: Array = []) -> Array[Constraint]:
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

	var edge_mode: int = params.get("edge_evidence", EdgeEvidence.IGNORE)
	var variants: Dictionary = {}   # canonical_id -> {transform_key -> part_id}
	for part: Part in parts:
		for source: Dictionary in part.transform_sources:
			var canonical_id: String = source["canonical_id"]
			var transform_key: String = source["transform_key"]
			if not variants.has(canonical_id):
				variants[canonical_id] = {}
			variants[canonical_id][transform_key] = part.id

	# Position lookup: image_id -> {Vector2i -> part_id}, plus each image's
	# tile-grid extent (tile coordinates) for wrap/border decisions.
	var by_image: Dictionary = {}
	var grid_rect: Dictionary = {}   # img_id -> Rect2i in tile coords
	var seen_samples: Dictionary = {} # "image|x,y|canonical" -> true
	for part: Part in parts:
		for occ: Dictionary in part.occurrences:
			var img_id: String = occ["image_id"]
			var pos: Vector2i = occ["position"]
			var canonical_id: String = occ.get("canonical_id", part.canonical_id)
			var sample_key := "%s|%d,%d|%s" % [img_id, pos.x, pos.y, canonical_id]
			if seen_samples.has(sample_key):
				continue   # every variant carries source provenance; read it once
			seen_samples[sample_key] = true
			if not by_image.has(img_id):
				by_image[img_id] = {}
			# Variants share source occurrences. Map each source location back
			# to the canonical tile that produced it, then expand its relation
			# into the transform variants selected for that canonical tile.
			by_image[img_id][pos] = canonical_id
			@warning_ignore("integer_division")
			var tc := Vector2i(pos.x / step.x, pos.y / step.y)
			var r: Rect2i = grid_rect.get(img_id, Rect2i(tc, Vector2i.ONE))
			var lo := r.position.min(tc)
			var hi := (r.position + r.size - Vector2i.ONE).max(tc)
			grid_rect[img_id] = Rect2i(lo, hi - lo + Vector2i.ONE)

	# Progress: every recorded tile position participates in pair extraction,
	# so one global counter over positions gives a smooth 0→1 fraction even
	# for single-image runs.
	var positions_total := 0
	for grid_map: Dictionary in by_image.values():
		positions_total += grid_map.size()
	var positions_done := 0

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
					@warning_ignore("integer_division")
					var ntc := Vector2i(npos.x / step.x, npos.y / step.y)
					var rect: Rect2i = grid_rect[img_id]
					match edge_mode:
						EdgeEvidence.WRAP:
							# Seam pair, unless the gap is an interior hole.
							if rect.has_point(ntc):
								continue
							var wx := rect.position.x + posmod(
									ntc.x - rect.position.x, rect.size.x)
							var wy := rect.position.y + posmod(
									ntc.y - rect.position.y, rect.size.y)
							var wn := Vector2i(wx * step.x, wy * step.y)
							if not grid.has(wn):
								continue   # ragged grid; skip rather than guess
							npos = wn
						EdgeEvidence.BORDER:
							# Real border only: the missing neighbor must be
							# outside the tile rect, not an interior hole.
							@warning_ignore("integer_division")
							var ptc := Vector2i(pos.x / step.x, pos.y / step.y) \
									+ Vector2i(signi(offset.x), signi(offset.y))
							if rect.has_point(ptc):
								continue
							_record_outside_transforms(aggregate, variants, a_id,
									offset, img_id, pos, npos)
							continue
						_:
							continue
				var b_id: String = grid[npos]
				_record_pair_transforms(aggregate, variants, directional,
						a_id, b_id, offset, img_id, pos, npos)

			# Pair extraction uses canonical directions so every real pair is
			# visited once. Border evidence is directional, though: inspecting
			# only canonical directions would anchor the right/bottom edges but
			# leave the matching left/top edges unconstrained. Record the
			# inverse directions only for virtual-outside neighbors.
			if edge_mode == EdgeEvidence.BORDER:
				for offset: Vector2i in offsets:
					var edge_offset := -offset
					var edge_pos := pos + edge_offset
					if grid.has(edge_pos):
						continue
					@warning_ignore("integer_division")
					var edge_tc := Vector2i(
							edge_pos.x / step.x, edge_pos.y / step.y)
					var rect: Rect2i = grid_rect[img_id]
					if rect.has_point(edge_tc):
						continue   # interior gap: no outside evidence
					_record_outside_transforms(aggregate, variants, a_id, edge_offset,
							img_id, pos, edge_pos)

			positions_done += 1
			report_progress.call(float(positions_done)
					/ float(maxi(positions_total, 1)))

	var list: Array = aggregate.values()
	Ids.by_id(list)
	result.assign(list)
	for c: Constraint in result:
		c.weight = c.evidence.size()
	return result


func _record_pair_transforms(aggregate: Dictionary, variants: Dictionary,
		directional: bool, a_id: String, b_id: String, offset: Vector2i,
		img_id: String, pos: Vector2i, npos: Vector2i) -> void:
	var a_variants: Dictionary = variants.get(a_id, {})
	var b_variants: Dictionary = variants.get(b_id, {})
	for key: String in a_variants:
		if not b_variants.has(key):
			continue
		var c := _get_or_create(aggregate, directional, a_variants[key],
				b_variants[key], _transform_offset(offset, key))
		c.evidence.append({"image_id": img_id, "positions": [pos, npos]})


func _record_outside_transforms(aggregate: Dictionary, variants: Dictionary,
		a_id: String, offset: Vector2i, img_id: String, pos: Vector2i,
		npos: Vector2i) -> void:
	for key: String in (variants.get(a_id, {}) as Dictionary):
		_record_outside(aggregate, variants[a_id][key], _transform_offset(offset, key),
				img_id, pos, npos)


func _transform_offset(offset: Vector2i, key: String) -> Vector2i:
	match key:
		# Image.rotate_90(true) is clockwise in screen coordinates: a source
		# relation (x, y) maps to (-y, x), including virtual outside edges.
		"rot90": return Vector2i(-offset.y, offset.x)
		"rot180": return -offset
		"rot270": return Vector2i(offset.y, -offset.x)
		"flip_h": return Vector2i(-offset.x, offset.y)
		"flip_v": return Vector2i(offset.x, -offset.y)
	return offset


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
		key = "adj|%s|%s|%d,%d" % [first, second, offset.x, offset.y]

	if aggregate.has(key):
		return aggregate[key]

	var c := Constraint.new()
	c.type = &"adjacency"
	c.params = {"offset": offset, "symmetric": not directional}
	c.participants = [
		{"part_id": first, "role": "a"},
		{"part_id": second, "role": "b"},
	]
	# Readable id built from participants + offset: debuggable by eye.
	c.id = Ids.constraint(first, second, offset)
	aggregate[key] = c
	return c


func _record_outside(aggregate: Dictionary, a_id: String, offset: Vector2i,
		img_id: String, pos: Vector2i, npos: Vector2i) -> void:
	## a_id was observed with nothing beyond it at offset: record the
	## virtual outside tile as its neighbor in that direction.
	var key := "out|%s|%d,%d" % [a_id, offset.x, offset.y]
	var c: Constraint
	if aggregate.has(key):
		c = aggregate[key]
	else:
		c = Constraint.new()
		c.type = &"adjacency"
		c.params = {"offset": offset, "to_outside": true}
		c.participants = [
			{"part_id": a_id, "role": "a"},
			{"part_id": ConstraintIndex.OUTSIDE, "role": "out"},
		]
		c.id = "c_%s_out_%d_%d" % [Ids.short(a_id), offset.x, offset.y]
		aggregate[key] = c
	c.evidence.append({"image_id": img_id, "positions": [pos, npos]})
