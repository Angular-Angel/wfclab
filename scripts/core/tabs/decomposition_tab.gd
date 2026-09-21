class_name DecompositionTab extends Control
## Configure a decomposition run (plus constraint extraction) and execute it.
## The run config is a JSON-safe snapshot — it is also what project save/load
## stores and reloads.

var _technique_option: OptionButton
var _params_box: VBoxContainer
var _ct_section: VBoxContainer
var _image_list: ItemList
var _run_button: Button
var _status: Label
var _edits_label: Label

var _param_values: Dictionary = {}
var _current_technique: DecompositionTechnique

var _auto_constraints: CheckButton
var _find_button: Button

var _ct_status: Label
var _ct_enabled: Dictionary = {}   # id -> bool
var _ct_values: Dictionary = {}    # id -> params Dictionary
var _ct_checks: Dictionary = {}    # id -> CheckButton
var _ct_boxes: Dictionary = {}     # id -> VBoxContainer (param widgets)



func _ready() -> void:
	var split := HSplitContainer.new()
	split.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(split)

	# Left panel scrolls vertically: its content (technique + params +
	# constraint section + image list + run button) exceeds the window
	# at small window sizes.
	var left_scroll := ScrollContainer.new()
	left_scroll.custom_minimum_size = Vector2(320.0, 0.0)
	left_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	left_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	split.add_child(left_scroll)

	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left_scroll.add_child(left)

	left.add_child(_mk_label("Technique"))
	_technique_option = OptionButton.new()
	for technique: DecompositionTechnique in TechniqueRegistry.get_decomposition_techniques():
		_technique_option.add_item(technique.get_display_name())
		_technique_option.set_item_metadata(_technique_option.item_count - 1, technique.get_id())
	_technique_option.item_selected.connect(_on_technique_selected)
	left.add_child(_technique_option)

	left.add_child(_mk_label("Parameters"))
	_params_box = VBoxContainer.new()
	left.add_child(_params_box)

	_auto_constraints = CheckButton.new()
	_auto_constraints.text = "Immediately find constraints"
	_auto_constraints.button_pressed = true
	_auto_constraints.tooltip_text = ("When enabled, running a decomposition also "
		+ "executes the constraint techniques against the fresh parts.")
	left.add_child(_auto_constraints)

	left.add_child(_mk_label("Images (click to toggle inclusion)"))
	_image_list = ItemList.new()
	_image_list.select_mode = ItemList.SELECT_MULTI
	_image_list.custom_minimum_size = Vector2(0.0, 120.0)
	left.add_child(_image_list)
	AppData.images_changed.connect(_rebuild_image_list)
	_rebuild_image_list()

	_run_button = Button.new()
	_run_button.text = "Run Decomposition"
	_run_button.pressed.connect(_on_run_pressed)
	left.add_child(_run_button)

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	left.add_child(_status)

	_edits_label = Label.new()
	_edits_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	left.add_child(_edits_label)
	AppData.edits_changed.connect(_update_edits_label)
	_update_edits_label()

	var middle_scroll := ScrollContainer.new()
	middle_scroll.custom_minimum_size = Vector2(320.0, 0.0)
	middle_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	middle_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	middle_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	split.add_child(middle_scroll)

	var middle := VBoxContainer.new()
	middle.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	middle_scroll.add_child(middle)

	middle.add_child(_mk_label("Constraint Extraction"))
	_ct_section = VBoxContainer.new()
	middle.add_child(_ct_section)
	for ct: ConstraintTechnique in TechniqueRegistry.get_constraint_techniques():
		var check := CheckButton.new()
		check.text = ct.get_display_name()
		check.button_pressed = true
		check.toggled.connect(_on_ct_toggled.bind(ct.get_id()))
		_ct_section.add_child(check)
		var box := VBoxContainer.new()
		box.add_theme_constant_override("margin_left", 16)
		_ct_section.add_child(box)
		_ct_checks[ct.get_id()] = check
		_ct_boxes[ct.get_id()] = box
		_ct_enabled[ct.get_id()] = true
		_ct_values[ct.get_id()] = {}
		ParamBuilder.build(ct.get_parameter_specs(), _ct_values[ct.get_id()], box)

	_find_button = Button.new()
	_find_button.text = "Find Constraints"
	_find_button.disabled = true
	_find_button.pressed.connect(_on_find_constraints_pressed)
	middle.add_child(_find_button)
	_ct_status = Label.new()
	_ct_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	middle.add_child(_ct_status)
	AppData.parts_changed.connect(_update_find_button)
	_update_find_button()

	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.add_child(right)
	right.add_child(_mk_label("Last Run"))

	if _technique_option.item_count > 0:
		_technique_option.select(0)
		_on_technique_selected(0)


