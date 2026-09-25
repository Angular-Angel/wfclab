extends GdUnitTestSuite

const Builders = preload("res://tests/builders.gd")

## TileCollapse session behavior: recovery strategies, border evidence,
## interactive pin/clear editing, and geometry — driven through the public
## create_session()/step()/try_assign()/try_clear() API.
##
## Engine semantics the fixtures rely on (verified against tile_collapse.gd /
## constraint_index.gd):
##   - Evidence arcs are permissions, never obligations; assigned neighbors
##     are skipped by _revise.
##   - The border pass runs at construction (_reset_attempt queues every slot
##     once the index has OUTSIDE evidence); a border wipe alone can never
##     empty a domain (the family that activates a delta's border is itself
##     border-ok there).
##   - A construction failure reports contradictions == 0 and restarts == 0;
##     those counters only track step-time recovery.
##   - The 1e6:1 weight ratio bounds first-pick flake probability at <= 1e-6
##     with the seed pinned.

const SEED := 20260924


func _rng() -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	return rng


func _session(index: ConstraintIndex, params: Dictionary) -> Variant:
	return TileCollapse.new().create_session(index, params, _rng())


func _impossible_index() -> ConstraintIndex:
	## Parts A (weight 1e6, tag "ta") and B (tag "tb"); evidence A->B at
	## (1, 0); authored exclusion ta~tb at chebyshev distance 1. The rule
	## empties A's evidence arc at (1, 0) while forcing nb_empty = false, so
	## the wipe cannot be neutralized by unknown_free. Setup leaves both
	## domains {A, B} (B's empty arc is unconstrained under unknown_free);
	## the first observation weighted-picks dominant A at slot 0 and the
	## rule-emptied arc wipes slot 1 to empty at step time.
	var a := Builders.make_part("aaaaaaaaaaaa", Color.RED)
	a.weight = 1000000.0
	var b := Builders.make_part("bbbbbbbbbbbb", Color.BLUE)
	var constraints: Array[Constraint] = [
		Builders.make_constraint(a.id, b.id, Vector2i(1, 0))]
	var tags := {a.id: ["ta"], b.id: ["tb"]}
	var rules := [{"type": "exclusion", "tag_a": "ta", "tag_b": "tb",
			"distance": 1, "metric": "chebyshev", "enabled": true}]
	return ConstraintIndex.build([a, b], constraints, tags, rules)


func test_mask_helpers_round_trip() -> void:
	# Multiword masks: 2 words, bits in word 1. Only mask_full/mask_empty
	# take nwords; the rest read the mask's own length.
	var full := BitMask.full(2, 70)
	assert_int(BitMask.count(full)).is_equal(70)
	assert_bool(BitMask.is_empty(full)).is_false()

	var m := BitMask.empty(2)
	assert_bool(BitMask.is_empty(m)).is_true()
	assert_int(BitMask.count(m)).is_equal(0)

	BitMask.set_bit(m, 64)
	BitMask.set_bit(m, 13)
	assert_int(BitMask.count(m)).is_equal(2)
	assert_bool(BitMask.has(m, 64)).is_true()
	assert_bool(BitMask.has(m, 13)).is_true()
	assert_bool(BitMask.has(m, 12)).is_false()
	assert_int(BitMask.first(m)).is_equal(13)
	assert_array(BitMask.iter(m)).is_equal([13, 64] as Array[int])
	assert_int(BitMask.kth(m, 0)).is_equal(13)
	assert_int(BitMask.kth(m, 1)).is_equal(64)
	assert_int(BitMask.kth(m, 2)).is_equal(-1)
	assert_int(BitMask.ctz(64)).is_equal(6)

	BitMask.clear_bit(m, 64)
	assert_bool(BitMask.has(m, 64)).is_false()
	assert_int(BitMask.first(m)).is_equal(13)

	BitMask.only(m, 64)
	assert_array(BitMask.iter(m)).is_equal([64] as Array[int])
	assert_bool(BitMask.is_empty(m)).is_false()


func test_stop_strategy_fails_fast_on_impossible_index() -> void:
	var session: Variant = _session(_impossible_index(), {
		"output_width": 2, "output_height": 1, "contradiction_strategy": 0,
	})
	assert_bool(session.is_finished()).is_false()   # setup leaves {A, B} live

	session.step()

	assert_bool(session.is_finished()).is_true()
	assert_that(session.phase).is_equal(SynthesisSession.Phase.FAILED)
	assert_that(session.get_result()).is_equal({})
	assert_int(session.contradictions).is_equal(1)
	assert_int(session.restarts).is_equal(0)


func test_restart_strategy_respects_recovery_budget() -> void:
	var session: Variant = _session(_impossible_index(), {
		"output_width": 2, "output_height": 1, "contradiction_strategy": 1,
		"max_recovery_attempts": 3,
	})
	while not session.is_finished():
		session.step()

	assert_that(session.phase).is_equal(SynthesisSession.Phase.FAILED)
	assert_int(session.restarts).is_equal(3)
	assert_int(session.contradictions).is_equal(4)
	assert_that(session.get_result()).is_equal({})


