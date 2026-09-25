class_name WeightOverrideEditor extends HBoxContainer
## The "Weight override" check + spin row shared by the Parts and
## Constraints inspectors. The widget only emits; the owning tab decides
## what to write to AppData (same owner-handles-guard contract as
## PalettePicker). Spin edits while unchecked emit nothing, matching the
## original per-tab handlers.

signal override_changed(enabled: bool, value: float)

var _check := CheckButton.new()
var _spin := SpinBox.new()


func _init() -> void:
	_check.text = "Weight override"
	_check.toggled.connect(func(pressed: bool) -> void:
		override_changed.emit(pressed, _spin.value))
	add_child(_check)
	_spin.min_value = 0.0
	_spin.max_value = 99999.0
	_spin.value_changed.connect(func(value: float) -> void:
		if _check.button_pressed:
			override_changed.emit(true, value))
	add_child(_spin)


func set_enabled_silent(enabled: bool) -> void:
	_check.set_pressed_no_signal(enabled)


func set_silent(enabled: bool, value: float) -> void:
	set_enabled_silent(enabled)
	_spin.set_value_no_signal(value)
