extends Node
## Central registry of technique runs, shown in the Monitor tab.
## All mutations are marshalled to the main thread via call_deferred, so
## worker threads can report safely through the Callables made by
## make_recorder(). Reads (get_run_list/get_run) are main-thread only and
## return the live records — treat them as read-only.

signal runs_changed

var revision := 0                 # bumped on every record mutation

var _runs: Dictionary = {}        # int id -> record Dictionary
var _next_id := 1


# --- Lifecycle (main thread) ---------------------------------------------------

func begin_run(kind: String, title: String, technique_id: String,
		params: Dictionary, inputs: Array, thread: String,
		stage_plan: Array = []) -> int:
	## kind: "decomposition" | "constraints" | "synthesis" | "session".
	## stage_plan: optional Array of {key, label} declaring the stages up
	## front so overall progress math stays monotonic as stages begin.
	var id := _next_id
	_next_id += 1
	var stages: Array = []
	for step: Dictionary in stage_plan:
		stages.append({
			"key": String(step.get("key", "")),
			"label": String(step.get("label", step.get("key", ""))),
			"status": "pending", "started_ms": 0, "ended_ms": 0,
			"fraction": 0.0, "note": "",
		})
	_runs[id] = {
		"id": id, "kind": kind, "title": title,
		"technique_id": technique_id,
		"params": params.duplicate(true),
		"inputs": inputs.duplicate(true),
		"thread": thread,
		"status": "running", "stages": stages, "current_stage": "",
		"progress": 0.0, "stats": {}, "summary": "", "error": "",
		"live_status": "", "steps": 0,
		"started_ms": Time.get_ticks_msec(), "ended_ms": 0, "rev": 1,
	}
	_bump()
	return id


## A thread-safe report_progress(fraction) Callable bound to one stage.
## Time-throttled at the source (batch solvers can report every step);
## the stage is created on first report if it was not in the plan.
func make_recorder(run_id: int, stage_key: String) -> Callable:
	var throttle := {"last_ms": 0}   # dict: captured by reference, so the
	return func(fraction: float) -> void:   # worker's updates persist here
		var now := Time.get_ticks_msec()
		if fraction < 1.0 and now - int(throttle["last_ms"]) < 60:
			return
		throttle["last_ms"] = now
		_report_fraction.call_deferred(
				run_id, stage_key, clampf(fraction, 0.0, 1.0))


# --- Thread-safe mutators (defer to main thread) --------------------------------

func begin_stage(run_id: int, stage_key: String, label: String,
		started_ms: int = -1) -> void:
	## started_ms: explicit timestamp for synchronous stages whose deferred
	## begin would otherwise execute after the work it brackets. -1 = now.
	_begin_stage.call_deferred(run_id, stage_key, label, started_ms)


func end_stage(run_id: int, stage_key: String, note: String,
		ended_ms: int = -1) -> void:
	## ended_ms: explicit timestamp, matching begin_stage's started_ms
	## convention. -1 = now.
	_end_stage.call_deferred(run_id, stage_key, note, ended_ms)


func finish_run(run_id: int, stats: Dictionary, summary: String) -> void:
	_finish_run.call_deferred(run_id, stats.duplicate(true), summary)


func fail_run(run_id: int, error: String) -> void:
	_fail_run.call_deferred(run_id, error)


func cancel_run(run_id: int) -> void:
	_cancel_run.call_deferred(run_id)


## Live update for interactive sessions (no stage model).
func update_session(run_id: int, status_text: String, progress: float,
		steps: int) -> void:
	_update_session.call_deferred(run_id, status_text, progress, steps)


func clear_finished() -> void:
	for id in _runs.keys():   # keys() copy: dict is mutated below
		match String((_runs[id] as Dictionary).get("status", "")):
			"done", "failed", "canceled":
				_runs.erase(id)
	_bump()


# --- Reads (main thread) ---------------------------------------------------------

## Newest first. Callers must treat returned records as read-only.
func get_run_list() -> Array:
	var list: Array = _runs.values()
	list.reverse()
	return list


func get_run(id: int) -> Dictionary:
	return _runs.get(id, {})


# --- Deferred implementations ------------------------------------------------------

