class_name PixelOverlap extends ConstraintTechnique
## Overlap compatibility: parts may sit adjacent when their facing pixel
## strips match within tolerance. Comparative only — no occurrence data —
## so pairs never seen together in the sources may still be declared legal.
##
## Relaxations (both default 0 = strict):
##   allowed_omissions — pass when at most this many pixels of the facing
##     strip have no satisfying counterpart.
##   flex — a pixel may be satisfied by a counterpart displaced up to this
##     many pixels along the seam (above/below for horizontal adjacency),
##     same depth index, within tolerance.
##
## Terrain key: when AppData's terrain key defines enabled classes, strips
## are classified through TerrainMapper before extraction — a pixel
## matching a class compares as that class's representative color, so
## different colors of the same terrain are interchangeable. `tolerance`
## then only meaningfully applies to unclassed pixels (and to distances
## between representatives — keep them well apart). Classification is
## deterministic, so the rigid exact fast path in _match still applies.
func get_id() -> StringName:
	return &"pixel_overlap"


func get_display_name() -> String:
	return "Pixel Overlap"


func get_parameter_specs() -> Array[Dictionary]:
	return [
		{"key": "overlap_layers", "label": "Overlap Layers", "type": "int",
		"default": 2, "min": 1, "max": 64},
		{"key": "tolerance", "label": "Tolerance", "type": "int",
		"default": 0, "min": 0, "max": 256},
		{"key": "allowed_omissions", "label": "Allowed Omissions",
		"type": "int", "default": 0, "min": 0, "max": 256},
		{"key": "flex", "label": "Flex", "type": "int",
		"default": 0, "min": 0, "max": 64},
	]


