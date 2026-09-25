class_name PixelOverlap extends ConstraintTechnique
## Overlap compatibility: parts may sit adjacent when their facing pixel
## strips match within tolerance. Comparative only — no occurrence data —
## so pairs never seen together in the sources may still be declared legal.
##
## Relaxations (all default 0 = strict):
##   allowed_omissions — pass when at most this many pixels of EACH facing
##     strip have no satisfying counterpart (two-sided: per direction).
##   flex — global positional flex: a pixel may be satisfied by a
##     counterpart displaced up to this many pixels along the seam.
##   per-class flex (terrain key) — a classed pixel's flex comes from its
##     class's "flex" field, overriding the global value for that pixel;
##     unclassed pixels use the global flex. Flex loosens POSITION only:
##     cross-class color identity is still enforced by tolerance.
##
## Two-sided matching: a pair is legal only when every pixel of EACH side
## finds a counterpart on the other (a-pixels budgeted by a-side flex,
## b-pixels by b-side flex). With zero total flex capability this reduces
## exactly to the old one-sided aligned comparison, so strict models are
## unchanged.
##
## Acceleration: a relation whose two strips contain NO flex-capable pixel
## is deterministic-aligned — byte equality (tolerance 0, omissions 0) via
## the hash join, else the aligned counter + byte-sum window prune. Loose
## relations use distinct-strip grouping + the two-way matcher (the sum
## prune does not hold there: flex can reuse one counterpart twice).
## Terrain key: strips are classified through TerrainMapper before
## extraction; classification and byte rewrite share one pass.
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
		params: Dictionary, report_progress: Callable,
		terrain_classes: Array = []) -> Array[Constraint]:
	var result: Array[Constraint] = []
	if parts.size() < 2:
		return result
	var depth := maxi(1, int(params.get("overlap_layers", 2)))
	var tolerance := maxi(0, int(params.get("tolerance", 0)))
	var omissions := maxi(0, int(params.get("allowed_omissions", 0)))
	var flex := maxi(0, int(params.get("flex", 0)))
	var groups: Array = terrain_classes
	var decoded: Array = TerrainMapper.prepare(groups)
	var class_flex := PackedInt32Array()
	class_flex.resize(decoded.size())
	for ci in decoded.size():
		class_flex[ci] = int(decoded[ci]["flex"])
	var ordered: Array[Part] = []
	ordered.assign(parts)
	Ids.by_id(ordered)

	# Strips indexed FROM THE SEAM: u = 0 touches the neighbor, u = depth-1
	# is deepest. v runs along the seam. Byte (u, v) at (v*depth+u)*4; the
	# class strip records each pixel's decoded-class id (-1 unclassed), in
	# the same order.
	var strips: Dictionary = {}   # part_id -> per-side bytes/cls/loose
	# --- strip extraction: O(parts) image work; fixed 20% slice ------------
	var strips_share := 0.2
	var total := maxi(ordered.size(), 1)
	var done := 0
	for p: Part in ordered:
		if p.size.x >= depth and p.size.y >= depth:
			var img := p.pixel_data.duplicate() as Image
			ImageOps.to_rgba8_in_place(img)
			var cls_map := StripUtil.class_map(img, decoded)
			var w := img.get_width()
			var data := img.get_data()
			var entry := {}
			for side_name: String in StripUtil.SIDES:
				var g := StripUtil.side(side_name, p.size)
				var start: Vector2i = g["start"]
				var along: Vector2i = g["along"]
				var inward: Vector2i = g["inward"]
				var span: int = g["span"]
				var cls := StripUtil.classes(cls_map, w, depth,
						start, along, inward, span)
				entry[side_name] = StripUtil.bytes(data, w, depth,
						start, along, inward, span)
				entry[side_name + "_cls"] = cls
				entry[side_name + "_loose"] = _strip_loose(cls, class_flex, flex)
			strips[p.id] = entry
		done += 1
		report_progress.call(strips_share * float(done) / float(total))

	var aggregate: Dictionary = {}
	var match_span := 1.0 - strips_share
	var half := match_span * 0.5
	_match_sides(aggregate, strips, ordered, "right", "left", true,
			depth, tolerance, omissions, flex, class_flex,
			strips_share, half, report_progress)
	_match_sides(aggregate, strips, ordered, "bottom", "top", false,
			depth, tolerance, omissions, flex, class_flex,
			strips_share + half, half, report_progress)

	# Deterministic output via native key-string sort.
	var keys: Array = aggregate.keys()
	keys.sort()
	var list: Array = []
	list.resize(keys.size())
	for i in keys.size():
		list[i] = aggregate[keys[i]]
	result.assign(list)
	return result


# --- matching ---------------------------------------------------------------------

