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


# --- Manual editing & slot inspection (optional) ------------------------------
## Main-thread calls, safe between steps. Defaults make sessions without
## spatial slots inert: no editing, no geometry.

func try_assign(_slot: int, _part_id: String) -> bool:
	## Pin a part into a slot and propagate. Returns false (leaving the
	## session unchanged) if rejected or unsupported.
	return false


func try_clear(_slot: int) -> bool:
	## Remove a pin; the slot returns to a domain rebuilt from other pins.
	return false


func get_slot_domain(_slot: int) -> Dictionary:
	## Parts that could currently occupy the slot.
	return {}


func get_slot_assignment(_slot: int) -> String:
	return ""


func get_slot_dims() -> Vector2i:
	return Vector2i.ZERO


func get_slot_step() -> Vector2i:
	return Vector2i.ZERO


func get_render_size() -> Vector2i:
	return Vector2i.ZERO


func pixel_to_slot(_px: Vector2i) -> int:
	## Closest slot center to a rendered pixel, or -1 if outside.
	return -1


func slot_rect(_slot: int) -> Rect2i:
	return Rect2i()


func get_source_index() -> ConstraintIndex:
	## The snapshot this session runs against (UI should render/edit from
	## THIS, not AppData, so mid-session edits elsewhere can't skew it).
	return null
