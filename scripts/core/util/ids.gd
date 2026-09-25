class_name Ids extends RefCounted
## Single home for the entity id schemes, so format changes (and the
## no-save-format-change guarantee) have one auditable place:
##   part        "p_" + hash[0..12)
##   image       "img_" + hash[0..10)
##   constraint  prefix + short(a) + "_" + short(b) + "_ox_oy"  ("c_"/"o_")
## short() = substr(2, 6): strips the "p_"/"c_"/"o_" prefix family and
## keeps 6 chars, matching the extractor's ids by construction.
## Deliberately per-site: the output id ("out_%d_%s", app_data.gd) and
## adjacency's to-outside variant ("c_%s_out_%d_%d") are single copies.
static func short(x: String) -> String:
	return x.substr(2, 6)


static func part(hash_hex: String) -> String:
	return "p_" + hash_hex.substr(0, 12)


static func image(hash_hex: String) -> String:
	return "img_" + hash_hex.substr(0, 10)


static func constraint(a_id: String, b_id: String, offset: Vector2i,
		prefix := "c_") -> String:
	return "%s%s_%s_%d_%d" % [prefix, short(a_id), short(b_id), offset.x, offset.y]


## Deterministic ordering by entity id, regardless of load/aggregate
## order. Sorts in place; accepts typed and untyped arrays.
static func by_id(arr: Array) -> void:
	arr.sort_custom(func(a: Variant, b: Variant) -> bool: return a.id < b.id)
