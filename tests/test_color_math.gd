extends GdUnitTestSuite
## Tests for ColorMath: hex decode round-trips (missing "#", 3- and
## 6-digit forms, invalid entries skipped) and the per-channel Chebyshev
## match with inclusive tolerance boundaries.

const Builders := preload("res://tests/builders.gd")


func test_decode_six_digit_forms() -> void:
	var decoded := ColorMath.decode_hex(["ff0000", "#00ff00"])
	assert_int(decoded.size()).is_equal(2)
	assert_int(decoded[0][0]).is_equal(255)
	assert_int(decoded[0][1]).is_equal(0)
	assert_int(decoded[0][2]).is_equal(0)
	assert_int(decoded[1][0]).is_equal(0)
	assert_int(decoded[1][1]).is_equal(255)


func test_decode_accepts_missing_hash_and_three_digit_form() -> void:
	var decoded := ColorMath.decode_hex(["#fff", "0f0"])
	assert_int(decoded.size()).is_equal(2)
	assert_int(decoded[0][0]).is_equal(255)
	assert_int(decoded[0][1]).is_equal(255)
	assert_int(decoded[0][2]).is_equal(255)
	assert_int(decoded[1][1]).is_equal(255)


func test_decode_skips_invalid_entries() -> void:
	assert_array(ColorMath.decode_hex(["nothex", "zzzzzz", "#12"])).is_empty()
	# mixed: valid entries survive alongside invalid ones
	var decoded := ColorMath.decode_hex(["bogus", "#0000ff"])
	assert_int(decoded.size()).is_equal(1)
	assert_int(decoded[0][2]).is_equal(255)


func test_decode_round_trips_through_to_html() -> void:
	var decoded := ColorMath.decode_hex([Color("#1a2b3c").to_html(false)])
	assert_int(decoded[0][0]).is_equal(0x1a)
	assert_int(decoded[0][1]).is_equal(0x2b)
	assert_int(decoded[0][2]).is_equal(0x3c)


func test_matches_tolerance_boundaries_are_inclusive_and_per_channel() -> void:
	var target := PackedInt32Array([100, 100, 100])
	# exactly at tolerance: matches, per channel independently
	assert_bool(ColorMath.matches(100 + 16, 100, 100, target, 16)).is_true()
	assert_bool(ColorMath.matches(100, 100 - 16, 100, target, 16)).is_true()
	assert_bool(ColorMath.matches(100, 100, 100 + 16, target, 16)).is_true()
	# one step beyond on any channel: no match
	assert_bool(ColorMath.matches(100 + 17, 100, 100, target, 16)).is_false()
	assert_bool(ColorMath.matches(100, 100, 84 - 1, target, 16)).is_false()
	# tolerance 0 is exact-match only
	assert_bool(ColorMath.matches(100, 100, 100, target, 0)).is_true()
	assert_bool(ColorMath.matches(101, 100, 100, target, 0)).is_false()


func test_matches_sees_through_coverage_fraction_end_to_end() -> void:
	# 2×2 image: one fully transparent pixel (excluded from numerator and
	# denominator) and one pixel just outside tolerance.
	var img := Builders.solid_image(2, 2, Color("#00ff00"))
	img.set_pixel(0, 0, Color(0, 1, 0, 0))          # transparent: not counted
	img.set_pixel(1, 1, Color("#00dd00"))           # delta 34 on green
	# tolerance 34: all 3 counted pixels match
	assert_float(TagMatcher.coverage_fraction(img, ["00ff00"], 34)).is_equal(1.0)
	# tolerance 33: the exact pixel (2) match, the off one (1) doesn't → 2/3
	assert_float(TagMatcher.coverage_fraction(img, ["#00ff00"], 33)) \
			.is_equal(2.0 / 3.0)
	# fully transparent image: coverage 0.0
	var empty := Builders.solid_image(2, 2, Color(1, 1, 1, 0))
	assert_float(TagMatcher.coverage_fraction(empty, ["#ffffff"], 255)).is_equal(0.0)
