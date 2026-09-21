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
    # Pair matching below is O(parts²) and dominates runtime, so extraction
    # gets a modest share — but nonzero, so the stage moves immediately.
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
    var n := ordered.size()
    var match_span := 1.0 - strips_share
    for i in n:
        # Report at the top: the `continue` paths below can't skip ticks,
        # and i == n - 1 lands exactly on 1.0 even when n < 16.
        if i % 16 == 15 or i == n - 1:
            report_progress.call(strips_share
                    + match_span * float(i + 1) / float(maxi(n, 1)))
        var a := ordered[i]
        var sa: Dictionary = strips.get(a.id, {})
        if sa.is_empty():
            continue
        for j in n:
            var b := ordered[j]
            if a.size != b.size:
                continue   # uniform-grid assumption
            var sb: Dictionary = strips.get(b.id, {})
            if sb.is_empty():
                continue
            if _match(sa["right"], sb["left"], depth, a.size.y,
                    tolerance, flex, omissions):
                _record(aggregate, a, b, Vector2i(a.size.x, 0))
            if _match(sa["bottom"], sb["top"], depth, a.size.x,
                    tolerance, flex, omissions):
                _record(aggregate, a, b, Vector2i(0, a.size.y))
    var list: Array = aggregate.values()
    list.sort_custom(func(x: Constraint, y: Constraint) -> bool:
        return x.id < y.id)
    result.assign(list)
    return result

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