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
	# Determinism: process images in stable id order regardless of load order.
	var ordered := images.duplicate()
	Ids.by_id(ordered)

	var parts_by_hash: Dictionary = {}   # hash hex -> Part
	var total_tiles := 0
	var time_start := Time.get_ticks_msec()

	# Progress: one counter per scanline across all participating images, so
	# single-image runs still produce a smooth fraction. Images too small to
	# contribute are excluded from the denominator, keeping the end at 1.0.
	var rows_total := 0
	for asset: ImageAssetData in ordered:
		if asset.image.get_width() >= tile_size.x \
				and asset.image.get_height() >= tile_size.y:
			rows_total += ceili(float(asset.image.get_height())
					/ float(stride.y))
	var rows_done := 0

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
			rows_done += 1
			report_progress.call(float(rows_done)
					/ float(maxi(rows_total, 1)))

	# Keep canonical source parts. AppData materializes selected transform
	# variants later so individual sources can opt in without re-extraction.
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


static func transform_image(source: Image, transform_key: String) -> Image:
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