func test_backtracking_strategy_recovers_when_a_later_pick_exists() -> void:
	var session: Variant = _session(_impossible_index(), {
		"output_width": 2, "output_height": 1, "contradiction_strategy": 2,
	})
	while not session.is_finished():
		session.step()

	assert_that(session.phase).is_equal(SynthesisSession.Phase.DONE)
	assert_int(session.backtracks).is_equal(1)
	var result: Dictionary = session.get_result()
	assert_bool(result.is_empty()).is_false()
	# The dominant first pick dead-ended; [B, B] is the only completion
	# (A is excluded within chebyshev distance 1 of B).
	var b_id := "p_bbbbbbbbbbbb"
	assert_that(session.get_slot_assignment(0)).is_equal(b_id)
	assert_that(session.get_slot_assignment(1)).is_equal(b_id)
	assert_int(result["stats"]["backtracks"]).is_equal(1)


func test_outside_evidence_forbids_interior_border_violations() -> void:
	# DONE side: P with OUTSIDE evidence only at LEFT, Q unconstrained,
	# 2-wide grid: column 0 may only take P; the right edge stays unenforced
	# (no family has OUTSIDE evidence on that delta).
	var p := Builders.make_part("aaaaaaaaaaaa", Color.RED)
	var q := Builders.make_part("bbbbbbbbbbbb", Color.BLUE)
	var done_index := ConstraintIndex.build([p, q], [
		Builders.make_constraint(p.id, ConstraintIndex.OUTSIDE, Vector2i.LEFT)])
	var done: Variant = _session(done_index, {"output_width": 2, "output_height": 1})
	while not done.is_finished():
		done.step()

	assert_that(done.phase).is_equal(SynthesisSession.Phase.DONE)
	assert_that(done.get_slot_assignment(0)).is_equal(p.id)

	# FAILED side: P with OUTSIDE evidence at RIGHT plus evidence P->Q at
	# (1, 0) and unknown_free = false: the arc prunes the edge slot to {Q},
	# the border pass wipes Q (not border-ok there) -> empty at setup ->
	# construction FAILED with contradictions == 0, restarts == 0.
	var fail_index := ConstraintIndex.build([p, q], [
		Builders.make_constraint(p.id, ConstraintIndex.OUTSIDE, Vector2i.RIGHT),
		Builders.make_constraint(p.id, q.id, Vector2i(1, 0))])
	var failed: Variant = _session(fail_index, {
		"output_width": 2, "output_height": 1, "unknown_free": false,
	})

	assert_that(failed.phase).is_equal(SynthesisSession.Phase.FAILED)
	assert_int(failed.contradictions).is_equal(0)
	assert_int(failed.restarts).is_equal(0)
	assert_that(failed.get_result()).is_equal({})


func test_try_assign_pin_and_rejection_rollback() -> void:
	var a := Builders.make_part("aaaaaaaaaaaa", Color.RED)
	var b := Builders.make_part("bbbbbbbbbbbb", Color.BLUE)
	var index := ConstraintIndex.build([a, b], [
		Builders.make_constraint(a.id, b.id, Vector2i(1, 0))])
	var session: Variant = _session(index, {"output_width": 2, "output_height": 1})

	assert_bool(session.try_assign(0, a.id)).is_true()
	assert_that(session.get_slot_assignment(0)).is_equal(a.id)
	assert_float(session.get_progress()).is_equal(0.5)
	assert_str(session.last_rejection).is_empty()

	# The arc pins slot 1 to {B}; assigning A there must be rejected and
	# leave domain, assignment, and progress untouched.
	var domain_before: Dictionary = session.get_slot_domain(1)
	assert_that(domain_before).is_equal({b.id: true})

	assert_bool(session.try_assign(1, a.id)).is_false()
	assert_str(session.last_rejection).is_not_empty()
	assert_that(session.get_slot_domain(1)).is_equal(domain_before)
	assert_that(session.get_slot_assignment(1)).is_equal("")
	assert_float(session.get_progress()).is_equal(0.5)


func test_try_clear_unpins_and_rebuilds_domain() -> void:
	var a := Builders.make_part("aaaaaaaaaaaa", Color.RED)
	var b := Builders.make_part("bbbbbbbbbbbb", Color.BLUE)
	var index := ConstraintIndex.build([a, b], [
		Builders.make_constraint(a.id, b.id, Vector2i(1, 0))])
	var session: Variant = _session(index, {"output_width": 2, "output_height": 1})

	assert_bool(session.try_assign(0, a.id)).is_true()
	assert_bool(session.try_clear(0)).is_true()

	var domain: Dictionary = session.get_slot_domain(0)
	assert_bool(domain.has(a.id)).is_true()
	assert_bool(domain.has(b.id)).is_true()
	assert_that(session.get_slot_assignment(0)).is_equal("")

	assert_bool(session.try_assign(0, a.id)).is_true()
	assert_that(session.get_slot_assignment(0)).is_equal(a.id)


