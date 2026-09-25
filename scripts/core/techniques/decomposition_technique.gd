@abstract class_name DecompositionTechnique extends TechniqueBase
## Contract for decomposition techniques. Techniques are stateless algorithms:
## parameters arrive as arguments, results leave as return values.
## Parameter specs drive the auto-built UI. Each spec is a Dictionary:
##   key, label, type ("int" | "vector2i" | "bool" | "enum"),
##   default, min, max (numeric), options (enum: Array[String])

## Returns {parts: Array[Part], stats: Dictionary}. Must be deterministic:
## same images (by id order) + same params -> same part ids and occurrence
## order. report_progress(fraction) may be called from a worker thread.
@abstract func decompose(images: Array[ImageAssetData], params: Dictionary,
		report_progress: Callable) -> Dictionary