func extract(parts: Array[Part], images: Array[ImageAssetData],
		params: Dictionary, report_progress: Callable) -> Array[Constraint]:
	var result: Array[Constraint] = []
	if parts.size() < 2:
		return result
	var depth := maxi(1, int(params.get("overlap_layers", 2)))
	var tolerance := maxi(0, int(params.get("tolerance", 0)))
	var omissions := maxi(0, int(params.get("allowed_omissions", 0)))
	var flex := maxi(0, int(params.get("flex", 0)))
	var groups: Array = AppData.active_terrain_classes()
	var ordered: Array[Part] = []
	ordered.assign(parts)
	ordered.sort_custom(func(a: Part, b: Part) -> bool: return a.id < b.id)

	# Strips indexed FROM THE SEAM: u = 0 touches the neighbor, u = depth-1
	# is deepest. v runs along the seam. Pixel (u, v) = bytes at
	# (v * depth + u) * 4. Both sides of a pair therefore align seam-to-seam.
	var strips: Dictionary = {}   # part_id -> {side: PackedByteArray}
	# --- strip extraction: O(parts) image work; fixed 20% slice ------------
	var strips_share := 0.2
	var total := maxi(ordered.size(), 1)
	var done := 0
	for p: Part in ordered:
		if p.size.x >= depth and p.size.y >= depth:
			var img := p.pixel_data.duplicate() as Image
			if img.is_compressed():
				img.decompress()
			img.convert(Image.FORMAT_RGBA8)
			if not groups.is_empty():
				TerrainMapper.apply(img, groups)   # disposable copy; in place
			strips[p.id] = {
				"right": _strip(img, depth, Vector2i(p.size.x - 1, 0),
					Vector2i(0, 1), Vector2i(-1, 0), p.size.y),
				"left": _strip(img, depth, Vector2i(0, 0),
					Vector2i(0, 1), Vector2i(1, 0), p.size.y),
				"bottom": _strip(img, depth, Vector2i(0, p.size.y - 1),
					Vector2i(1, 0), Vector2i(0, -1), p.size.x),
				"top": _strip(img, depth, Vector2i(0, 0),
					Vector2i(1, 0), Vector2i(0, 1), p.size.x),
			}
		done += 1
		report_progress.call(strips_share * float(done) / float(total))

	var aggregate: Dictionary = {}
	var match_span := 1.0 - strips_share
	if tolerance == 0 and flex == 0 and omissions == 0:
		# --- strict path: hash join (byte equality => bucket lookup) --------
		var left_buckets: Dictionary = {}   # key -> Array[Part]
		var top_buckets: Dictionary = {}
		for b: Part in ordered:
			var sb: Dictionary = strips.get(b.id, {})
			if sb.is_empty():
				continue
			var lk := _bucket_key(b.size, sb["left"])
			if not left_buckets.has(lk):
				left_buckets[lk] = []
			(left_buckets[lk] as Array).append(b)
			var tk := _bucket_key(b.size, sb["top"])
			if not top_buckets.has(tk):
				top_buckets[tk] = []
			(top_buckets[tk] as Array).append(b)
		var n := ordered.size()
		for i in n:
			if i % 64 == 63 or i == n - 1:
				report_progress.call(strips_share
						+ match_span * float(i + 1) / float(maxi(n, 1)))
			var a: Part = ordered[i]
			var sa: Dictionary = strips.get(a.id, {})
			if sa.is_empty():
				continue
			var right: PackedByteArray = sa["right"]
			for b: Part in left_buckets.get(_bucket_key(a.size, right), []):
				if right == (strips[b.id]["left"] as PackedByteArray):
					_record(aggregate, a, b, Vector2i(a.size.x, 0))
			var bottom: PackedByteArray = sa["bottom"]
			for b: Part in top_buckets.get(_bucket_key(a.size, bottom), []):
				if bottom == (strips[b.id]["top"] as PackedByteArray):
					_record(aggregate, a, b, Vector2i(0, a.size.y))
	else:
		# --- fuzzy path: distinct-strip matching with sum-window pruning ----
		# Each relation gets half the remaining progress slice.
		var half := match_span * 0.5
		_match_sides(aggregate, strips, ordered, "right", "left", true,
				depth, tolerance, omissions, flex,
				strips_share, half, report_progress)
		_match_sides(aggregate, strips, ordered, "bottom", "top", false,
				depth, tolerance, omissions, flex,
				strips_share + half, half, report_progress)

	# Deterministic output without a per-object comparator: sorting the key
	# strings natively is far cheaper than sort_custom over Constraint objects.
	var keys: Array = aggregate.keys()
	keys.sort()
	var list: Array = []
	list.resize(keys.size())
	for i in keys.size():
		list[i] = aggregate[keys[i]]
	result.assign(list)
	return result


