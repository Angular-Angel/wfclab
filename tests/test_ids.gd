extends GdUnitTestSuite
## Golden-string pins for every id format routed through Ids — the
## guarantee behind the plan's no-save-format-change promise. If one of
## these strings changes, existing .wfcproj files and stored ids break.

const IdsScript := preload("res://scripts/core/util/ids.gd")


func test_part_id_golden() -> void:
	assert_str(IdsScript.part("0123456789abcdef")).is_equal("p_0123456789ab")
	# hashes shorter than the slice length pass through whole
	assert_str(IdsScript.part("abc")).is_equal("p_abc")


func test_image_id_golden() -> void:
	assert_str(IdsScript.image("0123456789abcdef")).is_equal("img_0123456789")


func test_constraint_id_golden() -> void:
	assert_str(IdsScript.constraint("p_aabbccddee00", "p_112233445566",
			Vector2i(3, -2))).is_equal("c_aabbcc_112233_3_-2")
	# the PixelOverlap overlap-family uses the "o_" prefix, same layout
	assert_str(IdsScript.constraint("p_aabbccddee00", "p_112233445566",
			Vector2i(0, 1), "o_")).is_equal("o_aabbcc_112233_0_1")


func test_short_pins_the_prefix_strip_discipline() -> void:
	assert_str(IdsScript.short("p_aabbccddee")).is_equal("aabbcc")
	# Known residual (pre-existing, harmless): rebuild_id() on a to-outside
	# constraint participants[1] == "~outside" shorts to "utside" instead of
	# the extractor's literal "out". It stays a unique dictionary key; the
	# pin documents the behavior rather than blessing a format change.
	assert_str(IdsScript.short("~outside")).is_equal("utside")


func test_to_outside_extractor_format_golden() -> void:
	# AdjacencyExtractor's to-outside variant is a per-site literal routed
	# through Ids.short; pinned here as part of the format promise.
	assert_str("c_%s_out_%d_%d" % [IdsScript.short("p_aabbccddee00"), 3, -2]) \
			.is_equal("c_aabbcc_out_3_-2")


func test_by_id_sorts_deterministically() -> void:
	var arr := []
	for id in ["p_c", "p_a", "p_b"]:
		var p := Part.new()
		p.id = id
		arr.append(p)
	IdsScript.by_id(arr)
	assert_str((arr[0] as Part).id).is_equal("p_a")
	assert_str((arr[1] as Part).id).is_equal("p_b")
	assert_str((arr[2] as Part).id).is_equal("p_c")
