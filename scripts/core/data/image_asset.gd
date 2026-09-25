class_name ImageAssetData extends RefCounted
## A loaded input or generated output image. The seed of the future ImageAsset
## resource.

var id: String
var path: String
var name: String
var image: Image
var texture: ImageTexture
var thumb: ImageTexture
var hash: String          # digest of raw pixels; used for ids and later caching


static func load_from_path(path: String) -> ImageAssetData:
	var image := Image.load_from_file(path)
	if image == null or image.is_empty():
		return null
	# Normalize at the boundary: tile regions, transforms, hashes, strip
	# extraction, and palettes then all see one uniform byte layout.
	image = ImageOps.to_rgba8(image)
	return from_image(image, path.get_file(), path)


static func from_image(image: Image, display_name: String, source_path := "") -> ImageAssetData:
	if image == null or image.is_empty():
		return null
	var asset := ImageAssetData.new()
	asset.path = source_path
	asset.name = display_name
	asset.image = image
	asset.hash = PixelHash.of(image)
	asset.id = Ids.image(asset.hash)
	asset.texture = ImageTexture.create_from_image(image)
	asset.thumb = _make_thumbnail(image)
	return asset


static func _make_thumbnail(image: Image) -> ImageTexture:
	const SIZE := Vector2i(96, 96)
	var size := image.get_size()
	var ratio := minf(float(SIZE.x) / size.x, float(SIZE.y) / size.y)
	var thumb := image.duplicate()
	thumb.resize(
		maxi(1, int(size.x * ratio)),
		maxi(1, int(size.y * ratio)),
		Image.INTERPOLATE_LANCZOS
	)
	return ImageTexture.create_from_image(thumb)
