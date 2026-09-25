class_name StripUtil extends RefCounted
## The seam-strip walk shared by PixelOverlap and ConstraintIndex: bytes,
## class ids, and per-side geometry for the four tile seams. Strips are
## indexed FROM THE SEAM: u = 0 touches the neighbor, u = depth-1 is
## deepest; v runs along the seam.

const SIDES := ["right", "left", "bottom", "top"]


static func bytes(data: PackedByteArray, img_w: int, depth: int,
		start: Vector2i, along: Vector2i, inward: Vector2i,
		span: int) -> PackedByteArray:
	## RGBA8 bytes of the depth × span strip at `start`, stepping `along`
	## across the seam and `inward` away from it. Outer loop = v (along
	## the seam), inner = u (seam inward).
	var out := PackedByteArray()
	out.resize(depth * span * 4)
	var k := 0
	for s in span:
		var base := start + along * s
		for u in depth:
			var p := base + inward * u
			var o := (p.y * img_w + p.x) * 4
			out[k] = data[o]
			out[k + 1] = data[o + 1]
			out[k + 2] = data[o + 2]
			out[k + 3] = data[o + 3]
			k += 4
	return out


static func classes(cls_map: PackedInt32Array, img_w: int, depth: int,
		start: Vector2i, along: Vector2i, inward: Vector2i,
		span: int) -> PackedInt32Array:
	## Class id per strip pixel, identical iteration order to bytes().
	## Empty class map (no terrain key) yields an empty array, which the
	## matcher treats as "every pixel unclassed".
	if cls_map.is_empty():
		return PackedInt32Array()
	var out := PackedInt32Array()
	out.resize(depth * span)
	var k := 0
	for s in span:
		var base := start + along * s
		for u in depth:
			var p := base + inward * u
			out[k] = cls_map[p.y * img_w + p.x]
			k += 1
	return out


static func side(side_name: String, part_size: Vector2i) -> Dictionary:
	## Geometry of one seam of a part_size tile: {start, along, inward,
	## span} in the coordinate frame bytes()/classes() walk.
	match side_name:
		"right":
			return {"start": Vector2i(part_size.x - 1, 0),
					"along": Vector2i(0, 1), "inward": Vector2i(-1, 0),
					"span": part_size.y}
		"left":
			return {"start": Vector2i(0, 0), "along": Vector2i(0, 1),
					"inward": Vector2i(1, 0), "span": part_size.y}
		"bottom":
			return {"start": Vector2i(0, part_size.y - 1),
					"along": Vector2i(1, 0), "inward": Vector2i(0, -1),
					"span": part_size.x}
		"top":
			return {"start": Vector2i(0, 0), "along": Vector2i(1, 0),
					"inward": Vector2i(0, 1), "span": part_size.x}
	return {}


static func class_map(img: Image, decoded: Array) -> PackedInt32Array:
	## Terrain class map for an already-RGBA8 image; empty when no decoded
	## key is active. Note: apply_mapped REWRITES img in place (apply()
	## semantics) — pass a copy you own.
	var cls_map := PackedInt32Array()
	if not decoded.is_empty():
		cls_map = TerrainMapper.apply_mapped(img, decoded)
	return cls_map