func _match_sides(aggregate: Dictionary, strips: Dictionary,
		ordered: Array[Part], a_side: String, b_side: String,
		horizontal: bool, depth: int, tolerance: int, omissions: int,
		global_flex: int, class_flex: PackedInt32Array,
		base: float, span: float, report_progress: Callable) -> void:
	## One relation (a.side ~ b.side) over DISTINCT strip groups. See the
	## candidate-selection summary in the class comment.
	# 1) distinct groups keyed by (size, bytes, class ids)
	var a_groups: Dictionary = {}
	var b_groups: Dictionary = {}
	for p: Part in ordered:
		var s: Dictionary = strips.get(p.id, {})
		if s.is_empty():
			continue
		_group_strip(a_groups, p, s[a_side], s[a_side + "_cls"],
				s[a_side + "_loose"])
		_group_strip(b_groups, p, s[b_side], s[b_side + "_cls"],
				s[b_side + "_loose"])

	# 2) per-size b index: strict groups (bucketed / sum-sorted) + loose
	var use_bucket := tolerance == 0 and omissions == 0
	var by_size: Dictionary = {}
	for key: String in b_groups:
		var g: Dictionary = b_groups[key]
		var sz: Vector2i = g["size"]
		var sk := "%d,%d" % [sz.x, sz.y]
		var entry: Dictionary = by_size.get(sk, {})
		if entry.is_empty():
			entry = {"strict": [], "loose": [], "sorted": false,
					"sums": [], "bucket": {}}
			by_size[sk] = entry
		if bool(g["loose"]):
			(entry["loose"] as Array).append(g)
		else:
			(entry["strict"] as Array).append(g)
			if use_bucket:
				var bk: String = (g["bytes"] as PackedByteArray).hex_encode()
				var bucket: Dictionary = entry["bucket"]
				if not bucket.has(bk):
					bucket[bk] = []
				for pb: Part in (g["parts"] as Array):
					(bucket[bk] as Array).append(pb)

	# 3) match each distinct a group against its candidates
	var a_keys: Array = a_groups.keys()
	a_keys.sort()
	var processed := 0
	for a_key: String in a_keys:
		var ga: Dictionary = a_groups[a_key]
		var size: Vector2i = ga["size"]
		var sk := "%d,%d" % [size.x, size.y]
		var entry: Dictionary = by_size.get(sk, {})
		if not entry.is_empty():
			var a_bytes: PackedByteArray = ga["bytes"]
			var a_parts: Array = ga["parts"]
			var seam := size.y if horizontal else size.x
			var a_loose := bool(ga["loose"])
			if not a_loose and use_bucket:
				# strict a: byte equality against all strict b (hex keys are
				# exact, no re-verification needed)...
				var hit: Array = (entry["bucket"] as Dictionary).get(
						(a_bytes as PackedByteArray).hex_encode(), [])
				for pb: Part in hit:
					for pa: Part in a_parts:
						_record(aggregate, pa, pb, Vector2i(size.x, 0)
								if horizontal else Vector2i(0, size.y))
			elif not a_loose:
				# strict a, tolerant/omitting: window prune + aligned counter
				var strict_list: Array = entry["strict"]
				if not strict_list.is_empty():
					if not bool(entry["sorted"]):
						strict_list.sort_custom(
								func(x: Dictionary, y: Dictionary) -> bool:
							if int(x["sum"]) != int(y["sum"]):
								return int(x["sum"]) < int(y["sum"])
							return String(x["key"]) < String(y["key"]))
						var sums: Array = []
						sums.resize(strict_list.size())
						for i in strict_list.size():
							sums[i] = int((strict_list[i] as Dictionary)["sum"])
						entry["sums"] = sums
						entry["sorted"] = true
					var window := _sum_window(size, depth, tolerance,
							omissions, horizontal)
					for gb: Dictionary in _window(entry["sums"], strict_list,
							int(ga["sum"]), window):
						if _match_aligned(a_bytes, gb["bytes"],
								tolerance, omissions):
							_record_pairs(aggregate, a_parts, gb["parts"],
									size, horizontal)
			else:
				# loose a: two-way matcher against every same-size b group
				for gb: Dictionary in entry["strict"]:
					if _match_two_way(a_bytes, ga["cls"], gb["bytes"],
							gb["cls"], depth, seam, tolerance, class_flex,
							global_flex, omissions):
						_record_pairs(aggregate, a_parts, gb["parts"],
								size, horizontal)
				for gb: Dictionary in entry["loose"]:
					if _match_two_way(a_bytes, ga["cls"], gb["bytes"],
							gb["cls"], depth, seam, tolerance, class_flex,
							global_flex, omissions):
						_record_pairs(aggregate, a_parts, gb["parts"],
								size, horizontal)
			if not a_loose:
				# ...and the loose b groups, which byte equality cannot
				# cover (a loose match need not be byte-equal).
				for gb: Dictionary in entry["loose"]:
					if _match_two_way(a_bytes, ga["cls"], gb["bytes"],
							gb["cls"], depth, seam, tolerance, class_flex,
							global_flex, omissions):
						_record_pairs(aggregate, a_parts, gb["parts"],
								size, horizontal)
		processed += 1
		report_progress.call(base + span * float(processed)
				/ float(maxi(a_keys.size(), 1)))


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
	# kept inline (hot loop); shared logic in ColorMath.matches
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
		# kept inline (hot loop); shared logic in ColorMath.matches
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
	c.id = Ids.constraint(a.id, b.id, offset, "o_")
	c.evidence.append({"image_id": "overlap", "positions": []})  # weight = 1
	aggregate[key] = c


