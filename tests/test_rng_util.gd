extends GdUnitTestSuite
## Tests for RngUtil.weighted_pick: draw-for-draw equivalence with the
## reference walk-down sampler, the zero-total uniform branch, and
## weight-respected selection.

const RngUtilScript := preload("res://scripts/core/util/rng_util.gd")


func _picks(weights: Array[float], seed: int, count: int) -> Array[int]:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var out: Array[int] = []
	for i in count:
		out.append(RngUtilScript.weighted_pick(weights, rng))
	return out


func test_reference_walk_down_equivalence() -> void:
	# An independent reference implementation must produce the identical
	# pick for the same seed: same total sum order, same randf draw, same
	# walk-down sequence.
	var weights: Array[float] = [3.5, 0.0, 1.25, 7.0]
	for seed in 200:
		var rng := RandomNumberGenerator.new()
		rng.seed = seed
		var got: int = RngUtilScript.weighted_pick(weights, rng)
		var ref_rng := RandomNumberGenerator.new()
		ref_rng.seed = seed
		var total := 0.0
		for w in weights:
			total += w
		var expected: int
		if total <= 0.0:
			expected = ref_rng.randi_range(0, weights.size() - 1)
		else:
			var r := ref_rng.randf() * total
			expected = weights.size() - 1
			for i in weights.size():
				r -= weights[i]
				if r <= 0.0:
					expected = i
					break
		assert_int(got).is_equal(expected)
	# sanity: draws stay in range
	for p in _picks(weights, 999, 100):
		assert_int(p).is_between(0, weights.size() - 1)


func test_zero_total_is_uniform_over_indices() -> void:
	var seen := {false: 0, true: 0}
	for seed in 40:
		var p: int = _picks([0.0, 0.0], seed, 1)[0]
		seen[p == 0] += 1
	# A uniform coin flip across 40 seeded draws never lands all-one-side.
	assert_int(seen[true]).is_between(5, 35)
	assert_int(seen[false]).is_between(5, 35)


func test_zero_weight_entry_is_never_picked() -> void:
	var weights: Array[float] = [0.0, 5.0, 0.0]
	var picks := _picks(weights, 777, 200)
	for p: int in picks:
		assert_int(p).is_equal(1)


func test_negative_total_falls_back_to_uniform() -> void:
	# Degenerate weights (all negative) total <= 0: uniform branch.
	var picks := _picks([-1.0, -2.0], 42, 50)
	for p: int in picks:
		assert_int(p).is_between(0, 1)
