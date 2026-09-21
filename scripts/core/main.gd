extends Control

## WFC Lab — main window. Menu bar + six tabs.

const ImagesTab := preload("res://scripts/core/tabs/images_tab.gd")
# DecompositionTab / PartsTab / ConstraintsTab have global class_names.

const TAB_NAMES: Array[String] = [
	"Images",
	"Decomposition",
	"Parts",
	"Constraints",
	"Terrain Keys",
	"Synthesizers",
	"Outputs",
]

const MENU_SAVE := 100
const MENU_LOAD := 101
const MENU_CLEAR_EDITS := 200

var _decomp_tab: DecompositionTab = null
var _save_dialog: FileDialog
var _load_dialog: FileDialog
var _clear_confirm: ConfirmationDialog


func _ready() -> void:
	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(root)

	var bar := MenuBar.new()
	root.add_child(bar)
	_build_menu(bar)

	var tabs := TabContainer.new()
	tabs.name = "MainTabs"
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(tabs)

	var images_page: Control = null
	for tab_name in TAB_NAMES:
		var page: Control
		match tab_name:
			"Images":
				page = ImagesTab.new()
				images_page = page
			"Decomposition":
				page = DecompositionTab.new()
				_decomp_tab = page
			"Parts":
				page = PartsTab.new()
			"Constraints":
				page = ConstraintsTab.new()
			"Terrain Keys":
				page = TerrainKeysTab.new()
			"Synthesizers":
				page = SynthesizersTab.new()
			"Outputs":
				page = OutputsTab.new()
			_:
				page = _make_placeholder(tab_name)
		page.name = tab_name
		tabs.add_child(page)

	_build_dialogs()

	# Occurrence jump: any tab emitting occurrence_selected -> Images tab.
	if images_page != null:
		for tab_name in ["Parts", "Constraints"]:
			var page := tabs.get_node_or_null(NodePath(tab_name))
			if page != null and page.has_signal("occurrence_selected"):
				page.occurrence_selected.connect(
					_jump_to_occurrence.bind(tabs, images_page))


func _build_menu(bar: MenuBar) -> void:
	var file_menu := PopupMenu.new()
	file_menu.name = "File"
	file_menu.add_item("Save Project...", MENU_SAVE)
	file_menu.add_item("Load Project...", MENU_LOAD)
	file_menu.id_pressed.connect(_on_menu_id)
	bar.add_child(file_menu)

	var edit_menu := PopupMenu.new()
	edit_menu.name = "Edit"
	edit_menu.add_item("Clear All Edits...", MENU_CLEAR_EDITS)
	edit_menu.id_pressed.connect(_on_menu_id)
	bar.add_child(edit_menu)


func _build_dialogs() -> void:
	_save_dialog = FileDialog.new()
	_save_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	_save_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_save_dialog.filters = ["*.wfcproj ; WFC Lab project"]
	_save_dialog.file_selected.connect(_on_save_project)
	add_child(_save_dialog)

	_load_dialog = FileDialog.new()
	_load_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_load_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_load_dialog.filters = ["*.wfcproj ; WFC Lab project"]
	_load_dialog.file_selected.connect(_on_load_project)
	add_child(_load_dialog)

	_clear_confirm = ConfirmationDialog.new()
	_clear_confirm.title = "Clear All Edits"
	_clear_confirm.dialog_text = (
        "Discard all manual edits (enabled flags, weight overrides) "
		+ "and part merges?\n\n"
		+ "The last extraction will be re-materialized without them.")
	_clear_confirm.ok_button_text = "Clear Edits"
	_clear_confirm.confirmed.connect(func() -> void: AppData.clear_all_edits())
	add_child(_clear_confirm)


func _on_menu_id(id: int) -> void:
	match id:
		MENU_SAVE:
			_save_dialog.popup_centered_ratio(0.7)
		MENU_LOAD:
			_load_dialog.popup_centered_ratio(0.7)
		MENU_CLEAR_EDITS:
			_clear_confirm.popup_centered()


func _on_save_project(path: String) -> void:
	if AppData.save_project(path):
		print("Project saved: %s" % path)


func _on_load_project(path: String) -> void:
	var data := AppData.load_project(path)
	if data.is_empty():
		return
	var run: Dictionary = data.get("run", {})
	if _decomp_tab != null and run.has("technique_id"):
		# Re-runs the stored config; materialization re-applies the edits.
		_decomp_tab.run_config(run)


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
