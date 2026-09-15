@abstract class_name ConstraintTechnique extends RefCounted
## Contract for constraint extraction techniques. Stateless algorithms, same
## discipline as DecompositionTechnique: params in, results out, deterministic.

@abstract func get_id() -> StringName
@abstract func get_display_name() -> String

## Parameter specs: same format as DecompositionTechnique.
@abstract func get_parameter_specs() -> Array[Dictionary]

## Returns Array[Constraint]. `parts` are the freshly extracted parts (with
## occurrences) from the decomposition stage of the same run; `images` are
## the corpus. report_progress(fraction) may be called from a worker thread.
@abstract func extract(parts: Array[Part], images: Array[ImageAssetData],
		params: Dictionary, report_progress: Callable) -> Array[Constraint]