func _mk_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l


func _update_edits_label() -> void:
	_edits_label.text = "Edits: %d parts, %d constraints, %d merges" % [
		AppData.part_edits.size(),
		AppData.constraint_edits.size(),
		AppData.alias_records.size()]


func _on_ct_toggled(pressed: bool, tech_id: StringName) -> void:
	_ct_enabled[tech_id] = pressed


# --- Technique / image list handling --------------------------------------------

func _on_technique_selected(index: int, initial_params: Dictionary = {}) -> void:
	var id: StringName = _technique_option.get_item_metadata(index)
	_current_technique = TechniqueRegistry.get_decomposition(id)
	for child in _params_box.get_children():
		child.free()
	_param_values = {}
	ParamBuilder.build(_current_technique.get_parameter_specs(), _param_values, _params_box, initial_params)


func _rebuild_image_list() -> void:
	_image_list.clear()
	for asset: ImageAssetData in AppData.get_image_list():
		var index := _image_list.add_item(asset.name)
		_image_list.set_item_metadata(index, asset.id)
		_image_list.select(index)


func _selected_image_ids() -> Array:
	var ids: Array = []
	for index in _image_list.get_selected_items():
		ids.append(_image_list.get_item_metadata(index))
	return ids


# --- Config apply / run -----------------------------------------------------------

func apply_config(config: Dictionary) -> void:
	## Sync all widgets from a stored (e.g. loaded) run config.
	var tech_id := StringName(String(config.get("technique_id", "")))
	for i in _technique_option.item_count:
		if _technique_option.get_item_metadata(i) == tech_id:
			_technique_option.select(i)
			_on_technique_selected(i, config.get("params", {}))
			break

	var job_params: Dictionary = {}
	for job: Dictionary in config.get("constraint_jobs", []):
		job_params[job.get("id", "")] = job.get("params", {})
	for ct: ConstraintTechnique in TechniqueRegistry.get_constraint_techniques():
		var ct_id := String(ct.get_id())
		var is_on: bool = job_params.has(ct_id)
		(_ct_checks[ct.get_id()] as CheckButton).set_pressed_no_signal(is_on)
		_ct_enabled[ct.get_id()] = is_on
		var box: VBoxContainer = _ct_boxes[ct.get_id()]
		for child in box.get_children():
			child.free()
		_ct_values[ct.get_id()] = {}
		ParamBuilder.build(ct.get_parameter_specs(), _ct_values[ct.get_id()], box, job_params.get(ct_id, {}))

	var include: Array = config.get("image_ids", [])
	for i in _image_list.item_count:
		if include.has(_image_list.get_item_metadata(i)):
			_image_list.select(i)
		else:
			_image_list.deselect(i)
			
	_auto_constraints.set_pressed_no_signal(config.get("auto_constraints", true))


func run_config(config: Dictionary) -> void:
	apply_config(config)
	_run_with(config)


func _on_run_pressed() -> void:
	if _current_technique == null:
		return
	var config := {
		"technique_id": String(_current_technique.get_id()),
		"params": _param_values.duplicate(true),
		"image_ids": _selected_image_ids(),
		"constraint_jobs": _collect_constraint_jobs(),
		"constraints_ran": _auto_constraints.button_pressed,
		"auto_constraints": _auto_constraints.button_pressed,
	}
	_run_with(config)


