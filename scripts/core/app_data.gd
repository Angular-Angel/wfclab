extends Node
## Shared state. Owns images, the last RAW extraction, and the MATERIALIZED
## parts/constraints (raw + user edits). Everyone else reads materialized.

signal images_changed
signal outputs_changed
signal parts_changed
signal constraints_changed
signal edits_changed
signal synthesis_changed
signal rules_changed
signal tagging_rules_changed

var images: Dictionary = {}          # id -> ImageAssetData
var outputs: Dictionary = {}         # id -> {asset, stats, meta}
var parts: Dictionary = {}           # id -> Part (materialized)
var constraints: Dictionary = {}     # id -> Constraint (materialized)
var last_run_stats: Dictionary = {}
var last_run_config: Dictionary = {}   # JSON-safe: what produced the raw data
var last_synthesis: Dictionary = {}   # {image, stats, meta}
var _next_output_number := 1
var _index: ConstraintIndex = null
var _index_valid := false

# --- User edits (applied on top of every materialization) ---
var part_edits: Dictionary = {}        # part_id -> {enabled, weight_override}
var transform_edits: Dictionary = {}   # canonical_id -> {transform_key -> enabled}
var constraint_edits: Dictionary = {}  # constraint_id -> {enabled, weight_override}
var alias_records: Array = []          # [{from, into}] — part merge records
var tag_edits: Dictionary = {}         # part_id -> Array[String]; survives re-decomposition
var rules: Array = []                  # authored rules (Dictionaries); source of truth for UI
var _next_rule_number := 1
var tagging_rules: Array = []          # auto-tag rules; applied via apply_tagging_rules()
var _next_tag_rule_number := 1

var _raw_parts: Array[Part] = []
var _raw_constraints: Array[Constraint] = []
var _alias_mapping: Dictionary = {}    # merged-away id -> survivor id


func _ready() -> void:
	parts_changed.connect(func() -> void: _index_valid = false)
	constraints_changed.connect(func() -> void: _index_valid = false)
	# Tag, rule, weight, and enabled edits all change what the index snapshot
	# bakes in. This also fixes a pre-existing staleness bug: weight_override
	# and enabled edits used to leave the built index stale until the next
	# parts_changed/constraints_changed.
	edits_changed.connect(func() -> void: _index_valid = false)
	rules_changed.connect(func() -> void: _index_valid = false)


## The defined seam for synthesizers: built on the main thread, returned as
## an immutable snapshot (safe to hand to a worker task).
func get_constraint_index() -> ConstraintIndex:
	if not _index_valid:
		_index = ConstraintIndex.build(get_part_list(), get_constraint_list(),
				tag_edits, rules)
		_index_valid = true
	return _index


func set_synthesis(image: Image, stats: Dictionary, meta: Dictionary) -> void:
	var output_number := _next_output_number
	_next_output_number += 1
	var asset := ImageAssetData.from_image(image, "Output %d" % output_number)
	# Keep every successful synthesis, including repeated images from the same seed.
	asset.id = "out_%d_%s" % [output_number, asset.hash.substr(0, 10)]
	var output := {"asset": asset, "stats": stats.duplicate(true), "meta": meta.duplicate(true)}
	outputs[asset.id] = output
	last_synthesis = {"image": image, "stats": stats, "meta": meta, "output_id": asset.id}
	outputs_changed.emit()
	synthesis_changed.emit()

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


func remove_image(id: String) -> bool:
	if not images.erase(id):
		return false
	images_changed.emit()
	return true


# --- Generated outputs ---------------------------------------------------------

func get_output_list() -> Array[Dictionary]:
	var list: Array[Dictionary] = []
	list.assign(outputs.values())
	return list


func get_output(id: String) -> Dictionary:
	return outputs.get(id, {})


func remove_output(id: String) -> bool:
	if not outputs.erase(id):
		return false
	if last_synthesis.get("output_id", "") == id:
		last_synthesis = {}
		synthesis_changed.emit()
	outputs_changed.emit()
	return true


# --- Run ingestion (raw -> materialized) --------------------------------------

func set_parts(raw_parts: Array[Part], stats: Dictionary) -> void:
	_raw_parts = raw_parts
	last_run_stats = stats
	_materialize_parts()


