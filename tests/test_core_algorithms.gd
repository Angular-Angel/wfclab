extends GdUnitTestSuite


func _part(id_hash: String, color: Color, position := Vector2i.ZERO,
		image_id := "source") -> Part:
	var image := Image.create_empty(1, 1, false, Image.FORMAT_RGBA8)
	image.set_pixel(0, 0, color)
	var part := Part.new()
	part.setup(image, id_hash, image_id, position)
	part.weight = 1.0
	return part


func _constraint(a: String, b: String, offset: Vector2i, weight := 1.0,
		symmetric := false) -> Constraint:
	var constraint := Constraint.new()
	constraint.participants = [
		{"part_id": a, "role": "a"},
		{"part_id": b, "role": "b"},
	]
	constraint.params = {"offset": offset, "symmetric": symmetric}
	constraint.weight = weight
	constraint.rebuild_id()
	return constraint


func _constraint_signatures(constraints: Array[Constraint]) -> Array[String]:
	var signatures: Array[String] = []
	for constraint: Constraint in constraints:
		signatures.append("%s:%d" % [constraint.id, constraint.weight])
	signatures.sort()
	return signatures


func test_constraint_rebuild_id_weight_and_part_ids() -> void:
	var constraint := _constraint("p_abcdef123456", "p_987654321000", Vector2i(3, -2), 4.0)

	assert_that(constraint.id).is_equal("c_abcdef_987654_3_-2")
	assert_that(constraint.part_ids()).is_equal(["p_abcdef123456", "p_987654321000"])
	assert_that(constraint.get_effective_weight()).is_equal(4.0)
	constraint.weight_override = 2.5
	assert_that(constraint.get_effective_weight()).is_equal(2.5)


func test_constraint_index_builds_reverse_and_symmetric_neighbors() -> void:
	var a := _part("aaaaaaaaaaaa", Color.RED)
	var b := _part("bbbbbbbbbbbb", Color.BLUE)
	var index := ConstraintIndex.build([a, b], [
		_constraint(a.id, b.id, Vector2i(2, 0), 2.0),
		_constraint(a.id, b.id, Vector2i(0, 3), 1.0, true),
	])

	assert_that(index.get_neighbors(a.id, Vector2i(2, 0))).is_equal({b.id: 2.0})
	assert_that(index.get_neighbors(b.id, Vector2i(-2, 0))).is_equal({a.id: 2.0})
	assert_that(index.get_neighbors(a.id, Vector2i(0, 3))).is_equal({b.id: 1.0})
	assert_that(index.get_neighbors(b.id, Vector2i(0, 3))).is_equal({a.id: 1.0})
	assert_that(index.get_neighbors(a.id, Vector2i(0, -3))).is_equal({b.id: 1.0})
	assert_that(index.get_offsets()).contains_exactly([
		Vector2i(2, 0), Vector2i(-2, 0), Vector2i(0, 3), Vector2i(0, -3),
	])
	assert_that(index.get_part_ids()).contains_exactly([a.id, b.id])


func test_constraint_index_ignores_disabled_data_and_keeps_outside_one_way() -> void:
	var enabled := _part("aaaaaaaaaaaa", Color.RED)
	var disabled := _part("bbbbbbbbbbbb", Color.BLUE)
	disabled.enabled = false
	var ignored := _constraint(enabled.id, disabled.id, Vector2i.RIGHT)
	var disabled_constraint := _constraint(enabled.id, enabled.id, Vector2i.DOWN)
	disabled_constraint.enabled = false
	var outside := _constraint(enabled.id, ConstraintIndex.OUTSIDE, Vector2i.LEFT, 3.0)
	var index := ConstraintIndex.build([enabled, disabled], [ignored, disabled_constraint, outside])

	assert_that(index.tile_size).is_equal(Vector2i.ONE)
	assert_that(index.get_part_ids()).contains_exactly([enabled.id])
	assert_that(index.get_neighbors(enabled.id, Vector2i.LEFT)).is_equal({ConstraintIndex.OUTSIDE: 3.0})
	assert_that(index.get_neighbors(ConstraintIndex.OUTSIDE, Vector2i.RIGHT)).is_empty()
	assert_bool(index.has_outside()).is_true()


func test_json_codec_round_trips_nested_vectors_and_numeric_types() -> void:
	var source := {
		"origin": Vector2i(-12, 987654),
		"nested": [Vector2i(4, -7), {"whole": 8, "fraction": 2.25}],
	}
	var decoded: Dictionary = JsonCodec.decode(JsonCodec.encode(source))

	assert_that(decoded).is_equal(source)
	var from_json: Dictionary = JsonCodec.decode({"whole": 12.0, "fraction": 12.5})
	assert_that(typeof(from_json["whole"])).is_equal(TYPE_INT)
	assert_that(from_json["whole"]).is_equal(12)
	assert_that(typeof(from_json["fraction"])).is_equal(TYPE_FLOAT)
	assert_that(from_json["fraction"]).is_equal(12.5)


