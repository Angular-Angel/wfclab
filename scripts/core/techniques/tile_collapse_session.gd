class_name TileCollapseSession extends SynthesisSession
## One resumable TileCollapse run. Batch synthesize() drives this class,
## so RNG consumption (one _weighted_pick + one _pick_member per
## observation) is identical in both modes and a seed reproduces the
## same output either way.
##
## dom masks, buckets, and all propagation tables are FAMILY-indexed;
## assigned[] stores concrete member part ids for rendering and pins.

var _index: ConstraintIndex
var _rng: RandomNumberGenerator
var _out_w: int
var _out_h: int
var _cell: Vector2i
var _deltas: Array[Vector2i]
var _contradiction_strategy: int
var _max_recovery_attempts: int
var _unknown_free: bool

var dom: Array[PackedInt64Array] = []
var _size: PackedInt32Array = PackedInt32Array()   # cached mask_count per slot
var _buckets: Array = []                   # [size] -> {slot: true}; bucket 0 = assigned
var _min_bucket := 1
var _queue: Array[int] = []
var _queue_head := 0
var _in_queue: PackedByteArray = PackedByteArray()
var _trail: Array = []                     # {slot: int, removed: PackedInt64Array}
var nparts := 0                            # FAMILY count (not part count)
var nwords := 0                            # 64-bit words per family mask
var _full_mask: PackedInt64Array = PackedInt64Array()

var assigned: Array[String] = []
var _decisions: Array[Dictionary] = []
var _pinned: Dictionary = {} # slot -> member part id; persists across restarts
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
	_cell = _index.derive_step()
	_deltas = _index.derive_deltas(_cell)
	_index.prepare(_deltas, _cell, {
		"terrain_merge": params.get("terrain_merge", false),
		"terrain_merge_depth": params.get("terrain_merge_depth", 1),
	})
	nparts = _index.family_count
	nwords = _index.family_nwords
	_bordered = _index.has_outside()
	if _deltas.is_empty():
		push_warning("TileCollapse: no usable offsets; output is unconstrained.")
	_reset_attempt()


func _reset_attempt() -> bool:
	nparts = _index.family_count
	nwords = _index.family_nwords
	var full := BitMask.full(nwords, nparts)
	_full_mask = full
	dom.clear(); assigned.clear()
	dom.resize(_out_w * _out_h)
	assigned.resize(_out_w * _out_h)
	_size.resize(_out_w * _out_h)
	_size.fill(0)              # REQUIRED — stale sizes corrupt bucket bookkeeping
	_in_queue.resize(_out_w * _out_h)
	_in_queue.fill(0)          # defensive — don't rely on resize zeroing
	_buckets.clear()
	for i in nparts + 1:
		_buckets.append({})
	_min_bucket = 1
	_queue_clear_all()
	_decisions.clear()
	_trail.clear()
	last_slot = -1
	_collapsed = 0
	for slot: int in _pinned.keys():
		var pid: String = _pinned[slot]
		var fi := _index.family_of_part_id(pid)
		if fi < 0:
			push_warning("TileCollapse: pinned part %s left the index; pin dropped." % pid)
			_pinned.erase(slot)
			continue
		var m := BitMask.empty(nwords)
		BitMask.set_bit(m, fi)
		assigned[slot] = pid
		_collapsed += 1
		_set_dom(slot, m)               # bucket 0 (assigned)
		_queue_append(slot)
	for i in dom.size():
		if assigned[i] != "":
			continue
		_set_dom(i, full.duplicate())
		if _bordered:
			_queue_append(i)
	var trace: Array = []
	if not _propagate(trace):
		last_wipe = _describe_wipe(trace[0]) if not trace.is_empty() else "border setup"
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
	if _queue_empty():
		var slot := _pick_slot()
		if slot == -1:
			phase = Phase.DONE
			return false
		var fi := _weighted_pick(dom[slot])
		var mi := _pick_member(fi)
		var removed := dom[slot].duplicate()
		BitMask.clear_bit(removed, fi)
		_decisions.append({
			"slot": slot,
			"rejected_fi": fi,
			"trail_len": _trail.size(),   # everything above this is undone on backtrack
			"collapsed": _collapsed,      # pre-decision counter
		})
		_trail.append({"slot": slot, "removed": removed})
		var m := dom[slot]
		BitMask.only(m, fi)
		_set_dom(slot, m)
		assigned[slot] = _index.part_ids[mi]
		last_slot = slot
		_collapsed += 1
		_queue_append(slot)
		if micro:
			return true
	var trace: Array = []
	if not _propagate(trace, micro):
		if not trace.is_empty():
			last_wipe = _describe_wipe(trace[0])
		_recover_from_contradiction()
		if is_finished():
			return false
		return true
	return true


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
	while not _decisions.is_empty():
		var d: Dictionary = _decisions.pop_back()
		_undo_to(int(d["trail_len"]))    # includes the collapse entry
		var slot: int = d["slot"]
		assigned[slot] = ""
		var m := dom[slot]               # now the restored pre-decision domain
		BitMask.clear_bit(m, int(d["rejected_fi"]))
		_set_dom(slot, m)
		_collapsed = int(d["collapsed"])
		_queue_clear_all()               # drop stale entries from the failed cascade
		if BitMask.is_empty(dom[slot]):
			continue
		_queue_append(slot)
		backtracks += 1
		return
	last_wipe = "no automatic decision remains; pinned constraints are incompatible"
	phase = Phase.FAILED