func _run_with(config: Dictionary) -> void:
	var run_images: Array[ImageAssetData] = []
	for id in config.get("image_ids", []):
		if AppData.images.has(id):
			run_images.append(AppData.images[id])
	if run_images.is_empty():
		_status.text = "No images selected."
		return
	var technique := TechniqueRegistry.get_decomposition(
		StringName(String(config.get("technique_id", ""))))
	if technique == null:
		_status.text = "Unknown technique."
		return

	var ct_jobs: Array = []
	for job: Dictionary in config.get("constraint_jobs", []):
		var t := TechniqueRegistry.get_constraint_technique(
			StringName(String(job.get("id", ""))))
		if t != null:
			ct_jobs.append({
				"technique": t,
				"params": (job.get("params", {}) as Dictionary).duplicate(true),
			})

	var params: Dictionary = (config.get("params", {}) as Dictionary).duplicate(true)
	var snapshot: Dictionary = config.duplicate(true)

	# --- Monitor bookkeeping (main thread) ---
	var constraints_planned: bool = config.get("constraints_ran", true)
	var stage_plan: Array = [{"key": "decompose", "label": "Decompose"}]
	if constraints_planned:
		for job: Dictionary in ct_jobs:
			var ct: ConstraintTechnique = job["technique"]
			stage_plan.append({
				"key": "ct_%s" % String(ct.get_id()),
				"label": ct.get_display_name(),
			})
	stage_plan.append({"key": "publish", "label": "Publish"})
	var input_names: Array = []
	for asset: ImageAssetData in run_images:
		input_names.append(asset.name)
	var run_id := RunMonitor.begin_run("decomposition",
			"%s — decomposition" % technique.get_display_name(),
			String(technique.get_id()), params, input_names, "worker",
			stage_plan)
	var decompose_rec := RunMonitor.make_recorder(run_id, "decompose")

	_run_button.disabled = true
	_status.text = "Running..."

	WorkerThreadPool.add_task(func() -> void:
		var t0 := Time.get_ticks_msec()
		RunMonitor.begin_stage(run_id, "decompose", "Decompose", t0)
		var result: Dictionary = technique.decompose(run_images, params, decompose_rec)
		var t1 := Time.get_ticks_msec()
		if result.is_empty():
			RunMonitor.end_stage(run_id, "decompose", "returned no result", t1)
			_publish_result.call_deferred(result, [], snapshot, run_id)
			return
		var raw_parts: Array = result["parts"]
		var stats: Dictionary = result["stats"]
		RunMonitor.end_stage(run_id, "decompose",
				"%d tiles → %d raw parts" % [
					int(stats.get("total_tiles", 0)), raw_parts.size()], t1)
		var all_constraints: Array[Constraint] = []
		if constraints_planned:
			for job: Dictionary in ct_jobs:
				var ct: ConstraintTechnique = job["technique"]
				var key := "ct_%s" % String(ct.get_id())
				RunMonitor.begin_stage(run_id, key, ct.get_display_name(),
						Time.get_ticks_msec())
				var cs: Array[Constraint] = ct.extract(
					result["parts"], run_images, job["params"],
					RunMonitor.make_recorder(run_id, key))
				RunMonitor.end_stage(run_id, key,
						"%d constraints" % cs.size(), Time.get_ticks_msec())
				all_constraints.append_array(cs)
		_publish_result.call_deferred(result, all_constraints, snapshot, run_id)
	)

func _collect_constraint_jobs() -> Array:
	var jobs: Array = []
	for ct: ConstraintTechnique in TechniqueRegistry.get_constraint_techniques():
		if _ct_enabled.get(ct.get_id(), false):
			jobs.append({
				"id": String(ct.get_id()),
				"params": (_ct_values[ct.get_id()] as Dictionary).duplicate(true),
			})
	return jobs


func _update_find_button() -> void:
	_find_button.disabled = AppData.get_part_list().is_empty()


func _publish_result(result: Dictionary, all_constraints: Array[Constraint],
		config: Dictionary, run_id: int) -> void:
	_run_button.disabled = false
	if result.is_empty():
		_status.text = "Run failed (see console)."
		RunMonitor.fail_run(run_id, "decompose() returned no result.")
		return
	var t0 := Time.get_ticks_msec()
	RunMonitor.begin_stage(run_id, "publish", "Publish", t0)
	var stats: Dictionary = result["stats"]
	AppData.last_run_config = config
	var t_parts := Time.get_ticks_msec()
	AppData.set_parts(result["parts"], stats)
	var t_constraints := Time.get_ticks_msec()
	if not all_constraints.is_empty():
		AppData.set_constraints(all_constraints)
	var t_end := Time.get_ticks_msec()
	# Materialized counts reflect the transform expansion, merges, and edit
	# application — the numbers the Parts/Constraints tabs actually show.
	# (AppData.last_run_stats aliases this dict, so it gains these keys too.)
	stats["materialized_parts"] = AppData.parts.size()
	if not all_constraints.is_empty():
		stats["materialized_constraints"] = AppData.constraints.size()
	RunMonitor.end_stage(run_id, "publish",
			"set_parts %d ms · set_constraints %d ms" % [
				t_constraints - t_parts, t_end - t_constraints],
			t_end)
	RunMonitor.finish_run(run_id, stats,
			"Done: %d tiles → %d raw parts → %d parts, %d constraints" % [
				stats["total_tiles"], stats["part_count"],
				int(stats["materialized_parts"]), all_constraints.size()])
	_status.text = "Done: %d tiles → %d parts, %d constraints (%d ms)" % [
		stats["total_tiles"], stats["part_count"],
		all_constraints.size(), stats["elapsed_ms"]]

	var tabs := get_parent() as TabContainer
	if tabs != null:
		var target

		if not all_constraints.is_empty():
			target = tabs.get_node_or_null("Constraints")
		else:
			target = tabs.get_node_or_null("Parts")

		if target != null:
			tabs.current_tab = tabs.get_tab_idx_from_control(target)