func _match_sides(aggregate: Dictionary, strips: Dictionary,
		ordered: Array[Part], a_side: String, b_side: String,
		horizontal: bool, depth: int, tolerance: int, omissions: int,
		flex: int, base: float, span: float, report_progress: Callable) -> void:
	## One fuzzy relation (e.g. a.right ~ b.left) over DISTINCT strip groups.
	## Parts sharing a byte-identical strip match identically against any
	## candidate, so they are matched once per group and the hit expands to
	## every part pair. With flex == 0, candidate groups are pre-pruned by a
	## provable byte-sum bound; with flex > 0 the bound does not hold and all
	## same-size groups are compared.
	# 1) Group parts by (size, strip bytes). hex_encode() keys are exact, so
	#    there is no collision handling at all.
	var a_groups: Dictionary = {}
	var b_groups: Dictionary = {}
	for p: Part in ordered:
		var s: Dictionary = strips.get(p.id, {})
		if s.is_empty():
			continue
		_group_strip(a_groups, p, s[a_side])
		_group_strip(b_groups, p, s[b_side])

	# 2) Bucket b groups by tile size (preserves the uniform-grid size guard);
	#    when pruning, sort each bucket by byte-sum for window queries.
	var by_size: Dictionary = {}   # "w,h" -> {groups: Array, sums: Array}
	for key: String in b_groups:
		var g: Dictionary = b_groups[key]
		var sk := "%d,%d" % [(g["size"] as Vector2i).x, (g["size"] as Vector2i).y]
		if not by_size.has(sk):
			by_size[sk] = {"groups": [], "sums": []}
		((by_size[sk] as Dictionary)["groups"] as Array).append(g)
	var prune := flex == 0
	if prune:
		for sk: String in by_size:
			var entry: Dictionary = by_size[sk]
			var gs: Array = entry["groups"]
			# Tie-break on key so equal sums stay deterministic.
			gs.sort_custom(func(x: Dictionary, y: Dictionary) -> bool:
				if int(x["sum"]) != int(y["sum"]):
					return int(x["sum"]) < int(y["sum"])
				return String(x["key"]) < String(y["key"]))
			var sums: Array = []
			sums.resize(gs.size())
			for i in gs.size():
				sums[i] = int((gs[i] as Dictionary)["sum"])
			entry["sums"] = sums

	# 3) Match each distinct a group against its candidate b groups.
	var a_keys: Array = a_groups.keys()
	a_keys.sort()
	var processed := 0
	for a_key: String in a_keys:
		var ga: Dictionary = a_groups[a_key]
		var size: Vector2i = ga["size"]
		var sk := "%d,%d" % [size.x, size.y]
		var entry: Dictionary = by_size.get(sk, {})
		if not entry.is_empty():
			var cands: Array = entry["groups"]
			if prune:
				cands = _window(entry["sums"], cands, int(ga["sum"]),
						_sum_window(size, depth, tolerance, omissions,
						horizontal))
			var offset := Vector2i(size.x, 0) if horizontal \
					else Vector2i(0, size.y)
			var span_px := size.y if horizontal else size.x
			var a_bytes: PackedByteArray = ga["bytes"]
			var a_parts: Array = ga["parts"]
			for gb: Dictionary in cands:
				var hit := false
				if prune:
					hit = _match_aligned(a_bytes, gb["bytes"], tolerance,
							omissions)
				else:
					hit = _match(a_bytes, gb["bytes"], depth, span_px,
							tolerance, flex, omissions)
				if hit:
					for pa: Part in a_parts:
						for pb: Part in gb["parts"]:
							_record(aggregate, pa, pb, offset)
		processed += 1
		report_progress.call(base + span * float(processed)
				/ float(maxi(a_keys.size(), 1)))


func _group_strip(groups: Dictionary, p: Part, strip: PackedByteArray) -> void:
	var key := "%d,%d|%s" % [p.size.x, p.size.y, strip.hex_encode()]
	if groups.has(key):
		((groups[key] as Dictionary)["parts"] as Array).append(p)
		return
	var sum := 0
	for b in strip:
		sum += b
	groups[key] = {"key": key, "size": p.size, "bytes": strip,
			"sum": sum, "parts": [p]}


func _window(sums: Array, groups: Array, target: int, window: int) -> Array:
	## Groups whose byte-sum lies within [target - window, target + window].
	# bsearch(before=true) => first index with sum >= lo;
	# bsearch(before=false) => first index with sum > hi.
	var lo: int = sums.bsearch(target - window, true)
	var hi: int = sums.bsearch(target + window, false)
	return groups.slice(lo, hi)


func _sum_window(size: Vector2i, depth: int, tolerance: int,
		omissions: int, horizontal: bool) -> int:
	## Provable bound on |sum(a) - sum(b)| for a successful flex == 0 match:
	## satisfied pixels differ by <= tolerance per channel; each omitted pixel
	## (at most `omissions` of them) differs by <= 255 per channel.
	var span_px := size.y if horizontal else size.x
	var pixels := span_px * depth
	var wild := 4 * mini(omissions, pixels)
	return (4 * pixels - wild) * tolerance + wild * 255


