class_name TerrainMapper extends RefCounted
## Pixel-level color equivalence for comparative techniques. Applies an
## ordered list of terrain classes to an RGBA8 image IN PLACE: a pixel
## matching a class (any listed color within per-channel tolerance, RGB
## only) is rewritten to that class's representative color (its first valid
## entry). First matching class wins; alpha is never modified; fully
## transparent pixels are left untouched so their raw bytes still compare
## exactly as before.
##
## Matching semantics mirror TagMatcher: per-channel Chebyshev distance on
## RGB; colors arrive as hex strings ("rrggbb" or "#rrggbb") because rule
## dictionaries are JSON-persisted; a class with no valid colors is inert.
##
## Per-class "flex" (positional slack along the seam, consumed by
## PixelOverlap) rides on the class dictionary: 0 = strict. apply_mapped()
## records each pixel's class id in the SAME pass as the rewrite, so a
## consumer's per-pixel classification can never diverge from the bytes it
## compares.
##
## Callers must pass a disposable copy (PixelOverlap duplicates before
## converting). Keep representative colors well separated from each other:
## with strip tolerance > 0, two classes whose representatives are close can
## still cross-match.

## Decoded, ordered class list. The returned array's indices ARE the class
## ids recorded by apply_mapped(): index 0..n-1, -1 = unclassed/transparent.
static func prepare(classes: Array) -> Array:
    var out: Array = []
    for c: Variant in classes:
        if not (c is Dictionary):
            continue
        if not bool((c as Dictionary).get("enabled", true)):
            continue   # toggled off: skip without deleting
        var colors := _decode_hex((c as Dictionary).get("colors", []))
        if colors.is_empty():
            continue   # inert class: nothing to match or represent
        out.append({
            "rep": colors[0],
            "colors": colors,
            "tolerance": clampi(int((c as Dictionary).get("tolerance", 0)),
                0, 255),
            "flex": clampi(int((c as Dictionary).get("flex", 0)), 0, 64),
        })
    return out

## Backward-compatible wrapper: rewrite only, no class map returned.
static func apply(img: Image, classes: Array) -> void:
    if img == null:
        return
    var decoded := prepare(classes)
    if decoded.is_empty():
        return
    apply_mapped(img, decoded)

## Rewrites in place (apply() semantics) and returns a w*h class-id array:
## decoded-list index for classed pixels, -1 for unclassed and fully
## transparent ones. Classification and rewrite share one pass and one
## first-match decision.
static func apply_mapped(img: Image, decoded: Array) -> PackedInt32Array:
    var out := PackedInt32Array()
    if img == null or decoded.is_empty():
        return out
    ImageOps.to_rgba8_in_place(img)
    var w := img.get_width()
    var h := img.get_height()
    var data := img.get_data()   # copy; written back once below
    data.resize(w * h * 4)       # drop any mipmap tail; comparison copy only
    out.resize(w * h)
    out.fill(-1)
    for i in range(0, data.size(), 4):
        if data[i + 3] == 0:
            continue   # transparent: never reclassified (see class comment)
        var r: int = data[i]
        var g: int = data[i + 1]
        var b: int = data[i + 2]
        for ci in decoded.size():
            if _matches(r, g, b, decoded[ci]):
                var rep: PackedInt32Array = decoded[ci]["rep"]
                data[i] = rep[0]
                data[i + 1] = rep[1]
                data[i + 2] = rep[2]
                out[i >> 2] = ci
                break
    img.set_data(w, h, false, Image.FORMAT_RGBA8, data)
    return out

static func _decode_hex(hex_colors: Array) -> Array[PackedInt32Array]:
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

static func _matches(r: int, g: int, b: int, c: Dictionary) -> bool:
    var tol: int = c["tolerance"]
    for t: PackedInt32Array in c["colors"]:
        if absi(r - t[0]) <= tol and absi(g - t[1]) <= tol \
                and absi(b - t[2]) <= tol:
            return true
    return false