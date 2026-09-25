class_name RngUtil extends RefCounted
## RNG helper shared by the samplers. Precondition: weights is non-empty.


## Weighted choice: sum; if the total is <= 0, a uniform index via one
## randi_range draw; otherwise randf() * total walked down the weights.
## Consumes exactly one rng draw either way, and walks in array order, so
## it reproduces the tile-collapse samplers' draw-for-draw behavior.
static func weighted_pick(weights: Array[float], rng: RandomNumberGenerator) -> int:
	var total := 0.0
	for w in weights:
		total += w
	if total <= 0.0:
		return rng.randi_range(0, weights.size() - 1)
	var r := rng.randf() * total
	for i in weights.size():
		r -= weights[i]
		if r <= 0.0:
			return i
	return weights.size() - 1