func test_pixel_hash_distinguishes_pixels_and_quantizes_with_tolerance() -> void:
	var first := Image.create_empty(1, 1, false, Image.FORMAT_RGBA8)
	var second := Image.create_empty(1, 1, false, Image.FORMAT_RGBA8)
	var nearby := Image.create_empty(1, 1, false, Image.FORMAT_RGBA8)
	first.set_pixel(0, 0, Color8(100, 100, 100, 255))
	second.set_pixel(0, 0, Color8(101, 100, 100, 255))
	nearby.set_pixel(0, 0, Color8(102, 100, 100, 255))

	assert_that(PixelHash.of(first)).is_equal(PixelHash.of(first.duplicate()))
	assert_that(PixelHash.of(first)).is_not_equal(PixelHash.of(nearby))
	assert_that(PixelHash.of(first, 1)).is_equal(PixelHash.of(second, 1))


func test_part_setup_and_clone_keep_pixels_shared_but_mutable_state_independent() -> void:
	var part := _part("1234567890abcdef", Color.GREEN, Vector2i(4, 8), "image-a")
	part.weight = 3.0
	var clone := part.clone()
	clone.occurrences.append({"image_id": "image-b", "position": Vector2i.ZERO})
	clone.transform_sources[0]["transform_key"] = "rot90"

	assert_that(part.id).is_equal("p_1234567890ab")
	assert_that(part.canonical_id).is_equal(part.id)
	assert_that(part.occurrence_count()).is_equal(1)
	assert_that(clone.occurrence_count()).is_equal(2)
	assert_that(clone.pixel_data).is_same(part.pixel_data)
	assert_that(part.transform_sources[0]["transform_key"]).is_equal("identity")


func test_adjacency_extracts_pairs_deterministically_and_honors_custom_step() -> void:
	var a := _part("aaaaaaaaaaaa", Color.RED, Vector2i(0, 0))
	var b := _part("bbbbbbbbbbbb", Color.BLUE, Vector2i(2, 0))
	var extractor := AdjacencyExtractor.new()
	var params := {"directional": true, "step_mode": AdjacencyExtractor.StepMode.CUSTOM,
		"custom_step": Vector2i(2, 1), "edge_evidence": AdjacencyExtractor.EdgeEvidence.IGNORE}
	var forward := extractor.extract([a, b], [], params, func(_progress: float) -> void: pass)
	var reverse := extractor.extract([b, a], [], params, func(_progress: float) -> void: pass)

	assert_that(_constraint_signatures(forward)).is_equal(_constraint_signatures(reverse))
	assert_that(forward.size()).is_equal(1)
	assert_that(forward[0].participants[0]["part_id"]).is_equal(a.id)
	assert_that(forward[0].participants[1]["part_id"]).is_equal(b.id)
	assert_that(forward[0].params["offset"]).is_equal(Vector2i(2, 0))


func test_adjacency_border_evidence_emits_virtual_outside_edges() -> void:
	var part := _part("aaaaaaaaaaaa", Color.RED)
	var constraints := AdjacencyExtractor.new().extract([part], [], {
		"edge_evidence": AdjacencyExtractor.EdgeEvidence.BORDER,
	}, func(_progress: float) -> void: pass)
	var offsets: Array[Vector2i] = []
	for constraint: Constraint in constraints:
		assert_that(constraint.participants[1]["part_id"]).is_equal(ConstraintIndex.OUTSIDE)
		offsets.append(constraint.params["offset"])

	assert_that(offsets).contains_exactly([
		Vector2i.LEFT, Vector2i.UP, Vector2i.DOWN, Vector2i.RIGHT,
	])


func test_tile_collapse_derives_geometry_and_matches_stepped_synthesis() -> void:
	var part := _part("aaaaaaaaaaaa", Color.RED)
	part.size = Vector2i(4, 6)
	var index := ConstraintIndex.build([part], [])
	var geometry_index := ConstraintIndex.build([part], [
		_constraint(part.id, part.id, Vector2i(2, 0)),
		_constraint(part.id, part.id, Vector2i(0, 3)),
		_constraint(part.id, part.id, Vector2i(5, 5)),
	])
	var step := TileCollapse._derive_step(geometry_index)
	assert_that(step).is_equal(Vector2i(2, 3))
	assert_that(TileCollapse._derive_deltas(geometry_index, step)).contains_exactly([
		Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
	])

	var params := {"output_width": 3, "output_height": 2, "contradiction_strategy": 0}
	var batch_rng := RandomNumberGenerator.new()
	batch_rng.seed = 12345
	var batch := TileCollapse.new().synthesize(index, params, batch_rng, func(_progress: float) -> void: pass)
	var step_rng := RandomNumberGenerator.new()
	step_rng.seed = 12345
	var session := TileCollapse.new().create_session(index, params, step_rng)
	while not session.is_finished():
		session.step()
	var stepped := session.get_result()

	assert_that(PixelHash.of(batch["image"])).is_equal(PixelHash.of(stepped["image"]))
	assert_that(batch["stats"]["output_slots"]).is_equal(Vector2i(3, 2))