func _match_aligned(sa: PackedByteArray, sb: PackedByteArray,
		tolerance: int, omissions: int) -> bool:
	## flex == 0 matcher: strips align 1:1, so a flat pixel loop replaces the
	## per-pixel _satisfied() calls. Byte order (v*depth+u) matches _match()'s
	## iteration order, so semantics — including per-pixel failure counting —
	## are identical.
	var failures := 0
	for p in range(0, sa.size(), 4):
		if absi(sa[p] - sb[p]) > tolerance \
				or absi(sa[p + 1] - sb[p + 1]) > tolerance \
				or absi(sa[p + 2] - sb[p + 2]) > tolerance \
				or absi(sa[p + 3] - sb[p + 3]) > tolerance:
			failures += 1
			if failures > omissions:
				return false
	return true


func _bucket_key(size: Vector2i, strip: PackedByteArray) -> String:
	## PackedByteArray has no hash() member in this Godot version; the global
	## hash() function hashes any Variant by content. Collisions are harmless:
	## the join re-checks byte equality before recording a constraint.
	return "%d,%d|%d" % [size.x, size.y, hash(strip)]


func _strip(img: Image, depth: int, start: Vector2i, along: Vector2i,
		inward: Vector2i, span: int) -> PackedByteArray:
	## Copies depth × span pixels from `start` (a point on the seam),
	## stepping `along` across the seam and `inward` away from it.
	## Outer loop = v (along the seam), inner = u (seam inward).
	var w := img.get_width()
	var bytes := img.get_data()
	var out := PackedByteArray()
	out.resize(depth * span * 4)
	var k := 0
	for s in span:
		var base := start + along * s
		for u in depth:
			var p := base + inward * u
			var o := (p.y * w + p.x) * 4
			out[k] = bytes[o]
			out[k + 1] = bytes[o + 1]
			out[k + 2] = bytes[o + 2]
			out[k + 3] = bytes[o + 3]
			k += 4
	return out

func _match(sa: PackedByteArray, sb: PackedByteArray, depth: int, span: int,
		tolerance: int, flex: int, omissions: int) -> bool:
	## True when at most `omissions` pixels of `sa` lack a satisfying
	## counterpart in `sb` (same u, within ±flex along the seam, in tolerance).
	if tolerance == 0 and flex == 0 and omissions == 0:
		return sa == sb   # rigid exact: whole-array equality, hard fast path
	var failures := 0
	for v in span:
		for u in depth:
			if _satisfied(sa, sb, u, v, depth, span, tolerance, flex):
				continue
			failures += 1
			if failures > omissions:
				return false
	return true

func _satisfied(sa: PackedByteArray, sb: PackedByteArray, u: int, v: int,
		depth: int, span: int, tolerance: int, flex: int) -> bool:
	var ao := (v * depth + u) * 4
	for dv in range(-flex, flex + 1):
		var vv := v + dv
		if vv < 0 or vv >= span:
			continue
		var bo := (vv * depth + u) * 4
		if absi(sa[ao] - sb[bo]) <= tolerance \
				and absi(sa[ao + 1] - sb[bo + 1]) <= tolerance \
				and absi(sa[ao + 2] - sb[bo + 2]) <= tolerance \
				and absi(sa[ao + 3] - sb[bo + 3]) <= tolerance:
			return true
	return false

func _record(aggregate: Dictionary, a: Part, b: Part, offset: Vector2i) -> void:
	var key := "ov|%s>%s|%d,%d" % [a.id, b.id, offset.x, offset.y]
	if aggregate.has(key):
		return
	var c := Constraint.new()
	c.type = &"pixel_overlap"
	c.params = {"offset": offset, "symmetric": false}
	c.participants = [
		{"part_id": a.id, "role": "a"},
		{"part_id": b.id, "role": "b"},
	]
	c.id = "o_%s_%s_%d_%d" % [
		a.id.substr(2, 6), b.id.substr(2, 6), offset.x, offset.y]
	c.evidence.append({"image_id": "overlap", "positions": []})  # weight = 1
	aggregate[key] = c
