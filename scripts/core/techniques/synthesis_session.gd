class_name SynthesisSession extends RefCounted
## A resumable synthesis run, advanced in discrete increments so a UI can
## play, pause, and single-step it. Driven from the main thread.

enum Phase { RUNNING, DONE, FAILED }

var phase := Phase.RUNNING


## Advance one atomic unit of work. Returns false once finished.
func step() -> bool:
	return false


## Finest-grained advance (e.g. a single propagation operation).
## Defaults to step() for synthesizers without sub-steps.
func micro_step() -> bool:
	return step()


func is_finished() -> bool:
	return phase != Phase.RUNNING


## Same shape as Synthesizer.synthesize()'s return; {} until DONE.
func get_result() -> Dictionary:
	return {}


func get_status() -> String:
	return ""


func get_progress() -> float:
	return 0.0


## Partial-state render, or null if unsupported.
func get_preview() -> Image:
	return null


## Optional diagnostic render (e.g. candidate-count heatmap), or null.
func get_entropy_image() -> Image:
	return null
