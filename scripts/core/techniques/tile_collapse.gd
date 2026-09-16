class_name TileCollapse extends Synthesizer
## Model-synthesis-style observe-and-propagate on a fixed grid of slots.
## Slots are laid out at the constraint grid step, so overlapping-window
## extractions (stride < tile size) produce an overlapping raster, and
## tile-grid extractions produce a tiling. A configurable recovery strategy
## handles contradictions: stop, restart, or chronological backtracking.
##
## Batch synthesize() runs a Session to completion, so a given seed yields
## identical output whether run in batch or stepped interactively.


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
	return Session.new(index, params, rng)


# --- Internals (static so Session can drive them) -------------------------------

static func _derive_step(index: ConstraintIndex) -> Vector2i:
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


@warning_ignore("integer_division")
static func _derive_deltas(index: ConstraintIndex, step: Vector2i) -> Array[Vector2i]:
	## Constraint offsets converted to slot units; non-grid offsets skipped.
	var deltas: Array[Vector2i] = []
	for off: Vector2i in index.get_offsets():
		if off.x % step.x != 0 or off.y % step.y != 0:
			continue
		var d := Vector2i(off.x / step.x, off.y / step.y)
		if d != Vector2i.ZERO and not deltas.has(d):
			deltas.append(d)
	return deltas


static func _pick_slot(candidates: Array[Dictionary],
		assigned: Array[String]) -> int:
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