func _undo_to(mark: int) -> void:
	while _trail.size() > mark:
		var e: Dictionary = _trail.pop_back()
		var slot: int = e["slot"]
		var rem: PackedInt64Array = e["removed"]
		var m := dom[slot]
		for w in nwords:
			m[w] = m[w] | rem[w]
		_set_dom(slot, m)                    # COW write-back + buckets


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
			"parts": _index.part_ids.size(),
			"families": _index.family_count,
			"largest_family": _index.largest_family_size,
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
	## cool = many. Dims are output_slots, not pixels. Domain sizes are
	## in FAMILY units now, so the color scale adapts to family count.
	var img := Image.create_empty(
			_out_w, _out_h, false, Image.FORMAT_RGBA8)
	var scale := maxf(8.0, float(_index.family_count) / 16.0)
	for i in dom.size():
		var col: Color
		if assigned[i] != "":
			col = Color(0.95, 0.95, 0.95)
		else:
			var t := clampf(float(_size[i]) / scale, 0.0, 1.0)
			col = Color(1.0, 0.3, 0.2).lerp(Color(0.15, 0.25, 0.7), t)
		img.set_pixel(i % _out_w, i / _out_w, col)
	return img


# --- Manual editing & inspection -----------------------------------------

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


@warning_ignore("integer_division")
func _propagate(trace: Array, single: bool = false) -> bool:
	## AC-3 over all deltas, on FAMILY masks. Rule deltas (di >= evidence
	## count) carry a precomputed family-int complement of their union
	## source-tag mask: if dom[s] holds ANY family outside that union,
	## the arc's allowed set is full and cannot prune — skip in a couple
	## of word ops. All-rule-relevant slots revise eagerly, which is what
	## keeps self-exclusion rules from clumping into late contradictions.
	var ne := _index.evidence_delta_count
	var total := _index.delta_list.size()
	while not _queue_empty():
		var s := _queue_pop()
		var sx := s % _out_w
		var sy := s / _out_w
		for di in total:
			if di >= ne:
				var inv: PackedInt64Array = _index.f_rule_src_not[di]
				var all_src := true
				for w in nwords:
					if dom[s][w] & inv[w] != 0:
						all_src = false
						break
				if not all_src:
					continue
			var delta: Vector2i = _index.delta_list[di]
			var qx := sx + delta.x
			var qy := sy + delta.y
			if qx < 0 or qx >= _out_w or qy < 0 or qy >= _out_h:
				# delta_has_outside is false for rule deltas, so the
				# border branch only ever fires on evidence deltas.
				if _bordered and _index.delta_has_outside[di]:
					if not _apply_border(s, di, trace):
						return false
				continue
			var q := qy * _out_w + qx
			if assigned[q] != "":
				continue
			if not _revise(s, q, di, trace):
				return false
		if single:
			return true
	return true


