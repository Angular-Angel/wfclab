extends GdUnitTestSuite
## ProjectCodec suite: encode→write→read round-trip and the decode-side
## normalizations, including the real v1 "legacy terrain_keys" migration
## that previously had no direct coverage.

const ProjectCodecScript := preload("res://scripts/core/project_codec.gd")

const ROUND_TRIP_PATH := "user://test_codec_round_trip.wfcproj"
const LEGACY_PATH := "user://test_codec_legacy.wfcproj"


func _state() -> Dictionary:
	return {
		"run": {"technique_id": "grid_tiles", "params": {"tile": 32}},
		"part_edits": {"p_aabbcc112200": {"enabled": false}},
		"transform_edits": {"p_aabbcc112200": {"rot90": false}},
		"constraint_edits": {"c_aabbcc_112233_2_0": {"weight_override": 4.5}},
		"alias_records": [{"from": "p_112233445500", "into": "p_aabbcc112200"}],
		"tag_edits": {"p_aabbcc112200": ["water", ""]},
		"rules": [{"id": "rule_1", "type": "exclusion"}],
		"tagging_rules": [{"id": "tagrule_1", "tag": "water"}],
		"terrain_key": [{"name": "stone", "colors": ["ff0000"]}],
	}


func test_write_read_round_trip_preserves_state() -> void:
	var data := ProjectCodecScript.encode([], _state())
	assert_bool(ProjectCodecScript.write(ROUND_TRIP_PATH, data)).is_true()

	var loaded := ProjectCodecScript.read(ROUND_TRIP_PATH)
	assert_dict(loaded).is_not_empty()
	assert_int(int(loaded["version"])).is_equal(ProjectCodecScript.VERSION)
	# floats come back from JSON as whole ints where the codec restores them
	assert_that(loaded["run"]).is_equal(_state()["run"])
	assert_that(loaded["part_edits"]).is_equal(_state()["part_edits"])
	assert_that(loaded["terrain_key"]).is_equal(_state()["terrain_key"])
	assert_array(loaded["rules"]).is_equal(_state()["rules"])
	# tag edits: empty-string tags were filtered out at decode
	assert_dict(loaded["tag_edits"]).is_equal(
			{"p_aabbcc112200": ["water"] as Array[String]})
	# constraint weight override: JSON whole floats restore as floats here?
	# 4.5 is fractional, so it stays a float and compares equal.
	assert_that(loaded["constraint_edits"]).is_equal(_state()["constraint_edits"])


func test_read_missing_file_is_empty() -> void:
	assert_dict(ProjectCodecScript.read("user://definitely_not_here.wfcproj")) \
			.is_empty()


func test_decode_migrates_legacy_multi_key_terrain_keys() -> void:
	# v1 saves stored several keys; decode adopts the FIRST ENABLED key's
	# classes and always writes the unified "terrain_key" array.
	var legacy := {
		"version": 1,
		"terrain_keys": [
			{"name": "off", "enabled": false, "classes": [["never"]]},
			{"name": "stone", "enabled": true, "classes": ["aabbcc"]},
			{"name": "later-enabled", "classes": ["ffffff"]},
		],
	}
	var decoded := ProjectCodecScript.decode(legacy)
	var key: Array = decoded["terrain_key"]
	assert_array(key).is_equal(["aabbcc"])


func test_decode_legacy_all_disabled_yields_empty_key() -> void:
	var legacy := {
		"terrain_keys": [{"name": "off", "enabled": false, "classes": ["aabbcc"]}],
	}
	assert_array(ProjectCodecScript.decode(legacy)["terrain_key"]).is_empty()


func test_decode_without_any_key_yields_empty_key() -> void:
	assert_array(ProjectCodecScript.decode({"version": 1})["terrain_key"]) \
			.is_empty()


func test_decode_modern_terrain_key_wins_over_legacy() -> void:
	var mixed := {
		"terrain_key": ["modern"],
		"terrain_keys": [{"classes": ["legacy"]}],
	}
	assert_array(ProjectCodecScript.decode(mixed)["terrain_key"]) \
			.is_equal(["modern"])


func test_decode_normalizes_rules_and_tag_edits() -> void:
	var decoded := ProjectCodecScript.decode({
		"rules": "not-an-array",
		"tagging_rules": 42,
		"tag_edits": {"p_x": ["keep", "", 12], "p_empty": []},
	})
	assert_array(decoded["rules"]).is_empty()
	assert_array(decoded["tagging_rules"]).is_empty()
	# non-string and empty-string tags dropped; fully-empty ids dropped
	assert_dict(decoded["tag_edits"]).is_equal({"p_x": ["keep"] as Array[String]})
