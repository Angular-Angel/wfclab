extends Node
## Single enumeration point for available techniques.

var _decomposition: Dictionary = {}   # StringName -> DecompositionTechnique


func _ready() -> void:
	register_decomposition(GridTiles.new())


func register_decomposition(technique: DecompositionTechnique) -> void:
	assert(technique is DecompositionTechnique)
	assert(not technique.get_id().is_empty())
	assert(not _decomposition.has(technique.get_id()),
		"Duplicate decomposition technique id: %s" % technique.get_id())
	_decomposition[technique.get_id()] = technique


func get_decomposition_techniques() -> Array[DecompositionTechnique]:
	return _decomposition.values()


func get_decomposition(id: StringName) -> DecompositionTechnique:
	return _decomposition.get(id)