func set_constraints(raw_constraints: Array[Constraint]) -> void:
	## Ingest freshly extracted raw constraints and materialize them as-is.
	## Re-extraction is NOT done here: it belongs to the edit paths
	## (set_transform_enabled, merge_parts, set_terrain_key), which call
	## _regenerate_constraints() explicitly. Callers must therefore extract
	## against the part set they intend the constraints to describe.
	_raw_constraints = raw_constraints
	_materialize_constraints()


func get_part_list() -> Array[Part]:
	var list: Array[Part] = []
	list.assign(parts.values())
	return list


func get_canonical_part(id: String) -> Part:
	for raw: Part in _raw_parts:
		if raw.id == id:
			return raw
	return null


func get_constraint_list() -> Array[Constraint]:
	var list: Array[Constraint] = []
	list.assign(constraints.values())
	return list


# --- Editing -------------------------------------------------------------------

func edit_part(id: String, key: String, value: Variant) -> void:
	if not part_edits.has(id):
		part_edits[id] = {}
	part_edits[id][key] = value
	if parts.has(id):
		_apply_edit_fields(parts[id], part_edits[id])
	edits_changed.emit()


func set_transform_enabled(canonical_id: String, transform_key: String,
		enabled: bool) -> void:
	if transform_key == "identity":
		return
	if not transform_edits.has(canonical_id):
		transform_edits[canonical_id] = {}
	transform_edits[canonical_id][transform_key] = enabled
	_materialize_parts()
	_regenerate_constraints()
	edits_changed.emit()


func is_transform_enabled(canonical_id: String, transform_key: String) -> bool:
	if transform_key == "identity":
		return true
	if transform_edits.has(canonical_id) and transform_edits[canonical_id].has(transform_key):
		return transform_edits[canonical_id][transform_key]
	return _run_transform_enabled(transform_key)


func _run_transform_enabled(transform_key: String) -> bool:
	var params: Dictionary = last_run_config.get("params", {})
	match transform_key:
		"rot90": return params.get("rotation_90", false)
		"rot180": return params.get("rotation_180", false) or \
				(params.get("reflect_horizontal", false) and params.get("reflect_vertical", false))
		"rot270": return params.get("rotation_270", false)
		"flip_h": return params.get("reflect_horizontal", false)
		"flip_v": return params.get("reflect_vertical", false)
	return false


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
	transform_edits.clear()
	constraint_edits.clear()
	alias_records.clear()
	if not _raw_parts.is_empty() or not parts.is_empty():
		_materialize_parts()
		_regenerate_constraints()
	edits_changed.emit()


# --- Tags (edits layer) --------------------------------------------------------
## Tags live here, not on Part, so they survive re-decomposition the same way
## other edits do. They are read through by the UI and baked into the
## ConstraintIndex as bitmasks at build time. Tags on parts that are later
## merged away or disabled become inert (the id no longer materializes).

func get_tags(part_id: String) -> Array[String]:
	var list: Array[String] = []
	list.assign(tag_edits.get(part_id, []))
	return list


func get_all_tags() -> Array[String]:
	var seen := {}
	for id: String in tag_edits:
		for tag: Variant in tag_edits[id]:
			if tag is String and not (tag as String).is_empty():
				seen[tag] = true
	var out: Array[String] = []
	out.assign(seen.keys())
	out.sort()
	return out


func add_part_tag(part_id: String, tag: String) -> void:
	if _add_tag_silent(part_id, tag):
		edits_changed.emit()


func _add_tag_silent(part_id: String, tag: String) -> bool:
	tag = tag.strip_edges()
	if tag.is_empty() or not parts.has(part_id):
		return false
	var arr: Array = tag_edits.get(part_id, [])
	if arr.has(tag):
		return false
	arr.append(tag)
	tag_edits[part_id] = arr
	return true


func remove_part_tag(part_id: String, tag: String) -> void:
	if not tag_edits.has(part_id):
		return
	var arr: Array = tag_edits[part_id]
	arr.erase(tag)
	if arr.is_empty():
		tag_edits.erase(part_id)
	edits_changed.emit()


# --- Authored rules -------------------------------------------------------------
## Source of truth for the rules UI; compiled into the index by
## ConstraintIndex.prepare(). Rules are NOT expanded into the constraints
## dictionary — they are derived data, recomputed on every index build.
## Note: "Clear All Edits" deliberately leaves tags and rules intact.