func _record_pairs(aggregate: Dictionary, a_parts: Array, b_parts: Array,
		size: Vector2i, horizontal: bool) -> void:
	var offset := Vector2i(size.x, 0) if horizontal else Vector2i(0, size.y)
	for pa: Part in a_parts:
		for pb: Part in b_parts:
			_record(aggregate, pa, pb, offset)


func _strip_loose(cls_arr: PackedInt32Array, class_flex: PackedInt32Array,
		global_flex: int) -> bool:
	## True when any pixel of the strip can use flex > 0.
	if global_flex > 0:
		return true
	if cls_arr.is_empty():
		return false
	for c in cls_arr:
		if c >= 0 and class_flex[c] > 0:
			return true
	return false


func _group_strip(groups: Dictionary, p: Part, strip: PackedByteArray,
		cls: PackedInt32Array, loose: bool) -> void:
	## Distinct-strip groups: identical bytes AND identical class ids share
	# a group (byte-equal strips with different classifications are kept
	# apart so the matcher's flex decisions stay group-uniform).
	var cls_key := ""
	if not cls.is_empty():
		var sa := PackedStringArray()
		for c in cls:
			sa.append(str(c))
		cls_key = ",".join(sa)
	var key := "%d,%d|%s|%s" % [p.size.x, p.size.y, strip.hex_encode(), cls_key]
	if groups.has(key):
		((groups[key] as Dictionary)["parts"] as Array).append(p)
		return
	var sum := 0
	for b in strip:
		sum += b
	groups[key] = {"key": key, "size": p.size, "bytes": strip, "cls": cls,
			"loose": loose, "sum": sum, "parts": [p]}


func _match_two_way(sa: PackedByteArray, ca: PackedInt32Array,
		sb: PackedByteArray, cb: PackedInt32Array, depth: int, span: int,
		tolerance: int, class_flex: PackedInt32Array, global_flex: int,
		omissions: int) -> bool:
	## Two-sided matcher: each direction gets its own omissions budget.
	## A counterpart may be reused within a direction (no consumption), so
	## the byte-sum prune is invalid here — by design, this path never uses
	## it.
	return _one_way(sa, ca, sb, cb, depth, span, tolerance, class_flex,
			global_flex, omissions) \
			and _one_way(sb, cb, sa, ca, depth, span, tolerance, class_flex,
			global_flex, omissions)


func _one_way(sa: PackedByteArray, ca: PackedInt32Array,
		sb: PackedByteArray, cb: PackedInt32Array, depth: int, span: int,
		tolerance: int, class_flex: PackedInt32Array, global_flex: int,
		omissions: int) -> bool:
	var failures := 0
	for v in span:
		for u in depth:
			var k := v * depth + u
			var f := global_flex
			if not ca.is_empty():
				var c := ca[k]
				if c >= 0:
					f = class_flex[c]
			var ao := k * 4
			var ok := false
			if f == 0:
				ok = _px_match(sa, ao, sb, ao, tolerance)
			else:
				# dv = 0 first, then ±1, ±2...: identical-byte neighbors
				# (the common case) resolve on the first compare.
				if _px_match(sa, ao, sb, ao, tolerance):
					ok = true
				else:
					for d in range(1, f + 1):
						var vv := v + d
						if vv < span and _px_match(sa, ao, sb,
								(vv * depth + u) * 4, tolerance):
							ok = true
							break
						vv = v - d
						if vv >= 0 and _px_match(sa, ao, sb,
								(vv * depth + u) * 4, tolerance):
							ok = true
							break
			if not ok:
				failures += 1
				if failures > omissions:
					return false
	return true


func _px_match(sa: PackedByteArray, ao: int, sb: PackedByteArray, bo: int,
		tolerance: int) -> bool:
	# kept inline (hot loop); shared logic in ColorMath.matches
	if tolerance == 0:
		return sa[ao] == sb[bo] and sa[ao + 1] == sb[bo + 1] \
				and sa[ao + 2] == sb[bo + 2] and sa[ao + 3] == sb[bo + 3]
	return absi(sa[ao] - sb[bo]) <= tolerance \
			and absi(sa[ao + 1] - sb[bo + 1]) <= tolerance \
			and absi(sa[ao + 2] - sb[bo + 2]) <= tolerance \
			and absi(sa[ao + 3] - sb[bo + 3]) <= tolerance
