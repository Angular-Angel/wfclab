class_name ParamBuilder extends RefCounted
## Spec-driven parameter widgets. Writes user values into `values` via
## lambdas, so owning tabs never need per-type setter handlers.

static func build(specs: Array[Dictionary], values: Dictionary,
		box: Container, initial: Dictionary = {}) -> void:
	for spec: Dictionary in specs:
		var key: String = spec["key"]
		var default: Variant = initial.get(key, spec["default"])
		values[key] = default
		var row := HBoxContainer.new()
		var label := Label.new()
		label.text = spec["label"]
		label.custom_minimum_size = Vector2(110.0, 0.0)
		row.add_child(label)

		match spec["type"]:
			"int":
				var spin := SpinBox.new()
				spin.min_value = spec.get("min", 0)
				spin.max_value = spec.get("max", 9999)
				spin.value = default
				spin.value_changed.connect(
					func(v: float) -> void: values[key] = int(v))
				row.add_child(spin)
			"vector2i":
				var def_v: Vector2i = default
				var spin_x := SpinBox.new()
				var spin_y := SpinBox.new()
				for spin: SpinBox in [spin_x, spin_y]:
					spin.min_value = spec.get("min", 0)
					spin.max_value = spec.get("max", 9999)
					spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				spin_x.value = def_v.x
				spin_y.value = def_v.y
				spin_x.value_changed.connect(func(v: float) -> void:
					values[key] = Vector2i(int(v), (values[key] as Vector2i).y))
				spin_y.value_changed.connect(func(v: float) -> void:
					values[key] = Vector2i((values[key] as Vector2i).x, int(v)))
				row.add_child(spin_x)
				row.add_child(spin_y)
			"bool":
				var check := CheckButton.new()
				check.button_pressed = default
				check.toggled.connect(
					func(p: bool) -> void: values[key] = p)
				row.add_child(check)
			"enum":
				var option := OptionButton.new()
				for option_name: String in spec["options"]:
					option.add_item(option_name)
				option.selected = default
				option.item_selected.connect(
					func(i: int) -> void: values[key] = i)
				row.add_child(option)

		box.add_child(row)
