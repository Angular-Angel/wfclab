class_name PixelHash extends RefCounted
static func of(image: Image, tolerance: int = 0) -> String:
	## Hash the PIXELS, not the byte layout: normalize to RGBA8 first so
	## identical pixels hash identically regardless of source format (L8
	## grayscale PNGs, RGB8 24-bit PNGs, RGBA8, ...). Never mutates the
	## caller's image.
	var src := image
	if src.is_compressed() or src.get_format() != Image.FORMAT_RGBA8:
		src = src.duplicate()
		if src.is_compressed():
			src.decompress()
		src.convert(Image.FORMAT_RGBA8)
	var data := src.get_data()   # copy; safe to mutate
	if tolerance > 0:
		var step := tolerance * 2 + 1   # values within ±tolerance usually collide
		for i in data.size():
			data[i] = int(data[i]) / step   # integer division = floor quantize
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_MD5)
	ctx.update(data)
	return ctx.finish().hex_encode()
