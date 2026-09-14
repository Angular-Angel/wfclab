extends Control

## Images tab: load image files, browse them, preview one. Storage lives in
## AppData; this tab is pure UI.

var _file_dialog: FileDialog
var _list: ItemList
var _preview: TextureRect
var _info: Label
var _fit_check: CheckButton


func _ready() -> void:
	var split := HSplitContainer.new()
	split.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(split)

	var left := VBoxContainer.new()
	left.custom_minimum_size = Vector2(240.0, 0.0)
	split.add_child(left)

	var load_button := Button.new()
	load_button.text = "Load Images..."
	load_button.pressed.connect(_open_file_dialog)
	left.add_child(load_button)

	_list = ItemList.new()
	_list.custom_minimum_size = Vector2(240.0, 200.0)
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list.fixed_icon_size = Vector2i(96, 96)
	_list.item_selected.connect(_on_item_selected)
	left.add_child(_list)

	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.add_child(right)

	var toolbar := HBoxContainer.new()
	right.add_child(toolbar)

	_fit_check = CheckButton.new()
	_fit_check.text = "Fit to window"
	_fit_check.button_pressed = true
	_fit_check.toggled.connect(func(_p: bool) -> void: _apply_view_mode())
	toolbar.add_child(_fit_check)

	_info = Label.new()
	_info.text = "No image selected"
	toolbar.add_child(_info)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_child(scroll)

	_preview = TextureRect.new()
	_preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_preview.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_preview.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.add_child(_preview)
	_apply_view_mode()

	_file_dialog = FileDialog.new()
	_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILES
	_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_file_dialog.filters = [
		"*.png ; PNG images",
		"*.jpg, *.jpeg ; JPEG images",
		"*.webp ; WebP images",
		"*.bmp ; BMP images",
	]
	_file_dialog.files_selected.connect(_on_files_selected)
	add_child(_file_dialog)

	AppData.images_changed.connect(_rebuild_list)
	_rebuild_list()


func _open_file_dialog() -> void:
	_file_dialog.popup_centered_ratio(0.7)


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
		var index := _index_of_asset(last_added)
		if index >= 0:
			_list.select(index)
			_on_item_selected(index)


func _rebuild_list() -> void:
	_list.clear()
	for asset: ImageAssetData in AppData.get_image_list():
		var index := _list.add_icon_item(asset.thumb)
		_list.set_item_text(index, asset.name)
		_list.set_item_metadata(index, asset.id)


func _index_of_asset(asset: ImageAssetData) -> int:
	for i in _list.item_count:
		if _list.get_item_metadata(i) == asset.id:
			return i
	return -1


func _on_item_selected(index: int) -> void:
	var asset: ImageAssetData = AppData.images[_list.get_item_metadata(index)]
	_preview.texture = asset.texture
	_apply_view_mode()
	_info.text = "%s  (%d × %d)" % [asset.name, asset.image.get_width(), asset.image.get_height()]


func _apply_view_mode() -> void:
	if _fit_check.button_pressed:
		_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		_preview.custom_minimum_size = Vector2.ZERO
	else:
		_preview.stretch_mode = TextureRect.STRETCH_KEEP
		if _preview.texture != null:
			_preview.custom_minimum_size = _preview.texture.get_size()
	_apply_filter_mode()


func _apply_filter_mode() -> void:
	if _preview.texture == null:
		return
	var tex_size := _preview.texture.get_size()
	var view_size := get_viewport_rect().size
	var upscaled := tex_size.x < view_size.x or tex_size.y < view_size.y
	_preview.texture_filter = (
		CanvasItem.TEXTURE_FILTER_NEAREST if upscaled
		else CanvasItem.TEXTURE_FILTER_LINEAR
	)
