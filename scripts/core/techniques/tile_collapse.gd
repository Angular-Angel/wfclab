class_name TileCollapse extends Synthesizer
## Model-synthesis-style observe-and-propagate on a fixed grid of slots.
## Slots are laid out at the constraint grid step, so overlapping-window
## extractions (stride < tile size) produce an overlapping raster, and
## tile-grid extractions produce a tiling. Restarts from scratch on
## contradiction (no backtracking yet).


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
		{"key": "max_restarts", "label": "Max Restarts", "type": "int",
			"default": 30, "min": 0, "max": 1000},
	]


func synthesize(index: ConstraintIndex, params: Dictionary,
		rng: RandomNumberGenerator, report_progress: Callable) -> Dictionary:
	var started := Time.get_ticks_msec()
	var out_w: int = maxi(1, params.get("output_width", 24))
	var out_h: int = maxi(1, params.get("output_height", 16))
	var max_restarts: int = maxi(0, params.get("max_restarts", 30))

	if index.get_part_ids().is_empty():
		push_error("TileCollapse: no enabled parts.")
		return {}

	var step := _derive_step(index)
	var deltas := _derive_deltas(index, step)
	if deltas.is_empty():
		push_warning("TileCollapse: no usable offsets; output is unconstrained.")

	for restart in max_restarts + 1:
		report_progress.call(float(restart) / float(max_restarts + 1))
		var attempt := _attempt(index, rng, out_w, out_h, step, deltas)
		if not attempt.is_empty():
			var image := _render(index, attempt["assigned"], out_w, out_h, step)
			return {
				"image": image,
				"stats": {
					"restarts": restart,
					"elapsed_ms": Time.get_ticks_msec() - started,
					"output_slots": Vector2i(out_w, out_h),
					"step": step,
				},
			}
	push_warning("TileCollapse: exhausted restarts.")
	return {}


# --- Internals -----------------------------------------------------------------

func _derive_step(index: ConstraintIndex) -> Vector2i:
	## Pixel distance between adjacent slots: smallest positive constraint
	## offset per axis, falling back to the tile size.
	var step := index.tile_size
	var min_x := -1
	var min_y := -1
	for off: Vector2i in index.get_offsets():
		if off.x > 0 and (min_x == -1 or off.x < min_x):
			min_x = off.x
		if off.y > 0 and (min_y == -1 or off.y < min_y):
			min_y = off.y
	if min_x > 0:
		step.x = min_x
	if min_y > 0:
		step.y = min_y
	if step.x <= 0:
		step.x = 1
	if step.y <= 0:
		step.y = 1
	return step


func _derive_deltas(index: ConstraintIndex, step: Vector2i) -> Array[Vector2i]:
	## Constraint offsets converted to slot units; non-grid offsets skipped.
	var deltas: Array[Vector2i] = []
	for off: Vector2i in index.get_offsets():
		if off.x % step.x != 0 or off.y % step.y != 0:
			continue
		var d := Vector2i(off.x / step.x, off.y / step.y)
		if d != Vector2i.ZERO and not deltas.has(d):
			deltas.append(d)
	return deltas


func _attempt(index: ConstraintIndex, rng: RandomNumberGenerator,
		out_w: int, out_h: int, step: Vector2i,
		deltas: Array[Vector2i]) -> Dictionary:
	var n := out_w * out_h
	var template := {}
	for id: String in index.get_part_ids():
		template[id] = true

	var candidates: Array[Dictionary] = []
	candidates.resize(n)
	var assigned: Array[String] = []
	assigned.resize(n)
	for i in n:
		candidates[i] = template.duplicate()
		assigned[i] = ""

	while true:
		var slot := _pick_slot(candidates, assigned)
		if slot == -1:
			return {"assigned": assigned}
		var picked := _weighted_pick(candidates[slot], index, rng)
		candidates[slot] = {picked: true}
		assigned[slot] = picked
		if not _propagate(index, candidates, assigned, slot,
				out_w, out_h, step, deltas):
			return {}
	return {}


func _pick_slot(candidates: Array[Dictionary], assigned: Array[String]) -> int:
	## Most-constrained-first (the cheap stand-in for WFC's entropy rule).
	var best := -1
	var best_size := 1 << 30
	for i in candidates.size():
		if assigned[i] != "":
			continue
		var size: int = candidates[i].size()
		if size < best_size:
			best_size = size
			best = i
	return best


func _weighted_pick(options: Dictionary, index: ConstraintIndex,
		rng: RandomNumberGenerator) -> String:
	var total := 0.0
	for id: String in options:
		total += index.get_weight(id)
	var keys: Array = options.keys()
	if total <= 0.0 or keys.is_empty():
		return keys[rng.randi_range(0, keys.size() - 1)] if not keys.is_empty() else ""
	var r := rng.randf() * total
	for id: String in options:
		r -= index.get_weight(id)
		if r <= 0.0:
			return id
	return keys[keys.size() - 1]


func _propagate(index: ConstraintIndex, candidates: Array[Dictionary],
		assigned: Array[String], start: int, out_w: int, out_h: int,
		step: Vector2i, deltas: Array[Vector2i]) -> bool:
	## AC-3 style: when a slot's domain changes, revise neighboring domains.
	var queue: Array[int] = [start]
	while not queue.is_empty():
		var s: int = queue.pop_front()
		var sx := s % out_w
		var sy := s / out_w
		for delta: Vector2i in deltas:
			var qx := sx + delta.x
			var qy := sy + delta.y
			if qx < 0 or qx >= out_w or qy < 0 or qy >= out_h:
				continue
			var q := qy * out_w + qx
			if assigned[q] != "":
				continue
			var pixel_off := Vector2i(delta.x * step.x, delta.y * step.y)
			var allowed: Dictionary = {}
			if candidates[s].size() == 1:
				allowed = index.get_neighbors(
					candidates[s].keys()[0], pixel_off)
			else:
				for x: String in candidates[s]:
					var nb: Dictionary = index.get_neighbors(x, pixel_off)
					for y: String in nb:
						allowed[y] = true
			var new_q: Dictionary = {}
			for y: String in candidates[q]:
				if allowed.has(y):
					new_q[y] = true
			if new_q.size() != candidates[q].size():
				if new_q.is_empty():
					return false   # contradiction -> restart
				candidates[q] = new_q
				queue.append(q)
	return true


func _render(index: ConstraintIndex, assigned: Array[String],
		out_w: int, out_h: int, step: Vector2i) -> Image:
	var ts := index.tile_size
	var width := maxi(1, (out_w - 1) * step.x + ts.x)
	var height := maxi(1, (out_h - 1) * step.y + ts.y)
	var img := Image.create_empty(width, height, false, Image.FORMAT_RGBA8)
	for i in assigned.size():
		var part_id: String = assigned[i]
		if part_id == "":
			continue
		var src := index.get_part(part_id).pixel_data
		if src.get_format() != Image.FORMAT_RGBA8:
			src = src.duplicate()
			src.convert(Image.FORMAT_RGBA8)
		var x := (i % out_w) * step.x
		var y := (i / out_w) * step.y
		img.blit_rect(src, Rect2i(Vector2i.ZERO, src.get_size()), Vector2i(x, y))
	return img
