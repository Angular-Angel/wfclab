extends GdUnitTestSuite


func _mk_part(id: String, enabled := true) -> Part:
	var p := Part.new()
	p.id = id
	p.canonical_id = id
	p.transform_key = "identity"
	p.canonical_hash = id
	p.pixel_data = Image.create_empty(4, 4, false, Image.FORMAT_RGBA8)
	p.size = Vector2i(4, 4)
	p.enabled = enabled
	p.weight = 1.0
	return p


func _mk_adj(a: String, b: String, offset: Vector2i) -> Constraint:
	var c := Constraint.new()
	c.type = &"adjacency"
	c.participants = [
		{"part_id": a, "role": "anchor"},
		{"part_id": b, "role": "neighbor"},
	]
	c.params = {"offset": offset}
	c.weight = 1.0
	c.evidence = [{"image_id": "test", "positions": [Vector2i.ZERO, offset]}]
	return c


func _exclusion_rule(tag_a: String, tag_b: String, dist: int,
		metric := "chebyshev") -> Dictionary:
	return {"type": "exclusion", "tag_a": tag_a, "tag_b": tag_b,
			"distance": dist, "metric": metric, "enabled": true}


func _build(tags: Dictionary, rules: Array, disable := []) -> ConstraintIndex:
	var parts: Array[Part] = [
		_mk_part("p_forest"), _mk_part("p_lava"), _mk_part("p_plain")]
	for id: String in disable:
		for p: Part in parts:
			if p.id == id:
				p.enabled = false
	var constraints: Array[Constraint] = [_mk_adj("p_forest", "p_plain", Vector2i(1, 0))]
	return ConstraintIndex.build(parts, constraints, tags, rules)


func test_rule_deltas_not_in_offsets() -> void:
	var idx := _build({"p_forest": ["forest"], "p_lava": ["lava"]},
			[_exclusion_rule("forest", "lava", 2)])
	idx.prepare([Vector2i(1, 0)], Vector2i(1, 1))
	assert_int(idx.get_offsets().size()).is_equal(1)          # evidence only
	assert_bool(idx.delta_list.has(Vector2i(2, 0))).is_true() # rule delta exists
	assert_bool(idx.delta_list.has(Vector2i(0, 2))).is_true()


func test_exclusion_prunes_both_directions() -> void:
	var idx := _build({"p_forest": ["forest"], "p_lava": ["lava"]},
			[_exclusion_rule("forest", "lava", 2)])
	idx.prepare([Vector2i(1, 0)], Vector2i(1, 1))
	var fi := idx.int_of("p_forest")
	var li := idx.int_of("p_lava")
	var di = idx._pixel_to_di[Vector2i(1, 0)]
	assert_bool(TileCollapse.mask_has(idx.nb_mask[fi][di], li)).is_false()
	var di_rev = idx._pixel_to_di[Vector2i(-1, 0)]
	assert_bool(TileCollapse.mask_has(idx.nb_mask[li][di_rev], fi)).is_false()


func test_exclusion_overrides_unknown_free() -> void:
	var idx := _build({"p_forest": ["forest"], "p_lava": ["lava"]},
			[_exclusion_rule("forest", "lava", 2)])
	idx.prepare([], Vector2i(1, 1))   # no evidence deltas at all
	var fi := idx.int_of("p_forest")
	var li := idx.int_of("p_lava")
	var pi := idx.int_of("p_plain")
	var d2 = idx._pixel_to_di[Vector2i(2, 0)]
	assert_bool(idx.nb_empty[fi][d2]).is_false()   # authored: never "free"
	var mf: PackedInt64Array = idx.nb_mask[fi][d2]
	assert_bool(TileCollapse.mask_has(mf, li)).is_false()
	assert_bool(TileCollapse.mask_has(mf, pi)).is_true()
	var mp: PackedInt64Array = idx.nb_mask[pi][d2]
	assert_bool(TileCollapse.mask_has(mp, li)).is_true()   # untagged: unaffected


func test_tags_on_disabled_part_are_inert() -> void:
	var idx := _build({"p_forest": ["forest"]}, [], ["p_forest"])
	idx.prepare([Vector2i(1, 0)], Vector2i(1, 1))
	assert_int(idx.tag_mask("forest").size()).is_equal(0)


func test_offset_metrics_manhattan_and_euclidean() -> void:
	# At distance 2 both metrics coincide; at distance 3 the diamond loses
	# the four (±2, ±2) diagonals the disc still contains. delta_list holds
	# the evidence delta alongside the rule deltas — account for it.
	var tags := {"p_forest": ["forest"], "p_lava": ["lava"]}
	var manhattan := _build(tags, [_exclusion_rule("forest", "lava", 3, "manhattan")])
	manhattan.prepare([Vector2i(1, 0)], Vector2i(1, 1))
	var euclidean := _build(tags, [_exclusion_rule("forest", "lava", 3, "euclidean")])
	euclidean.prepare([Vector2i(1, 0)], Vector2i(1, 1))

	for diagonal: Vector2i in [Vector2i(2, 2), Vector2i(-2, -2)]:
		assert_bool(manhattan.delta_list.has(diagonal)).is_false()
		assert_bool(euclidean.delta_list.has(diagonal)).is_true()
	for arm: Vector2i in [Vector2i(0, 3), Vector2i(3, 0)]:
		assert_bool(manhattan.delta_list.has(arm)).is_true()
		assert_bool(euclidean.delta_list.has(arm)).is_true()
	assert_int(euclidean.delta_list.size()).is_equal(
			manhattan.delta_list.size() + 4)


func test_duplicate_pair_constraints_accumulate_weight() -> void:
	var idx := ConstraintIndex.build(
			[_mk_part("p_forest"), _mk_part("p_lava")], [
				_mk_adj("p_forest", "p_lava", Vector2i(1, 0)),
				_mk_adj("p_forest", "p_lava", Vector2i(1, 0)),
			], {})
	assert_that(idx.get_neighbors("p_forest", Vector2i(1, 0))).is_equal(
			{"p_lava": 2.0})


func test_family_layer_groups_identical_parts() -> void:
	# Parts with identical neighbor behavior merge into one family; rule
	# deltas and families are built in prepare(), not build().
	var idx := ConstraintIndex.build(
			[_mk_part("p_forest"), _mk_part("p_lava")], [], {}, [])
	idx.prepare([], Vector2i(1, 1))

	assert_int(idx.family_count).is_equal(1)
	assert_float(idx.family_weights[0]).is_equal(2.0)
	assert_int(idx.family_of_part_id("p_forest")).is_equal(0)
	assert_int(idx.family_of_part_id("p_lava")).is_equal(0)
	assert_int(idx.largest_family_size).is_equal(2)


func test_unknown_rule_types_and_tags_warn_but_do_not_throw() -> void:
	var rules := [
		{"type": "bogus", "tag_a": "forest", "tag_b": "lava",
			"distance": 1, "metric": "chebyshev", "enabled": true},
		_exclusion_rule("forest", "missing_tag", 2),
	]
	var idx := _build({"p_forest": ["forest"], "p_lava": ["lava"]}, rules)
	idx.prepare([Vector2i(1, 0)], Vector2i(1, 1))

	# Index still builds; no rule deltas were added.
	assert_int(idx.get_offsets().size()).is_equal(1)
	assert_array(idx.delta_list).is_equal([Vector2i(1, 0)] as Array[Vector2i])
