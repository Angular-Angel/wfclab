extends GdUnitTestSuite

const Builders = preload("res://tests/builders.gd")

## PaletteExtractor: transparency, exact-color coalescing, deterministic
## ordering, cap truncation, and the bucket_bits = 0 off switch.


func test_transparent_pixels_are_excluded() -> void:
	var img := Builders.flat_image(2, 1, [Color8(255, 0, 0), Color(0, 0, 0, 0)])
	var palette := PaletteExtractor.palette_of_images([img] as Array[Image])

	assert_int(palette["total"]).is_equal(1)
	assert_int(palette["entries"].size()).is_equal(1)
	assert_str(palette["entries"][0]["hex"]).is_equal("ff0000")
	assert_int(palette["entries"][0]["count"]).is_equal(1)


func test_coalescing_picks_most_frequent_exact_color() -> void:
	# Dark red x3, pure red x2: same bucket at 16 levels; the representative
	# is the MOST FREQUENT exact color (always a real tile color).
	var img := Builders.flat_image(5, 1, [
		Color8(240, 0, 0), Color8(240, 0, 0), Color8(240, 0, 0),
		Color8(255, 0, 0), Color8(255, 0, 0),
	])
	var palette := PaletteExtractor.palette_of_images([img] as Array[Image], 4)

	assert_int(palette["entries"].size()).is_equal(1)
	assert_str(palette["entries"][0]["hex"]).is_equal("f00000")
	assert_int(palette["entries"][0]["count"]).is_equal(5)


func test_output_sorted_by_count_then_color_and_capped() -> void:
	var img := Builders.flat_image(6, 1, [
		Color8(255, 0, 0), Color8(255, 0, 0), Color8(255, 0, 0),
		Color8(0, 0, 255), Color8(0, 0, 255),
		Color8(0, 255, 0),
	])
	var palette := PaletteExtractor.palette_of_images([img] as Array[Image], 0, 2)

	# Sorted by count desc, then color value asc; cap keeps the top 2 while
	# total still reflects every distinct color pre-truncation.
	assert_int(palette["total"]).is_equal(3)
	assert_int(palette["entries"].size()).is_equal(2)
	assert_str(palette["entries"][0]["hex"]).is_equal("ff0000")
	assert_str(palette["entries"][1]["hex"]).is_equal("0000ff")

	# bucket_bits = 0 disables coalescing: near-identical colors stay apart.
	var near := Builders.flat_image(5, 1, [
		Color8(240, 0, 0), Color8(240, 0, 0), Color8(240, 0, 0),
		Color8(255, 0, 0), Color8(255, 0, 0),
	])
	var exact := PaletteExtractor.palette_of_images([near] as Array[Image], 0)
	assert_int(exact["entries"].size()).is_equal(2)
	assert_str(exact["entries"][0]["hex"]).is_equal("f00000")
	assert_str(exact["entries"][1]["hex"]).is_equal("ff0000")
