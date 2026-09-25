class_name ColorMath extends RefCounted
## Shared hex-color decoding and per-channel (Chebyshev) color matching,
## single-sourced from TagMatcher and TerrainMapper. Colors arrive as hex
## strings ("rrggbb" or "#rrggbb") because rule dictionaries are JSON-
## persisted and Color variants do not round-trip reliably.

static func decode_hex(hex_colors: Array) -> Array[PackedInt32Array]:
	var out: Array[PackedInt32Array] = []
	for c: Variant in hex_colors:
		var s := String(c)
		if not s.begins_with("#"):
			s = "#" + s
		if not Color.html_is_valid(s):
			continue
		var col := Color(s)
		out.append(PackedInt32Array([
			int(round(col.r * 255.0)),
			int(round(col.g * 255.0)),
			int(round(col.b * 255.0))]))
	return out


## Per-channel Chebyshev match of one RGB triplet against one decoded
## target ([r, g, b]); alpha is never compared. Kept per-target — callers
## loop their color lists.
static func matches(r: int, g: int, b: int, target: PackedInt32Array,
		tol: int) -> bool:
	return absi(r - target[0]) <= tol and absi(g - target[1]) <= tol \
			and absi(b - target[2]) <= tol