func _begin_stage(run_id: int, stage_key: String, label: String,
		started_ms: int) -> void:
	var r := _record(run_id)
	if r.is_empty():
		return
	var s := _find_or_create_stage(r, stage_key, label)
	s["status"] = "running"
	s["started_ms"] = started_ms if started_ms >= 0 else Time.get_ticks_msec()
	s["fraction"] = 0.0
	s["note"] = ""
	r["current_stage"] = stage_key
	_touch(r)


func _report_fraction(run_id: int, stage_key: String, fraction: float) -> void:
	var r := _record(run_id)
	if r.is_empty() or String(r["status"]) != "running":
		return
	var s := _find_or_create_stage(r, stage_key, stage_key)
	if String(s["status"]) != "running":
		s["status"] = "running"
		s["started_ms"] = Time.get_ticks_msec()
	s["fraction"] = fraction
	_recompute_progress(r)
	_touch(r)


func _end_stage(run_id: int, stage_key: String, note: String,
		ended_ms: int) -> void:
	var r := _record(run_id)
	if r.is_empty():
		return
	var s := _find_or_create_stage(r, stage_key, stage_key)
	if String(s["status"]) == "running":
		s["status"] = "done"
		s["ended_ms"] = ended_ms if ended_ms >= 0 else Time.get_ticks_msec()
	if not note.is_empty():
		s["note"] = note
	if String(r["current_stage"]) == stage_key:
		r["current_stage"] = ""
	_recompute_progress(r)
	_touch(r)


func _finish_run(run_id: int, stats: Dictionary, summary: String) -> void:
	var r := _record(run_id)
	if r.is_empty():
		return
	var now := Time.get_ticks_msec()
	for s: Dictionary in r["stages"]:
		if String(s["status"]) == "running":
			s["status"] = "done"
			s["ended_ms"] = now
	r["status"] = "done"
	r["current_stage"] = ""
	r["progress"] = 1.0
	r["stats"] = stats
	if not summary.is_empty():
		r["summary"] = summary
	r["ended_ms"] = now
	_touch(r)


func _fail_run(run_id: int, error: String) -> void:
	var r := _record(run_id)
	if r.is_empty():
		return
	var now := Time.get_ticks_msec()
	for s: Dictionary in r["stages"]:
		match String(s["status"]):
			"running":
				s["status"] = "failed"
				s["ended_ms"] = now
			"pending":
				s["status"] = "canceled"
	r["status"] = "failed"
	r["current_stage"] = ""
	r["error"] = error
	r["ended_ms"] = now
	_touch(r)


func _cancel_run(run_id: int) -> void:
	var r := _record(run_id)
	if r.is_empty() or String(r["status"]) != "running":
		return
	var now := Time.get_ticks_msec()
	for s: Dictionary in r["stages"]:
		match String(s["status"]):
			"running":
				s["status"] = "canceled"
				s["ended_ms"] = now
			"pending":
				s["status"] = "canceled"
	r["status"] = "canceled"
	r["current_stage"] = ""
	r["ended_ms"] = now
	_touch(r)


func _update_session(run_id: int, status_text: String, progress: float,
		steps: int) -> void:
	var r := _record(run_id)
	if r.is_empty() or String(r["status"]) != "running":
		return
	r["live_status"] = status_text
	r["progress"] = clampf(progress, 0.0, 1.0)
	r["steps"] = steps
	_touch(r)


# --- Internals ---------------------------------------------------------------------

func _record(run_id: int) -> Dictionary:
	return _runs.get(run_id, {})


func _find_or_create_stage(r: Dictionary, stage_key: String,
		label: String) -> Dictionary:
	for s: Dictionary in r["stages"]:
		if s["key"] == stage_key:
			return s
	var s := {
		"key": stage_key, "label": label, "status": "pending",
		"started_ms": 0, "ended_ms": 0, "fraction": 0.0, "note": "",
	}
	(r["stages"] as Array).append(s)
	return s


func _recompute_progress(r: Dictionary) -> void:
	var stages: Array = r["stages"]
	if stages.is_empty():
		return
	var sum := 0.0
	for s: Dictionary in stages:
		match String(s["status"]):
			"done", "failed":
				sum += 1.0
			"running":
				sum += float(s["fraction"])
	r["progress"] = clampf(sum / float(stages.size()), 0.0, 1.0)


func _touch(r: Dictionary) -> void:
	r["rev"] = int(r["rev"]) + 1
	_bump()


func _bump() -> void:
	revision += 1
	runs_changed.emit()
