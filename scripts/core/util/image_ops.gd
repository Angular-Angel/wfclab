class_name ImageOps extends RefCounted
## Shared image normalization: one source of truth for the RGBA8 guard
## that every pixel-walking consumer needs.

static func to_rgba8(img: Image) -> Image:
	## Never mutates the input: returns a normalized copy only when the
	## source is compressed or not already RGBA8. Identical pixels then
	## behave identically everywhere regardless of source format (L8
	## grayscale PNGs, RGB8 24-bit PNGs, RGBA8, ...).
	if img.is_compressed() or img.get_format() != Image.FORMAT_RGBA8:
		var out := img.duplicate()
		if out.is_compressed():
			out.decompress()
		out.convert(Image.FORMAT_RGBA8)
		return out
	return img


static func to_rgba8_in_place(img: Image) -> void:
	## Same normalization directly on the caller's own image, no duplicate.
	## Use only when mutating the input is intended (apply() semantics).
	if img.is_compressed() or img.get_format() != Image.FORMAT_RGBA8:
		if img.is_compressed():
			img.decompress()
		img.convert(Image.FORMAT_RGBA8)
