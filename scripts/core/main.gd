extends Control

## WFC Lab — main window. Images, Decomposition, Parts, Constraints functional.

const ImagesTab := preload("res://scripts/core/tabs/images_tab.gd")
const DecompositionTabScript := preload("res://scripts/core/tabs/decomposition_tab.gd")
const PartsTab := preload("res://scripts/core/tabs/parts_tab.gd")
const ConstraintsTab := preload("res://scripts/core/tabs/constraints_tab.gd")

const TAB_NAMES: Array[String] = [
	"Images",
	"Decomposition",
	"Parts",
	"Constraints",
	"Synthesizers",
	"Outputs",
]


func _ready() -> void:
	var tabs := TabContainer.new()
	tabs.name = "MainTabs"
	tabs.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(tabs)

	var images_page: Control = null
	for tab_name in TAB_NAMES:
		var page: Control
		match tab_name:
			"Images":
				page = ImagesTab.new()
				images_page = page
			"Decomposition": page = DecompositionTabScript.new()
			"Parts": page = PartsTab.new()
			"Constraints": page = ConstraintsTab.new()
			_: page = _make_placeholder(tab_name)
		page.name = tab_name
		tabs.add_child(page)

	# Occurrence jump: any tab emitting occurrence_selected -> Images tab.
	if images_page != null:
		for tab_name in ["Parts", "Constraints"]:
			var page := tabs.get_node_or_null(NodePath(tab_name))
			if page != null and page.has_signal("occurrence_selected"):
				page.occurrence_selected.connect(
					_jump_to_occurrence.bind(tabs, images_page))


func _jump_to_occurrence(image_id: String, position: Vector2i, size: Vector2i,
		tabs: TabContainer, images_page: Control) -> void:
	tabs.current_tab = tabs.get_tab_idx_from_control(images_page)
	images_page.show_occurrence(image_id, position, size)


func _make_placeholder(tab_name: String) -> Control:
	var center := CenterContainer.new()
	var label := Label.new()
	label.text = "%s\nNot implemented yet." % tab_name
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	center.add_child(label)
	return center
