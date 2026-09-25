class_name TechniquePanel extends VBoxContainer
## The technique chooser shared by the Decomposition and Synthesizers
## tabs: a heading, the registry-populated OptionButton (display name
## shown, technique id in metadata), and the "Parameters" box rebuilt on
## every selection. `technique_selected` fires for user picks and for
## the programmatic select_initial/select_by_id; `initial` rides along
## so project load can seed the parameter widgets (Decomposition's
## apply_config path).

signal technique_selected(id: StringName, initial: Dictionary)

var params_box: VBoxContainer
var _option := OptionButton.new()


func _init(heading := "Technique") -> void:
	add_child(UiKit.label(heading))
	_option.item_selected.connect(func(i: int) -> void:
		technique_selected.emit(_option.get_item_metadata(i), {}))
	add_child(_option)
	add_child(UiKit.label("Parameters"))
	params_box = VBoxContainer.new()
	add_child(params_box)


func add_technique(id: StringName, display_name: String) -> void:
	_option.add_item(display_name)
	_option.set_item_metadata(_option.item_count - 1, id)


## Pick the first technique (and emit) after population; no-op when empty.
func select_initial() -> void:
	if _option.item_count > 0:
		_option.select(0)
		technique_selected.emit(_option.get_item_metadata(0), {})


## Selects the technique with the given id and emits with `initial`
## riding along; no-op (returns -1) when the id is unknown.
func select_by_id(id: StringName, initial: Dictionary = {}) -> int:
	for i in _option.item_count:
		if _option.get_item_metadata(i) == id:
			_option.select(i)
			technique_selected.emit(id, initial)
			return i
	return -1


## Clears `values` and rebuilds the parameter widgets into params_box,
## seeding from `initial`.
func rebuild_params(specs: Array[Dictionary], values: Dictionary,
		initial: Dictionary = {}) -> void:
	UiKit.clear_children(params_box)
	values.clear()
	ParamBuilder.build(specs, values, params_box, initial)
