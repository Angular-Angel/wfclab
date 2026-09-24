extends GdUnitTestSuite

const Builders = preload("res://tests/builders.gd")
const RunMonitorScript = preload("res://scripts/core/run_monitor.gd")

## Long-tail small modules: PixelHash format independence, ImageAssetData
## ids, JsonCodec edge cases, and the RunMonitor stage lifecycle (driven via
## the `_`-prefixed deferred impls to avoid frame awaits).


func test_pixel_hash_is_format_independent() -> void:
	# Same pixels in RGB8, L8, and RGBA8 hash identically — the documented
	# core claim that lets dedupe compare across sources. L8 is grayscale,
	# so the shared pixel must be gray.
	var gray := Color8(100, 100, 100)
	var rgba := Builders.solid_image(2, 2, gray)
	var rgb := Image.create_empty(2, 2, false, Image.FORMAT_RGB8)
	rgb.fill(gray)
	var l8 := Image.create_empty(2, 2, false, Image.FORMAT_L8)
	l8.fill(gray)

	assert_that(PixelHash.of(rgba)).is_equal(PixelHash.of(rgb))
	assert_that(PixelHash.of(rgba)).is_equal(PixelHash.of(l8))
	assert_that(PixelHash.of(rgba)).is_not_equal(PixelHash.of(
			Builders.solid_image(2, 2, Color8(100, 110, 121))))


func test_pixel_hash_handles_compressed_source() -> void:
	var img := Builders.flat_image(2, 1, [Color8(200, 10, 10), Color8(10, 200, 10)])

	# Lossless PNG round trip: hash must survive.
	var png := img.save_png_to_buffer()
	assert_int(png.size()).is_greater(0)
	var reloaded := Image.new()
	reloaded.load_png_from_buffer(png)
	assert_that(PixelHash.of(img)).is_equal(PixelHash.of(reloaded))

	# In-memory compression: pixels may change (lossy/driver-dependent), so
	# only assert that PixelHash.of runs on a compressed source.
	var compressed := img.duplicate()
	compressed.compress(Image.COMPRESS_BPTC)
	assert_int(typeof(PixelHash.of(compressed))).is_equal(TYPE_STRING)


func test_image_asset_from_image_derives_id_and_hash() -> void:
	var asset := ImageAssetData.from_image(
			Builders.flat_image(2, 1, [Color.RED, Color.BLUE]), "checker")
	assert_str(asset.id).is_equal("img_" + asset.hash.substr(0, 10))
	assert_str(asset.id).starts_with("img_")
	assert_int(asset.id.length()).is_equal(14)

	assert_object(ImageAssetData.load_from_path(
			"user://definitely_missing_pixels.png")).is_null()
	assert_object(ImageAssetData.from_image(null, "null-image")).is_null()
	assert_object(ImageAssetData.from_image(
			Image.create_empty(0, 0, false, Image.FORMAT_RGBA8),
			"empty-image")).is_null()


func test_json_codec_edge_cases() -> void:
	# A __v2i marker with EXTRA keys is NOT decoded as a vector.
	var not_vector: Dictionary = JsonCodec.decode({"__v2i": [1, 2], "extra": 3})
	assert_dict(not_vector).is_equal({"__v2i": [1, 2], "extra": 3})

	# Whole floats >= 2^31 stay floats; smaller whole floats become ints.
	var numbers: Dictionary = JsonCodec.decode({
		"big": 3000000000.0, "small": 12.0, "fraction": 1.5,
	})
	assert_int(typeof(numbers["big"])).is_equal(TYPE_FLOAT)
	assert_that(numbers["big"]).is_equal(3000000000.0)
	assert_int(typeof(numbers["small"])).is_equal(TYPE_INT)
	assert_int(typeof(numbers["fraction"])).is_equal(TYPE_FLOAT)

	# Nested arrays (with vectors inside) round trip.
	var source := {"grid": [[Vector2i(1, 2), 3.5], []], "v": Vector2i(-7, 9)}
	assert_dict(JsonCodec.decode(JsonCodec.encode(source))).is_equal(source)


func test_run_monitor_stage_lifecycle() -> void:
	var monitor: Variant = auto_free(RunMonitorScript.new())
	var plan := [{"key": "extract", "label": "Extract"},
			{"key": "solve", "label": "Solve"}]
	var id: int = monitor.begin_run("synthesis", "Run 1", "tile_collapse",
			{}, [], "main", plan)

	var run: Dictionary = monitor.get_run(id)
	assert_str(run["status"]).is_equal("running")
	assert_int(run["rev"]).is_equal(1)
	assert_str(run["stages"][0]["status"]).is_equal("pending")

	monitor._begin_stage(id, "extract", "Extract", -1)
	run = monitor.get_run(id)
	assert_str(run["stages"][0]["status"]).is_equal("running")
	assert_str(run["current_stage"]).is_equal("extract")
	assert_int(run["rev"]).is_equal(2)

	monitor._report_fraction(id, "extract", 0.5)
	run = monitor.get_run(id)
	assert_float(run["stages"][0]["fraction"]).is_equal(0.5)
	# progress = stage fraction / stage count.
	assert_float(run["progress"]).is_equal(0.25)

	monitor._end_stage(id, "extract", "extracted", -1)
	run = monitor.get_run(id)
	assert_str(run["stages"][0]["status"]).is_equal("done")
	assert_str(run["stages"][0]["note"]).is_equal("extracted")
	assert_float(run["progress"]).is_equal(0.5)

	monitor._begin_stage(id, "solve", "Solve", -1)
	monitor._finish_run(id, {"families": 3}, "all done")
	run = monitor.get_run(id)
	assert_str(run["status"]).is_equal("done")
	assert_float(run["progress"]).is_equal(1.0)   # running stage closed
	assert_str(run["stages"][1]["status"]).is_equal("done")
	assert_dict(run["stats"]).is_equal({"families": 3})
	assert_str(run["summary"]).is_equal("all done")

	# Failure path: running stage fails, pending stages cancel.
	var bad: int = monitor.begin_run("constraints", "Run 2", "adjacency",
			{}, [], "main", plan)
	monitor._begin_stage(bad, "extract", "Extract", -1)
	monitor._fail_run(bad, "boom")
	run = monitor.get_run(bad)
	assert_str(run["status"]).is_equal("failed")
	assert_str(run["error"]).is_equal("boom")
	assert_str(run["stages"][0]["status"]).is_equal("failed")
	assert_str(run["stages"][1]["status"]).is_equal("canceled")

	# clear_finished erases done/failed runs and keeps running ones.
	var live: int = monitor.begin_run("session", "Run 3", "tile_collapse",
			{}, [], "main", [])
	monitor.clear_finished()
	assert_dict(monitor.get_run(id)).is_empty()
	assert_dict(monitor.get_run(bad)).is_empty()
	assert_str(monitor.get_run(live)["status"]).is_equal("running")