func _on_find_constraints_pressed() -> void:
	var parts := AppData.get_part_list()
	if parts.is_empty():
		return
	var jobs := _collect_constraint_jobs()
	var corpus_ids: Array = AppData.last_run_config.get("image_ids", [])
	var run_images: Array[ImageAssetData] = []
	for id in corpus_ids:
		if AppData.images.has(id):
			run_images.append(AppData.images[id])
	if run_images.is_empty():
		run_images = AppData.get_image_list()
	if run_images.is_empty():
		_ct_status.text = "No images available."
		return
	var resolved: Array = []
	for job: Dictionary in jobs:
		var t := TechniqueRegistry.get_constraint_technique(StringName(String(job["id"])))
		if t != null:
			resolved.append({"technique": t,
				"params": (job["params"] as Dictionary).duplicate(true)})
	if resolved.is_empty():
		_ct_status.text = "No constraint techniques enabled."
		return
	# Keep the stored config in sync so edit-triggered regeneration and
	# project save/load reflect exactly what this button is about to do.
	if not AppData.last_run_config.is_empty():
		AppData.last_run_config["constraint_jobs"] = jobs
		AppData.last_run_config["constraints_ran"] = true

	# --- Monitor bookkeeping (main thread) ---
	var input_names: Array = []
	for asset: ImageAssetData in run_images:
		input_names.append(asset.name)
	var job_names: Array = []
	var stage_plan: Array = []
	for job: Dictionary in resolved:
		var ct: ConstraintTechnique = job["technique"]
		job_names.append(ct.get_display_name())
		stage_plan.append({
			"key": "find_%s" % String(ct.get_id()),
			"label": ct.get_display_name(),
		})
	stage_plan.append({"key": "publish", "label": "Publish"})
	var run_id := RunMonitor.begin_run("constraints",
			"Constraint extraction — %s" % ", ".join(PackedStringArray(job_names)),
			String((resolved[0]["technique"] as ConstraintTechnique).get_id()),
			{}, input_names, "worker", stage_plan)

	_find_button.disabled = true
	_ct_status.text = "Extracting..."
	WorkerThreadPool.add_task(func() -> void:
		var all_constraints: Array[Constraint] = []
		for job: Dictionary in resolved:
			var ct: ConstraintTechnique = job["technique"]
			var key := "find_%s" % String(ct.get_id())
			RunMonitor.begin_stage(run_id, key, ct.get_display_name(),
					Time.get_ticks_msec())
			all_constraints.append_array(ct.extract(
				parts, run_images, job["params"],
				RunMonitor.make_recorder(run_id, key)))
			RunMonitor.end_stage(run_id, key, "", Time.get_ticks_msec())
		_publish_constraints.call_deferred(all_constraints, run_id)
	)


func _publish_constraints(all_constraints: Array[Constraint], run_id: int) -> void:
	_update_find_button()
	var t0 := Time.get_ticks_msec()
	RunMonitor.begin_stage(run_id, "publish", "Publish", t0)
	AppData.set_constraints(all_constraints)
	var t_end := Time.get_ticks_msec()
	RunMonitor.end_stage(run_id, "publish",
			"set_constraints %d ms → %d materialized" % [
				t_end - t0, AppData.constraints.size()], t_end)
	RunMonitor.finish_run(run_id, {"constraint_count": all_constraints.size()},
			"Found %d constraints (%d materialized)." % [
				all_constraints.size(), AppData.constraints.size()])
	_ct_status.text = "Found %d constraints." % all_constraints.size()
	var tabs := get_parent() as TabContainer
	if tabs != null:
		var target := tabs.get_node_or_null("Constraints")
		if target != null:
			tabs.current_tab = tabs.get_tab_idx_from_control(target)