func _revise(s: int, q: int, di: int, trace: Array) -> bool:
	var sdom := dom[s]                       # read-only; no write-back needed
	var allowed := PackedInt64Array()
	allowed.resize(nwords)
	var unconstrained := false
	var full := _full_mask
	var probe := 0                           # candidates since last saturation check
	var done := false
	if _size[s] == 1:
		# singleton fast path
		var sfi := BitMask.first(sdom)
		var snb: PackedInt64Array = _index.f_nb_mask[sfi][di]
		for w in nwords:
			allowed[w] = snb[w]
		if _index.f_nb_empty[sfi][di]:
			unconstrained = _unknown_free
	else:
		for w in nwords:
			if done:
				break
			var v: int = sdom[w]
			if v == 0:
				continue
			while v != 0:
				var low := v & -v
				v ^= low
				var fi := (w << 6) + BitMask.ctz(low)
				if _index.f_nb_empty[fi][di]:
					if _unknown_free:
						unconstrained = true
						done = true
						break               # this family supports anything
					continue                # contributes nothing
				var nb: PackedInt64Array = _index.f_nb_mask[fi][di]
				for k in nwords:
					allowed[k] = allowed[k] | nb[k]
				probe += 1
				if probe == 16:
					probe = 0
					# Saturation check, amortized (every 16th candidate):
					# the union is monotonic, so once it equals the full
					# mask no further candidate can change it.
					var sat := true
					for k in nwords:
						if allowed[k] != full[k]:
							sat = false
							break
					if sat:
						done = true
						break
	if unconstrained:
		return true
	# Single pass to detect any change BEFORE mutating or allocating —
	# most cascaded revises change nothing and pay only this scan.
	var qdom := dom[q]
	var changed := false
	for w in nwords:
		if qdom[w] & allowed[w] != qdom[w]:
			changed = true
			break
	if not changed:
		return true
	var pre := dom[q].duplicate()            # pre-wipe state, for diagnostics
	var removed := PackedInt64Array()
	removed.resize(nwords)
	for w in nwords:
		var old_w: int = qdom[w]
		var new_w: int = old_w & allowed[w]
		if new_w != old_w:
			qdom[w] = new_w
			removed[w] = old_w & ~new_w
	if BitMask.is_empty(qdom):
		_record_wipe(q, s, di, allowed, trace, pre)
		return false
	_set_dom(q, qdom)                       # COW write-back + buckets
	_trail.append({"slot": q, "removed": removed})
	_queue_append(q)
	return true


func _apply_border(s: int, di: int, trace: Array) -> bool:
	var pre := dom[s].duplicate()        # pre-wipe, for reporting
	var sdom := dom[s]
	var removed := PackedInt64Array()
	removed.resize(nwords)
	var changed := false
	for w in nwords:
		var v: int = sdom[w]
		if v == 0:
			continue
		var keep := v
		var m := v
		while m != 0:
			var low := m & -m
			m ^= low
			var fi := (w << 6) + BitMask.ctz(low)
			if not _index.f_border_ok[fi][di]:
				keep &= ~low
		if keep != v:
			changed = true
			sdom[w] = keep
			removed[w] = v & ~keep
	if not changed:
		return true
	if BitMask.is_empty(sdom):
		trace.append({
			"at": s, "border": true,
			"delta": _index.delta_pixel[di],
			"allowed": [],
			"domain": _ids_of(pre),
		})
		return false
	_set_dom(s, sdom)                       # COW write-back + buckets
	_trail.append({"slot": s, "removed": removed})
	_queue_append(s)
	return true


