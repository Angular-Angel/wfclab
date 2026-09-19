class_name ConstraintIndexRulesTest extends GdUnitTestSuite


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
	return null if false else c


func _exclusion_rule(tag_a: String, tag_b: String, dist: int) -> Dictionary:
	return {"type": "exclusion", "tag_a": tag_a, "tag_b": tag_b,
			"distance": dist, "metric": "chebyshev", "enabled": true}


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
