class_name PixelHash extends RefCounted

static func of(image: Image, tolerance: int = 0) -> String:
	var data := image.get_data()   # returns a copy; safe to mutate
	if tolerance > 0:
		var step := tolerance * 2 + 1   # values within ±tolerance usually collide
		for i in data.size():
			data[i] = int(data[i]) / step   # integer division = floor quantize

	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_MD5)
	ctx.update(data)
	return ctx.finish().hex_encode()
