extends RefCounted
## Shared deterministic fixture builders for the test suites. This is NOT a
## test suite: `const Builders := preload("res://tests/builders.gd")` and call
## the static helpers. No class_name — keeps the global class registry clean.
##
## All helpers are deterministic: fixed sizes, explicit colors, no RNG, no
## timing.

const AppDataScript = preload("res://scripts/core/app_data.gd")


static func solid_image(width: int, height: int, col: Color) -> Image:
	var img := Image.create_empty(width, height, false, Image.FORMAT_RGBA8)
	img.fill(col)
	return img


static func flat_image(width: int, height: int, pixels: Array[Color]) -> Image:
	## Row-major pixel list: index = y * width + x.
	var img := Image.create_empty(width, height, false, Image.FORMAT_RGBA8)
	for y in height:
		for x in width:
			img.set_pixel(x, y, pixels[y * width + x])
	return img


static func grid_image(rows: Array) -> Image:
	## Explicit color grid: rows is an Array of equal-length Arrays of Color.
	var height := rows.size()
	var width := (rows[0] as Array).size()
	var img := Image.create_empty(width, height, false, Image.FORMAT_RGBA8)
	for y in height:
		for x in width:
			img.set_pixel(x, y, rows[y][x])
	return img


static func make_part(id_hash: String, color: Color, position := Vector2i.ZERO,
		image_id := "source") -> Part:
	## 1x1 solid part, the common case for index/synthesis fixtures.
	return make_part_from_image(solid_image(1, 1, color), id_hash, position,
			image_id)


static func make_part_from_image(img: Image, id_hash: String,
		position := Vector2i.ZERO, image_id := "source") -> Part:
	var part := Part.new()
	part.setup(img, id_hash, image_id, position)
	part.weight = 1.0
	return part


static func make_constraint(a: String, b: String, offset: Vector2i,
		weight := 1.0, symmetric := false) -> Constraint:
	var constraint := Constraint.new()
	constraint.participants = [
		{"part_id": a, "role": "a"},
		{"part_id": b, "role": "b"},
	]
	constraint.params = {"offset": offset, "symmetric": symmetric}
	constraint.weight = weight
	constraint.rebuild_id()
	return constraint


static func make_asset(id_name: String, image: Image) -> ImageAssetData:
	var asset := ImageAssetData.from_image(image, id_name)
	asset.id = id_name
	return asset

