class_name ConstraintIndex extends RefCounted
## Fast query layer over the materialized parts and constraints. Applies
## enabled flags and weight overrides once, centrally — every synthesizer
## sees the same edited world. Built as an immutable snapshot: safe to read
## from a worker thread even if the UI keeps editing.
##
## FAMILY LAYER: the solver operates entirely on family ints. Parts whose
## RAW evidence behavior is identical — same neighbor-id set per offset,
## same OUTSIDE evidence, same tags — share a family. Grouping on raw dicts
## + tags is exact: rule application is a pure function of (evidence rows,
## tag bits), so equal inputs imply equal post-rule rows. Arc weights are
## excluded from the signature because they never enter the neighbor masks;
## placement weights are preserved via family_weights and member-resolved
## picks. Family rows are built directly from the representative's raw
## neighbor dicts (sparse iteration), so prepare() never scans dense masks
## bit-by-bit.
## NOTE: part-level per-delta tables no longer exist; all per-delta queries
## are family-indexed (f_nb_mask / f_nb_empty / f_border_ok / f_rule_src).
## Authored rules append slot-unit deltas and prune family masks but NEVER
## touch _offsets, so get_offsets() — and therefore TileCollapse
## _derive_step/_derive_deltas and the Parts-tab neighbor view — stays
## evidence-only.
## NOTE: prepare() mutates the derived tables. Safe under the current
## one-session-per-index UI; revisit if two sessions ever share an index.

const OUTSIDE := "~outside"   # virtual part: the region beyond a source border

var _neighbors: Dictionary = {}   # part_id -> {"x,y" -> {part_id -> weight}}
var _offsets: Dictionary = {}     # Vector2i -> true
var _parts: Dictionary = {}       # part_id -> Part (enabled only)
var _weights: Dictionary = {}     # part_id -> effective weight
var tile_size := Vector2i(1, 1)
var _has_outside := false
var _terrain_classes: Array = []  # threaded in by build(); consumed by _build_families

# --- integer-id layer (per-PART; member resolution and weights) --------------
var part_ids: Array[String] = []          # int -> id, in _parts.keys() order
var _int_of: Dictionary = {}              # id -> int
var part_weights := PackedFloat64Array()  # effective weight per part int
var nwords := 0                           # 64-bit words per part-level mask

# --- authored layer (stored at build, compiled in prepare) -------------------
var authored_tags: Dictionary = {}        # part_id -> Array[String]
var authored_rules: Array = []            # rule Dictionaries in AppData format
var _tag_bits: Dictionary = {}            # tag -> PackedInt64Array over part ints
var _fam_tag_bits: Dictionary = {}        # tag -> PackedInt64Array over family ints

# --- per-delta tables (FAMILY-indexed; filled by prepare()) ------------------
var delta_list: Array[Vector2i] = []      # slot-unit deltas
var delta_pixel: Array[Vector2i] = []     # delta * step
var delta_has_outside: Array[bool] = []
var nb_mask: Array = []                   # [family][di] -> PackedInt64Array
var nb_empty: Array = []                  # [family][di] -> bool (no evidence)
var border_ok: Array = []                 # [family][di] -> bool (has OUTSIDE)
var _pixel_to_di: Dictionary = {}         # Vector2i -> delta index
var evidence_delta_count := 0             # pure rule deltas live at di >= this
var f_rule_src: Array = []                # [di] -> family src-tag mask (rule deltas; null for evidence)
var f_rule_src_not: Array = []            # [di] -> complement; the solver's skip test
var _prepared_key := ""

# --- family aggregates ---------------------------------------------------------
var family_count := 0
var family_nwords := 0
var family_of_part := PackedInt32Array()   # part int -> family int
var family_ids: Array[String] = []         # family int -> representative part id
var family_weights := PackedFloat64Array() # family int -> summed effective weight
var family_members: Array = []             # family int -> PackedInt32Array of part ints
var largest_family_size := 0

# --- solver-facing aliases ----------------------------------------------------
# The TileCollapse solver consumes the family tables under these names. They
# are the SAME Array objects as nb_mask / nb_empty / border_ok (assigned at
# the end of _build_families), so element writes through either name —
# including _exclude_at and _append_delta — are visible through both.
var f_nb_mask: Array = []
var f_nb_empty: Array = []
var f_border_ok: Array = []


