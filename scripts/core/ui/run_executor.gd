class_name RunExecutor extends RefCounted
## The run-launching choreography shared by the tabs: begin_run → disable
## buttons → status text → WorkerThreadPool task → deferred publish →
## terminal RunMonitor call + re-enable. API is shaped around the common
## skeleton, not a forcing of every variant through one template —
## multi-stage flows keep their stage bookkeeping in their own callables.

class RunSpec extends RefCounted:
	## Data for RunMonitor.begin_run. The `thread` arg is deliberately
	## absent: launch always passes "worker" (the interactive session's
	## "main"-thread run is out of scope).
	var kind: String
	var title: String
	var technique_id: String
	var params: Dictionary
	var inputs: Array
	var stage_plan: Array


	func _init(p_kind: String, p_title: String, p_technique_id: String,
			p_params: Dictionary, p_inputs: Array, p_stage_plan: Array = []) -> void:
		kind = p_kind
		title = p_title
		technique_id = p_technique_id
		params = p_params
		inputs = p_inputs
		stage_plan = p_stage_plan


## Begins the run, disables `buttons`, shows "Running…" on `status`
## (nullable), and queues the worker. `worker(run_id)` runs on a pool
## thread and returns the result; `publish(result, run_id)` is called
## deferred on the main thread and owns stage completion and
## finish/fail. Returns the run id.
static func launch(owner: Control, buttons: Array[Button], status: Label,
		spec: RunSpec, worker: Callable, publish: Callable) -> int:
	var run_id: int = RunMonitor.begin_run(spec.kind, spec.title,
			spec.technique_id, spec.params, spec.inputs, "worker",
			spec.stage_plan)
	for button in buttons:
		button.disabled = true
	if status != null:
		status.text = "Running…"
	WorkerThreadPool.add_task(func() -> void:
		var result: Variant = worker.call(run_id)
		publish.call_deferred(result, run_id))
	return run_id


## Continues an existing run with another worker task (same run id); used
## by multi-stage flows that must hop back to the main thread in between
## (decomposition's materialize step). `publish(result)` is called
## deferred on the main thread.
static func continue_run(worker: Callable, publish: Callable) -> void:
	WorkerThreadPool.add_task(func() -> void:
		var result: Variant = worker.call()
		publish.call_deferred(result))


## Terminal success: re-enables the run buttons and records the finish.
static func complete(buttons: Array[Button], run_id: int,
		stats: Dictionary, summary: String) -> void:
	for button in buttons:
		button.disabled = false
	RunMonitor.finish_run(run_id, stats, summary)


## Terminal failure: re-enables the run buttons and records the failure.
static func fail(buttons: Array[Button], run_id: int, error: String) -> void:
	for button in buttons:
		button.disabled = false
	RunMonitor.fail_run(run_id, error)