func get_slot_domain(slot: int) -> Dictionary:
	## Unassigned slots list family REPRESENTATIVE ids (one entry per
	## candidate family). Assigned slots list reps compatible with the
	## neighborhood plus the currently assigned member.
	if is_finished() or slot < 0 or slot >= dom.size():
		return {}
	if assigned[slot] == "":
		var out := {}
		for fi in BitMask.iter(dom[slot]):
			out[_index.family_ids[fi]] = true
		return out
	var d := _domain_excluding_self(slot)
	d[assigned[slot]] = true
	return d


func try_assign(slot: int, part_id: String) -> bool:
	## Pin a part into a slot and propagate. Accepts ANY family member
	## id (the family bit is the real gate), not just representatives.
	if slot < 0 or slot >= dom.size():
		last_rejection = "slot out of range"
		return false
	var fi := _index.family_of_part_id(part_id)
	if fi < 0 or not BitMask.has(dom[slot], fi):
		last_rejection = describe_pin(slot, part_id)
		return false
	var trail_mark := _trail.size()
	var q_mark := _queue_mark()
	var old_collapsed := _collapsed
	var old_assigned: String = assigned[slot]
	var was_pinned := old_assigned != ""

	var removed := dom[slot].duplicate()
	BitMask.clear_bit(removed, fi)
	_trail.append({"slot": slot, "removed": removed})

	var m := dom[slot]
	BitMask.only(m, fi)
	_set_dom(slot, m)
	assigned[slot] = part_id
	if not was_pinned:
		_collapsed += 1
	last_slot = slot
	_queue_append(slot)

	var trace: Array = []
	if not _propagate(trace):
		assigned[slot] = old_assigned      # BEFORE undo — buckets depend on it
		_undo_to(trail_mark)               # undoes pin AND propagation
		_queue_restore(q_mark)
		_collapsed = old_collapsed
		if not trace.is_empty():
			last_wipe = _describe_wipe(trace[0])
		last_rejection = ("propagation: %s" % last_wipe) \
			if not trace.is_empty() else "propagation contradiction"
		return false

	_pinned[slot] = part_id
	_trail.clear()
	_decisions.clear()
	last_rejection = ""
	return true


func _snapshot_state() -> Dictionary:
	return {
		"dom": dom.duplicate(),
		"size": _size.duplicate(),
		"assigned": assigned.duplicate(),
		"queue": _queue.duplicate(),
		"head": _queue_head,
		"in_queue": _in_queue.duplicate(),
		"collapsed": _collapsed,
		"decisions": _decisions.duplicate(),
		"trail": _trail.duplicate(),
		"min_bucket": _min_bucket,
	}


func _restore_state(s: Dictionary) -> void:
	dom = s["dom"]
	_size = s["size"]
	assigned = s["assigned"]
	_queue = s["queue"]
	_queue_head = int(s["head"])
	_in_queue = s["in_queue"]
	_collapsed = int(s["collapsed"])
	_decisions = s["decisions"]
	_trail = s["trail"]
	_min_bucket = int(s["min_bucket"])
	_refresh_buckets()


func _refresh_buckets() -> void:
	## Rebuild buckets wholesale from assigned + _size.
	_buckets.clear()
	for i in nparts + 1:
		_buckets.append({})
	_min_bucket = 1
	for i in dom.size():
		var b := 0 if assigned[i] != "" else _size[i]
		if b > 0:
			_buckets[b][i] = true
			if b < _min_bucket:
				_min_bucket = b


func try_clear(slot: int) -> bool:
	## Unpin a slot and rebuild from the remaining pins. Full rebuild is
	## required because unpinning must EXPAND domains, which propagation
	## alone cannot do.
	if is_finished() or slot < 0 or slot >= dom.size():
		return false
	if assigned[slot] == "":
		return false
	var snap := _snapshot_state()
	var old_pin: Variant = _pinned.get(slot, null)
	_pinned.erase(slot)
	if not _reset_attempt():
		_restore_state(snap)
		if old_pin != null:
			_pinned[slot] = old_pin
		return false
	last_slot = slot
	return true


