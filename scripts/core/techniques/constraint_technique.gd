@abstract class_name ConstraintTechnique extends TechniqueBase
## Contract for constraint extraction techniques. Stateless algorithms, same
## discipline as DecompositionTechnique: params in, results out, deterministic.
## Parameter specs: same format as DecompositionTechnique.

## Returns Array[Constraint]. `parts` are the freshly extracted parts (with
## occurrences) from the decomposition stage of the same run; `images` are
## the corpus. report_progress(fraction) may be called from a worker thread.
## terrain_classes: the enabled terrain-key classes (AppData's
## active_terrain_classes()), threaded in by callers so techniques stay
## autoload-free; empty = no terrain equivalence.
@abstract func extract(parts: Array[Part], images: Array[ImageAssetData],
		params: Dictionary, report_progress: Callable,
		terrain_classes: Array = []) -> Array[Constraint]
