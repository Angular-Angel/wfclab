extends GdUnitTestSuite

const Builders = preload("res://tests/builders.gd")

## End-to-end smoke: decomposition -> extraction -> index -> synthesis over a
## tiny authored 4x1 image with a repeating 3-color pattern. The cheapest
## regression net for "the whole app still generates": a batch run and an
## interactive session loop with an authored exclusion rule both drive the
## same public pipeline.
##
## The pattern is deliberately NON-interchangeable (A,B,C,A -> three tiles
## with distinct neighbor behavior, so no family merging) so the dark~dark
## exclusion rule stays satisfiable and the completed grid can be scanned.


func _rng() -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260924
	return rng


func _is_dark(tags: Dictionary, part_id: String) -> bool:
	return (tags[part_id] as Array).has("dark")


func test_end_to_end_checkerboard_pipeline() -> void:
	var noop := func(_progress: float) -> void: pass
	var red := Color8(220, 30, 30)
	var green := Color8(30, 220, 30)
	var blue := Color8(30, 30, 220)
	var asset := Builders.make_asset("img_pattern", Builders.flat_image(4, 1,
			[red, green, blue, red]))

	# --- decomposition: the repeating pattern dedupes to 3 tiles ---
	var decomp: Dictionary = GridTiles.new().decompose([asset], {
		"tile_size": Vector2i(1, 1), "stride": Vector2i(1, 1),
		"edge_handling": GridTiles.EdgeHandling.CLAMP, "dedupe": true,
	}, noop)
	var parts: Array[Part] = decomp["parts"]
	assert_int(parts.size()).is_equal(3)
	var total_occurrences := 0
	for part: Part in parts:
		total_occurrences += part.occurrence_count()
	assert_int(total_occurrences).is_equal(4)

	# --- extraction: one horizontal pair per adjacent (cyclic) step ---
	var constraints := AdjacencyExtractor.new().extract(parts, [], {
		"edge_evidence": AdjacencyExtractor.EdgeEvidence.IGNORE,
	}, noop)
	assert_int(constraints.size()).is_equal(3)
	for constraint: Constraint in constraints:
		assert_that(constraint.params["offset"]).is_equal(Vector2i(1, 0))

	var tags := {}
	for part: Part in parts:
		tags[part.id] = ["dark" if part.pixel_data.get_pixel(0, 0)
				.is_equal_approx(red) else "light"]

	# --- batch synthesis completes; render size matches geometry ---
	var index := ConstraintIndex.build(parts, constraints, tags, [])
	var params := {"output_width": 3, "output_height": 3,
			"contradiction_strategy": 1, "max_recovery_attempts": 10}
	var batch := TileCollapse.new().synthesize(index, params, _rng(), noop)
	assert_bool(batch.is_empty()).is_false()
	assert_int(batch["stats"]["families"]).is_equal(3)
	var probe: Variant = TileCollapse.new().create_session(index, params, _rng())
	assert_that((batch["image"] as Image).get_size()).is_equal(
			probe.get_render_size())

	# --- one exclusion rule: dark tiles never touch (chebyshev 1) ---
	var rules := [{"type": "exclusion", "tag_a": "dark", "tag_b": "dark",
			"distance": 1, "metric": "chebyshev", "enabled": true}]
	var ruled := ConstraintIndex.build(parts, constraints, tags, rules)
	var session: Variant = TileCollapse.new().create_session(ruled, params, _rng())
	while not session.is_finished():
		session.step()
	assert_that(session.phase).is_equal(SynthesisSession.Phase.DONE)

	var assigned: Array[String] = session.assigned
	for y in 3:
		for x in 3:
			var pid: String = assigned[y * 3 + x]
			if x < 2:
				assert_bool(_is_dark(tags, pid)
						and _is_dark(tags, assigned[y * 3 + x + 1])).is_false()
			if y < 2:
				assert_bool(_is_dark(tags, pid)
						and _is_dark(tags, assigned[(y + 1) * 3 + x])).is_false()