func add_rule(rule: Dictionary) -> String:
	var r := rule.duplicate(true)
	r["id"] = "rule_%d" % _next_rule_number
	_next_rule_number += 1
	r["enabled"] = bool(r.get("enabled", true))
	rules.append(r)
	rules_changed.emit()
	return r["id"]


func update_rule(id: String, fields: Dictionary) -> void:
	for r: Dictionary in rules:
		if String(r.get("id", "")) != id:
			continue
		for k: String in fields:
			if k != "id":
				r[k] = fields[k]
		rules_changed.emit()
		return


func remove_rule(id: String) -> void:
	for i in rules.size():
		if String((rules[i] as Dictionary).get("id", "")) == id:
			rules.remove_at(i)
			rules_changed.emit()
			return


## Callers must treat the returned array as read-only.
func get_rules() -> Array:
	return rules


# --- Auto-tag rules --------------------------------------------------------------
## Color-coverage rules that assign tags to materialized parts. Rules are
## applied EXPLICITLY (apply_tagging_rules), never implicitly during
## materialization — otherwise manually removed tags would resurrect on the
## next re-decomposition. "Strip" removes a tag everywhere; both operations
## write through the normal tag_edits layer and are idempotent.

func add_tagging_rule(rule: Dictionary) -> String:
	var r := rule.duplicate(true)
	r["id"] = "tagrule_%d" % _next_tag_rule_number
	_next_tag_rule_number += 1
	r["enabled"] = bool(r.get("enabled", true))
	tagging_rules.append(r)
	tagging_rules_changed.emit()
	return r["id"]


func update_tagging_rule(id: String, fields: Dictionary) -> void:
	for r: Dictionary in tagging_rules:
		if String(r.get("id", "")) != id:
			continue
		for k: String in fields:
			if k != "id":
				r[k] = fields[k]
		tagging_rules_changed.emit()
		return


func remove_tagging_rule(id: String) -> void:
	for i in tagging_rules.size():
		if String((tagging_rules[i] as Dictionary).get("id", "")) == id:
			tagging_rules.remove_at(i)
			tagging_rules_changed.emit()
			return


## Callers must treat the returned array as read-only.
func get_tagging_rules() -> Array:
	return tagging_rules


## Applies every enabled rule to all materialized parts. Additive and
## idempotent: parts already carrying the tag are left untouched and are
## not counted. Emits edits_changed exactly once. Returns
## {"tagged_parts": int, "per_rule": {rule_id: int}}.
func apply_tagging_rules() -> Dictionary:
	var report := {"tagged_parts": 0, "per_rule": {}}
	for rule: Dictionary in tagging_rules:
		if not bool(rule.get("enabled", true)):
			continue
		var tag := String(rule.get("tag", ""))
		if tag.is_empty():
			continue
		var count := 0
		for id: String in parts:
			var p: Part = parts[id]
			if p == null or p.pixel_data == null:
				continue
			if TagMatcher.rule_matches(p.pixel_data, rule):
				if _add_tag_silent(id, tag):
					count += 1
		report["per_rule"][String(rule.get("id", "?"))] = count
		report["tagged_parts"] = int(report["tagged_parts"]) + count
	if int(report["tagged_parts"]) > 0:
		edits_changed.emit()
	return report


func strip_tag_everywhere(tag: String) -> int:
	if tag.is_empty():
		return 0
	var removed := 0
	for id: String in tag_edits.keys():   # keys() copy: dict is mutated below
		var arr: Array = tag_edits[id]
		if arr.has(tag):
			arr.erase(tag)
			removed += 1
			if arr.is_empty():
				tag_edits.erase(id)
	if removed > 0:
		edits_changed.emit()
	return removed


# --- Terrain key (single, global) -------------------------------------------
## One ordered set of color-equivalence classes shared by every consumer
## (currently PixelOverlap). A class is {name, colors: [hex], tolerance,
## enabled, tag, min_fraction}: pixels matching any listed color within
## tolerance compare as that class's first color; first matching class
## wins; alpha untouched. enabled=false classes are skipped by extraction
## and tagging — toggle them to experiment without deleting. tag and
## min_fraction drive apply_terrain_key_tags() and are ignored by
## extraction. Unlike tagging rules, the key is consulted DURING
## constraint extraction, so every save regenerates constraints.
signal terrain_key_changed
var terrain_key_classes: Array = []
func get_terrain_key() -> Array:
	return terrain_key_classes
