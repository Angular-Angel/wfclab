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
			"type": "int", "default": 0, "min": 0, "max": 8,
		},
	]


func decompose(images: Array[ImageAssetData], params: Dictionary,
		report_progress: Callable) -> Dictionary:
	var tile_size: Vector2i = params.get("tile_size", Vector2i(8, 8))
	var stride := Vector2i(maxi(1, params.get("stride", tile_size).x),
			maxi(1, params.get("stride", tile_size).y))
	var edge_handling: int = params.get("edge_handling", EdgeHandling.DISCARD_PARTIAL)
	var dedupe: bool = params.get("dedupe", true)
	var tolerance: int = params.get("dedupe_tolerance", 0)

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
						{"image_id": asset.id, "position": Vector2i(ox, oy)})
				else:
					var part := Part.new()
					part.setup(tile, key, asset.id, Vector2i(ox, oy))
					parts_by_hash[key] = part
				total_tiles += 1

				x += stride.x
			y += stride.y

		report_progress.call(float(i + 1) / maxi(1, ordered.size()))

	# Weight = occurrence count (the only derived value in phase 1).
	var parts: Array[Part] = []
	for part: Part in parts_by_hash.values():
		part.weight = part.occurrence_count()
		parts.append(part)

	return {
		"parts": parts,
		"stats": {
			"technique": get_id(),
			"total_tiles": total_tiles,
			"part_count": parts.size(),
			"elapsed_ms": Time.get_ticks_msec() - time_start,
		},
	}
