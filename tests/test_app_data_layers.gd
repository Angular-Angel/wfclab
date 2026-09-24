extends GdUnitTestSuite

const AppDataScript = preload("res://scripts/core/app_data.gd")
const Builders = preload("res://tests/builders.gd")

## AppData layers: materialization, merges, tags, authored rules, auto-tag
## rules, terrain key, and persistence. Uses the existing AppData
## instantiation pattern (auto_free + _ready()) plus last_run_config seeding
## to steer _materialize_parts.

const ROUND_TRIP_PATH := "user://test_project.wfcproj"
const LEGACY_PATH := "user://test_legacy_project.wfcproj"
const RULE_NUMBERING_PATH := "user://test_rule_numbering.wfcproj"


func _data() -> Variant:
	var data: Variant = auto_free(AppDataScript.new())
	data._ready()
	return data


func _spy(data: Variant, signal_name: String) -> Array:
	## Connect a counting lambda; returns the hit list to assert on.
	var hits: Array = []
	data.connect(signal_name, func() -> void: hits.append(1))
	return hits


func _drop_file(path: String) -> void:
	var dir := DirAccess.open("user://")
	if dir != null and dir.file_exists(path.get_file()):
		dir.remove(path.get_file())


func _materialized_ids(data: Variant) -> Dictionary:
	## raw canonical id -> materialized part id.
	var ids: Dictionary = {}
	for p in data.get_part_list():
		ids[p.canonical_id] = p.id
	return ids


func test_materialize_expands_enabled_transform_variants() -> void:
	var data: Variant = _data()
	data.last_run_config = {"params": {"rotation_90": true}}

	var raw := Builders.make_part_from_image(Builders.grid_image(
			[[Color.RED, Color.GREEN], [Color.BLUE, Color.WHITE]]),
			"aabbccdd1122")
	var raw_parts: Array[Part] = [raw]
	data.set_parts(raw_parts, {})

	# Distinct pixels: identity AND rot90 materialize as separate parts,
	# both canonical back to the raw id; the variant shares occurrences.
	var list: Array = data.get_part_list()
	assert_int(list.size()).is_equal(2)
	var identity: Part = null
	var rot90: Part = null
	for p in list:
		if p.transform_key == "identity":
			identity = p
		elif p.transform_key == "rot90":
			rot90 = p
	assert_object(identity).is_not_null()
	assert_object(rot90).is_not_null()
	assert_that(identity.canonical_id).is_equal(raw.id)
	assert_that(rot90.canonical_id).is_equal(raw.id)
	assert_that(rot90.occurrences).is_equal(raw.occurrences)
	assert_float(rot90.get_effective_weight()).is_equal(1.0)

	# rot90 on a non-square part is skipped.
	data.last_run_config = {"params": {"rotation_90": true}}
	var wide := Builders.make_part_from_image(
			Builders.flat_image(2, 1, [Color.RED, Color.GREEN]), "1122334455")
	data.set_parts([wide] as Array[Part], {})
	for p in data.get_part_list():
		assert_that(p.transform_key).is_not_equal("rot90")


func test_run_transform_enabled_matrix() -> void:
	var data: Variant = _data()

	# identity always true, everything else off by default.
	assert_bool(data.is_transform_enabled("p_x", "identity")).is_true()
	for key: String in ["rot90", "rot180", "rot270", "flip_h", "flip_v"]:
		assert_bool(data.is_transform_enabled("p_x", key)).is_false()

	data.last_run_config = {"params": {"reflect_horizontal": true,
			"reflect_vertical": true}}
	# rot180 is implied by reflect_horizontal && reflect_vertical.
	assert_bool(data.is_transform_enabled("p_x", "rot180")).is_true()
	assert_bool(data.is_transform_enabled("p_x", "flip_h")).is_true()
	assert_bool(data.is_transform_enabled("p_x", "flip_v")).is_true()

	# The explicit rotation_180 flag alone forces it on; a single reflect
	# axis does not imply it.
	data.last_run_config = {"params": {"rotation_180": true}}
	assert_bool(data.is_transform_enabled("p_x", "rot180")).is_true()
	data.last_run_config = {"params": {"reflect_horizontal": true}}
	assert_bool(data.is_transform_enabled("p_x", "rot180")).is_false()
	assert_bool(data.is_transform_enabled("p_x", "flip_h")).is_true()


