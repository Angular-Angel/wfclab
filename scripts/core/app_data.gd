extends Node
## Shared state. Tabs read from here; nothing else owns data.

signal images_changed
signal parts_changed

var images: Dictionary = {}        # id -> ImageAssetData
var parts: Dictionary = {}         # id -> Part
var last_run_stats: Dictionary = {}


func add_image(asset: ImageAssetData) -> bool:
	if images.has(asset.id):
		return false   # same pixels already loaded (even from another path)
	images[asset.id] = asset
	images_changed.emit()
	return true


func get_image_list() -> Array[ImageAssetData]:
	var list: Array[ImageAssetData] = []
	list.assign(images.values())
	return list


func image_name(id: String) -> String:
	return images[id].name if images.has(id) else id


## Atomic snapshot swap — the UI never sees a half-computed part set.
func set_parts(new_parts: Array[Part], stats: Dictionary) -> void:
	parts = {}
	for part: Part in new_parts:
		parts[part.id] = part
	last_run_stats = stats
	parts_changed.emit()


func get_part_list() -> Array[Part]:
	var list: Array[Part] = []
	list.assign(parts.values())
	return list