func set_terrain_key(classes: Array) -> void:
	terrain_key_classes = classes.duplicate(true)
	terrain_key_changed.emit()
	_regenerate_constraints()
func has_terrain_key() -> bool:
	return not terrain_key_classes.is_empty()
## Enabled classes only — the extraction/tagging view of the key.
func active_terrain_classes() -> Array:
	var out: Array = []
	for cls: Variant in terrain_key_classes:
		if cls is Dictionary \
				and bool((cls as Dictionary).get("enabled", true)):
			out.append(cls)
	return out
## Explicit, like apply_tagging_rules: a part gets a class's tag when at
## least min_fraction of its non-transparent pixels fall within the class
## (per-channel tolerance of any listed color). Uses the same coverage
## math as tagging rules (TagMatcher.coverage_fraction), writes through
## the normal tag_edits layer, and is additive/idempotent — manually
## removed tags are never resurrected. Emits edits_changed at most once.
## Returns {"tagged_parts": int, "per_class": {class_name: int}}.
func apply_terrain_key_tags() -> Dictionary:
	var report := {"tagged_parts": 0, "per_class": {}}
	for cls: Dictionary in active_terrain_classes():
		var tag := String(cls.get("tag", "")).strip_edges()
		if tag.is_empty():
			continue   # class defines no tag; skip silently
		var colors: Array = cls.get("colors", [])
		if colors.is_empty():
			continue
		var tol := int(cls.get("tolerance", 0))
		var minf := float(cls.get("min_fraction", 0.1))
		var count := 0
		for id: String in parts:
			var p: Part = parts[id]
			if p == null or p.pixel_data == null:
				continue
			if TagMatcher.coverage_fraction(p.pixel_data, colors, tol) \
					>= minf:
				if _add_tag_silent(id, tag):
					count += 1
		report["per_class"][String(cls.get("name", "?"))] = count
		report["tagged_parts"] = int(report["tagged_parts"]) + count
	if int(report["tagged_parts"]) > 0:
		edits_changed.emit()
	return report


# --- Materialization ------------------------------------------------------------

func _materialize_parts() -> void:
	parts = {}
	_alias_mapping = {}
	# A hash-deduplicated part can receive several transform records from the
	# same source. Its source samples count once regardless of symmetry.
	var occurrence_sources: Dictionary = {} # materialized id -> canonical ids
	for raw: Part in _raw_parts:
		for transform_key: String in ["identity", "rot90", "rot180", "rot270", "flip_h", "flip_v"]:
			if not is_transform_enabled(raw.id, transform_key):
				continue
			if (transform_key == "rot90" or transform_key == "rot270") \
					and raw.size.x != raw.size.y:
				continue
			var image := raw.pixel_data if transform_key == "identity" \
					else GridTiles.transform_image(raw.pixel_data, transform_key)
			var hash := PixelHash.of(image, get_dedupe_tolerance())
			var id := "p_" + hash.substr(0, 12)
			var p: Part
			if parts.has(id):
				p = parts[id]
			else:
				p = Part.new()
				p.id = id
				p.canonical_id = raw.id
				p.canonical_hash = hash
				p.transform_key = transform_key
				p.pixel_data = image
				p.size = image.get_size()
				parts[id] = p
			p.transform_sources.append({
				"canonical_id": raw.id, "transform_key": transform_key})
			if not occurrence_sources.has(id):
				occurrence_sources[id] = {}
			if not occurrence_sources[id].has(raw.id):
				p.occurrences.append_array(raw.occurrences.duplicate(true))
				occurrence_sources[id][raw.id] = true
			p.weight = p.occurrence_count()

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


func get_dedupe_tolerance() -> int:
	var params: Dictionary = last_run_config.get("params", {})
	return int(params.get("dedupe_tolerance", 0))


