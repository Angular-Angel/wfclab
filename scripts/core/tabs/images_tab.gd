extends TabBase

## Images tab: load image files, browse them, preview one. Storage lives in
## AppData; this tab is pure UI.

var _file_dialog: FileDialog
var _list: ItemList
var _pane: PreviewPane
var _discard_button: Button


func _ready() -> void:
	super._ready()
	var split := _build_shell()

	var left := VBoxContainer.new()
	left.custom_minimum_size = Vector2(240.0, 0.0)
	split.add_child(left)

	left.add_child(UiKit.button("Load Images...", _open_file_dialog))
	_discard_button = UiKit.button("Discard Selected Image",
			_discard_selected_image)
	_discard_button.disabled = true
	left.add_child(_discard_button)
	left.add_child(_set_empty_state("No images loaded."))

	_list = ItemList.new()
	_list.custom_minimum_size = Vector2(240.0, 200.0)
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list.fixed_icon_size = Vector2i(96, 96)
	_list.item_selected.connect(_on_item_selected)
	left.add_child(_list)

	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.add_child(right)

	_pane = PreviewPane.new()
	_pane.info_label.text = "No image selected"
	right.add_child(_pane)

	_file_dialog = UiKit.file_dialog(FileDialog.FILE_MODE_OPEN_FILES, [
		"*.png ; PNG images",
		"*.jpg, *.jpeg ; JPEG images",
		"*.webp ; WebP images",
		"*.bmp ; BMP images",
	], _on_files_selected)
	add_child(_file_dialog)

	_bind_run_lock([_discard_button])
	AppData.images_changed.connect(_rebuild_list)
	_rebuild_list()


func _open_file_dialog() -> void:
	_file_dialog.popup_centered_ratio(UiKit.POPUP_RATIO)


func _on_files_selected(paths: PackedStringArray) -> void:
	var last_added: ImageAssetData = null
	for path in paths:
		var asset := ImageAssetData.load_from_path(path)
		if asset == null:
			push_warning("Failed to load image: %s" % path)
			continue
		if AppData.add_image(asset):
			last_added = asset
	if last_added != null:
		var index := _find_by_metadata(_list, last_added.id)
		if index >= 0:
			_list.select(index)
			_on_item_selected(index)


func _rebuild_list() -> void:
	_list.clear()
	var assets := AppData.get_image_list()
	if assets.is_empty():
		_set_empty_state("No images loaded.")
	else:
		_clear_empty_state()
	for asset: ImageAssetData in assets:
		var index := _list.add_icon_item(asset.thumb)
		_list.set_item_text(index, asset.name)
		_list.set_item_metadata(index, asset.id)
	_discard_button.disabled = true


func _on_item_selected(index: int) -> void:
	_pane.preview.clear_highlight()
	var asset: ImageAssetData = AppData.images[_list.get_item_metadata(index)]
	_pane.show_texture(asset.texture)
	_pane.info_label.text = "%s  (%d × %d)" % [
		asset.name, asset.image.get_width(), asset.image.get_height()]
	_discard_button.disabled = RunMonitor.has_running()


func _discard_selected_image() -> void:
	var selected := _list.get_selected_items()
	if selected.is_empty():
		return
	var image_id: String = _list.get_item_metadata(selected[0])
	UiKit.confirm(self, "Discard Image",
			"Discard \"%s\"?\n\nThe image is removed from the project. "
			+ "This cannot be undone." % AppData.image_name(image_id),
			"Discard", func() -> void:
				AppData.remove_image(image_id)
				_pane.show_texture(null)
				_pane.info_label.text = "No image selected"
	).popup_centered()


## Cross-tab API: show this image and flash-highlight a region of it,
## in image pixel coordinates. Returns false if the image isn't loaded.
func show_occurrence(image_id: String, position: Vector2i, region_size: Vector2i) -> bool:
	var index := _find_by_metadata(_list, image_id)
	if index < 0:
		return false
	_list.select(index)
	_on_item_selected(index)
	_pane.preview.flash_highlight(Rect2i(position, region_size))
	# In 1:1 mode the image is bigger than the viewport; scroll the
	# highlighted region roughly to center.
	_pane.scroll_to_region(Rect2i(position, region_size))
	return true
