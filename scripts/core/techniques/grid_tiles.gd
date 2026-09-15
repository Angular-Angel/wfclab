class_name GridTiles extends DecompositionTechnique
## Fixed-size rectangular tiles on a regular (possibly overlapping) grid.

enum EdgeHandling { DISCARD_PARTIAL, CLAMP }


func get_id() -> StringName:
	return &"grid_tiles"


func get_display_name() -> String:
	return "Grid Tiles"


func get_parameter_specs() -> Array[Dictionary]:
	return [
		{
			"key": "tile_size", "label": "Tile Size", "type": "vector2i",
			"default": Vector2i(8, 8), "min": 1, "max": 128,
		},
		{
			"key": "stride", "label": "Stride", "type": "vector2i",
			"default": Vector2i(8, 8), "min": 1, "max": 128,
		},
		{
			"key": "edge_handling", "label": "Edge Handling", "type": "enum",
			"default": EdgeHandling.DISCARD_PARTIAL,
			"options": ["Discard Partial", "Clamp"],
		},
		{
			"key": "dedupe", "label": "Dedupe Identical Tiles", "type": "bool",
			"default": true,
		},
		{
			"key": "dedupe_tolerance", "label": "Dedupe Tolerance",
			"type": "int", "default": 0, "min": 0, "max": 256,
		},
		{"key": "rotation_0", "label": "Rotation 0°", "type": "bool", "default": true},
		{"key": "rotation_90", "label": "Rotation 90°", "type": "bool", "default": false},
		{"key": "rotation_180", "label": "Rotation 180°", "type": "bool", "default": false},
		{"key": "rotation_270", "label": "Rotation 270°", "type": "bool", "default": false},
		{"key": "reflect_horizontal", "label": "Reflect Horizontal", "type": "bool", "default": false},
		{"key": "reflect_vertical", "label": "Reflect Vertical", "type": "bool", "default": false},
	]


