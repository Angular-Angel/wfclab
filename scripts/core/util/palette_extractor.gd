class_name PaletteExtractor extends RefCounted
## Extracts a frequency-sorted color palette from one or more images, for
## the auto-tag rule editor's "pick from tiles" popup.
##
## Semantics:
##   - transparent pixels (alpha == 0) never contribute,
##   - colors are counted exactly, then coalesced into per-channel buckets
##     of 2^bucket_bits levels for display; the representative is the most
##     frequent exact color in the bucket (always a real tile color),
##   - bucket_bits = 0 disables coalescing,
##   - output is sorted by count desc, then color value asc (deterministic),
##     and truncated to cap entries; "total" reports the distinct color
##     count BEFORE truncation.

static func palette_of_images(images: Array[Image], bucket_bits := 4,
		cap := 64) -> Dictionary:
	var exact := {}
	for img: Image in images:
		if img == null:
			continue
		var src := img
		if src.get_format() != Image.FORMAT_RGBA8:
			src = img.duplicate()   # never mutate part pixel data
			src.convert(Image.FORMAT_RGBA8)
		var data := src.get_data()
		for i in range(0, data.size(), 4):
			if data[i + 3] == 0:
				continue
			var rgb := (int(data[i]) << 16) | (int(data[i + 1]) << 8) \
					| int(data[i + 2])
			exact[rgb] = int(exact.get(rgb, 0)) + 1
	var merged := _coalesce(exact, bucket_bits)
	var keys := merged.keys()
	keys.sort_custom(func(a: int, b: int) -> bool:
		var ca := int(merged[a])
		var cb := int(merged[b])
		if ca != cb:
			return ca > cb          # most frequent first
		return a < b)               # deterministic tie-break by color value
	var entries: Array[Dictionary] = []
	for i in mini(keys.size(), cap):
		var rgb: int = keys[i]
		entries.append({
			"color": Color(
					float((rgb >> 16) & 0xFF) / 255.0,
					float((rgb >> 8) & 0xFF) / 255.0,
					float(rgb & 0xFF) / 255.0),
			"hex": "%02x%02x%02x" % [(rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF,
					rgb & 0xFF],
			"count": int(merged[rgb]),
		})
	return {"entries": entries, "total": merged.size()}


static func _coalesce(exact: Dictionary, bucket_bits: int) -> Dictionary:
	bucket_bits = clampi(bucket_bits, 0, 7)
	if bucket_bits == 0:
		return exact
	var buckets := {}     # bucket key -> [rep_rgb, total_count]
	for rgb: Variant in exact:
		var key := (((int(rgb) >> 16) & 0xFF) >> bucket_bits) << 16 \
				| (((int(rgb) >> 8) & 0xFF) >> bucket_bits) << 8 \
				| ((int(rgb) & 0xFF) >> bucket_bits)
		var entry: Variant = buckets.get(key)
		if entry == null:
			buckets[key] = [int(rgb), int(exact[rgb])]
		else:
			entry[1] += int(exact[rgb])
			if int(exact[rgb]) > int(exact[entry[0]]):
				entry[0] = int(rgb)
	var out := {}
	for key: Variant in buckets:
		out[(buckets[key] as Array)[0]] = (buckets[key] as Array)[1]
	return out