static func _weighted_pick(options: Dictionary, index: ConstraintIndex,
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


@warning_ignore("integer_division")
static func _propagate(index: ConstraintIndex, candidates: Array[Dictionary],
		assigned: Array[String], out_w: int, out_h: int, step: Vector2i,
		deltas: Array[Vector2i], queue: Array[int], single: bool,
		unknown_free: bool, bordered: bool, trace: Array = []) -> bool:
	## AC-3 style: when a slot's domain changes, revise neighboring domains.
	## The queue persists across calls; with single=true exactly one queue
	## entry is processed per call. With unknown_free, an empty neighbor set
	## means "never observed" (this pipeline has no negative evidence), so
	## the edge is left unconstrained instead of wiping the domain.
	while not queue.is_empty():
		var s: int = queue.pop_front()
		var sx := s % out_w
		var sy := s / out_w
		for delta: Vector2i in deltas:
			var qx := sx + delta.x
			var qy := sy + delta.y
			var pixel_off := Vector2i(delta.x * step.x, delta.y * step.y)
			if qx < 0 or qx >= out_w or qy < 0 or qy >= out_h:
				# The constraint extractor may only have evidence for selected
				# directions (for example its canonical +X/+Y scan). Do not
				# turn a missing directional observation into an impossible edge.
				# N8 evidence is directional: a diagonal slot relation must be
				# supported by the exact diagonal outside relation, even where
				# only one coordinate crosses the output boundary.
				if bordered and _has_outside_evidence(index, pixel_off):
					# This direction faces the output edge: every candidate
					# must be a tile observed touching a source border here.
					var keep: Dictionary = {}
					for x: String in candidates[s]:
						if index.get_neighbors(x, pixel_off).has(
								ConstraintIndex.OUTSIDE):
							keep[x] = true
					if keep.size() != candidates[s].size():
						if keep.is_empty():
							if trace != null:
								trace.append({"at": s, "border": true,
									"delta": pixel_off, "allowed": [],
									"domain": candidates[s].keys()})
							return false
						candidates[s] = keep
						queue.append(s)
				continue
			var q := qy * out_w + qx
			if assigned[q] != "":
				continue
			var allowed: Dictionary = {}
			var unconstrained := false
			if candidates[s].size() == 1:
				allowed = index.get_neighbors(
						candidates[s].keys()[0], pixel_off)
				unconstrained = unknown_free and allowed.is_empty()
			else:
				for x: String in candidates[s]:
					var nb: Dictionary = index.get_neighbors(x, pixel_off)
					if nb.is_empty():
						if unknown_free:
							unconstrained = true
							break   # this value supports anything
						continue
					for y: String in nb:
						allowed[y] = true
			if unconstrained:
				continue
			var new_q: Dictionary = {}
			for y: String in candidates[q]:
				if allowed.has(y):
					new_q[y] = true
			if new_q.size() != candidates[q].size():
				if new_q.is_empty():
					if trace != null:
						trace.append({
							"at": q, "from": s,
							"delta": Vector2i(delta.x * step.x, delta.y * step.y),
							"allowed": allowed.keys(),
							"domain": candidates[q].keys(),
						})
					return false   # contradiction -> restart
				candidates[q] = new_q
				queue.append(q)
		if single:
			return true
	return true


static func _has_outside_evidence(index: ConstraintIndex, offset: Vector2i) -> bool:
	for id: String in index.get_part_ids():
		if index.get_neighbors(id, offset).has(ConstraintIndex.OUTSIDE):
			return true
	return false


@warning_ignore("integer_division")
static func _render(index: ConstraintIndex, assigned: Array[String],
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


class Session extends SynthesisSession:
	## One resumable TileCollapse run. Batch synthesize() drives this class,
	## so RNG consumption (one _weighted_pick per observation) is identical
	## in both modes and a seed reproduces the same output either way.

	var _index: ConstraintIndex
	var _rng: RandomNumberGenerator
	var _out_w: int
	var _out_h: int
	var _cell: Vector2i
	var _deltas: Array[Vector2i]
	var _contradiction_strategy: int
	var _max_recovery_attempts: int
	var _unknown_free: bool

	var candidates: Array[Dictionary] = []
	var assigned: Array[String] = []
	var _queue: Array[int] = []
	var _decisions: Array[Dictionary] = []
	var _pinned: Dictionary = {} # slot -> part id; persists across restarts
	var last_slot := -1
	var recovery_attempts := 0
	var contradictions := 0
	var restarts := 0
	var backtracks := 0
	var steps_taken := 0
	var _collapsed := 0
	var _active_ms := 0
	var last_rejection := ""
	var last_wipe := ""
	var _bordered := false

	func _init(index: ConstraintIndex, params: Dictionary,
			rng: RandomNumberGenerator) -> void:
		_index = index
		_rng = rng
		_out_w = maxi(1, params.get("output_width", 24))
		_out_h = maxi(1, params.get("output_height", 16))
		_contradiction_strategy = clampi(params.get("contradiction_strategy", 1), 0, 2)
		_max_recovery_attempts = maxi(0, params.get("max_recovery_attempts", 30))
		_unknown_free = params.get("unknown_free", true)
		if _index.get_part_ids().is_empty():
			push_error("TileCollapse: no enabled parts.")
			phase = Phase.FAILED
			return
		_cell = TileCollapse._derive_step(_index)
		_deltas = TileCollapse._derive_deltas(_index, _cell)
		_bordered = _index.has_outside()
		if _deltas.is_empty():
			push_warning("TileCollapse: no usable offsets; output is unconstrained.")
		_reset_attempt()


	func _reset_attempt() -> bool:
		var template := {}
		for id: String in _index.get_part_ids():
			template[id] = true
		candidates.clear()
		assigned.clear()
		candidates.resize(_out_w * _out_h)
		assigned.resize(_out_w * _out_h)
		for i in candidates.size():
			candidates[i] = template.duplicate()
			assigned[i] = ""
		_queue.clear()
		_decisions.clear()
		last_slot = -1
		_collapsed = 0
		for slot: int in _pinned:
			var part_id: String = _pinned[slot]
			candidates[slot] = {part_id: true}
			assigned[slot] = part_id
			_collapsed += 1
			_queue.append(slot)
		if _bordered:
			for i in candidates.size():
				if not _queue.has(i):
					_queue.append(i)
		if not _queue.is_empty():
			var trace: Array = []
			if not TileCollapse._propagate(_index, candidates, assigned,
					_out_w, _out_h, _cell, _deltas, _queue, false,
					_unknown_free, _bordered, trace):
				last_wipe = _describe_wipe(trace[0]) \
						if not trace.is_empty() else "border setup"
				phase = Phase.FAILED
				return false
		return true


	func step() -> bool:
		## One observation plus propagation to a fixpoint. If a micro-step
		## left a cascade half-done, this finishes it first.
		return _advance(false)


	func micro_step() -> bool:
		## One observation OR one propagation queue entry — the wavefront
		## becomes watchable, and contradictions happen in plain sight.
		return _advance(true)


	func _advance(micro: bool) -> bool:
		if is_finished():
			return false
		steps_taken += 1
		var t0 := Time.get_ticks_msec()
		var keep_going := _advance_inner(micro)
		_active_ms += Time.get_ticks_msec() - t0
		return keep_going


	func _advance_inner(micro: bool) -> bool:
		if _queue.is_empty():
			var slot := TileCollapse._pick_slot(candidates, assigned)
			if slot == -1:
				phase = Phase.DONE
				return false
			var picked := TileCollapse._weighted_pick(candidates[slot], _index, _rng)
			_decisions.append(_snapshot_decision(slot, picked))
			candidates[slot] = {picked: true}
			assigned[slot] = picked
			last_slot = slot
			_collapsed += 1
			_queue.append(slot)
			if micro:
				return true   # leave the cascade pending so it can be watched
		var trace: Array = []
		if not TileCollapse._propagate(_index, candidates, assigned,
				_out_w, _out_h, _cell, _deltas, _queue, micro, _unknown_free, _bordered,
				trace):
			if not trace.is_empty():
				last_wipe = _describe_wipe(trace[0])
			_recover_from_contradiction()
			if is_finished():
				return false
		return true


	func _snapshot_decision(slot: int, picked: String) -> Dictionary:
		var snap_c: Array[Dictionary] = []
		snap_c.assign(candidates.duplicate(true))
		var snap_a: Array[String] = []
		snap_a.assign(assigned.duplicate())
		var snap_q: Array[int] = []
		snap_q.assign(_queue.duplicate())
		return {"slot": slot, "rejected": picked, "candidates": snap_c, "assigned": snap_a,
			"queue": snap_q, "collapsed": _collapsed}


	func _recover_from_contradiction() -> void:
		contradictions += 1
		if _contradiction_strategy == 0:
			phase = Phase.FAILED
			return
		if recovery_attempts >= _max_recovery_attempts:
			push_warning("TileCollapse: exhausted recovery attempts.")
			phase = Phase.FAILED
			return
		recovery_attempts += 1
		if _contradiction_strategy == 1:
			restarts += 1
			_reset_attempt()
			return
		_backtrack()


	func _backtrack() -> void:
		## Restore automatic decisions in reverse order. User pins are not on this
		## stack, so recovery never silently removes an explicit user choice.
		while not _decisions.is_empty():
			var decision: Dictionary = _decisions.pop_back()
			candidates = decision["candidates"]
			assigned = decision["assigned"]
			_queue = decision["queue"]
			_collapsed = decision["collapsed"]
			var slot: int = decision["slot"]
			var rejected: String = decision["rejected"]
			assigned[slot] = ""
			candidates[slot].erase(rejected)
			if candidates[slot].is_empty():
				continue
			_queue.append(slot)
			backtracks += 1
			return
		last_wipe = "no automatic decision remains; pinned constraints are incompatible"
		phase = Phase.FAILED


	func get_result() -> Dictionary:
		if phase != Phase.DONE:
			return {}
		return {
			"image": TileCollapse._render(
					_index, assigned, _out_w, _out_h, _cell),
			"stats": {
				"restarts": restarts,
				"backtracks": backtracks,
				"contradictions": contradictions,
				"recovery_attempts": recovery_attempts,
				"elapsed_ms": _active_ms,
				"output_slots": Vector2i(_out_w, _out_h),
				"step": _cell,
				"steps": steps_taken,
			},
		}


	@warning_ignore("integer_division")
	func get_status() -> String:
		if phase == Phase.FAILED:
			return "Failed: %s" % last_wipe
		if phase == Phase.DONE:
			return "Done: %d slots, %d contradictions (%d restarts, %d backtracks), %d steps." % [
					_out_w * _out_h, contradictions, restarts, backtracks, steps_taken]
		var base := "%s — %d/%d collapsed" % [
				_strategy_name(), _collapsed, _out_w * _out_h]
		if last_slot == -1:
			return base
		return base + " — last: %s" % Vector2i(
				last_slot % _out_w, last_slot / _out_w)


	func _strategy_name() -> String:
		match _contradiction_strategy:
			0: return "Stop on contradiction"
			1: return "Restart %d/%d" % [recovery_attempts, _max_recovery_attempts]
			2: return "Backtrack %d/%d" % [recovery_attempts, _max_recovery_attempts]
		return "Unknown recovery strategy"


	func get_progress() -> float:
		return float(_collapsed) / float(_out_w * _out_h)


	func get_preview() -> Image:
		return TileCollapse._render(_index, assigned, _out_w, _out_h, _cell)


	@warning_ignore("integer_division")
	func get_entropy_image() -> Image:
		## Slot-space map: white = collapsed, warm = few candidates,
		## cool = many. Dims are output_slots, not pixels.
		var img := Image.create_empty(
				_out_w, _out_h, false, Image.FORMAT_RGBA8)
		for i in candidates.size():
			var col: Color
			if assigned[i] != "":
				col = Color(0.95, 0.95, 0.95)
			else:
				var t := clampf(candidates[i].size() / 8.0, 0.0, 1.0)
				col = Color(1.0, 0.3, 0.2).lerp(Color(0.15, 0.25, 0.7), t)
			img.set_pixel(i % _out_w, i / _out_w, col)
		return img    # --- Manual editing & inspection -----------------------------------------

	func get_source_index() -> ConstraintIndex:
		return _index


	func get_slot_dims() -> Vector2i:
		return Vector2i(_out_w, _out_h)


	func get_slot_step() -> Vector2i:
		return _cell


	func get_render_size() -> Vector2i:
		return Vector2i(
				(_out_w - 1) * _cell.x + _index.tile_size.x,
				(_out_h - 1) * _cell.y + _index.tile_size.y)


	func get_slot_assignment(slot: int) -> String:
		return assigned[slot] if slot >= 0 and slot < assigned.size() else ""


	@warning_ignore("integer_division")
	func pixel_to_slot(px: Vector2i) -> int:
		## Closest slot CENTER to the pixel — overlap-aware: with a stride
		## smaller than the tile, several slots contain the pixel.
		var size := get_render_size()
		if px.x < 0 or px.y < 0 or px.x >= size.x or px.y >= size.y:
			return -1
		var ts := _index.tile_size
		var col := clampi(roundi((px.x - ts.x * 0.5) / float(_cell.x)),
				0, _out_w - 1)
		var row := clampi(roundi((px.y - ts.y * 0.5) / float(_cell.y)),
				0, _out_h - 1)
		return row * _out_w + col


	@warning_ignore("integer_division")
	func slot_rect(slot: int) -> Rect2i:
		return Rect2i(Vector2i(
				(slot % _out_w) * _cell.x,
				(slot / _out_w) * _cell.y), _index.tile_size)


	func get_slot_domain(slot: int) -> Dictionary:
		if is_finished() or slot < 0 or slot >= candidates.size():
			return {}
		if assigned[slot] == "":
			return candidates[slot].duplicate()
		var dom := _domain_excluding_self(slot)
		dom[assigned[slot]] = true
		return dom


	func try_assign(slot: int, part_id: String) -> bool:
		## Pin part_id at slot and propagate. Fully reverts on contradiction,
		## so a rejected edit leaves every domain exactly as it was.
		if is_finished() or slot < 0 or slot >= candidates.size():
			last_rejection = describe_pin(slot, part_id)
			return false
		if _index.get_part(part_id) == null:
			last_rejection = describe_pin(slot, part_id)
			return false
		if assigned[slot] == part_id:
			last_rejection = ""
			return true
		if not get_slot_domain(slot).has(part_id):
			last_rejection = describe_pin(slot, part_id)
			return false   # conflicts with pinned/singleton neighbors
		var snap_c: Array[Dictionary] = []
		snap_c.assign(candidates.duplicate(true))
		var snap_a: Array[String] = []
		snap_a.assign(assigned.duplicate())
		var snap_q: Array[int] = []
		snap_q.assign(_queue.duplicate())
		var snap_collapsed := _collapsed

		var was_pinned := assigned[slot] != ""
		candidates[slot] = {part_id: true}
		assigned[slot] = part_id
		if not was_pinned:
			_collapsed += 1
		last_slot = slot
		_queue.append(slot)
		
		var trace: Array = []
		if not TileCollapse._propagate(_index, candidates, assigned,
				_out_w, _out_h, _cell, _deltas, _queue, false, _unknown_free, _bordered, trace):
			candidates = snap_c
			assigned = snap_a
			_queue = snap_q
			_collapsed = snap_collapsed
			if not trace.is_empty():
				last_wipe = _describe_wipe(trace[0])
			last_rejection = ("propagation: %s" % _describe_wipe(trace[0])) \
					if not trace.is_empty() else "propagation contradiction"
			return false
		last_rejection = ""
		_pinned[slot] = part_id
		# Existing automatic observations are not user intent and their old
		# decision snapshots predate this pin. Rebuild only from hard pins so
		# future backtracking remains sound.
		if _reset_attempt():
			return true
		candidates = snap_c
		assigned = snap_a
		_queue = snap_q
		_collapsed = snap_collapsed
		_pinned.erase(slot)
		if was_pinned:
			_pinned[slot] = snap_a[slot]
		phase = Phase.RUNNING
		return false


	func try_clear(slot: int) -> bool:
		## Unpin a slot and rebuild domains from the remaining observations.
		## Propagation only removes candidates, so simply clearing the slot
		## would leave stale pruning behind and make a visually blank board
		## reject tiles that are actually valid.
		if is_finished() or slot < 0 or slot >= candidates.size():
			return false
		if assigned[slot] == "":
			return false
		var snap_c: Array[Dictionary] = []
		snap_c.assign(candidates.duplicate(true))
		var snap_a: Array[String] = []
		snap_a.assign(assigned.duplicate())
		var snap_q: Array[int] = []
		snap_q.assign(_queue.duplicate())
		var snap_collapsed := _collapsed
		var snap_decisions: Array[Dictionary] = []
		snap_decisions.assign(_decisions.duplicate(true))
		var old_pin: Variant = _pinned.get(slot, null)
		_pinned.erase(slot)
		if not _reset_attempt():
			candidates = snap_c
			assigned = snap_a
			_queue = snap_q
			_collapsed = snap_collapsed
			_decisions = snap_decisions
			if old_pin != null:
				_pinned[slot] = old_pin
			return false
		last_slot = slot
		return true


	func _rebuild_domains_from_assignments() -> bool:
		## Recreate the monotonic AC-3 state so removals can expand domains.
		var template := {}
		for id: String in _index.get_part_ids():
			template[id] = true
		for i in candidates.size():
			candidates[i] = {assigned[i]: true} if assigned[i] != "" else template.duplicate()
		_queue.clear()
		_collapsed = 0
		for i in assigned.size():
			if assigned[i] != "":
				_collapsed += 1
				_queue.append(i)
		if _bordered:
			for i in candidates.size():
				if not _queue.has(i):
					_queue.append(i)
		var trace: Array = []
		if TileCollapse._propagate(_index, candidates, assigned,
				_out_w, _out_h, _cell, _deltas, _queue, false,
				_unknown_free, _bordered, trace):
			return true
		if not trace.is_empty():
			last_wipe = _describe_wipe(trace[0])
		return false


	@warning_ignore("integer_division")
	func _domain_excluding_self(slot: int) -> Dictionary:
		## Parts compatible with every pinned (or collapsed-to-one) neighbor
		## of slot, ignoring slot's own pin. Falls back to the full set when
		## the neighborhood is over-constrained (rare path inconsistency).
		var full := {}
		for id: String in _index.get_part_ids():
			full[id] = true
		var pos := Vector2i(slot % _out_w, slot / _out_w)
		var dom := full.duplicate()
		for delta: Vector2i in _deltas:
			for d: Vector2i in [delta, -delta]:
				var npos := pos + d
				if npos.x < 0 or npos.x >= _out_w or npos.y < 0 or npos.y >= _out_h:
					continue
				var q := npos.y * _out_w + npos.x
				if q == slot:
					continue
				var value := ""
				if assigned[q] != "":
					value = assigned[q]
				elif candidates[q].size() == 1:
					value = candidates[q].keys()[0]
				if value == "":
					continue   # multi-candidate neighbor: no hard constraint
				var nb := _index.get_neighbors(value, -d)
				var keep := {}
				for x: String in dom:
					if nb.has(x):
						keep[x] = true
				dom = keep
				if dom.is_empty():
					return full
		if _bordered:
			for delta: Vector2i in _deltas:
				var np := pos + delta
				if np.x >= 0 and np.x < _out_w and np.y >= 0 and np.y < _out_h:
					continue
				var off := Vector2i(delta.x * _cell.x, delta.y * _cell.y)
				if not TileCollapse._has_outside_evidence(_index, off):
					continue
				var edge_keep: Dictionary = {}
				for x: String in dom:
					if _index.get_neighbors(x, off).has(ConstraintIndex.OUTSIDE):
						edge_keep[x] = true
				dom = edge_keep
		return dom

	@warning_ignore("integer_division")
	func describe_pin(slot: int, part_id: String) -> String:
		## "" if the immediate neighborhood permits the pin; else why not.
		if slot < 0 or slot >= candidates.size():
			return "slot out of range"
		if assigned[slot] == part_id:
			return ""
		if not get_slot_domain(slot).has(part_id):
			return "not in the slot's current domain"
		var pos := Vector2i(slot % _out_w, slot / _out_w)
		for d: Vector2i in _deltas:
			var n := pos + d
			if n.x < 0 or n.x >= _out_w or n.y < 0 or n.y >= _out_h:
				continue
			if _index.get_neighbors(part_id, d * _cell).is_empty():
				return "no observed neighbor at offset %s" % [d * _cell]
		return ""


	@warning_ignore("integer_division")
	func _describe_wipe(w: Dictionary) -> String:
		var at: int = w["at"]
		var off: Vector2i = w["delta"]
		if w.get("border", false):
			return "slot (%d,%d) wiped by image-edge rule at offset (%d,%d): needs a border-observed tile, only %s qualify" % [
					at % _out_w, at / _out_w, off.x, off.y, _short(w["domain"])]
		var from: int = w["from"]
		return "slot (%d,%d) wiped via offset (%d,%d) from (%d,%d): needs one of %s, slot only allows %s" % [
				at % _out_w, at / _out_w, off.x, off.y,
				from % _out_w, from / _out_w,
				_short(w["allowed"]), _short(w["domain"])]

	func _short(ids: Array) -> String:
		var parts: Array[String] = []
		for id: String in ids:
			parts.append(id.substr(2, 4) + "…" + id.right(4))
		return "[" + ", ".join(parts) + "]"