func has_outside() -> bool:
	return _has_outside


static func build(parts: Array[Part], constraints: Array[Constraint],
		tag_map: Dictionary = {}, rules: Array = [],
		terrain_classes: Array = []) -> ConstraintIndex:
	var idx := ConstraintIndex.new()
	idx._terrain_classes = terrain_classes

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


## Called once per session with the evidence-derived deltas; groups parts
## into families, builds family-indexed per-delta rows, then compiles
## authored rules on top. Rule deltas may exceed the passed deltas —
## TileCollapse consumes _index.delta_list, so exclusions propagate
## without solver changes.
func prepare(deltas: Array[Vector2i], step: Vector2i,
		merge_cfg: Dictionary = {}) -> void:
	## merge_cfg: {"terrain_merge": bool, "terrain_merge_depth": int}.
	## Part of the cache key: toggling the option on the same index object
	## forces a family rebuild instead of returning stale tables.
	var key := "%d|%d|%d|%s|%d" % [deltas.hash(), step.x, step.y,
			bool(merge_cfg.get("terrain_merge", false)),
			int(merge_cfg.get("terrain_merge_depth", 1))]
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
	# Session view of the evidence offsets: rebuilt from the prepared deltas
	# (pixel units) so get_offsets() stays evidence-only even though rules
	# append extra slot-unit deltas below. Consumers expect pixel units:
	# TileCollapse _derive_step/_derive_deltas and the Parts-tab neighbor
	# lookups key into _neighbors by pixel offset. Session._init derives
	# step/deltas BEFORE this runs, and a re-run re-derives the same deltas
	# from these pixel offsets, so behavior is unchanged across sessions.
	_offsets.clear()
	for d: Vector2i in deltas:
		_offsets[Vector2i(d.x * step.x, d.y * step.y)] = true
	_build_families(merge_cfg)
	# Solver-facing aliases: same Array objects, bound once per prepare.
	f_nb_mask = nb_mask
	f_nb_empty = nb_empty
	f_border_ok = border_ok
	evidence_delta_count = delta_list.size()
	f_rule_src.resize(evidence_delta_count)   # evidence region stays null
	_compile_rules(step)
	_build_rule_skip_tables()


func _assign_ints() -> void:
	for id: String in _parts.keys():
		_int_of[id] = part_ids.size()
		part_ids.append(id)
		part_weights.append(_weights.get(id, 0.0))
	nwords = (part_ids.size() + 63) >> 6


# --- tag compilation (part ints; also drives family tag masks) ------------------

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


# --- family construction ---------------------------------------------------------