func decompose(images: Array[ImageAssetData], params: Dictionary,
		report_progress: Callable) -> Dictionary:
	var tile_size: Vector2i = params.get("tile_size", Vector2i(8, 8))
	var stride := Vector2i(maxi(1, params.get("stride", tile_size).x),
			maxi(1, params.get("stride", tile_size).y))
	var edge_handling: int = params.get("edge_handling", EdgeHandling.DISCARD_PARTIAL)
	var dedupe: bool = params.get("dedupe", true)
	var tolerance: int = params.get("dedupe_tolerance", 0)
	var transforms: Array[String] = []
	if params.get("rotation_0", true): transforms.append("identity")
	if params.get("rotation_90", false): transforms.append("rot90")
	if params.get("rotation_180", false): transforms.append("rot180")
	if params.get("rotation_270", false): transforms.append("rot270")
	if params.get("reflect_horizontal", false): transforms.append("flip_h")
	if params.get("reflect_vertical", false): transforms.append("flip_v")
	# The two enabled reflection generators close under composition. Include the
	# 180° member if it was not already requested as a rotation.
	if params.get("reflect_horizontal", false) and params.get("reflect_vertical", false) \
			and not transforms.has("rot180"):
		transforms.append("rot180")

	# Determinism: process images in stable id order regardless of load order.
	var ordered := images.duplicate()
	ordered.sort_custom(func(a: ImageAssetData, b: ImageAssetData) -> bool:
		return a.id < b.id)

	var parts_by_hash: Dictionary = {}   # hash hex -> Part
	var total_tiles := 0
	var time_start := Time.get_ticks_msec()

	for i in ordered.size():
		var asset: ImageAssetData = ordered[i]
		var img := asset.image
		var w := img.get_width()
		var h := img.get_height()
		if w < tile_size.x or h < tile_size.y:
			continue

		var y := 0
		while y < h:
			var x := 0
			while x < w:
				# Origin of this tile; CLAMP pulls partial-edge tiles inward.
				var ox := x
				var oy := y
				if edge_handling == EdgeHandling.CLAMP:
					ox = mini(x, w - tile_size.x)
					oy = mini(y, h - tile_size.y)

				var tile := img.get_region(Rect2i(ox, oy, tile_size.x, tile_size.y))
				var key := PixelHash.of(tile, tolerance)

				if dedupe and parts_by_hash.has(key):
					(parts_by_hash[key] as Part).occurrences.append(
							{"image_id": asset.id, "position": Vector2i(ox, oy),
							"canonical_id": (parts_by_hash[key] as Part).id})
				else:
					var part := Part.new()
					part.setup(tile, key, asset.id, Vector2i(ox, oy))
					parts_by_hash[key] = part
				total_tiles += 1

				x += stride.x
			y += stride.y

		report_progress.call(float(i + 1) / maxi(1, ordered.size()))

	# Weight = occurrence count (the only derived value in phase 1). Source
	# tiles are retained temporarily to generate the requested variants; only
	# the selected transforms become output parts.
	var source_parts: Array[Part] = []
	for part: Part in parts_by_hash.values():
		part.weight = part.occurrence_count()
		source_parts.append(part)

	# Each enabled symmetry becomes a separately editable part. Identical
	# transforms collapse naturally by exact pixel hash.
	var parts: Array[Part] = []
	var variants_by_hash: Dictionary = {} # hash -> Part
	for base: Part in source_parts:
		for transform_key: String in transforms:
			if (transform_key == "rot90" or transform_key == "rot270") \
					and base.size.x != base.size.y:
				push_warning("GridTiles: 90° rotations require square tiles; skipped.")
				continue
			var variant_image := base.pixel_data if transform_key == "identity" \
					else _transform_image(base.pixel_data, transform_key)
			var variant_hash := PixelHash.of(variant_image, tolerance)
			if variants_by_hash.has(variant_hash):
				var existing: Part = variants_by_hash[variant_hash]
				existing.transform_sources.append({
					"canonical_id": base.id, "transform_key": transform_key})
				_append_canonical_occurrences(existing, base)
				# Preserve every canonical source sample when two different source
				# tiles yield the same transformed pixels. The helper filters and
				# snapshots occurrences, so a self-symmetric tile cannot grow its
				# own array while it is being iterated.
				continue
			var variant := base if transform_key == "identity" else Part.new()
			if transform_key != "identity":
				variant.pixel_data = variant_image
				variant.size = variant_image.get_size()
				variant.canonical_hash = variant_hash
				variant.id = "p_" + variant_hash.substr(0, 12)
				variant.canonical_id = base.id
			variant.occurrences = base.occurrences.duplicate(true)
			variant.weight = base.weight
			variant.transform_key = transform_key
			variant.transform_sources = [{
				"canonical_id": base.id, "transform_key": transform_key}]
			variants_by_hash[variant_hash] = variant
			parts.append(variant)

	return {
		"parts": parts,
		"stats": {
			"technique": get_id(),
			"total_tiles": total_tiles,
			"part_count": parts.size(),
			"elapsed_ms": Time.get_ticks_msec() - time_start,
		},
	}


func _transform_image(source: Image, transform_key: String) -> Image:
	var result := source.duplicate()
	match transform_key:
		# ClockDirection.CLOCKWISE is paired with the (x, y)->(-y, x) relation
		# mapping in AdjacencyExtractor._transform_offset().
		"rot90": result.rotate_90(ClockDirection.CLOCKWISE)
		"rot180": result.rotate_180()
		"rot270": result.rotate_90(ClockDirection.COUNTERCLOCKWISE)
		"flip_h": result.flip_x()
		"flip_v": result.flip_y()
	return result


func _append_canonical_occurrences(target: Part, source: Part) -> void:
	if target == source:
		return
	var source_occurrences := source.occurrences.duplicate(true)
	for occ: Dictionary in source_occurrences:
		if occ.get("canonical_id", source.id) != source.id:
			continue
		target.occurrences.append(occ)
	target.weight = target.occurrence_count()