func test_describe_pin_reports_reasons() -> void:
	var a := Builders.make_part("aaaaaaaaaaaa", Color.RED)
	var b := Builders.make_part("bbbbbbbbbbbb", Color.BLUE)
	var index := ConstraintIndex.build([a, b], [
		Builders.make_constraint(a.id, b.id, Vector2i(1, 0))])
	var session: Variant = _session(index, {"output_width": 2, "output_height": 1})

	assert_str(session.describe_pin(-1, a.id)).is_equal("slot out of range")
	assert_str(session.describe_pin(0, "p_missing0")).is_equal(
			"unknown or disabled part")

	assert_bool(session.try_assign(0, a.id)).is_true()
	assert_str(session.describe_pin(1, a.id)).is_equal(
			"not in the slot's current domain")


func test_unknown_free_false_constrains_unobserved_offsets() -> void:
	# Only A->B at (1, 0) is observed; with unknown_free = false no unobserved
	# pair can appear, so the forcing grid completes as exactly [A, B]
	# (dominant weight keeps the first pick at A with <= 1e-6 flake).
	var a := Builders.make_part("aaaaaaaaaaaa", Color.RED)
	a.weight = 1000000.0
	var b := Builders.make_part("bbbbbbbbbbbb", Color.BLUE)
	var index := ConstraintIndex.build([a, b], [
		Builders.make_constraint(a.id, b.id, Vector2i(1, 0))])
	var session: Variant = _session(index, {
		"output_width": 2, "output_height": 1,
		"unknown_free": false, "contradiction_strategy": 0,
	})
	while not session.is_finished():
		session.step()

	assert_that(session.phase).is_equal(SynthesisSession.Phase.DONE)
	assert_that(session.get_slot_assignment(0)).is_equal(a.id)
	assert_that(session.get_slot_assignment(1)).is_equal(b.id)


func test_render_geometry_with_overlap_step() -> void:
	# 3x2 tiles at slot step (2, 1) render into ((2-1)*2+3, (1-1)*1+2).
	var p := Builders.make_part_from_image(
			Builders.solid_image(3, 2, Color.RED), "aaaaaaaaaaaa")
	var index := ConstraintIndex.build([p], [
		Builders.make_constraint(p.id, p.id, Vector2i(2, 0)),
		Builders.make_constraint(p.id, p.id, Vector2i(0, 1))])
	var session: Variant = _session(index, {"output_width": 2, "output_height": 1})
	while not session.is_finished():
		session.step()

	assert_that(session.phase).is_equal(SynthesisSession.Phase.DONE)
	assert_that(session.get_render_size()).is_equal(Vector2i(5, 2))
	assert_that(session.slot_rect(0)).is_equal(
			Rect2i(Vector2i.ZERO, Vector2i(3, 2)))
	assert_that(session.slot_rect(1)).is_equal(
			Rect2i(Vector2i(2, 0), Vector2i(3, 2)))

	var result: Dictionary = session.get_result()
	var image: Image = result["image"]
	assert_that(image.get_size()).is_equal(Vector2i(5, 2))
	assert_that(image.get_pixel(2, 0)).is_equal(Color.RED)   # slot 1 blit


func test_same_seed_reproduces_identical_output() -> void:
	# Batch twice plus stepped once over a CONSTRAINED index (alternating
	# A/B chain, so propagation actually runs) — all three outputs equal.
	var a := Builders.make_part("aaaaaaaaaaaa", Color.RED)
	var b := Builders.make_part("bbbbbbbbbbbb", Color.BLUE)
	var index := ConstraintIndex.build([a, b], [
		Builders.make_constraint(a.id, b.id, Vector2i(1, 0)),
		Builders.make_constraint(b.id, a.id, Vector2i(1, 0))])
	var params := {"output_width": 3, "output_height": 2}

	var noop := func(_progress: float) -> void: pass
	var first := TileCollapse.new().synthesize(index, params, _rng(), noop)
	var second := TileCollapse.new().synthesize(index, params, _rng(), noop)

	var stepped_session: Variant = TileCollapse.new().create_session(
			index, params, _rng())
	while not stepped_session.is_finished():
		stepped_session.step()
	var stepped: Dictionary = stepped_session.get_result()

	assert_bool(first.is_empty()).is_false()
	assert_that(first["stats"]["families"] >= 1).is_true()
	assert_that(PixelHash.of(first["image"])).is_equal(PixelHash.of(second["image"]))
	assert_that(PixelHash.of(first["image"])).is_equal(PixelHash.of(stepped["image"]))