func _build_families(merge_cfg: Dictionary) -> void:
	## Family formation, two stages:
	## 1) INITIAL PARTITION. terrain_merge off: singletons. on: parts with
	##    equal tags AND equal per-side edge-terrain composition (class-id
	##    multiset per side at the configured depth; byte-exact strips when
	##    no terrain classes are active) are forced together.
	## 2) COARSENING to a fixpoint, at FAMILY level: each round, every
	##    family's signature is its tags plus, per offset, the sorted
	##    MULTISET of family ids over ALL members' neighbor arcs; families
	##    with equal signatures merge. Forced groups survive (families merge
	##    whole, never split); merges cascade (mutual references resolve as
	##    family ids collide) until stable.
	## The family's solver rows are the UNION of member rows — for exact
	## families members have identical rows, so the union equals them; for
	## terrain-merged families the union IS the opted-into semantics.
	## Equal multisets ⟹ equal union id-sets ⟹ interchangeable under union
	## semantics, so the fixpoint is sound for the model it defines.
	var merge_on := bool(merge_cfg.get("terrain_merge", false))
	var depth := clampi(int(merge_cfg.get("terrain_merge_depth", 1)), 1, 8)
	var np := part_ids.size()
	family_of_part = PackedInt32Array()
	family_of_part.resize(np)
	family_of_part.fill(-1)

	# Per-part evidence blocks once: offset key -> sorted neighbor part ints
	# (OUTSIDE -> -1). Rounds only touch ints and family assignments.
	var per_part: Array = []
	per_part.resize(np)
	for pi in np:
		var by_offset: Dictionary = _neighbors.get(part_ids[pi], {})
		var keys: Array = by_offset.keys()
		keys.sort()
		var blocks: Dictionary = {}
		for k: String in keys:
			var src: Dictionary = by_offset[k]
			var ids := PackedInt32Array()
			ids.resize(src.size())
			var w := 0
			for nid: Variant in src.keys():
				ids[w] = -1 if nid == OUTSIDE else _int_of.get(String(nid), -1)
				w += 1
			ids.sort()
			blocks[k] = ids
		per_part[pi] = blocks

	var tags_of: Array = []
	tags_of.resize(np)
	for pi in np:
		var t: Array = (authored_tags.get(part_ids[pi], []) as Array).duplicate()
		t.sort()
		tags_of[pi] = t

	# --- stage 1: initial partition ---
	var fam := PackedInt32Array()
	fam.resize(np)
	if merge_on:
		var decoded: Array = TerrainMapper.prepare(_terrain_classes)
		var by_key: Dictionary = {}
		for pi in np:
			var k := _edge_signature_key(pi, depth, decoded, tags_of)
			var lead: int = by_key.get(k, -1)
			if lead == -1:
				by_key[k] = pi
				fam[pi] = pi
			else:
				fam[pi] = lead
	else:
		for pi in np:
			fam[pi] = pi

	# --- stage 2: family-level coarsening to fixpoint ---
	while true:
		var fam_members: Dictionary = {}   # rep part int -> members
		for pi in np:
			var r: int = fam[pi]
			if not fam_members.has(r):
				fam_members[r] = PackedInt32Array()
			var lst: PackedInt32Array = fam_members[r]
			lst.append(pi)
			fam_members[r] = lst   # COW write-back
		var new_fam := PackedInt32Array()
		new_fam.resize(np)
		var by_sig: Dictionary = {}
		var merged := false
		var reps: Array = fam_members.keys()
		reps.sort()
		for r: int in reps:
			var sig := _family_signature(r, fam_members[r], fam,
					per_part, tags_of)
			var lead: int = by_sig.get(sig, -1)
			if lead == -1:
				by_sig[sig] = r
				for pi in fam_members[r]:
					new_fam[pi] = r
			else:
				merged = true
				for pi in fam_members[r]:
					new_fam[pi] = lead
		fam = new_fam
		if not merged:
			break

	# --- aggregates (dense family indices, first-occurrence order) ---
	var fam_rep := PackedInt32Array()
	var rep_seen := {}
	for pi in np:
		if not rep_seen.has(fam[pi]):
			rep_seen[fam[pi]] = true
			fam_rep.append(pi)
	var fam_index := {}
	for fi in fam_rep.size():
		fam_index[fam_rep[fi]] = fi
	for pi in np:
		family_of_part[pi] = fam_index[fam[pi]]
	family_count = fam_rep.size()
	family_nwords = (family_count + 63) >> 6
	for fi in family_count:
		assert(family_of_part[fam_rep[fi]] == fi,
				"family indices must be dense and rep-aligned")
	family_ids.clear()
	family_ids.resize(family_count)
	family_weights = PackedFloat64Array()
	family_weights.resize(family_count)
	var member_lists: Array = []
	member_lists.resize(family_count)
	for fi in family_count:
		member_lists[fi] = PackedInt32Array()
		family_ids[fi] = part_ids[fam_rep[fi]]
	for pi in np:
		var fi := family_of_part[pi]
		family_weights[fi] += part_weights[pi]
		var lst: PackedInt32Array = member_lists[fi]
		lst.append(pi)
		member_lists[fi] = lst
	largest_family_size = 0
	for fi in family_count:
		largest_family_size = maxi(largest_family_size,
				(member_lists[fi] as PackedInt32Array).size())
	family_members = member_lists

	# --- family rows: UNION over all members' raw dicts ---
	nb_mask.clear(); nb_empty.clear(); border_ok.clear()
	nb_mask.resize(family_count); nb_empty.resize(family_count)
	border_ok.resize(family_count)
	delta_has_outside.clear()
	delta_has_outside.resize(delta_list.size())
	delta_has_outside.fill(false)
	for fi in family_count:
		var mrow: Array = []; mrow.resize(delta_list.size())
		var erow: Array = []; erow.resize(delta_list.size())
		var brow: Array = []; brow.resize(delta_list.size())
		for di in delta_list.size():
			var pix: Vector2i = delta_pixel[di]
			var okey := "%d,%d" % [pix.x, pix.y]
			var m := PackedInt64Array()
			m.resize(family_nwords)
			var has_out := false
			var any_evidence := false
			for mi: int in (family_members[fi] as PackedInt32Array):
				var nb: Dictionary = (_neighbors.get(part_ids[mi], {})
						as Dictionary).get(okey, {})
				if nb.is_empty():
					continue
				any_evidence = true
				for nid: Variant in nb.keys():
					if nid == OUTSIDE:
						has_out = true
						continue
					var npi: int = _int_of.get(String(nid), -1)
					if npi == -1:
						continue
					var nfi := family_of_part[npi]
					m[nfi >> 6] |= 1 << (nfi & 63)
			mrow[di] = m
			erow[di] = not any_evidence   # evidence iff ANY member has arcs
			brow[di] = has_out
			if has_out:
				delta_has_outside[di] = true
		nb_mask[fi] = mrow; nb_empty[fi] = erow; border_ok[fi] = brow

	_compile_family_tags()


