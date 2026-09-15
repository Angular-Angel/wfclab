class_name JsonCodec extends RefCounted
## JSON can't store Vector2i, and it reads all numbers back as floats.
## Recursively convert both ways.

static func encode(value: Variant) -> Variant:
	match typeof(value):
		TYPE_VECTOR2I:
			return {"__v2i": [value.x, value.y]}
		TYPE_DICTIONARY:
			var out := {}
			for k: String in value:
				out[k] = encode(value[k])
			return out
		TYPE_ARRAY:
			var out_a: Array = []
			for v in value:
				out_a.append(encode(v))
			return out_a
		_:
			return value


static func decode(value: Variant) -> Variant:
	match typeof(value):
		TYPE_DICTIONARY:
			var d: Dictionary = value
			if d.size() == 1 and d.has("__v2i"):
				var a: Array = d["__v2i"]
				return Vector2i(int(a[0]), int(a[1]))
			var out := {}
			for k: String in d:
				out[k] = decode(d[k])
			return out
		TYPE_ARRAY:
			var arr: Array = value
			var out_a: Array = []
			for v in arr:
				out_a.append(decode(v))
			return out_a
		TYPE_FLOAT:
			# JSON numbers come back as floats; restore whole numbers as ints
			# so parameter dictionaries match their original types.
			if value == round(value) and absf(value) < 2147483647.0:
				return int(value)
			return value
		_:
			return value
