@abstract class_name Synthesizer extends RefCounted
## Contract for synthesizers, mirroring the technique pattern. Stateless:
## all inputs arrive as arguments; determinism comes from the caller's rng.

@abstract func get_id() -> StringName
@abstract func get_display_name() -> String
@abstract func get_parameter_specs() -> Array[Dictionary]

## Returns {image: Image, stats: Dictionary}, or {} on failure.
## report_progress(fraction) may be called from a worker thread.
@abstract func synthesize(index: ConstraintIndex, params: Dictionary,
		rng: RandomNumberGenerator, report_progress: Callable) -> Dictionary