func test_merge_parts_rewrites_participants_and_rebuilds_ids() -> void:
	var data: Variant = _data()
	var raw_a := Builders.make_part("aaaaaaaaaaaa", Color.RED)
	var raw_b := Builders.make_part("bbbbbbbbbbbb", Color.BLUE)
	var raw_c := Builders.make_part("cccccccccccc", Color.GREEN)
	data.set_parts([raw_a, raw_b, raw_c] as Array[Part], {})
	var ids := _materialized_ids(data)
	var id_a: String = ids[raw_a.id]
	var id_b: String = ids[raw_b.id]
	var id_c: String = ids[raw_c.id]

	data.set_constraints([
		Builders.make_constraint(id_a, id_b, Vector2i(1, 0)),
		Builders.make_constraint(id_b, id_c, Vector2i(1, 0)),
	] as Array[Constraint])

	# --- single merge a->b ---
	data.merge_parts(id_a, id_b)
	assert_bool(data.parts.has(id_a)).is_false()
	var merged_b: Part = data.parts[id_b]
	assert_int(merged_b.occurrence_count()).is_equal(2)
	assert_float(merged_b.get_effective_weight()).is_equal(2.0)

	# Constraints referencing a now point at b under a rebuilt id.
	var old_ab_id: String = Builders.make_constraint(id_a, id_b,
			Vector2i(1, 0)).id
	assert_bool(data.constraints.has(old_ab_id)).is_false()
	var found_rewritten := false
	for c in data.get_constraint_list():
		for participant in c.participants:
			assert_that(participant["part_id"]).is_not_equal(id_a)
		if c.participants[0]["part_id"] == id_b \
				and c.participants[1]["part_id"] == id_b:
			found_rewritten = true
	assert_bool(found_rewritten).is_true()

	# --- chain b->c: transitive at the PART level only ---
	data.merge_parts(id_b, id_c)
	assert_bool(data.parts.has(id_b)).is_false()
	var merged_c: Part = data.parts[id_c]
	assert_int(merged_c.occurrence_count()).is_equal(3)
	assert_float(merged_c.get_effective_weight()).is_equal(3.0)

	# Known defect: participant rewriting is single-step through
	# _alias_mapping, so the a->b constraint now points at merged-away b.
	# Deliberately NOT asserting constraint-level transitivity.
	var dangling := false
	for c in data.get_constraint_list():
		for participant in c.participants:
			var pid: String = participant["part_id"]
			if pid == id_b:
				dangling = true
	assert_bool(dangling).is_true()


func test_clear_all_edits_keeps_tags_and_rules() -> void:
	var data: Variant = _data()
	var raw := Builders.make_part("aaaaaaaaaaaa", Color.RED)
	data.set_parts([raw] as Array[Part], {})
	var id: String = _materialized_ids(data)[raw.id]

	data.add_part_tag(id, "forest")
	data.add_rule({"type": "exclusion", "tag_a": "forest", "tag_b": "lava",
			"distance": 1, "metric": "chebyshev"})
	data.edit_part(id, "enabled", false)
	assert_bool(data.parts[id].enabled).is_false()

	data.clear_all_edits()

	assert_bool(data.parts[id].enabled).is_true()          # part edit wiped
	assert_array(data.get_tags(id)).is_equal(["forest" as String])   # kept
	assert_int(data.get_rules().size()).is_equal(1)        # kept
	assert_int(data.part_edits.size()).is_equal(0)


func test_tag_crud_and_strip_everywhere() -> void:
	var data: Variant = _data()
	var raw_a := Builders.make_part("aaaaaaaaaaaa", Color.RED)
	var raw_b := Builders.make_part("bbbbbbbbbbbb", Color.BLUE)
	data.set_parts([raw_a, raw_b] as Array[Part], {})
	var ids := _materialized_ids(data)
	var id_a: String = ids[raw_a.id]
	var id_b: String = ids[raw_b.id]

	data.add_part_tag(id_a, "forest")
	data.add_part_tag(id_a, "forest")            # dedupe
	data.add_part_tag(id_a, "   ")               # empty rejected
	data.add_part_tag("p_missing", "x")          # unknown part rejected
	data.add_part_tag(id_a, " lava ")            # stripped on add
	assert_array(data.get_tags(id_a)).is_equal(["forest", "lava"] as Array[String])

	data.add_part_tag(id_b, "forest")
	assert_array(data.get_all_tags()).is_equal(["forest", "lava"] as Array[String])

	var edits_hits := _spy(data, "edits_changed")
	data.remove_part_tag(id_a, "forest")
	assert_array(data.get_tags(id_a)).is_equal(["lava" as String])

	assert_int(data.strip_tag_everywhere("lava")).is_equal(1)
	assert_int(data.strip_tag_everywhere("lava")).is_equal(0)   # idempotent
	assert_array(data.get_tags(id_a)).is_empty()
	assert_int(edits_hits.size()).is_equal(2)   # remove + one strip emission


