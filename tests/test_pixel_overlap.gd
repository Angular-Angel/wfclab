extends GdUnitTestSuite

const Builders = preload("res://tests/builders.gd")

## PixelOverlap suite. All tests drive the public extract() API and assert on
## the returned constraints (ids, participants, params.offset, evidence).
##
## Fixture recipe: 2x2 parts built from explicit color grids; strips are 1px
## wide at depth 1 (overlap_layers = 1). Fixtures are ASYMMETRIC on BOTH
## relations — every part gets four distinct-ish colors so that no part's top
## row equals its bottom row (that would emit A~A self-pairs at (0, 2)) and no
## unintended right~left pairing can match. A uniform-edge part may only be
## used deliberately, when a test wants to pin self-pair emission.

var _saved_key: Array = []


func before_test() -> void:
	_saved_key = Builders.terrain_key_snapshot()


func after_test() -> void:
	Builders.terrain_key_restore(_saved_key)


func _extract(parts: Array[Part], params: Dictionary) -> Array[Constraint]:
	return PixelOverlap.new().extract(parts, [], params,
			func(_progress: float) -> void: pass)


func _part2x2(tl: Color, tr: Color, bl: Color, br: Color,
		id_hash: String) -> Part:
	return Builders.make_part_from_image(Builders.grid_image(
			[[tl, tr], [bl, br]]), id_hash)


func _ids(constraints: Array[Constraint]) -> Array[String]:
	var ids: Array[String] = []
	for c: Constraint in constraints:
		ids.append(c.id)
	ids.sort()
	return ids


func test_strict_strip_match_emits_horizontal_constraint() -> void:
	# A's right column [red, red] matches B's left column [red, red]; every
	# other strip pairing differs.
	var a := _part2x2(Color("#00ff00"), Color("#ff0000"),
			Color8(255, 255, 255), Color("#ff0000"), "aaaaaaaaaaaa")
	var b := _part2x2(Color("#ff0000"), Color("#0000ff"),
			Color("#ff0000"), Color("#ffff00"), "bbbbbbbbbbbb")
	var result := _extract([a, b], {"overlap_layers": 1})

	assert_int(result.size()).is_equal(1)
	assert_that(result[0].type).is_equal(&"pixel_overlap")
	assert_that(result[0].params["offset"]).is_equal(Vector2i(2, 0))
	assert_that(result[0].id).is_equal("o_aaaaaa_bbbbbb_2_0")
	assert_int(result[0].evidence.size()).is_equal(1)
	assert_that(result[0].participants[0]["part_id"]).is_equal(a.id)
	assert_that(result[0].participants[1]["part_id"]).is_equal(b.id)


func test_strict_mismatch_emits_nothing() -> void:
	var a := _part2x2(Color("#00ff00"), Color("#ff0000"),
			Color8(255, 255, 255), Color("#ff0000"), "aaaaaaaaaaaa")
	var b := _part2x2(Color("#0000ff"), Color("#ffff00"),
			Color("#ff00ff"), Color("#00ffff"), "bbbbbbbbbbbb")
	var result := _extract([a, b], {"overlap_layers": 1})

	assert_array(result).is_empty()


func test_tolerance_is_per_channel_and_inclusive() -> void:
	# Facing strips differ by exactly 5 in the red channel only.
	var a := _part2x2(Color8(0, 255, 0), Color8(100, 0, 0),
			Color8(255, 255, 255), Color8(100, 0, 0), "aaaaaaaaaaaa")
	var b := _part2x2(Color8(105, 0, 0), Color8(0, 0, 255),
			Color8(105, 0, 0), Color8(255, 255, 0), "bbbbbbbbbbbb")

	assert_int(_extract([a, b],
			{"overlap_layers": 1, "tolerance": 5}).size()).is_equal(1)
	assert_int(_extract([a, b],
			{"overlap_layers": 1, "tolerance": 4}).size()).is_equal(0)


func test_allowed_omissions_budgets_single_pixel_failures() -> void:
	# Facing strips [red, green] vs [red, blue]: exactly one bad pixel.
	# Every other pairing differs in both pixels, so only A~B can match.
	var a := _part2x2(Color8(0, 255, 0), Color8(255, 0, 0),
			Color8(0, 0, 255), Color8(0, 255, 0), "aaaaaaaaaaaa")
	var b := _part2x2(Color8(255, 0, 0), Color8(255, 255, 0),
			Color8(0, 0, 255), Color8(255, 0, 255), "bbbbbbbbbbbb")

	var with_budget := _extract([a, b],
			{"overlap_layers": 1, "allowed_omissions": 1})
	assert_int(with_budget.size()).is_equal(1)
	assert_that(with_budget[0].id).is_equal("o_aaaaaa_bbbbbb_2_0")
	assert_int(_extract([a, b],
			{"overlap_layers": 1, "allowed_omissions": 0}).size()).is_equal(0)


