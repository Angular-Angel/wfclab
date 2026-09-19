class_name ConstraintIndex extends RefCounted
## Fast query layer over the materialized parts and constraints. Applies
## enabled flags and weight overrides once, centrally — every synthesizer
## sees the same edited world. Built as an immutable snapshot: safe to read
## from a worker thread even if the UI keeps editing.
##
## Authored content (tags + rules) is compiled in prepare(): rules append
## slot-unit deltas and prune neighbor masks but NEVER touch _offsets, so
## get_offsets() — and therefore TileCollapse._derive_step/_derive_deltas and
## the Parts-tab neighbor view — stays evidence-only.
## NOTE: prepare() mutates the derived tables. Safe under the current
## one-session-per-index UI; revisit if two sessions ever share an index.

const OUTSIDE := "~outside"   # virtual part: the region beyond a source border

var _neighbors: Dictionary = {}   # part_id -> {"x,y" -> {part_id -> weight}}
var _offsets: Dictionary = {}     # Vector2i -> true
var _parts: Dictionary = {}       # part_id -> Part (enabled only)
var _weights: Dictionary = {}     # part_id -> effective weight
var tile_size := Vector2i(1, 1)
var _has_outside := false

# --- integer-id layer -------------------------------------------------------
var part_ids: Array[String] = []          # int -> id, in _parts.keys() order
var _int_of: Dictionary = {}              # id -> int
var part_weights := PackedFloat64Array()  # effective weight per int
var nwords := 0                           # 64-bit words per domain mask

# --- authored layer (stored at build, compiled in prepare) -------------------
var authored_tags: Dictionary = {}        # part_id -> Array[String]
var authored_rules: Array = []            # rule Dictionaries in AppData format
var _tag_bits: Dictionary = {}            # tag -> PackedInt64Array over part ints

# --- per-delta tables (filled by prepare()) ---------------------------------
var delta_list: Array[Vector2i] = []      # slot-unit deltas
var delta_pixel: Array[Vector2i] = []     # delta * step
var delta_has_outside: Array[bool] = []   # replaces _has_outside_evidence()
var nb_mask: Array = []                   # [part_int][delta_int] -> PackedInt64Array
var nb_empty: Array = []                  # [part_int][delta_int] -> bool (no evidence)
var border_ok: Array = []                 # [part_int][delta_int] -> bool (has OUTSIDE)
var _pixel_to_di: Dictionary = {}         # Vector2i -> delta index
var evidence_delta_count := 0             # pure rule deltas live at di >= this
var rule_src: Array = []                  # [di] -> union src-tag mask (rule deltas only; null for evidence)
var rule_src_not: Array = []              # [di] -> complement of rule_src; the solver's skip test
var _prepared_key := ""


func has_outside() -> bool:
	return _has_outside


static func build(parts: Array[Part], constraints: Array[Constraint],
		tag_map: Dictionary = {}, rules: Array = []) -> ConstraintIndex:
	var idx := ConstraintIndex.new()

	for p: Part in parts:
		if not p.enabled:
			continue
		idx._parts[p.id] = p
		idx._weights[p.id] = p.get_effective_weight()
		if idx._parts.size() == 1:
			idx.tile_size = p.size
	for c: Constraint in constraints:
		if not c.enabled or c.participants.size() != 2:
			continue
		var a: String = c.participants[0]["part_id"]
		var b: String = c.participants[1]["part_id"]
		var offset: Vector2i = c.params.get("offset", Vector2i())
		var w: float = c.get_effective_weight()
		if a == OUTSIDE or b == OUTSIDE:
			var real := b if a == OUTSIDE else a
			if not idx._parts.has(real):
				continue
			idx._add(real, offset, OUTSIDE, w)
			idx._has_outside = true
			continue   # no reverse entry: OUTSIDE never occupies a slot
		if not idx._parts.has(a) or not idx._parts.has(b):
			continue   # references a disabled part; can never be placed
		idx._add(a, offset, b, w)
		idx._add(b, -offset, a, w)
		if c.params.get("symmetric", false):
			idx._add(b, offset, a, w)
			idx._add(a, -offset, b, w)
	idx.authored_tags = tag_map
	idx.authored_rules = rules
	return idx