func test_authored_rule_crud_and_numbering() -> void:
	_drop_file(RULE_NUMBERING_PATH)
	var data: Variant = _data()
	var first: String = data.add_rule({"type": "exclusion", "tag_a": "a",
			"tag_b": "b", "distance": 1, "metric": "chebyshev"})
	var second: String = data.add_rule({"type": "exclusion", "tag_a": "b",
			"tag_b": "c", "distance": 2, "metric": "manhattan"})
	assert_str(first).is_equal("rule_1")
	assert_str(second).is_equal("rule_2")

	data.update_rule("rule_1", {"distance": 3, "id": "spoof"})
	var stored: Array = data.get_rules()
	assert_int(stored[0]["distance"]).is_equal(3)
	assert_str(stored[0]["id"]).is_equal("rule_1")   # id cannot be patched

	data.remove_rule("rule_2")
	assert_int(data.get_rules().size()).is_equal(1)

	# After load, numbering continues past the max restored id.
	assert_bool(data.save_project(RULE_NUMBERING_PATH)).is_true()
	var fresh: Variant = _data()
	assert_bool(fresh.load_project(RULE_NUMBERING_PATH).is_empty()).is_false()
	assert_str(fresh.add_rule({"type": "exclusion", "tag_a": "x",
			"tag_b": "y", "distance": 1, "metric": "chebyshev"})).is_equal("rule_2")

	_drop_file(RULE_NUMBERING_PATH)


func test_apply_tagging_rules_is_idempotent_and_reports() -> void:
	var data: Variant = _data()
	var raw_red := Builders.make_part("aaaaaaaaaaaa", Color.RED)
	var raw_green := Builders.make_part("bbbbbbbbbbbb", Color8(0, 255, 0))
	data.set_parts([raw_red, raw_green] as Array[Part], {})

	data.add_tagging_rule({"tag": "forest", "colors": ["#00ff00"],
			"tolerance": 0, "min_fraction": 0.9})
	var disabled_id: String = data.add_tagging_rule({"tag": "unused",
			"colors": ["#ff0000"], "tolerance": 0, "min_fraction": 0.1,
			"enabled": false})

	var edits_hits := _spy(data, "edits_changed")
	var report: Dictionary = data.apply_tagging_rules()

	assert_int(report["tagged_parts"]).is_equal(1)
	assert_int(report["per_rule"]["tagrule_1"]).is_equal(1)
	assert_bool(report["per_rule"].has(disabled_id)).is_false()   # skipped
	var ids := _materialized_ids(data)
	assert_array(data.get_tags(ids[raw_green.id])).is_equal(["forest" as String])
	assert_array(data.get_tags(ids[raw_red.id])).is_empty()
	assert_int(edits_hits.size()).is_equal(1)   # conditional single emission

	var repeat: Dictionary = data.apply_tagging_rules()
	assert_int(repeat["tagged_parts"]).is_equal(0)   # idempotent
	assert_int(edits_hits.size()).is_equal(1)        # no re-emission


func test_terrain_key_filters_and_regen() -> void:
	var data: Variant = _data()
	var raw_red := Builders.make_part("aaaaaaaaaaaa", Color.RED)
	var raw_green := Builders.make_part("bbbbbbbbbbbb", Color8(0, 255, 0))
	var raw_mixed := Builders.make_part_from_image(
			Builders.flat_image(2, 1, [Color8(0, 255, 0), Color.RED]),
			"cccccccccccc")
	data.set_parts([raw_red, raw_green, raw_mixed] as Array[Part], {})
	# Adjacency-only jobs: pixel_overlap regeneration would consult the
	# AppData AUTOLOAD's key, not this instance's.
	data.last_run_config = {"constraint_jobs": [{"id": "adjacency", "params": {}}]}

	var key := [
		{"name": "grass", "colors": ["00ff00"], "tolerance": 0,
		"enabled": true, "tag": "grass", "min_fraction": 1.0},
		{"name": "off", "colors": ["ff0000"], "tolerance": 0,
		"enabled": false, "tag": "nope", "min_fraction": 0.1},
	]

	var terrain_hits := _spy(data, "terrain_key_changed")
	var constraint_hits := _spy(data, "constraints_changed")
	data.set_terrain_key(key)
	assert_int(terrain_hits.size()).is_equal(1)
	assert_int(constraint_hits.size()).is_equal(1)   # save regenerates

	# Disabled classes are dropped from the extraction/tagging view.
	assert_int(data.active_terrain_classes().size()).is_equal(1)

	# min_fraction honored: pure-green part tags, the half-green mix does not.
	var report: Dictionary = data.apply_terrain_key_tags()
	assert_int(report["tagged_parts"]).is_equal(1)
	assert_int(report["per_class"]["grass"]).is_equal(1)
	var ids := _materialized_ids(data)
	assert_array(data.get_tags(ids[raw_green.id])).is_equal(["grass" as String])
	assert_array(data.get_tags(ids[raw_mixed.id])).is_empty()


