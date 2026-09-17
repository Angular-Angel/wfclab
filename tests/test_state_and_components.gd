extends GdUnitTestSuite

const AppDataScript = preload("res://scripts/core/app_data.gd")
const TechniqueRegistryScript = preload("res://scripts/core/technique_registry.gd")


func _image(width: int, height: int, pixels: Array[Color]) -> Image:
	var image := Image.create_empty(width, height, false, Image.FORMAT_RGBA8)
	for y in height:
		for x in width:
			image.set_pixel(x, y, pixels[y * width + x])
	return image


func _asset(id_name: String, image: Image) -> ImageAssetData:
	var asset := ImageAssetData.from_image(image, id_name)
	asset.id = id_name
	return asset


func _raw_part(hash_hex: String, color: Color) -> Part:
	var part := Part.new()
	part.setup(_image(1, 1, [color]), hash_hex, "source", Vector2i.ZERO)
	part.weight = 1.0
	return part


func test_app_data_add_remove_and_number_synthesis_outputs() -> void:
	var data: Variant = auto_free(AppDataScript.new())
	data._ready()
	var asset := _asset("img_source", _image(1, 1, [Color.RED]))

	assert_bool(data.add_image(asset)).is_true()
	assert_bool(data.add_image(asset)).is_false()
	assert_that(data.image_name(asset.id)).is_equal("img_source")
	assert_bool(data.remove_image(asset.id)).is_true()
	assert_bool(data.remove_image(asset.id)).is_false()

	var output_image := _image(1, 1, [Color.BLUE])
	data.set_synthesis(output_image, {"seed": 1}, {"label": "first"})
	data.set_synthesis(output_image, {"seed": 2}, {"label": "second"})
	var output_ids: Array = data.outputs.keys()
	output_ids.sort()

	assert_that(output_ids[0]).contains("out_1_")
	assert_that(output_ids[1]).contains("out_2_")
	assert_that(data.last_synthesis["output_id"]).is_equal(output_ids[1])
	assert_that(data.get_output(output_ids[0])["stats"]).is_equal({"seed": 1})


func test_app_data_materializes_edits_and_invalidates_cached_index() -> void:
	var data: Variant = auto_free(AppDataScript.new())
	data._ready()
	var raw := _raw_part("aaaaaaaaaaaa", Color.RED)
	var raw_parts: Array[Part] = [raw]
	data.set_parts(raw_parts, {})
	var materialized: Part = data.get_part_list()[0]
	var initial_index: ConstraintIndex = data.get_constraint_index()

	data.edit_part(materialized.id, "enabled", false)
	data.edit_part(materialized.id, "weight_override", 7.5)
	data.parts_changed.emit()
	var edited_index: ConstraintIndex = data.get_constraint_index()
	assert_that(edited_index).is_not_equal(initial_index)
	assert_that(data.parts[materialized.id].get_effective_weight()).is_equal(7.5)
	assert_bool(data.parts[materialized.id].enabled).is_false()
	assert_that(edited_index.get_part_ids()).is_empty()

	var constraint := Constraint.new()
	constraint.participants = [
		{"part_id": materialized.id, "role": "a"},
		{"part_id": materialized.id, "role": "b"},
	]
	constraint.params = {"offset": Vector2i.RIGHT}
	constraint.evidence = [{"image_id": "source", "positions": []}]
	constraint.rebuild_id()
	var raw_constraints: Array[Constraint] = [constraint]
	data.set_constraints(raw_constraints)
	data.edit_constraint(constraint.id, "weight_override", 4.0)
	assert_that(data.constraints[constraint.id].get_effective_weight()).is_equal(4.0)


func test_technique_registry_registers_and_looks_up_builtins() -> void:
	var registry: Variant = auto_free(TechniqueRegistryScript.new())
	registry._ready()

	assert_that(registry.get_decomposition(&"grid_tiles")).is_instanceof(GridTiles)
	assert_that(registry.get_constraint_technique(&"adjacency")).is_instanceof(AdjacencyExtractor)
	assert_that(registry.get_synthesizer(&"tile_collapse")).is_instanceof(TileCollapse)
	assert_that(registry.get_decomposition_techniques()).has_size(1)
	assert_that(registry.get_constraint_techniques()).has_size(1)
	assert_that(registry.get_synthesizer_techniques()).has_size(1)
	assert_that(registry.get_synthesizer(&"missing")).is_null()


func test_grid_tiles_deduplicates_occurrences_and_clamps_edge_origins() -> void:
	var image := _image(3, 1, [Color.RED, Color.RED, Color.RED])
	var asset := _asset("img_grid", image)
	var result: Dictionary = GridTiles.new().decompose([asset], {
		"tile_size": Vector2i(2, 1), "stride": Vector2i(1, 1),
		"edge_handling": GridTiles.EdgeHandling.CLAMP, "dedupe": true,
	}, func(_progress: float) -> void: pass)
	var parts: Array[Part] = result["parts"]

	assert_that(result["stats"]["total_tiles"]).is_equal(3)
	assert_that(result["stats"]["part_count"]).is_equal(1)
	assert_that(parts[0].occurrence_count()).is_equal(3)
	assert_that(parts[0].occurrences[2]["position"]).is_equal(Vector2i(1, 0))


func test_grid_tiles_transforms_rotate_and_reflect_pixels() -> void:
	var source := _image(2, 2, [Color.RED, Color.GREEN, Color.BLUE, Color.WHITE])
	var rot90 := GridTiles.transform_image(source, "rot90")
	var flip_h := GridTiles.transform_image(source, "flip_h")

	assert_that(rot90.get_pixel(0, 0)).is_equal(Color.BLUE)
	assert_that(rot90.get_pixel(1, 0)).is_equal(Color.RED)
	assert_that(flip_h.get_pixel(0, 0)).is_equal(Color.GREEN)
	assert_that(flip_h.get_pixel(1, 1)).is_equal(Color.BLUE)


func test_param_builder_initializes_specs_and_tracks_control_updates() -> void:
	var box: VBoxContainer = auto_free(VBoxContainer.new())
	var values: Dictionary = {}
	ParamBuilder.build([
		{"key": "count", "label": "Count", "type": "int", "default": 2},
		{"key": "offset", "label": "Offset", "type": "vector2i", "default": Vector2i(3, 4)},
		{"key": "enabled", "label": "Enabled", "type": "bool", "default": true},
	], values, box, {"count": 5})

	assert_that(values).is_equal({"count": 5, "offset": Vector2i(3, 4), "enabled": true})
	var count_spin := box.get_child(0).get_child(1) as SpinBox
	var offset_x := box.get_child(1).get_child(1) as SpinBox
	var enabled_check := box.get_child(2).get_child(1) as CheckButton
	count_spin.value_changed.emit(9.0)
	offset_x.value_changed.emit(-2.0)
	enabled_check.toggled.emit(false)

	assert_that(values).is_equal({"count": 9, "offset": Vector2i(-2, 4), "enabled": false})
