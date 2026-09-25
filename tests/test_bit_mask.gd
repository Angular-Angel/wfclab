extends GdUnitTestSuite
## Direct BitMask suite: kth/only/first and the ctz cache, including edges
## the algorithm tests only brush past (empty masks, out-of-range k,
## multi-word masks, bits at position 63).

const BitMaskScript := preload("res://scripts/core/util/bit_mask.gd")


func _mask(nwords: int) -> PackedInt64Array:
	return BitMaskScript.empty(nwords)


func test_ctz_positions_and_cache_round_trips() -> void:
	# fresh lookups populate the cache; second call must hit it and agree
	for b: int in [0, 1, 31, 63]:
		var low := 1 << b
		var first_result: int = BitMaskScript.ctz(low)
		var cached_result: int = BitMaskScript.ctz(low)
		assert_int(first_result).is_equal(b)
		assert_int(cached_result).is_equal(b)
	# bit 63 must not sign-flip (63 is the last valid isolated bit)
	assert_int(BitMaskScript.ctz(1 << 63)).is_equal(63)
	# the cache persists across calls (static var) — clear it to prove
	# re-population reproduces the same answers
	BitMaskScript._ctz_cache.clear()
	assert_int(BitMaskScript.ctz(1 << 63)).is_equal(63)


func test_only_clears_everything_but_the_one_bit() -> void:
	var m := _mask(3)
	BitMaskScript.set_bit(m, 5)
	BitMaskScript.set_bit(m, 70)
	BitMaskScript.set_bit(m, 130)
	BitMaskScript.only(m, 130)
	assert_bool(BitMaskScript.is_empty(m)).is_false()
	assert_int(BitMaskScript.count(m)).is_equal(1)
	assert_bool(BitMaskScript.has(m, 130)).is_true()
	assert_bool(BitMaskScript.has(m, 70)).is_false()
	assert_bool(BitMaskScript.has(m, 5)).is_false()
	assert_int(BitMaskScript.first(m)).is_equal(130)


func test_first_returns_lowest_set_bit_across_words() -> void:
	var m := _mask(2)
	assert_int(BitMaskScript.first(m)).is_equal(-1)   # empty mask
	BitMaskScript.set_bit(m, 64 + 7)   # word 1, bit 7
	BitMaskScript.set_bit(m, 64 + 9)
	assert_int(BitMaskScript.first(m)).is_equal(71)


func test_kth_enumerates_set_bits_in_order_and_fails_cleanly() -> void:
	var m := _mask(2)
	assert_int(BitMaskScript.kth(m, 0)).is_equal(-1)   # empty mask
	BitMaskScript.set_bit(m, 3)
	BitMaskScript.set_bit(m, 63)
	BitMaskScript.set_bit(m, 64)      # first bit of word 1
	BitMaskScript.set_bit(m, 100)
	assert_int(BitMaskScript.count(m)).is_equal(4)
	assert_int(BitMaskScript.kth(m, 0)).is_equal(3)
	assert_int(BitMaskScript.kth(m, 1)).is_equal(63)
	assert_int(BitMaskScript.kth(m, 2)).is_equal(64)
	assert_int(BitMaskScript.kth(m, 3)).is_equal(100)
	# k beyond the last set bit → -1 (the samplers' fallback contract)
	assert_int(BitMaskScript.kth(m, 4)).is_equal(-1)
	assert_int(BitMaskScript.kth(m, -1)).is_equal(-1)


func test_full_and_count_agree() -> void:
	var m := BitMaskScript.full(2, 70)   # 70 bits: word 0/1 full, word 1 bit 6
	assert_int(BitMaskScript.count(m)).is_equal(70)
	assert_bool(BitMaskScript.has(m, 63)).is_true()
	assert_bool(BitMaskScript.has(m, 64)).is_true()
	assert_bool(BitMaskScript.has(m, 69)).is_true()
	assert_bool(BitMaskScript.has(m, 70)).is_false()
