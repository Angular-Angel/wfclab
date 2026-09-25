@abstract class_name TechniqueBase extends RefCounted
## Contract shared by every technique kind (decomposition, constraint,
## synthesizer): identity plus spec-driven parameter declaration.

@abstract func get_id() -> StringName
@abstract func get_display_name() -> String
@abstract func get_parameter_specs() -> Array[Dictionary]
