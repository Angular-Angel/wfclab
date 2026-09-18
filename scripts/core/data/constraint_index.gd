class_name ConstraintIndex extends RefCounted
## Fast query layer over the materialized parts and constraints. Applies
## enabled flags and weight overrides once, centrally — every synthesizer
## sees the same edited world. Built as an immutable snapshot: safe to read
## from a worker thread even if the UI keeps editing.

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

# --- per-delta tables (filled by prepare()) ---------------------------------
var delta_list: Array[Vector2i] = []      # slot-unit deltas, _derive_deltas order
var delta_pixel: Array[Vector2i] = []     # delta * step
var delta_has_outside: Array[bool] = []   # replaces _has_outside_evidence()
var nb_mask: Array = []                   # [part_int][delta_int] -> PackedInt64Array
var nb_empty: Array = []                  # [part_int][delta_int] -> bool
var border_ok: Array = []                 # [part_int][delta_int] -> bool (has OUTSIDE)
var _pixel_to_di: Dictionary = {}         # Vector2i -> delta index


func has_outside() -> bool:
	return _has_outside

static func build(parts: Array[Part], constraints: Array[Constraint]) -> ConstraintIndex:
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
	return idx


func prepare(deltas: Array[Vector2i], step: Vector2i) -> void:
	if part_ids.is_empty():
		for id: String in _parts.keys():          # order = old dict order
			_int_of[id] = part_ids.size()
			part_ids.append(id)
			part_weights.append(_weights.get(id, 0.0))
		nwords = (part_ids.size() + 63) >> 6
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
			var dict_empty := nb.is_empty()
			for nid: String in nb.keys():
				if nid == OUTSIDE:
					has_out = true
					continue
				if not _int_of.has(nid):
					continue
				m[_int_of[nid] >> 6] |= 1 << (_int_of[nid] & 63)
			mrow[di] = m
			erow[di] = dict_empty      # was: all_zero
			brow[di] = has_out
			if has_out:
				delta_has_outside[di] = true
		nb_mask.append(mrow); nb_empty.append(erow); border_ok.append(brow)


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
