extends Node
## Single enumeration point for available techniques.

var _decomposition: Dictionary = {}   # StringName -> DecompositionTechnique
var _constraint: Dictionary = {}      # StringName -> ConstraintTechnique
var _synthesizers: Dictionary = {}   # StringName -> Synthesizer


func _ready() -> void:
	register_decomposition(GridTiles.new())
	register_constraint(AdjacencyExtractor.new())
	register_synthesizer(TileCollapse.new())


func register_decomposition(technique: DecompositionTechnique) -> void:
	assert(technique is DecompositionTechnique)
	assert(not technique.get_id().is_empty())
	assert(not _decomposition.has(technique.get_id()),
		"Duplicate decomposition technique id: %s" % technique.get_id())
	_decomposition[technique.get_id()] = technique


func get_decomposition_techniques() -> Array[DecompositionTechnique]:
	var list: Array[DecompositionTechnique] = []
	list.assign(_decomposition.values())
	return list


func get_decomposition(id: StringName) -> DecompositionTechnique:
	return _decomposition.get(id)


func register_constraint(technique: ConstraintTechnique) -> void:
	assert(technique is ConstraintTechnique)
	assert(not technique.get_id().is_empty())
	assert(not _constraint.has(technique.get_id()),
		"Duplicate constraint technique id: %s" % technique.get_id())
	_constraint[technique.get_id()] = technique


func get_constraint_techniques() -> Array[ConstraintTechnique]:
	var list: Array[ConstraintTechnique] = []
	list.assign(_constraint.values())
	return list


func get_constraint_technique(id: StringName) -> ConstraintTechnique:
	return _constraint.get(id)


func register_synthesizer(synth: Synthesizer) -> void:
	assert(synth is Synthesizer)
	assert(not synth.get_id().is_empty())
	assert(not _synthesizers.has(synth.get_id()),
		"Duplicate synthesizer id: %s" % synth.get_id())
	_synthesizers[synth.get_id()] = synth


func get_synthesizer_techniques() -> Array[Synthesizer]:
	var list: Array[Synthesizer] = []
	list.assign(_synthesizers.values())
	return list


func get_synthesizer(id: StringName) -> Synthesizer:
	return _synthesizers.get(id)