func _weighted_pick(m: PackedInt64Array) -> int:
	## Weighted choice over FAMILY ints. Family weight is the sum of its
	## members' effective weights, so family-then-member sampling has the
	## same outcome distribution as the old per-part pick.
	var total := 0.0
	for w in nwords:
		var v: int = m[w]
		while v != 0:
			var low := v & -v
			v ^= low
			total += _index.family_weights[(w << 6) + BitMask.ctz(low)]
	if total <= 0.0:
		var k := _rng.randi_range(0, BitMask.count(m) - 1)
		return BitMask.kth(m, k)
	var r := _rng.randf() * total
	for w in nwords:
		var v: int = m[w]
		while v != 0:
			var low := v & -v
			v ^= low
			var fi := (w << 6) + BitMask.ctz(low)
			r -= _index.family_weights[fi]
			if r <= 0.0:
				return fi
	return BitMask.kth(m, BitMask.count(m) - 1)


func _pick_member(fi: int) -> int:
	## Resolve a family to a concrete part int, occurrence-weighted, so
	## every variant still appears and source frequencies carry through.
	## Called only from the observation path (pins bypass it), so batch
	## and stepped runs consume rng identically. Singleton families
	## consume no rng.
	var members: PackedInt32Array = _index.family_members[fi]
	if members.size() == 1:
		return members[0]
	var total := 0.0
	for mi in members:
		total += _index.part_weights[mi]
	if total <= 0.0:
		return members[_rng.randi_range(0, members.size() - 1)]
	var r := _rng.randf() * total
	for mi in members:
		r -= _index.part_weights[mi]
		if r <= 0.0:
			return mi
	return members[members.size() - 1]


func _pick_slot() -> int:
	while _min_bucket < _buckets.size():
		var b: Dictionary = _buckets[_min_bucket]
		var best := -1
		for slot: int in b.keys():
			if assigned[slot] != "":
				b.erase(slot)        # stale entry from the collapse path
				continue
			if best == -1 or slot < best:
				best = slot          # lowest index wins ties (legacy MRV order)
		if best != -1:
			return best
		_min_bucket += 1
	return -1


@warning_ignore("integer_division")
func _domain_excluding_self(slot: int) -> Dictionary:
	## Families compatible with every pinned (or collapsed-to-one)
	## neighbor of slot, ignoring slot's own pin. Returns representative
	## ids. Falls back to the full family set when the neighborhood is
	## over-constrained (rare path inconsistency).
	var full := {}
	for fi in _index.family_count:
		full[_index.family_ids[fi]] = true
	var pos := Vector2i(slot % _out_w, slot / _out_w)
	var out := full.duplicate()
	for di in _index.delta_list.size():
		var pix: Vector2i = _index.delta_pixel[di]
		for sgn in [1, -1]:
			var d: Vector2i = _index.delta_list[di] * sgn
			var npos := pos + d
			if npos.x < 0 or npos.x >= _out_w or npos.y < 0 or npos.y >= _out_h:
				continue
			var q := npos.y * _out_w + npos.x
			if q == slot:
				continue
			var value_fi := -1
			if assigned[q] != "":
				value_fi = _index.family_of_part_id(assigned[q])
			elif _size[q] == 1:
				value_fi = BitMask.first(dom[q])
			if value_fi < 0:
				continue   # multi-candidate neighbor: no hard constraint
			var nb: PackedInt64Array = _index.f_mask_neighbors(value_fi, pix * -sgn)
			var keep := {}
			for fi in BitMask.iter(nb):
				var fid: String = _index.family_ids[fi]
				if out.has(fid):
					keep[fid] = true
			out = keep
			if out.is_empty():
				return full
	if _bordered:
		for di in _index.delta_list.size():
			var delta: Vector2i = _index.delta_list[di]
			var np := pos + delta
			if np.x >= 0 and np.x < _out_w and np.y >= 0 and np.y < _out_h:
				continue
			if not _index.delta_has_outside[di]:
				continue
			var edge_keep := {}
			for pid: String in out.keys():
				var efi := _index.family_of_part_id(pid)
				if efi >= 0 and _index.f_border_ok[efi][di]:
					edge_keep[pid] = true
			out = edge_keep
	return out


