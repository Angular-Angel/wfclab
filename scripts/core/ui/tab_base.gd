@abstract class_name TabBase extends Control
## Shared tab lifecycle and rebuild machinery: the per-tab status line, the
## HSplit shell, debounced rebuilds, selection-retain helpers, and the
## empty-state hooks the standardized hints build on. Tabs call
## super._ready() first, then build their content.


## The per-tab status line. Created here so every tab names it the same;
## each tab places it in its own layout (tabs without a status line simply
## never add it).
var status: Label

var _rebuild_timer: Timer
var _empty_label: Label
var _run_lock_buttons: Array[Button] = []


func _ready() -> void:
	status = UiKit.status_label("")


## The tab-root shell, so every tab's split comes from one factory.
func _build_shell() -> HSplitContainer:
	var split := UiKit.split_shell()
	add_child(split)
	return split


## Debounced rebuild: dragging a SpinBox fires many edits per second, and
## each would otherwise rebuild the whole tab. Callers connect their change
## signals to `func() -> void: _debounce_rebuild(_rebuild)`; the first call
## creates the one-shot timer, later calls restart it.
func _debounce_rebuild(fn: Callable) -> void:
	if _rebuild_timer == null:
		_rebuild_timer = Timer.new()
		_rebuild_timer.one_shot = true
		_rebuild_timer.wait_time = UiKit.DEBOUNCE_S
		_rebuild_timer.timeout.connect(fn)
		add_child(_rebuild_timer)
	_rebuild_timer.start()


func _find_by_metadata(list: ItemList, id: Variant) -> int:
	for i in list.item_count:
		if list.get_item_metadata(i) == id:
			return i
	return -1


## Selection-preserved-across-rebuild: snapshots the selected item's
## metadata, lets `rebuild` clear and refill the list, then re-selects the
## item carrying that metadata. Tabs needing extra behavior on re-select
## (e.g. refreshing a detail pane) pair _find_by_metadata with their own
## select handler instead.
func _retain_selection(list: ItemList, rebuild: Callable) -> void:
	var selected := list.get_selected_items()
	var keep: Variant = list.get_item_metadata(selected[0]) \
			if not selected.is_empty() else null
	rebuild.call()
	if keep == null:
		return
	var index := _find_by_metadata(list, keep)
	if index != -1:
		list.select(index)


## Standardized empty-state hint. The label is created lazily and reused:
## place it in the layout once (add_child of the returned label) where the
## hint belongs; later calls update its text in place. Hosts that rebuild
## their containers and free the label call _release_empty_state() first,
## then re-add the fresh label returned here.
func _set_empty_state(text: String) -> Label:
	if _empty_label == null or not is_instance_valid(_empty_label):
		_empty_label = UiKit.note(text)
	_empty_label.text = text
	_empty_label.show()
	return _empty_label


func _clear_empty_state() -> void:
	if _empty_label != null and is_instance_valid(_empty_label):
		_empty_label.hide()


## Forgets the cached empty-state label (it lives inside a container the
## host is about to rebuild).
func _release_empty_state() -> void:
	_empty_label = null


## R20 global run lock: the given AppData-mutating buttons are disabled
## while ANY monitored run is active. Bind once in _ready, after the
## buttons exist. Non-button widgets (SpinBox/LineEdit, per-row dynamic
## buttons) consult RunMonitor.has_running() at their refresh sites.
func _bind_run_lock(buttons: Array[Button]) -> void:
	_run_lock_buttons.append_array(buttons)
	if not RunMonitor.busy_changed.is_connected(_apply_run_lock):
		RunMonitor.busy_changed.connect(_apply_run_lock)
	_apply_run_lock()


func _apply_run_lock() -> void:
	var busy := RunMonitor.has_running()
	for button in _run_lock_buttons:
		button.disabled = busy


## Focus the sibling tab by its page name (main.gd names each page after
## TAB_NAMES). Used after a run publishes to jump where the results are.
func switch_to_tab(tab_name: String) -> void:
	var tabs := get_parent() as TabContainer
	if tabs == null:
		return
	var target := tabs.get_node_or_null(NodePath(tab_name))
	if target != null:
		tabs.current_tab = tabs.get_tab_idx_from_control(target)
