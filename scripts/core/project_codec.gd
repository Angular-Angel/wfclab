class_name ProjectCodec extends RefCounted
## .wfcproj file format: version-2 payload assembly, JSON write/read, and
## decode-side normalization (tag-edit filtering, rule-array adoption, the
## legacy terrain_keys migration). State adoption stays in AppData.

const VERSION := 2


static func encode(images: Array, state: Dictionary) -> Dictionary:
	var data := {
		"version": VERSION,
		"images": images,
		"run": state["run"],
		"part_edits": state["part_edits"],
		"transform_edits": state["transform_edits"],
		"constraint_edits": state["constraint_edits"],
		"alias_records": state["alias_records"],
		"tag_edits": state["tag_edits"],
		"rules": state["rules"],
		"tagging_rules": state["tagging_rules"],
		"terrain_key": state["terrain_key"],
	}
	return data


static func write(path: String, data: Dictionary) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("Cannot write project file: %s" % path)
		return false
	f.store_string(JSON.stringify(JsonCodec.encode(data), "\t"))
	return true


static func read(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("Cannot open project file: %s" % path)
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if parsed == null or not (parsed is Dictionary):
		push_error("Invalid project file: %s" % path)
		return {}
	return decode(parsed)


static func decode(payload: Variant) -> Dictionary:
	var data: Dictionary = JsonCodec.decode(payload)
	data["tag_edits"] = _decode_tag_edits(data.get("tag_edits", {}))
	var rules: Array = []
	var loaded_rules: Variant = data.get("rules", [])
	if loaded_rules is Array:
		rules.assign(loaded_rules)
	data["rules"] = rules
	var tag_rules: Array = []
	var loaded_tag_rules: Variant = data.get("tagging_rules", [])
	if loaded_tag_rules is Array:
		tag_rules.assign(loaded_tag_rules)
	data["tagging_rules"] = tag_rules
	var key_classes: Array = []
	var loaded_key: Variant = data.get("terrain_key", null)
	if loaded_key is Array:
		key_classes.assign(loaded_key)
	else:
		# Legacy multi-key projects: adopt the first enabled key's classes.
		for k: Variant in data.get("terrain_keys", []):
			if k is Dictionary and bool((k as Dictionary).get("enabled", true)):
				var classes: Variant = (k as Dictionary).get("classes", [])
				if classes is Array:
					key_classes.assign(classes)
					break
	data["terrain_key"] = key_classes
	return data


static func _decode_tag_edits(src: Variant) -> Dictionary:
	var out := {}
	if src is Dictionary:
		for k: Variant in src:
			var arr: Array[String] = []
			for t: Variant in src[k]:
				if t is String and not (t as String).is_empty():
					arr.append(t)
			if not arr.is_empty():
				out[String(k)] = arr
	return out
