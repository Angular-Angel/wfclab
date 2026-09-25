@abstract class_name Synthesizer extends TechniqueBase
## Contract for synthesizers, mirroring the technique pattern. Stateless:
## all inputs arrive as arguments; determinism comes from the caller's rng.

## Returns {image: Image, stats: Dictionary}, or {} on failure.
## report_progress(fraction) may be called from a worker thread.
@abstract func synthesize(index: ConstraintIndex, params: Dictionary,
		rng: RandomNumberGenerator, report_progress: Callable) -> Dictionary


## --- Interactive stepping (optional) ----------------------------------------
## Synthesizers that can advance incrementally override these. A session must
## produce the same result as synthesize() for the same arguments and rng
## state, so batch and stepped runs stay interchangeable.

## Whether create_session() is available for this technique.
func supports_stepping() -> bool:
	return false


## A resumable run driven from the main thread. Only called when
## supports_stepping() is true; the synthesizer itself stays stateless.
func create_session(_index: ConstraintIndex, _params: Dictionary,
		_rng: RandomNumberGenerator) -> SynthesisSession:
	return null