## Called once per session with the evidence-derived deltas; compiles tags,
## builds the per-delta tables, then compiles authored rules on top. Rule
## deltas may exceed the passed deltas — TileCollapse consumes
## _index.delta_list, so exclusions propagate without solver changes.
func prepare(deltas: Array[Vector2i], step: Vector2i) -> void:
	# Sessions re-call prepare() with identical inputs (Restart, recovery
	# attempts); skip the full rebuild in that case. Authored content cannot
	# change under us: edits rebuild the whole index object.
	var key := "%d|%d|%d" % [deltas.hash(), step.x, step.y]
	if key == _prepared_key:
		return
	_prepared_key = key

	if part_ids.is_empty():
		_assign_ints()
	_compile_tags()
	delta_list = deltas.duplicate()
	delta_pixel.clear()
	_pixel_to_di.clear()
	for d: Vector2i in deltas:
		_pixel_to_di[d] = delta_pixel.size()
		delta_pixel.append(Vector2i(d.x * step.x, d.y * step.y))
	var np := part_ids.size()
	nb_mask.clear(); nb_empty.clear(); border_ok.clear()
	delta_has_outside.clear()
	delta_has_outside.resize(delta_list.size())
	delta_has_outside.fill(false)
	for pi in np:
		var by_offset: Dictionary = _neighbors.get(part_ids[pi], {})
		var mrow: Array = []; var erow: Array = []; var brow: Array = []
		mrow.resize(delta_list.size()); erow.resize(delta_list.size())
		brow.resize(delta_list.size())
		for di in delta_list.size():
			var off: Vector2i = delta_pixel[di]
			var nb: Dictionary = by_offset.get("%d,%d" % [off.x, off.y], {})
			var m := PackedInt64Array(); m.resize(nwords)
			var has_out := false
			for nid: String in nb.keys():
				if nid == OUTSIDE:
					has_out = true
					continue
				if not _int_of.has(nid):
					continue            # defensive; build() filters disabled parts
				m[_int_of[nid] >> 6] |= 1 << (_int_of[nid] & 63)
			mrow[di] = m
			erow[di] = nb.is_empty()    # raw-dict empty: OUTSIDE-only evidence is NOT empty
			brow[di] = has_out
			if has_out:
				delta_has_outside[di] = true
		nb_mask.append(mrow); nb_empty.append(erow); border_ok.append(brow)
	evidence_delta_count = delta_list.size()
	evidence_delta_count = delta_list.size()
	rule_src.resize(evidence_delta_count)   # evidence slots stay null
	_compile_rules(step)
	_build_rule_skip_tables()


func _assign_ints() -> void:
	for id: String in _parts.keys():
		_int_of[id] = part_ids.size()
		part_ids.append(id)
		part_weights.append(_weights.get(id, 0.0))
	nwords = (part_ids.size() + 63) >> 6


# --- tag compilation ----------------------------------------------------------

func _compile_tags() -> void:
	_tag_bits.clear()
	if nwords == 0:
		return
	for id: Variant in authored_tags:
		var pi: int = _int_of.get(String(id), -1)
		if pi == -1:
			continue   # tags on merged-away or disabled parts are inert
		for tag: Variant in authored_tags[id]:
			if not (tag is String) or (tag as String).is_empty():
				continue
			var m: PackedInt64Array = _tag_bits.get(tag, PackedInt64Array())
			if m.size() != nwords:
				m.resize(nwords)
			m[pi >> 6] |= 1 << (pi & 63)
			_tag_bits[tag] = m


## Bitmask over part ints for a tag; empty (and inert) before prepare().
func tag_mask(tag: String) -> PackedInt64Array:
	return _tag_bits.get(tag, PackedInt64Array())


# --- rule compilation -----------------------------------------------------------

func _compile_rules(step: Vector2i) -> void:
	for rule: Dictionary in authored_rules:
		if not bool(rule.get("enabled", true)):
			continue
		match String(rule.get("type", "")):
			"exclusion":
				_apply_exclusion(rule, step)
			_:
				push_warning("ConstraintIndex: unknown rule type '%s' skipped."
						% String(rule.get("type", "")))


## A rule arc from slot s can prune only if EVERY candidate in dom[s]
## sources some rule at that delta. dom[s] & rule_src_not[di] != 0 proves
## otherwise in O(nwords) — usually one word — replacing a full revise.
func _build_rule_skip_tables() -> void:
	rule_src_not.clear()
	rule_src_not.resize(delta_list.size())
	for di in range(evidence_delta_count, delta_list.size()):
		var src: PackedInt64Array = rule_src[di]
		var inv := PackedInt64Array()
		inv.resize(nwords)
		for w in nwords:
			inv[w] = ~src[w]
		rule_src_not[di] = inv


