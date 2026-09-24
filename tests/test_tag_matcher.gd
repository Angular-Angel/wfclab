extends GdUnitTestSuite

const Builders := preload("res://tests/builders.gd")


func test_exact_match_full_coverage() -> void:
	var img := Builders.solid_image(4, 4, Color("#00ff00"))
	assert_float(TagMatcher.coverage_fraction(img, ["#00ff00"], 0)).is_equal(1.0)


func test_tolerance_is_per_channel_and_inclusive() -> void:
	var img := Builders.solid_image(2, 2, Color("#00dd00"))   # green channel delta 34 from #00ff00
	assert_float(TagMatcher.coverage_fraction(img, ["#00ff00"], 34)).is_equal(1.0)
	assert_float(TagMatcher.coverage_fraction(img, ["#00ff00"], 33)).is_equal(0.0)


func test_any_target_matches() -> void:
	var img := Builders.solid_image(2, 2, Color("#ff0000"))
	assert_float(TagMatcher.coverage_fraction(
			img, ["#00ff00", "#ff0000"], 0)).is_equal(1.0)


func test_transparent_pixels_excluded_from_both_sides() -> void:
	var img := Builders.solid_image(2, 2, Color("#00ff00"))
	img.set_pixel(0, 0, Color(0, 0, 0, 0))
	assert_float(TagMatcher.coverage_fraction(img, ["#00ff00"], 0)).is_equal(1.0)
	var empty := Builders.solid_image(2, 2, Color(0, 0, 0, 0))
	assert_float(TagMatcher.coverage_fraction(empty, ["#00ff00"], 255)).is_equal(0.0)


func test_rule_threshold_semantics() -> void:
	var img := Builders.solid_image(4, 4, Color("#00ff00"))
	img.set_pixel(0, 0, Color("#ff0000"))
	var rule := {"tag": "forest", "colors": ["#00ff00"],
			"tolerance": 0, "min_fraction": 0.9}
	assert_bool(TagMatcher.rule_matches(img, rule)).is_true()     # 15/16 = 0.9375
	rule["min_fraction"] = 0.95
	assert_bool(TagMatcher.rule_matches(img, rule)).is_false()


func test_rule_without_colors_is_inert() -> void:
	var img := Builders.solid_image(2, 2, Color("#00ff00"))
	var rule := {"tag": "forest", "colors": [], "tolerance": 255,
			"min_fraction": 0.0}
	assert_bool(TagMatcher.rule_matches(img, rule)).is_false()
