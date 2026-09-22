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


## Called once per session with the evidence-derived deltas; groups parts
## into families, builds family-indexed per-delta rows, then compiles
## authored rules on top. Rule deltas may exceed the passed deltas —
## TileCollapse consumes _index.delta_list, so exclusions propagate
## without solver changes.
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
	_build_families()
	# Bind the solver-facing aliases to the canonical arrays (same objects,
	# not copies). Deliberately HERE rather than inside _build_families: the
	# tables are rebuilt in place across re-prepares, so one binding per
	# full prepare suffices, and rewriting _build_families can no longer
	# drop it.
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

func _build_families() -> void:
	## Iterative coarsening to a STABLE partition.
	##
	## Round 0: every part is its own family. Each round gives every part a
	## signature — its tag set plus, per evidence offset, the sorted
	## MULTISET of family ids of its allowed neighbors — and merges parts
	## with identical signatures. Families never split, so the family count
	## strictly decreases and the loop terminates; the fixpoint is stable:
	## every member of every family shares the same family-level neighbor
	## blocks at every offset.
	##
	## Soundness: build() adds both directions of every constraint, so
	## _neighbors is symmetric-closed. Under symmetric closure, stability
	## implies block-uniformity between families (complete-or-empty
	## bipartite arcs): x∈F arcing to y∈G puts the reverse arc in y's
	## outgoing set, stability copies it to every G member, and the reverse
	## generation copies it back to every F member. Complete bipartite
	## blocks are exactly what makes independent occurrence-weighted member
	## picks (Session._pick_member) reproduce the part-level model exactly.
	## The same closure rules out partial touches of a family, so multiset
	## (not set) comparison in the signature is exact.
	##
	## Mutual pairs — A and B each appearing in the other's neighbor sets —
	## are the canonical catch: their raw sets differ only by swapping
	## A↔B, which the family-level view of round 2 erases.
	var np := part_ids.size()
	family_of_part = PackedInt32Array()
	family_of_part.resize(np)
	family_of_part.fill(-1)

	# Pre-extract evidence once as int structures: per part, per sorted
	# offset key, the sorted neighbor part ints (OUTSIDE -> -1). Rounds
	# then only touch ints and family assignments.
	var per_part: Array = []          # pi -> Dictionary(offsetkey -> PackedInt32Array)
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

	# Sorted tags per part: parts with different tags never merge, keeping
	# authored-rule behavior per-member exact.
	var tags_of: Array = []
	tags_of.resize(np)
	for pi in np:
		var t: Array = (authored_tags.get(part_ids[pi], []) as Array).duplicate()
		t.sort()
		tags_of[pi] = t

	# --- coarsening rounds ---
	var fam := PackedInt32Array()     # part int -> current family rep part int
	fam.resize(np)
	for pi in np:
		fam[pi] = pi
	while true:
		var groups: Dictionary = {}   # signature -> first (lowest-index) member
		var assign := PackedInt32Array()
		assign.resize(np)
		for pi in np:
			var sig := _stability_signature(pi, fam, per_part, tags_of)
			var lead: int = groups.get(sig, -1)
			if lead == -1:
				groups[sig] = pi
				assign[pi] = pi
			else:
				assign[pi] = lead
		var old_count := 0
		var seen := {}
		for pi in np:
			if not seen.has(fam[pi]):
				seen[fam[pi]] = true
				old_count += 1
		if groups.size() >= old_count:
			break   # fixpoint: stable partition, sound by construction
		fam = assign

	# --- family aggregates (unchanged from here down) ---
	var fam_rep := PackedInt32Array()
	var rep_seen := {}
	for pi in np:
		if not rep_seen.has(fam[pi]):
			rep_seen[fam[pi]] = true
			fam_rep.append(pi)
	
	# Remap coarsening labels (representative part ints) to dense family
	# indices in first-occurrence order — family_of_part must be 0..count-1,
	# everything downstream (weights, tag bits, neighbor masks) indexes by it.
	var fam_index := {}
	for fi in fam_rep.size():
		fam_index[fam_rep[fi]] = fi
	for pi in np:
		family_of_part[pi] = fam_index[fam[pi]]

	family_count = fam_rep.size()
	family_nwords = (family_count + 63) >> 6
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
		member_lists[fi] = lst   # packed arrays are COW: write back required
	largest_family_size = 0
	for fi in family_count:
		largest_family_size = maxi(largest_family_size,
				(member_lists[fi] as PackedInt32Array).size())
	family_members = member_lists

	# Family rows from the representative's raw dicts. Members share the
	# rep's behavior: stable partition ⟹ identical family-level blocks, and
	# (by the closure argument above) identical raw partner sets.
	nb_mask.clear(); nb_empty.clear(); border_ok.clear()
	nb_mask.resize(family_count); nb_empty.resize(family_count)
	border_ok.resize(family_count)
	delta_has_outside.clear()
	delta_has_outside.resize(delta_list.size())
	delta_has_outside.fill(false)
	for fi in family_count:
		var by_offset: Dictionary = _neighbors.get(family_ids[fi], {})
		var mrow: Array = []; mrow.resize(delta_list.size())
		var erow: Array = []; erow.resize(delta_list.size())
		var brow: Array = []; brow.resize(delta_list.size())
		for di in delta_list.size():
			var pix: Vector2i = delta_pixel[di]
			var nb: Dictionary = by_offset.get("%d,%d" % [pix.x, pix.y], {})
			var m := PackedInt64Array()
			m.resize(family_nwords)
			var has_out := false
			for nid: Variant in nb.keys():
				if nid == OUTSIDE:
					has_out = true
					continue
				var npi: int = _int_of.get(String(nid), -1)
				if npi == -1:
					continue   # defensive; build() filters disabled parts
				var nfi := family_of_part[npi]
				m[nfi >> 6] |= 1 << (nfi & 63)
			mrow[di] = m
			erow[di] = nb.is_empty()   # OUTSIDE-only evidence is NOT empty
			brow[di] = has_out
			if has_out:
				delta_has_outside[di] = true
		nb_mask[fi] = mrow; nb_empty[fi] = erow; border_ok[fi] = brow

	_compile_family_tags()


func _stability_signature(pi: int, fam: PackedInt32Array, per_part: Array,
		tags_of: Array) -> String:
	## Tag set + per-offset sorted family-id MULTISETS, as one string.
	## Multiset (with repeats) rather than set: two parts touching different
	## counts of the same family must not merge; symmetric closure makes
	## partial touches impossible for well-formed models, so equal
	## multisets here ⟺ interchangeable behavior.
	var parts := PackedStringArray()
	for t: Variant in tags_of[pi]:
		parts.append(str(t))
	var blocks: Dictionary = per_part[pi]
	for k: String in blocks.keys():   # keys were sorted at extraction
		var ids: PackedInt32Array = blocks[k]
		var fams := PackedInt32Array()
		fams.resize(ids.size())
		for i in ids.size():
			fams[i] = -1 if ids[i] < 0 else fam[ids[i]]
		fams.sort()
		var enc := PackedStringArray()
		enc.append(k)
		enc.append(str(fams.size()))
		for f in fams:
			enc.append(str(f))
		parts.append("|".join(enc))
	return "§".join(parts)


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
				var pi := (w << 6) + TileCollapse._ctz(low)
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
	var full := TileCollapse.mask_full(family_nwords, family_count)
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
			var fi := (w << 6) + TileCollapse._ctz(low)
			var m: PackedInt64Array
			if nb_empty[fi][di]:
				m = TileCollapse.mask_full(family_nwords, family_count)
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
