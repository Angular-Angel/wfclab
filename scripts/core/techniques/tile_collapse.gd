class_name TileCollapse extends Synthesizer
## Model-synthesis-style observe-and-propagate on a fixed grid of slots.
## Slots are laid out at the constraint grid step, so overlapping-window
## extractions (stride < tile size) produce an overlapping raster, and
## tile-grid extractions produce a tiling. A configurable recovery strategy
## handles contradictions: stop, restart, or chronological backtracking.
##
## Batch synthesize() runs a Session to completion, so a given seed yields
## identical output whether run in batch or stepped interactively.
##
## The solver operates on FAMILY ints (see ConstraintIndex): parts with
## identical post-rule behavior are merged, and each observation resolves
## its family to a concrete member part, occurrence-weighted, so variety
## and source frequencies are preserved in the output.


func get_id() -> StringName:
	return &"tile_collapse"


func get_display_name() -> String:
	return "Tile Collapse (WFC-style)"


func get_parameter_specs() -> Array[Dictionary]:
	return [
		{"key": "output_width", "label": "Output Width", "type": "int",
			"default": 24, "min": 1, "max": 256},
		{"key": "output_height", "label": "Output Height", "type": "int",
			"default": 16, "min": 1, "max": 256},
		{"key": "contradiction_strategy", "label": "Contradiction Strategy", "type": "enum",
			"default": 1, "options": ["Stop immediately", "Restart", "Backtracking"]},
		{"key": "max_recovery_attempts", "label": "Max Recovery Attempts", "type": "int",
			"default": 30, "min": 0, "max": 1000},
		{"key": "unknown_free", "label": "Unobserved = Free", "type": "bool",
			"default": true},
		{"key": "terrain_merge", "label": "Merge Terrain-Equivalent Parts",
			"type": "bool", "default": false},
		{"key": "terrain_merge_depth", "label": "Merge Edge Depth",
			"type": "int", "default": 1, "min": 1, "max": 8},
	]


func synthesize(index: ConstraintIndex, params: Dictionary,
		rng: RandomNumberGenerator, report_progress: Callable) -> Dictionary:
	var session := create_session(index, params, rng)
	while not session.is_finished():
		session.step()
		report_progress.call(session.get_progress())
	return session.get_result()


func supports_stepping() -> bool:
	return true


func create_session(index: ConstraintIndex, params: Dictionary,
		rng: RandomNumberGenerator) -> SynthesisSession:
	return TileCollapseSession.new(index, params, rng)


# --- Internals (static so Session can drive them) -------------------------------

@warning_ignore("integer_division")
static func _render(index: ConstraintIndex, assigned: Array[String],
		out_w: int, out_h: int, step: Vector2i) -> Image:
	## assigned holds concrete member part ids, so rendering is unchanged
	## by family compression.
	var ts := index.tile_size
	var width := maxi(1, (out_w - 1) * step.x + ts.x)
	var height := maxi(1, (out_h - 1) * step.y + ts.y)
	var img := Image.create_empty(width, height, false, Image.FORMAT_RGBA8)
	for i in assigned.size():
		var part_id: String = assigned[i]
		if part_id == "":
			continue
		var src := ImageOps.to_rgba8(index.get_part(part_id).pixel_data)
		var x := (i % out_w) * step.x
		var y := (i / out_w) * step.y
		img.blit_rect(src, Rect2i(Vector2i.ZERO, src.get_size()), Vector2i(x, y))
	return img