func _family_signature(rep: int, members: PackedInt32Array,
		fam: PackedInt32Array, per_part: Array, tags_of: Array) -> String:
	## Tags + per-offset sorted family-id MULTISETS aggregated over all
	## members. Multiset (not set): keeps option-off behavior identical to
	## the shipped exact grouping, and stays conservative for unions.
	var parts := PackedStringArray()
	for t: Variant in tags_of[rep]:
		parts.append(str(t))
	var blocks: Dictionary = per_part[rep]
	for k: String in blocks.keys():   # inserted sorted; iteration is sorted
		var acc := PackedInt32Array()
		for m: int in members:
			acc.append_array((per_part[m] as Dictionary).get(k,
					PackedInt32Array()))
		for i in acc.size():
			acc[i] = -1 if acc[i] < 0 else fam[acc[i]]
		acc.sort()
		var enc := PackedStringArray()
		enc.append(k)
		enc.append(str(acc.size()))
		for f in acc:
			enc.append(str(f))
		parts.append("|".join(enc))
	return "§".join(parts)


func _edge_signature_key(pi: int, depth: int, decoded: Array,
		tags_of: Array) -> String:
	## Initial-partition key: tags + per-side edge composition at `depth`.
	## With active terrain classes: sorted class-id multiset per side
	## (transparent/unclassed = -1, kept so transparency patterns matter).
	## Without: byte-exact strips (stronger than ID equality, still exact).
	var p: Part = _parts[part_ids[pi]]
	# Clamped depth: parts smaller than `depth` still contribute a shallower
	# strip here (PixelOverlap skips such parts entirely instead).
	var d_eff := mini(depth, mini(p.size.x, p.size.y))
	var sections := PackedStringArray()
	for t: Variant in tags_of[pi]:
		sections.append(str(t))
	var img := p.pixel_data.duplicate() as Image
	ImageOps.to_rgba8_in_place(img)
	var cls_map := StripUtil.class_map(img, decoded)
	var w := img.get_width()
	var data := img.get_data()
	for side_name: String in StripUtil.SIDES:
		var g := StripUtil.side(side_name, p.size)
		var start: Vector2i = g["start"]
		var along: Vector2i = g["along"]
		var inward: Vector2i = g["inward"]
		var span: int = g["span"]
		if decoded.is_empty():
			sections.append(StripUtil.bytes(data, w, d_eff, start, along,
					inward, span).hex_encode())
		else:
			var ids := StripUtil.classes(cls_map, w, d_eff, start, along,
					inward, span)
			ids.sort()
			var enc := PackedStringArray()
			for c in ids:
				enc.append(str(c))
			sections.append(",".join(enc))
	return "§".join(sections)


func _compile_family_tags() -> void:
	## Family-int tag masks, derived from the sparse part-int ones. Tag
	## memberships are small, so per-bit iteration here is cheap.
	_fam_tag_bits.clear()
	if family_nwords == 0:
		return
	for tag: String in _tag_bits:
		var pm: PackedInt64Array = _tag_bits[tag]
		var m := PackedInt64Array()
		m.resize(family_nwords)
		for w in pm.size():
			var v: int = pm[w]
			while v != 0:
				var low := v & -v
				v ^= low
				var pi := (w << 6) + BitMask.ctz(low)
				var fi := family_of_part[pi]
				m[fi >> 6] |= 1 << (fi & 63)
		_fam_tag_bits[tag] = m


