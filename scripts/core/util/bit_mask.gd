class_name BitMask extends RefCounted
## Bit-set toolkit over PackedInt64Array masks, 64 slots per word.
## Domain masks, tag masks, and family masks all share it.

static var _ctz_cache: Dictionary = {}


static func ctz(low: int) -> int:
	## low must be an isolated bit (v & -v). Position lookup is cached:
	## a dictionary hit replaces the 64-position scan on every hot path.
	var hit: Variant = _ctz_cache.get(low)
	if hit != null:
		return int(hit)
	for b in 64:
		if (low >> b) & 1 == 1:
			_ctz_cache[low] = b
			return b
	return 64


static func full(nwords: int, nparts: int) -> PackedInt64Array:
	var m := PackedInt64Array(); m.resize(nwords)
	for w in nwords:
		var bits := 0
		for b in 64:
			if (w << 6) + b < nparts:
				bits |= 1 << b
		m[w] = bits
	return m


static func empty(nwords: int) -> PackedInt64Array:
	var m := PackedInt64Array(); m.resize(nwords)
	return m


static func is_empty(m: PackedInt64Array) -> bool:
	for w in m.size():
		if m[w] != 0:
			return false
	return true


static func count(m: PackedInt64Array) -> int:
	var n := 0
	for w in m.size():
		var v := m[w]
		while v != 0:
			v &= v - 1
			n += 1
	return n


static func has(m: PackedInt64Array, i: int) -> bool:
	return (m[i >> 6] >> (i & 63)) & 1 == 1


static func set_bit(m: PackedInt64Array, i: int) -> void:
	m[i >> 6] |= 1 << (i & 63)


static func clear_bit(m: PackedInt64Array, i: int) -> void:
	m[i >> 6] &= ~(1 << (i & 63))


static func only(m: PackedInt64Array, i: int) -> void:
	for w in m.size():
		m[w] = 0
	m[i >> 6] = 1 << (i & 63)


static func first(m: PackedInt64Array) -> int:
	for w in m.size():
		var v := m[w]
		if v != 0:
			return (w << 6) + ctz(v & -v)
	return -1


static func kth(m: PackedInt64Array, k: int) -> int:
	var seen := 0
	for w in m.size():
		var v := m[w]
		while v != 0:
			var low := v & -v
			if seen == k:
				return (w << 6) + ctz(low)
			seen += 1
			v ^= low
	return -1


static func iter(m: PackedInt64Array) -> Array[int]:
	var out: Array[int] = []
	for w in m.size():
		var v := m[w]
		while v != 0:
			var low := v & -v
			out.append((w << 6) + ctz(low))
			v ^= low
	return out
