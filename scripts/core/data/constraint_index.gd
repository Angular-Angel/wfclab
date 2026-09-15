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
