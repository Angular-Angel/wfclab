class_name Part extends RefCounted
## A decomposed component. Variants retain their source tile's canonical id and
## symbolic transform so constraint extraction can transform their relations.

var id: String                  # "p_" + canonical_hash prefix
var canonical_id: String        # == id until symmetry lands
var transform_key := "identity"   # identity, rot90, rot180, rot270, flip_h, flip_v
var transform_sources: Array[Dictionary] = [] # [{canonical_id, transform_key}]
var canonical_hash: String      # exact hash of pixel data; the dedupe key
var pixel_data: Image
var size: Vector2i
var occurrences: Array[Dictionary] = []   # {image_id: String, position: Vector2i}
var weight: float = 0.0         # derived (occurrence count); set after extraction
var weight_override: Variant = null       # null = use derived
var enabled := true
var notes := ""

var _texture: ImageTexture


## Populate from an extracted tile. Call once, right after construction.
func setup(tile: Image, hash_hex: String, image_id: String, position: Vector2i) -> void:
	pixel_data = tile
	size = tile.get_size()
	canonical_hash = hash_hex
	id = Ids.part(hash_hex)
	canonical_id = id
	transform_sources.append({"canonical_id": id, "transform_key": transform_key})
	occurrences.append({"image_id": image_id, "position": position,
		"canonical_id": id})


func get_texture() -> ImageTexture:
	## Lazy; MUST be called from the main thread (ImageTexture creation is
	## not thread-safe). The Parts tab is the only caller.
	if _texture == null:
		_texture = ImageTexture.create_from_image(pixel_data)
	return _texture


func occurrence_count() -> int:
	return occurrences.size()


func get_effective_weight() -> float:
	return weight_override if weight_override != null else weight


func clone() -> Part:
	## Shallow clone: pixel_data is shared (images are read-only here),
	## mutable state (occurrences) is duplicated.
	var p := Part.new()
	p.id = id
	p.canonical_id = canonical_id
	p.transform_key = transform_key
	p.transform_sources = transform_sources.duplicate(true)
	p.canonical_hash = canonical_hash
	p.pixel_data = pixel_data
	p.size = size
	p.occurrences = occurrences.duplicate()
	p.weight = weight
	p.weight_override = weight_override
	p.enabled = enabled
	p.notes = notes
	return p
