class_name Constraint extends RefCounted
## A learned or authored fact relating parts. Phase 1: extracted adjacency.

enum Origin { EXTRACTED, AUTHORED, EDITED }

var id: String
var type: StringName                    # e.g. &"adjacency"
var participants: Array[Dictionary] = []   # {part_id: String, role: String}
var params: Dictionary = {}             # e.g. {"offset": Vector2i}
var weight: float = 0.0                 # derived (evidence count); set after extraction
var weight_override: Variant = null     # null = use derived
var evidence: Array[Dictionary] = []    # {image_id, positions: Array[Vector2i]}
var origin: int = Origin.EXTRACTED
var enabled := true


func get_effective_weight() -> float:
	return weight_override if weight_override != null else weight


func part_ids() -> Array[String]:
	var ids: Array[String] = []
	for p: Dictionary in participants:
		ids.append(p["part_id"])
	return ids