func _regenerate_constraints() -> void:
	# Constraint techniques consume the active, globally deduplicated variants.
	# This is inexpensive compared with decomposition and keeps edits immediate.
	if _raw_parts.is_empty() or last_run_config.is_empty() \
			or not last_run_config.get("constraints_ran", true):
		_materialize_constraints()   # re-apply edits to existing raw constraints
		return
	var run_images: Array[ImageAssetData] = []
	for image_id in last_run_config.get("image_ids", []):
		if images.has(image_id):
			run_images.append(images[image_id])
	var regenerated: Array[Constraint] = []
	for job: Dictionary in last_run_config.get("constraint_jobs", []):
		var technique := TechniqueRegistry.get_constraint_technique(
				StringName(String(job.get("id", ""))))
		if technique != null:
			regenerated.append_array(technique.extract(get_part_list(), run_images,
					job.get("params", {}), func(_progress: float) -> void: pass))
	_raw_constraints = regenerated
	_materialize_constraints()


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
		"version": 2,
		"images": image_records,
		"run": last_run_config,
		"part_edits": part_edits,
		"transform_edits": transform_edits,
		"constraint_edits": constraint_edits,
		"alias_records": alias_records,
		"tag_edits": tag_edits,
		"rules": rules,
		"tagging_rules": tagging_rules,
		"terrain_key": terrain_key_classes,
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
	outputs = {}
	parts = {}
	constraints = {}
	_raw_parts = []
	_raw_constraints = []
	_alias_mapping = {}
	last_run_stats = {}
	last_synthesis = {}
	_next_output_number = 1
	last_run_config = data.get("run", {})
	part_edits = data.get("part_edits", {})
	transform_edits = data.get("transform_edits", {})
	constraint_edits = data.get("constraint_edits", {})
	alias_records = []
	alias_records.assign(data.get("alias_records", []))
	tag_edits = _decode_tag_edits(data.get("tag_edits", {}))
	rules = []
	var loaded_rules: Variant = data.get("rules", [])
	if loaded_rules is Array:
		rules.assign(loaded_rules)
	_next_rule_number = _max_rule_number() + 1
	tagging_rules = []
	var loaded_tag_rules: Variant = data.get("tagging_rules", [])
	if loaded_tag_rules is Array:
		tagging_rules.assign(loaded_tag_rules)
	_next_tag_rule_number = _max_tag_rule_number() + 1
	terrain_key_classes = []
	var loaded_key: Variant = data.get("terrain_key", null)
	if loaded_key is Array:
		terrain_key_classes.assign(loaded_key)
	else:
		# Legacy multi-key projects: adopt the first enabled key's classes.
		for k: Variant in data.get("terrain_keys", []):
			if k is Dictionary and bool((k as Dictionary).get("enabled", true)):
				var classes: Variant = (k as Dictionary).get("classes", [])
				if classes is Array:
					terrain_key_classes.assign(classes)
					break
	for rec: Dictionary in data.get("images", []):
		var asset := ImageAssetData.load_from_path(rec["path"])
		if asset == null:
			push_warning("Project image missing, skipped: %s" % rec["path"])
			continue
		images[asset.id] = asset
	# Load replaces several state arrays wholesale, and each has a change
	# signal that some tab rebuilds from — emit them all. tagging_rules_changed
	# was missing here, so the auto-tag rule list stayed stale after loading
	# (it is only rebuilt on that signal, plus once at _ready, pre-load).
	images_changed.emit()
	outputs_changed.emit()
	parts_changed.emit()
	constraints_changed.emit()
	rules_changed.emit()
	tagging_rules_changed.emit()
	edits_changed.emit()
	terrain_key_changed.emit()
	return data


func _decode_tag_edits(src: Variant) -> Dictionary:
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


func _max_rule_number() -> int:
	var maxn := 0
	for r: Variant in rules:
		var rid := String((r as Dictionary).get("id", ""))
		if rid.begins_with("rule_") and rid.substr(5).is_valid_int():
			maxn = maxi(maxn, int(rid.substr(5)))
	return maxn


func _max_tag_rule_number() -> int:
	var maxn := 0
	for r: Variant in tagging_rules:
		var rid := String((r as Dictionary).get("id", ""))
		if rid.begins_with("tagrule_") and rid.substr(8).is_valid_int():
			maxn = maxi(maxn, int(rid.substr(8)))
	return maxn
