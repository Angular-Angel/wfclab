class_name PixelOverlap extends ConstraintTechnique
## Overlap compatibility: parts may sit adjacent when their facing pixel
## strips match within tolerance. Comparative only — no occurrence data —
## so pairs never seen together in the sources may still be declared legal.

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
    ]

func extract(parts: Array[Part], images: Array[ImageAssetData],
        params: Dictionary, report_progress: Callable) -> Array[Constraint]:
    var result: Array[Constraint] = []
    if parts.size() < 2:
        return result
    var depth := maxi(1, int(params.get("overlap_layers", 2)))
    var tolerance := maxi(0, int(params.get("tolerance", 0)))

    var ordered: Array[Part] = []
    ordered.assign(parts)
    ordered.sort_custom(func(a: Part, b: Part) -> bool: return a.id < b.id)

    # Normalize once: RGBA8 bytes, strips per side. Duplicate before convert:
    # pixel_data is shared with previews/materialization.
    var right: Dictionary = {}
    var left: Dictionary = {}
    var bottom: Dictionary = {}
    var top: Dictionary = {}
    for p: Part in ordered:
        if p.size.x < depth or p.size.y < depth:
            continue
        var img := p.pixel_data.duplicate() as Image
        if img.is_compressed():
            img.decompress()
        img.convert(Image.FORMAT_RGBA8)
        right[p.id] = _strip(img, depth, p.size.x - depth, 0, depth, p.size.y)
        left[p.id] = _strip(img, depth, 0, 0, depth, p.size.y)
        bottom[p.id] = _strip(img, depth, 0, p.size.y - depth, p.size.x, depth)
        top[p.id] = _strip(img, depth, 0, 0, p.size.x, depth)

    var aggregate: Dictionary = {}
    var n := ordered.size()
    for i in n:
        var a := ordered[i]
        if not right.has(a.id):
            continue
        for j in n:
            var b := ordered[j]
            if a.size != b.size or not right.has(b.id):
                continue   # mixed-size tiles unsupported (uniform-grid assumption)
            # strip_a(facing) vs strip_b(front): byte-wise, early exit.
            if _match(right[a.id], left[b.id], tolerance):
                _record(aggregate, a, b, Vector2i(a.size.x, 0))
            if _match(bottom[a.id], top[b.id], tolerance):
                _record(aggregate, a, b, Vector2i(0, a.size.y))
        if i % 16 == 15:
            report_progress.call(float(i + 1) / n)

    var list: Array = aggregate.values()
    list.sort_custom(func(x: Constraint, y: Constraint) -> bool: return x.id < y.id)
    result.assign(list)
    return result

func _strip(img: Image, depth: int, x0: int, y0: int, w: int, h: int) -> PackedByteArray:
    var bytes := img.get_data()
    var out := PackedByteArray()
    out.resize(depth * 4 * ((w if y0 == 0 and h == img.get_height() else depth) * 0 + _strip_len(w, h, depth)))
    # (simpler: build directly in the comparison below — see note)
    var k := 0
    for y in range(y0, y0 + h):
        for x in range(x0, x0 + w):
            var o := (y * img.get_width() + x) * 4
            out[k] = bytes[o]; out[k + 1] = bytes[o + 1]
            out[k + 2] = bytes[o + 2]; out[k + 3] = bytes[o + 3]
            k += 4
    return out

func _strip_len(w: int, h: int, depth: int) -> int:
    return w * h   # caller passes strip dims; len = w*h pixels * 4 bytes

func _match(a: PackedByteArray, b: PackedByteArray, tolerance: int) -> bool:
    if a.size() != b.size():
        return false
    if tolerance == 0:
        return a == b   # PackedByteArray supports direct equality
    for i in a.size():
        if absi(int(a[i]) - int(b[i])) > tolerance:
            return false
    return true

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