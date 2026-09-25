extends GdUnitTestSuite
## Direct StripUtil suite: side() geometry on non-square parts (where a
## span/along swap bug only shows), and classes() with an empty class map.

const StripUtilScript := preload("res://scripts/core/util/strip_util.gd")


func test_right_and_left_spans_follow_height_on_non_square_parts() -> void:
	# 7 wide × 3 tall: the vertical seams span the HEIGHT (3), not the width.
	var right: Dictionary = StripUtilScript.side("right", Vector2i(7, 3))
	assert_dict(right).is_equal({
		"start": Vector2i(6, 0), "along": Vector2i(0, 1),
		"inward": Vector2i(-1, 0), "span": 3,
	})
	var left: Dictionary = StripUtilScript.side("left", Vector2i(7, 3))
	assert_dict(left).is_equal({
		"start": Vector2i(0, 0), "along": Vector2i(0, 1),
		"inward": Vector2i(1, 0), "span": 3,
	})


func test_top_and_bottom_spans_follow_width_on_non_square_parts() -> void:
	# The horizontal seams span the WIDTH (7), and bottom starts at y = 2.
	var bottom: Dictionary = StripUtilScript.side("bottom", Vector2i(7, 3))
	assert_dict(bottom).is_equal({
		"start": Vector2i(0, 2), "along": Vector2i(1, 0),
		"inward": Vector2i(0, -1), "span": 7,
	})
	var top: Dictionary = StripUtilScript.side("top", Vector2i(7, 3))
	assert_dict(top).is_equal({
		"start": Vector2i(0, 0), "along": Vector2i(1, 0),
		"inward": Vector2i(0, 1), "span": 7,
	})


func test_side_unknown_name_is_empty() -> void:
	assert_dict(StripUtilScript.side("diagonal", Vector2i(4, 4))).is_empty()


func test_classes_with_empty_map_yields_empty_array() -> void:
	# No terrain key active: empty class map → empty strip, regardless of
	# geometry — the matcher reads that as "every pixel unclassed".
	var out := StripUtilScript.classes(PackedInt32Array(), 8, 2,
			Vector2i(7, 0), Vector2i(0, 1), Vector2i(-1, 0), 3)
	assert_array(out).is_empty()


func test_classes_walk_matches_bytes_iteration_order() -> void:
	# 4-wide map, depth 2 inward from x=3, span 2 along +y:
	# outer loop v (down the seam), inner loop u (inward, away from seam).
	var cls_map := PackedInt32Array()
	cls_map.resize(16)
	cls_map[3 + 0 * 4] = 10   # (3,0) u=0
	cls_map[2 + 0 * 4] = 11   # (2,0) u=1
	cls_map[3 + 1 * 4] = 20   # (3,1) u=0
	cls_map[2 + 1 * 4] = 21   # (2,1) u=1
	var out := StripUtilScript.classes(cls_map, 4, 2,
			Vector2i(3, 0), Vector2i(0, 1), Vector2i(-1, 0), 2)
	assert_array(out).is_equal(PackedInt32Array([10, 11, 20, 21]))
