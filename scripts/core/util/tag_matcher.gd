class_name TagMatcher extends RefCounted
## Automatic tag determination: fraction of a part's pixels matching a set
## of target colors within a per-channel tolerance. Colors arrive as hex
## strings ("rrggbb" or "#rrggbb") because rule dictionaries are JSON-
## persisted and Color variants do not round-trip reliably.
##
## Matching semantics:
##   - a pixel matches when |r-tr|, |g-tg|, |b-tb| <= tolerance for ANY
##     target color (per-channel / Chebyshev, alpha not compared),
##   - pixels with alpha == 0 are excluded from numerator AND denominator
##     (transparent padding does not skew coverage),
##   - a fully transparent image has coverage 0.0 and never matches.

static func coverage_fraction(img: Image, hex_colors: Array,
        tolerance: int) -> float:
    var targets := _decode(hex_colors)
    if targets.is_empty() or img == null:
        return 0.0
    var src := img
    if src.get_format() != Image.FORMAT_RGBA8:
        src = img.duplicate()   # never mutate the part's pixel data
        src.convert(Image.FORMAT_RGBA8)
    var data := src.get_data()
    var tol := clampi(tolerance, 0, 255)
    var matched := 0
    var counted := 0
    for i in range(0, data.size(), 4):
        if data[i + 3] == 0:
            continue
        counted += 1
        var r: int = data[i]
        var g: int = data[i + 1]
        var b: int = data[i + 2]
        for t: PackedInt32Array in targets:
            if absi(r - t[0]) <= tol and absi(g - t[1]) <= tol \
                    and absi(b - t[2]) <= tol:
                matched += 1
                break
    if counted == 0:
        return 0.0
    return float(matched) / float(counted)


## rule keys: colors (hex strings), tolerance (int), min_fraction (0..1).
## Missing/empty colors make the rule inert rather than erroring.
static func rule_matches(img: Image, rule: Dictionary) -> bool:
    var fraction := coverage_fraction(img, rule.get("colors", []),
            int(rule.get("tolerance", 16)))
    return fraction >= float(rule.get("min_fraction", 0.1))


static func _decode(hex_colors: Array) -> Array[PackedInt32Array]:
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