@warning_ignore("integer_division")
func describe_pin(slot: int, part_id: String) -> String:
	## "" if the immediate neighborhood permits the pin; else why not.
	## Accepts any family member id, not just representatives.
	if slot < 0 or slot >= dom.size():
		return "slot out of range"
	var fi := _index.family_of_part_id(part_id)
	if fi < 0:
		return "unknown or disabled part"
	if assigned[slot] == part_id:
		return ""
	if not BitMask.has(dom[slot], fi):
		return "not in the slot's current domain"
	var pos := Vector2i(slot % _out_w, slot / _out_w)
	for d: Vector2i in _deltas:
		var n := pos + d
		if n.x < 0 or n.x >= _out_w or n.y < 0 or n.y >= _out_h:
			continue
		if BitMask.is_empty(_index.f_mask_neighbors(fi, d * _cell)):
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
			_short(w["allowed"]), _short(w["domain"])] + (" [authored rule]" if w.get("rule", false) else "")


func _ids_of(m: PackedInt64Array, cap := 12) -> Array:
	## Masks are family-indexed; diagnostics list representative ids.
	var out: Array = []
	var total := BitMask.count(m)
	for fi in BitMask.iter(m):
		if out.size() >= cap:
			out.append("…+%d more" % (total - cap))
			break
		out.append(_index.family_ids[fi])
	return out


func _record_wipe(q: int, s: int, di: int, allowed: PackedInt64Array, trace: Array, pre = null) -> void:
	trace.append({
		"at": q, "from": s,
		"delta": _index.delta_pixel[di],
		"allowed": _ids_of(allowed),
		"domain": _ids_of(dom[q]) if not pre else _ids_of(pre),
		"rule": di >= _index.evidence_delta_count,
	})


func _short(ids: Array) -> String:
	var parts: Array[String] = []
	for id: String in ids:
		parts.append(id.substr(2, 4) + "…" + id.right(4))
	return "[" + ", ".join(parts) + "]"


func _queue_append(s: int) -> void:
	if _in_queue[s] == 1:
		return
	_in_queue[s] = 1
	_queue.append(s)


func _queue_pop() -> int:
	var s: int = _queue[_queue_head]
	_queue[_queue_head] = 0
	_queue_head += 1
	_in_queue[s] = 0
	return s


func _queue_empty() -> bool:
	return _queue_head >= _queue.size()


func _queue_clear_all() -> void:
	_queue.clear()
	_queue_head = 0
	_in_queue.fill(0)


func _queue_mark() -> Dictionary:
	return {"size": _queue.size(), "head": _queue_head}


func _queue_restore(mk: Dictionary) -> void:
	for i in range(_queue_head, _queue.size()):
		_in_queue[_queue[i]] = 0
	_queue.resize(int(mk["size"]))
	_queue_head = int(mk["head"])
	for i in range(_queue_head, _queue.size()):
		_in_queue[_queue[i]] = 1


func _set_dom(slot: int, m: PackedInt64Array) -> void:
	var old_size := _size[slot]
	var new_size := BitMask.count(m)
	dom[slot] = m                       # COW write-back — required
	_size[slot] = new_size
	var old_bucket := 0 if assigned[slot] != "" else old_size
	var new_bucket := 0 if assigned[slot] != "" else new_size
	if old_bucket != new_bucket:
		if old_bucket > 0 and old_bucket < _buckets.size():
			_buckets[old_bucket].erase(slot)
		if new_bucket > 0:
			_buckets[new_bucket][slot] = true
			if new_bucket < _min_bucket:
				_min_bucket = new_bucket