func test_save_and_load_project_round_trip() -> void:
	_drop_file(ROUND_TRIP_PATH)
	_drop_file(LEGACY_PATH)
	var data: Variant = _data()
	var raw := Builders.make_part("aaaaaaaaaaaa", Color.RED)
	data.set_parts([raw] as Array[Part], {})
	var id: String = _materialized_ids(data)[raw.id]

	data.add_part_tag(id, "forest")
	data.add_rule({"type": "exclusion", "tag_a": "forest", "tag_b": "lava",
			"distance": 1, "metric": "chebyshev"})
	data.edit_part(id, "weight_override", 3.5)
	data.set_terrain_key([{"name": "stone", "colors": ["ff0000"],
			"tolerance": 2, "enabled": true}])

	assert_bool(data.save_project(ROUND_TRIP_PATH)).is_true()
	var fresh: Variant = _data()
	var loaded: Dictionary = fresh.load_project(ROUND_TRIP_PATH)
	assert_bool(loaded.is_empty()).is_false()

	assert_array(fresh.get_tags(id)).is_equal(data.get_tags(id))
	assert_array(fresh.get_rules()).is_equal(data.get_rules())
	assert_array(fresh.terrain_key_classes).is_equal(data.terrain_key_classes)
	assert_dict(fresh.part_edits).is_equal(data.part_edits)

	# Missing file -> empty Dictionary.
	assert_dict(fresh.load_project("user://definitely_missing.wfcproj")).is_empty()

	# _decode_tag_edits drops empty and non-string entries.
	var decoded: Dictionary = fresh._decode_tag_edits({
		"id": ["ok", "", 42, null, "also_ok"],
		"empty": [],
	})
	assert_dict(decoded).is_equal({"id": ["ok", "also_ok"]})

	# Legacy terrain_keys array migrates the first ENABLED key's classes.
	var legacy := {
		"version": 1,
		"terrain_keys": [
			{"name": "disabled_first", "enabled": false,
			"classes": [{"name": "no", "colors": ["000000"]}]},
			{"name": "active", "enabled": true,
			"classes": [{"name": "yes", "colors": ["ffffff"]}]},
		],
	}
	var f := FileAccess.open(LEGACY_PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify(legacy))
	f = null
	var migrated: Variant = _data()
	migrated.load_project(LEGACY_PATH)
	assert_array(migrated.terrain_key_classes).is_equal(
			[{"name": "yes", "colors": ["ffffff"]}] as Array)

	_drop_file(ROUND_TRIP_PATH)
	_drop_file(LEGACY_PATH)


func test_remove_output_clears_last_synthesis() -> void:
	var data: Variant = _data()
	var image := Builders.solid_image(1, 1, Color.RED)
	data.set_synthesis(image, {"seed": 1}, {"label": "first"})
	data.set_synthesis(image, {"seed": 2}, {"label": "second"})
	var ids: Array = data.outputs.keys()
	ids.sort()
	var first_id: String = ids[0]
	var second_id: String = ids[1]
	assert_that(data.last_synthesis["output_id"]).is_equal(second_id)

	var synthesis_hits := _spy(data, "synthesis_changed")

	# Removing another (non-current) output leaves last_synthesis alone.
	assert_bool(data.remove_output(first_id)).is_true()
	assert_that(data.last_synthesis["output_id"]).is_equal(second_id)
	assert_int(synthesis_hits.size()).is_equal(0)

	# Removing the current output resets last_synthesis and emits.
	assert_bool(data.remove_output(second_id)).is_true()
	assert_dict(data.last_synthesis).is_empty()
	assert_int(synthesis_hits.size()).is_equal(1)

	assert_bool(data.remove_output("out_missing")).is_false()