func test_flex_permits_seam_displacement_within_budget() -> void:
	# A's right strip [red, green] vs B's left [green, red]: a mirrored
	# (cyclic) shift along the seam — every pixel finds a counterpart
	# displaced by exactly 1, in BOTH directions (two-sided matcher).
	var a := _part2x2(Color8(255, 255, 255), Color8(255, 0, 0),
			Color8(0, 0, 0), Color8(0, 255, 0), "aaaaaaaaaaaa")
	var b := _part2x2(Color8(0, 255, 0), Color8(255, 255, 0),
			Color8(255, 0, 0), Color8(0, 0, 255), "bbbbbbbbbbbb")

	var flexed := _extract([a, b], {"overlap_layers": 1, "flex": 1})
	assert_int(flexed.size()).is_equal(1)
	assert_that(flexed[0].params["offset"]).is_equal(Vector2i(2, 0))
	assert_int(_extract([a, b], {"overlap_layers": 1, "flex": 0}).size()).is_equal(0)


func test_vertical_pairs_use_vertical_offsets() -> void:
	# A's bottom row [red, green] matches B's top row [red, green].
	var a := _part2x2(Color8(255, 255, 255), Color8(0, 0, 0),
			Color8(255, 0, 0), Color8(0, 255, 0), "aaaaaaaaaaaa")
	var b := _part2x2(Color8(255, 0, 0), Color8(0, 255, 0),
			Color8(0, 0, 255), Color8(255, 255, 0), "bbbbbbbbbbbb")
	var result := _extract([a, b], {"overlap_layers": 1})

	assert_int(result.size()).is_equal(1)
	assert_that(result[0].params["offset"]).is_equal(Vector2i(0, 2))
	assert_that(result[0].id).is_equal("o_aaaaaa_bbbbbb_0_2")


func test_extraction_order_does_not_change_output() -> void:
	var a := _part2x2(Color("#00ff00"), Color("#ff0000"),
			Color8(255, 255, 255), Color("#ff0000"), "aaaaaaaaaaaa")
	var b := _part2x2(Color("#ff0000"), Color("#0000ff"),
			Color("#ff0000"), Color("#ffff00"), "bbbbbbbbbbbb")

	var forward := _ids(_extract([a, b], {"overlap_layers": 1}))
	var reverse := _ids(_extract([b, a], {"overlap_layers": 1}))

	assert_array(forward).is_not_empty()
	assert_array(forward).is_equal(reverse)


func test_parts_smaller_than_depth_are_skipped() -> void:
	# 1x2 parts cannot provide a 2px-deep strip: skipped, no crash.
	var a := Builders.make_part_from_image(
			Builders.flat_image(1, 2, [Color.RED, Color.GREEN]), "aaaaaaaaaaaa")
	var b := Builders.make_part_from_image(
			Builders.flat_image(1, 2, [Color.BLUE, Color.WHITE]), "bbbbbbbbbbbb")
	var result := _extract([a, b], {"overlap_layers": 2})

	assert_array(result).is_empty()


func test_terrain_class_rewrites_unify_colors() -> void:
	# A's right column is red, B's left column is green; both are members of
	# one terrain class whose representative is red, so AFTER classification
	# the strips are byte-equal and match strictly. extract() reads the
	# AppData AUTOLOAD (registered in project.godot) — snapshotted in
	# before_test and restored unconditionally in after_test.
	AppData.terrain_key_classes = [{
		"name": "stone", "colors": ["ff0000", "00ff00"],
		"tolerance": 0, "flex": 0, "enabled": true,
	}]

	var a := _part2x2(Color("#0000ff"), Color("#ff0000"),
			Color8(255, 255, 255), Color("#ff0000"), "aaaaaaaaaaaa")
	var b := _part2x2(Color("#00ff00"), Color("#ffff00"),
			Color("#00ff00"), Color("#00ffff"), "bbbbbbbbbbbb")

	assert_int(_extract([a, b], {"overlap_layers": 1}).size()).is_equal(1)


func test_symmetric_pair_records_both_directions() -> void:
	# A's right [red, black] matches B's left [red, black] AND B's right
	# [green, white] matches A's left [green, white]: two directed pairs.
	var a := _part2x2(Color("#00ff00"), Color("#ff0000"),
			Color8(255, 255, 255), Color8(0, 0, 0), "aaaaaaaaaaaa")
	var b := _part2x2(Color("#ff0000"), Color("#00ff00"),
			Color8(0, 0, 0), Color8(255, 255, 255), "bbbbbbbbbbbb")
	var result := _extract([a, b], {"overlap_layers": 1})

	assert_array(_ids(result)).is_equal(
			["o_aaaaaa_bbbbbb_2_0", "o_bbbbbb_aaaaaa_2_0"] as Array[String])
