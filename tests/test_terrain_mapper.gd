extends GdUnitTestSuite

const Builders = preload("res://tests/builders.gd")

## TerrainMapper: prepare() filtering/clamping, apply_mapped() rewrite +
## classification, and format normalization.


func test_prepare_filters_disabled_and_inert_classes() -> void:
	var decoded := TerrainMapper.prepare([
		{"name": "on", "colors": ["ff0000"], "tolerance": 300, "flex": 99},
		{"name": "off", "colors": ["00ff00"], "enabled": false},
		{"name": "inert", "colors": ["nope", "##"], "enabled": true},
		42,
	])

	assert_int(decoded.size()).is_equal(1)
	assert_int(decoded[0]["tolerance"]).is_equal(255)   # clamped 0..255
	assert_int(decoded[0]["flex"]).is_equal(64)         # clamped 0..64
	assert_array(Array(decoded[0]["rep"])).is_equal([255, 0, 0])


func test_apply_mapped_rewrites_and_records_class_ids() -> void:
	var img := Builders.flat_image(3, 1, [
		Color8(238, 0, 0),      # within class 0 tolerance: rewritten to rep
		Color(0, 0, 0, 0),      # transparent: untouched, id -1
		Color8(0, 0, 250),      # class 1 within tolerance: rewritten to rep
	])
	var decoded := TerrainMapper.prepare([
		{"name": "warm", "colors": ["ff0000", "00ee00"], "tolerance": 18},
		{"name": "cool", "colors": ["0000ff"], "tolerance": 5},
	])

	var classes := TerrainMapper.apply_mapped(img, decoded)

	assert_int(classes[0]).is_equal(0)    # first matching class wins
	assert_int(classes[1]).is_equal(-1)   # transparent stays unclassed
	assert_int(classes[2]).is_equal(1)
	assert_that(img.get_pixel(0, 0)).is_equal(Color8(255, 0, 0))
	assert_that(img.get_pixel(1, 0)).is_equal(Color(0, 0, 0, 0))
	assert_that(img.get_pixel(2, 0)).is_equal(Color8(0, 0, 255))


func test_apply_converts_non_rgba8_input() -> void:
	var img := Image.create_empty(1, 1, false, Image.FORMAT_RGB8)
	img.fill(Color8(255, 0, 0))

	TerrainMapper.apply(img, [{"name": "red", "colors": ["ff0000"],
			"tolerance": 0}])

	assert_int(img.get_format()).is_equal(Image.FORMAT_RGBA8)
	assert_that(img.get_pixel(0, 0)).is_equal(Color8(255, 0, 0))
