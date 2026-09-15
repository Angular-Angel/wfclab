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


func clone() -> Constraint:
	var c := Constraint.new()
	c.id = id
	c.type = type
	c.participants = participants.duplicate(true)
	c.params = params.duplicate(true)
	c.weight = weight
	c.weight_override = weight_override
	c.evidence = evidence.duplicate(true)
	c.origin = origin
	c.enabled = enabled
	return c


func rebuild_id() -> void:
	## Recompute the id from current participants + offset. Called after
	## alias rewriting changes participants. Must stay in sync with
	## AdjacencyExtractor's id scheme.
	var offset: Vector2i = params.get("offset", Vector2i())
	id = "c_%s_%s_%d_%d" % [
		participants[0]["part_id"].substr(2, 6),
		participants[1]["part_id"].substr(2, 6),
		offset.x, offset.y]