## "No part of tag_a within distance (slot units) of a part of tag_b."
## Authored negative knowledge: applies regardless of what the examples
## observed, so unknown_free must never neutralize it (see _exclude_at).
func _apply_exclusion(rule: Dictionary, step: Vector2i) -> void:
	var tag_a := String(rule.get("tag_a", ""))
	var tag_b := String(rule.get("tag_b", ""))
	var dist := maxi(1, int(rule.get("distance", 1)))
	var metric := String(rule.get("metric", "chebyshev"))
	if tag_a.is_empty() or tag_b.is_empty():
		return
	if not _tag_bits.has(tag_a) or not _tag_bits.has(tag_b):
		push_warning("ConstraintIndex: exclusion rule references unknown tag(s) '%s'/'%s'; inert."
				% [tag_a, tag_b])
		return
	for o: Vector2i in _offsets_within(dist, metric):
		var pix := Vector2i(o.x * step.x, o.y * step.y)
		var di: int = _pixel_to_di.get(pix, -1)
		if di == -1:
			di = _append_delta(o, pix)
		_exclude_at(di, tag_a, tag_b)
		_exclude_at(di, tag_b, tag_a)   # tag_a == tag_b harmlessly double-applies


## All slot offsets with metric-distance <= dist, excluding the origin.
## Deterministic row-major order. Distance is inclusive ("within X").
func _offsets_within(dist: int, metric: String) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for dy in range(-dist, dist + 1):
		for dx in range(-dist, dist + 1):
			if dx == 0 and dy == 0:
				continue
			var ok := false
			match metric:
				"manhattan":
					ok = absi(dx) + absi(dy) <= dist
				"euclidean":
					ok = dx * dx + dy * dy <= dist * dist
				_:
					ok = true   # chebyshev (default)
			if ok:
				out.append(Vector2i(dx, dy))
	return out


## Append a rule-only delta column: every part starts fully allowed (no
## evidence at this offset, but "unobserved" must not mean "free" for an
## authored rule), nb_empty=false, no OUTSIDE evidence.
func _append_delta(o: Vector2i, pix: Vector2i) -> int:
	var di := delta_list.size()
	delta_list.append(o)
	delta_pixel.append(pix)
	_pixel_to_di[pix] = di
	delta_has_outside.append(false)
	var full := TileCollapse.mask_full(nwords, part_ids.size())
	for pi in part_ids.size():
		nb_mask[pi].append(full)   # COW-shared; exclusion writes copy lazily
		nb_empty[pi].append(false)
		border_ok[pi].append(false)
	var zero := PackedInt64Array()
	zero.resize(nwords)
	rule_src.append(zero)
	return di


## Remove every dst-tag bit from src-tag parts' neighbor masks at delta di.
## If a src part had no evidence at this offset, start from the full mask —
## otherwise unknown_free would silently void the exclusion.
func _exclude_at(di: int, src_tag: String, dst_tag: String) -> void:
	var dst := tag_mask(dst_tag)
	var src := tag_mask(src_tag)
	for w in src.size():
		var v: int = src[w]
		while v != 0:
			var low := v & -v
			v ^= low
			var pi := (w << 6) + TileCollapse._ctz(low)
			var m: PackedInt64Array = nb_mask[pi][di]
			if nb_empty[pi][di]:
				m = TileCollapse.mask_full(nwords, part_ids.size())
			for k in m.size():
				m[k] = m[k] & ~dst[k]
			nb_mask[pi][di] = m         # COW write-back — required
			nb_empty[pi][di] = false
			if di >= evidence_delta_count:
				var u: PackedInt64Array = rule_src[di]
				for j in src.size():
					u[j] = u[j] | src[j]
				rule_src[di] = u                # COW write-back — required


# --- evidence query layer (unchanged) -------------------------------------------

func _add(a: String, offset: Vector2i, b: String, w: float) -> void:
	if not _neighbors.has(a):
		_neighbors[a] = {}
	var by_offset: Dictionary = _neighbors[a]
	var key := "%d,%d" % [offset.x, offset.y]
	if not by_offset.has(key):
		by_offset[key] = {}
	var acc: Dictionary = by_offset[key]
	acc[b] = acc.get(b, 0.0) + w
	_offsets[offset] = true


## {part_id -> weight} of parts allowed at (part_id's slot + offset).
func get_neighbors(part_id: String, offset: Vector2i) -> Dictionary:
	var by_offset: Dictionary = _neighbors.get(part_id, {})
	return by_offset.get("%d,%d" % [offset.x, offset.y], {})


func get_offsets() -> Array[Vector2i]:
	var list: Array[Vector2i] = []
	list.assign(_offsets.keys())
	return list


func get_part_ids() -> Array[String]:
	var list: Array[String] = []
	list.assign(_parts.keys())
	return list


func get_part(part_id: String) -> Part:
	return _parts.get(part_id)


func get_weight(part_id: String) -> float:
	return _weights.get(part_id, 0.0)


func int_of(part_id: String) -> int:
	return _int_of.get(part_id, -1)


func mask_neighbors(pi: int, pixel_off: Vector2i) -> PackedInt64Array:
	var di: int = _pixel_to_di.get(pixel_off, -1)
	return PackedInt64Array() if di == -1 else nb_mask[pi][di]