func _fam_tag_mask(tag: String) -> PackedInt64Array:
	return _fam_tag_bits.get(tag, PackedInt64Array())


# --- rule compilation (family space) ---------------------------------------------

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


## A rule arc from slot s can prune only if EVERY candidate family in dom[s]
## sources some rule at that delta. dom[s] & f_rule_src_not[di] != 0 proves
## otherwise in O(family words) — usually one word — replacing a full revise.
func _build_rule_skip_tables() -> void:
	f_rule_src_not.clear()
	f_rule_src_not.resize(delta_list.size())
	for di in range(evidence_delta_count, delta_list.size()):
		var src: PackedInt64Array = f_rule_src[di]
		var inv := PackedInt64Array()
		inv.resize(family_nwords)
		for w in family_nwords:
			inv[w] = ~src[w]
		f_rule_src_not[di] = inv


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
	if not _fam_tag_bits.has(tag_a) or not _fam_tag_bits.has(tag_b):
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


## Append a rule-only delta column: every family starts fully allowed (no
## evidence at this offset, but "unobserved" must not mean "free" for an
## authored rule), nb_empty=false, no OUTSIDE evidence.
func _append_delta(o: Vector2i, pix: Vector2i) -> int:
	var di := delta_list.size()
	delta_list.append(o)
	delta_pixel.append(pix)
	_pixel_to_di[pix] = di
	delta_has_outside.append(false)
	var full := BitMask.full(family_nwords, family_count)
	for fi in family_count:
		nb_mask[fi].append(full)   # COW-shared; exclusion writes copy lazily
		nb_empty[fi].append(false)
		border_ok[fi].append(false)
	var zero := PackedInt64Array()
	zero.resize(family_nwords)
	f_rule_src.append(zero)
	return di


## Remove every dst-tag family bit from src-tag families' neighbor masks at
## delta di. If a src family had no evidence at this offset, start from the
## full mask — otherwise unknown_free would silently void the exclusion.
func _exclude_at(di: int, src_tag: String, dst_tag: String) -> void:
	var dst := _fam_tag_mask(dst_tag)
	var src := _fam_tag_mask(src_tag)
	if di >= evidence_delta_count:
		var u: PackedInt64Array = f_rule_src[di]
		for k in src.size():
			u[k] = u[k] | src[k]
		f_rule_src[di] = u                # COW write-back — required
	for w in src.size():
		var v: int = src[w]
		while v != 0:
			var low := v & -v
			v ^= low
			var fi := (w << 6) + BitMask.ctz(low)
			var m: PackedInt64Array
			if nb_empty[fi][di]:
				m = BitMask.full(family_nwords, family_count)
			else:
				m = (nb_mask[fi][di] as PackedInt64Array).duplicate()
			for k in m.size():
				m[k] = m[k] & ~dst[k]
			nb_mask[fi][di] = m
			nb_empty[fi][di] = false


# --- evidence query layer ---------------------------------------------------------

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


func derive_step() -> Vector2i:
	## Pixel distance between adjacent slots: smallest positive constraint
	## offset per axis, falling back to the tile size.
	var step := tile_size
	var min_x := -1
	var min_y := -1
	for off: Vector2i in get_offsets():
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
func derive_deltas(step: Vector2i) -> Array[Vector2i]:
	## Constraint offsets converted to slot units; non-grid offsets skipped.
	var deltas: Array[Vector2i] = []
	for off: Vector2i in get_offsets():
		if off.x % step.x != 0 or off.y % step.y != 0:
			continue
		var d := Vector2i(off.x / step.x, off.y / step.y)
		if d != Vector2i.ZERO and not deltas.has(d):
			deltas.append(d)
	return deltas


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


func f_mask_neighbors(fi: int, pixel_off: Vector2i) -> PackedInt64Array:
	## Family-int neighbor mask at a pixel offset. Bits are FAMILY ints.
	var di: int = _pixel_to_di.get(pixel_off, -1)
	return PackedInt64Array() if di == -1 else nb_mask[fi][di]


func family_of_part_id(part_id: String) -> int:
	## Family int for any member part id, or -1 if the part is not in the
	## index (disabled or unknown). Pins and slot queries resolve through
	## this, so any variant can be pinned, not just representatives.
	var pi: int = _int_of.get(part_id, -1)
	return -1 if pi < 0 else family_of_part[pi]
