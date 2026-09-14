extends Control

## WFC Lab — main window. Six tabs; Images, Decomposition, Parts functional.

const ImagesTab := preload("res://scripts/core/tabs/images_tab.gd")
const DecompositionTab := preload("res://scripts/core/tabs/decomposition_tab.gd")
const PartsTab := preload("res://scripts/core/tabs/parts_tab.gd")

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

	for tab_name in TAB_NAMES:
		var page: Control
		match tab_name:
			"Images": page = ImagesTab.new()
			"Decomposition": page = DecompositionTab.new()
			"Parts": page = PartsTab.new()
			_: page = _make_placeholder(tab_name)
		page.name = tab_name
		tabs.add_child(page)

	tabs.current_tab = 0


func _make_placeholder(tab_name: String) -> Control:
	var center := CenterContainer.new()
	var label := Label.new()
	label.text = "%s\nNot implemented yet." % tab_name
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	center.add_child(label)
	return center
