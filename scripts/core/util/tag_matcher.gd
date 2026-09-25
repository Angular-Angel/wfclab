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
    var targets := ColorMath.decode_hex(hex_colors)
    if targets.is_empty() or img == null:
        return 0.0
    var src := ImageOps.to_rgba8(img)   # never mutate the part's pixel data
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
            if ColorMath.matches(r, g, b, t, tol):
                matched += 1
                break
    if counted == 0:
        return 0.0
    return float(matched) / float(counted)


## rule keys: colors (hex strings), tolerance (int), min_fraction (0..1).
## Missing/empty colors make the rule inert rather than erroring: it never
## matches, regardless of min_fraction (0.0 >= 0.0 would otherwise pass).
static func rule_matches(img: Image, rule: Dictionary) -> bool:
    var colors: Array = rule.get("colors", [])
    if colors.is_empty():
        return false
    var fraction := coverage_fraction(img, colors,
            int(rule.get("tolerance", 16)))
    return fraction >= float(rule.get("min_fraction", 0.1))
