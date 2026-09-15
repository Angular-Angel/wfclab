extends Node
## Shared state. Owns images, the last RAW extraction, and the MATERIALIZED
## parts/constraints (raw + user edits). Everyone else reads materialized.

signal images_changed
signal parts_changed
signal constraints_changed
signal edits_changed

var images: Dictionary = {}          # id -> ImageAssetData
var parts: Dictionary = {}           # id -> Part (materialized)
var constraints: Dictionary = {}     # id -> Constraint (materialized)
var last_run_stats: Dictionary = {}
var last_run_config: Dictionary = {}   # JSON-safe: what produced the raw data

# --- User edits (applied on top of every materialization) ---
var part_edits: Dictionary = {}        # part_id -> {enabled, weight_override}
var constraint_edits: Dictionary = {}  # constraint_id -> {enabled, weight_override}
var alias_records: Array = []          # [{from, into}] — part merge records

var _raw_parts: Array[Part] = []
var _raw_constraints: Array[Constraint] = []
var _alias_mapping: Dictionary = {}    # merged-away id -> survivor id


# --- Images -----------------------------------------------------------------

func add_image(asset: ImageAssetData) -> bool:
	if images.has(asset.id):
		return false
	images[asset.id] = asset
	images_changed.emit()
	return true


func get_image_list() -> Array[ImageAssetData]:
	var list: Array[ImageAssetData] = []
	list.assign(images.values())
	return list


func image_name(id: String) -> String:
	return images[id].name if images.has(id) else id


# --- Run ingestion (raw -> materialized) --------------------------------------

func set_parts(raw_parts: Array[Part], stats: Dictionary) -> void:
	_raw_parts = raw_parts
	last_run_stats = stats
	_materialize_parts()


func set_constraints(raw_constraints: Array[Constraint]) -> void:
	_raw_constraints = raw_constraints
	_materialize_constraints()


func get_part_list() -> Array[Part]:
	var list: Array[Part] = []
	list.assign(parts.values())
	return list


func get_constraint_list() -> Array[Constraint]:
	var list: Array[Constraint] = []
	list.assign(constraints.values())
	return list


# --- Editing (lightweight: table + live object, no re-materialization) --------

func edit_part(id: String, key: String, value: Variant) -> void:
	if not part_edits.has(id):
		part_edits[id] = {}
	part_edits[id][key] = value
	if parts.has(id):
		_apply_edit_fields(parts[id], part_edits[id])
	edits_changed.emit()


func edit_constraint(id: String, key: String, value: Variant) -> void:
	if not constraint_edits.has(id):
		constraint_edits[id] = {}
	constraint_edits[id][key] = value
	if constraints.has(id):
		_apply_edit_fields(constraints[id], constraint_edits[id])
	edits_changed.emit()


func merge_parts(from_id: String, into_id: String) -> void:
	if from_id == into_id:
		return
	alias_records.append({"from": from_id, "into": into_id})
	_materialize_parts()
	_materialize_constraints()
	edits_changed.emit()


func clear_all_edits() -> void:
	part_edits.clear()
	constraint_edits.clear()
	alias_records.clear()
	if not _raw_parts.is_empty() or not parts.is_empty():
		_materialize_parts()
		_materialize_constraints()
	edits_changed.emit()


# --- Materialization ------------------------------------------------------------

func _materialize_parts() -> void:
	parts = {}
	_alias_mapping = {}
	for raw: Part in _raw_parts:
		var p := raw.clone()
		parts[p.id] = p

	# Apply merge records in chronological order (chains resolve naturally).
	for rec: Dictionary in alias_records:
		var from_id: String = rec["from"]
		var into_id: String = _alias_mapping.get(rec["into"], rec["into"])
		if not parts.has(from_id) or not parts.has(into_id) or from_id == into_id:
			continue   # part vanished from a new extraction; record stays for later
		var from_part: Part = parts[from_id]
		var into_part: Part = parts[into_id]
		into_part.occurrences.append_array(from_part.occurrences)
		into_part.weight = into_part.occurrence_count()
		parts.erase(from_id)
		_alias_mapping[from_id] = into_id

	_apply_part_edits()
	parts_changed.emit()


func _materialize_constraints() -> void:
	constraints = {}
	var merged: Dictionary = {}
	for raw: Constraint in _raw_constraints:
		var c := raw.clone()
		var changed := false
		for p: Dictionary in c.participants:
			var pid: String = p["part_id"]
			if _alias_mapping.has(pid):
				p["part_id"] = _alias_mapping[pid]
				changed = true
		if changed:
			c.rebuild_id()
		if merged.has(c.id):
			# Two constraints became identical after merging: combine evidence.
			(merged[c.id] as Constraint).evidence.append_array(c.evidence)
		else:
			merged[c.id] = c
	for c: Constraint in merged.values():
		c.weight = c.evidence.size()
		constraints[c.id] = c

	_apply_constraint_edits()
	constraints_changed.emit()


func _apply_part_edits() -> void:
	for id: String in part_edits:
		if parts.has(id):
			_apply_edit_fields(parts[id], part_edits[id])


func _apply_constraint_edits() -> void:
	for id: String in constraint_edits:
		if constraints.has(id):
			_apply_edit_fields(constraints[id], constraint_edits[id])


func _apply_edit_fields(obj: Object, e: Dictionary) -> void:
	# Part and Constraint share the edited field names.
	if e.has("enabled"):
		obj.set("enabled", e["enabled"])
	if e.has("weight_override"):
		obj.set("weight_override", e["weight_override"])


# --- Project persistence ---------------------------------------------------------

func save_project(path: String) -> bool:
	var image_records: Array = []
	for asset: ImageAssetData in get_image_list():
		image_records.append({"path": asset.path, "id": asset.id})
	var data := {
		"version": 1,
		"images": image_records,
		"run": last_run_config,
		"part_edits": part_edits,
		"constraint_edits": constraint_edits,
		"alias_records": alias_records,
	}
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("Cannot write project file: %s" % path)
		return false
	f.store_string(JSON.stringify(JsonCodec.encode(data), "\t"))
	return true


## Loads images and edit tables, returns the decoded project Dictionary
## (its "run" entry drives the auto re-run; empty Dictionary on failure).
func load_project(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("Cannot open project file: %s" % path)
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if parsed == null or not (parsed is Dictionary):
		push_error("Invalid project file: %s" % path)
		return {}
	var data: Dictionary = JsonCodec.decode(parsed)

	# Reset state.
	images = {}
	parts = {}
	constraints = {}
	_raw_parts = []
	_raw_constraints = []
	_alias_mapping = {}
	last_run_stats = {}
	last_run_config = data.get("run", {})
	part_edits = data.get("part_edits", {})
	constraint_edits = data.get("constraint_edits", {})
	alias_records = []
	alias_records.assign(data.get("alias_records", []))

	for rec: Dictionary in data.get("images", []):
		var asset := ImageAssetData.load_from_path(rec["path"])
		if asset == null:
			push_warning("Project image missing, skipped: %s" % rec["path"])
			continue
		images[asset.id] = asset

	images_changed.emit()
	parts_changed.emit()
	constraints_changed.emit()
	return data
