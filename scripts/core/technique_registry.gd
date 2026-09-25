extends Node
## Single enumeration point for available techniques. One generic store,
## kind-keyed; the register/get/get_list triplets stay as thin wrappers so
## the public API (and the tabs) don't move.

const KIND_DECOMPOSITION := &"decomposition"
const KIND_CONSTRAINT := &"constraint"
const KIND_SYNTHESIZER := &"synthesizer"

var _store: Dictionary = {}   # kind -> {StringName -> TechniqueBase}


func _ready() -> void:
	register_decomposition(GridTiles.new())
	register_constraint(AdjacencyExtractor.new())
	register_constraint(PixelOverlap.new())
	register_synthesizer(TileCollapse.new())


func _register(kind: StringName, technique: TechniqueBase) -> void:
	var bucket: Dictionary = _store.get_or_add(kind, {})
	assert(not technique.get_id().is_empty())
	assert(not bucket.has(technique.get_id()),
		"Duplicate %s technique id: %s" % [kind, technique.get_id()])
	bucket[technique.get_id()] = technique


func _bucket(kind: StringName) -> Dictionary:
	return _store.get_or_add(kind, {})


# --- Decomposition -----------------------------------------------------------

func register_decomposition(technique: DecompositionTechnique) -> void:
	_register(KIND_DECOMPOSITION, technique)


func get_decomposition_techniques() -> Array[DecompositionTechnique]:
	var list: Array[DecompositionTechnique] = []
	list.assign(_bucket(KIND_DECOMPOSITION).values())
	return list


func get_decomposition(id: StringName) -> DecompositionTechnique:
	return _bucket(KIND_DECOMPOSITION).get(id)


# --- Constraint ---------------------------------------------------------------

func register_constraint(technique: ConstraintTechnique) -> void:
	_register(KIND_CONSTRAINT, technique)


func get_constraint_techniques() -> Array[ConstraintTechnique]:
	var list: Array[ConstraintTechnique] = []
	list.assign(_bucket(KIND_CONSTRAINT).values())
	return list


func get_constraint_technique(id: StringName) -> ConstraintTechnique:
	return _bucket(KIND_CONSTRAINT).get(id)


# --- Synthesizer ---------------------------------------------------------------

func register_synthesizer(synth: Synthesizer) -> void:
	_register(KIND_SYNTHESIZER, synth)


func get_synthesizer_techniques() -> Array[Synthesizer]:
	var list: Array[Synthesizer] = []
	list.assign(_bucket(KIND_SYNTHESIZER).values())
	return list


func get_synthesizer(id: StringName) -> Synthesizer:
	return _bucket(KIND_SYNTHESIZER).get(id)
