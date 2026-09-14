WFC Lab — Design Document (rev 2)

Project: Interactive decomposition framework for example-based procedural generation research
Engine: Godot 4.x
Status: Phase 1 — Analysis only (synthesis deferred)
0. Revision Delta (rev 1 → rev 2)

Symmetry handling is folded into the Part/Constraint model:
rev 1 concept
	
rev 2 replacement
SymmetryGroup resource	TRANSFORM_SET parameter type + transform annotation on parts
PartVariant class	A Part is a variant: Part.transform + Part.canonical_id
Orbits	Transform family: all parts sharing a canonical_id (emergent, queried like any filter)
Constraint symmetry modes (EXPLICIT/IMPLIED)	One mechanism: constraints stored canonically; families derived on demand
weight_mode (per-orbit / per-variant)	aggregate_by parameter of frequency weighting
Symmetry editor UI panel	A parameter widget (checkbox grid over D4) in the auto-generated inspector
 
 

Deleted from the codebase plan: symmetry_group.gd, part_variant.gd. Added: transform_family.gd (D4 math, canonicalization, closure validation).
1. Goals & Non-Goals

(Unchanged from rev 1.)

     Load images; decompose into Parts and Constraints via pluggable, parameterized techniques.
     Browse and live-edit every derived quantity.
     Data model ready for a future synthesis consumer.
     Adding a technique = implementing one interface + declaring parameters.

Non-goals: synthesis, 3D input, learned/interpolating decomposition.
2. Core Data Model

All Resources; cross-references by stable string ID; every derived value has an optional user override.
2.1 Project

 
Project
├── image_assets: Dictionary[String, ImageAsset]
├── pipeline_runs: Dictionary[String, PipelineRun]
└── settings
 
 
2.2 ImageAsset

 
ImageAsset
├── id, name, source_path
├── image: Image, texture: ImageTexture
├── regions_of_interest: Array[Region]
└── tags: Array[String]
 
 
2.3 Part

There is only one kind of part. A part is pixel data at a specific orientation, linked to its family:

 
Part
├── id: String
├── canonical_id: String              # points to the family's canonical part (may be self)
├── transform: Transform2D            # D4 element mapping canonical form → this part
├── hash: String                      # hash of THIS part's pixels (used for dedupe)
├── canonical_hash: String            # hash of canonical form (equal across the family)
├── pixel_data: Image                 # this orientation's pixels
├── mask: BitMap                      # non-rectangular support, if segmentation-based
├── source: { discovered_by: String, occurrences: Array[Occurrence] }
├── weight: float                     # derived, editable
├── weight_override: Variant          # NIL = use derived
└── user_flags: { enabled: bool, pinned: bool, notes: String }

 
Occurrence
├── image_id: String
├── position: Vector2i
└── transform: Transform2D            # orientation at which it was observed (identity = canonical)
 
 

Canonicalization (deterministic, important): when two parts are pixel-equal up to a D4 transform, they join one family. The canonical member is chosen as the orientation with the lexicographically minimal hash of the eight orientations — not "whichever was found first." This makes canonical_id stable across images, runs, and corpus order, which is what makes user edits, blocklists, and alias records re-attachable after recompute.

Transform family (the old "orbit"): { p ∈ parts : p.canonical_id == X }. It is a query, not a structure. The parts grid, constraint matrix, and inspector all group by it when asked. A family may contain any subset of D4 depending on the allowed-transform filter — including a single member.

Weight note: because the family is a query, "per-family vs per-part weighting" needs no separate mode flag on the model — it's purely how frequency weighting aggregates (§5.3).
2.4 Constraint

Participants reference parts directly; each part already encodes its own orientation, so no transform bookkeeping lives on the constraint:

 
Constraint
├── id: String
├── type: String                      # "adjacency", "overlap", "cooccurrence", ...
├── arity: int
├── participants: Array[{ part_id: String, role: String }]   # roles: "left", "right", "anchor", ...
├── params: Dictionary                # e.g. {"offset": Vector2i(3,0), "neighborhood": "N4"}
├── weight: float                     # derived (e.g. evidence count), editable
├── weight_override: Variant
├── evidence: Array[{ image_id: String, positions: Array[Vector2i] }]
├── origin: enum { EXTRACTED, AUTHORED, EDITED }
└── user_flags: { enabled, notes }
 
 

Symmetry of constraints — one mechanism, no modes. A constraint stores one concrete configuration of oriented parts. Applying a global transform g to a constraint maps each participant to the part with the same canonical_id and transform = t ∘ g, and transforms params (an offset of (3,0) becomes (0,3) under rot90). The constraint's family is its orbit under this action, computed on demand. Consumers (UI now, synthesis later) read "the constraint set under allowed transforms" and get the family members that survive the filter. Nothing is stored twice; nothing has an EXPLICIT/IMPLIED switch.

Note this also cleans up an old subtlety: rev 1's participant_level (variant-level vs orbit-collapsed) is now just "which parts exist after the filter" plus a display grouping — not a constraint-extraction mode.
2.5 PipelineRun

 
PipelineRun
├── id, name
├── image_ids: Array[String]
├── technique_id: String
├── parameter_set: ParameterSet       # includes the allowed-transform set
├── constraint_techniques: Array[ConstraintTechniqueConfig]
├── parts: Dictionary[String, Part]       # canonical extraction result
├── constraints: Dictionary[String, Constraint]   # stored canonically
├── materialized_view: ViewFilter          # see §4
└── status: { state, progress, errors, timing }
 
 
3. Parameter System

(Unchanged mechanism; the transform set is now just one more parameter.)

 
ParameterSpec { key, label, type, default, range/options, live_recompute, tooltip }
 

Types: INT, INT,**
4. Transform Set Parameter & The Materialized View

The single most important simplification, worth its own section.

     Decomposition techniques always compute in canonical frame: extract, canonicalize each result, dedupe by canonical_hash, record occurrences with their observed transform. The allowed-transform parameter is not consulted during extraction.
     The TRANSFORM_SET parameter (a D4 subgroup picker, rendered as the 3×3 toggle grid) defines a ViewFilter: which family members are materialized as active parts, and (by the group action of §2.4) which constraint family members are materialized as active constraints.
     Applying/changing the filter is a cheap post-pass — no image re-scan, no re-segmentation. It behaves exactly like any other IMMEDIATE parameter, which is why it no longer deserves to be a subsystem.

 
Images ─▶ Decomposition (canonical, ignore transform filter)
                │
                ▼
          Parts (all families, canonical members only)
                │
                ▼
          Constraint extraction (canonical frame)
                │
                ▼
          Materialize view (apply transform filter)
                │
                ▼
          Active parts + active constraints ─▶ UI / future synthesis
 
 

Closure requirement: the allowed-transform set must be a group (closed under composition) or family materialization behaves pathologically (a constraint's family member exists only if all its participants' transformed parts were materialized — with a non-closed set you get partial constraints). Two options, pick one: (a) the picker only exposes the 10 subgroups of D4; (b) allow arbitrary sets and auto-expand to closure with a warning. Recommend (a) — the 10 subgroups cover every practical case and the picker becomes a simple dropdown with visual previews.

Weight filter interaction: aggregate_by: CANONICAL | PART in frequency weighting (§5.3) answers the old per-orbit/per-variant question: CANONICAL gives every family member the family's aggregate weight; PART weights each member by its own occurrence count.
5. Decomposition Techniques

Same interface and same technique list as rev 1 — none of them change, because they now simply never think about symmetry (they extract, canonicalize, and emit):
gdscript
 
  
 
 
class_name DecompositionTechnique extends RefCounted
func get_id() -> StringName
func get_display_name() -> String
func get_parameter_specs() -> Array[ParameterSpec]
func decompose(images: Array[ImageAsset], params: ParameterSet,
               report_progress: Callable) -> DecompositionResult
 
 

Techniques: Grid Tiles (tile size, offset mode, stride, edge handling, dedupe, dedupe tolerance), Overlapping Windows (window size, stride, dedupe, dedupe tolerance, alpha handling), Segmentation (quantization colors/method, merge tolerance, min region area, boundary handling, snap-to-grid, output form), Quadtree (max depth, error metric, split threshold, min size, merge), Sprite/Rect Detection (background color/tolerance, gaps, size bounds). Perceptual hashing (exact/aHash/dHash/pHash) remains a shared utility used by dedupe_tolerance.

Reserved: hierarchical decomposition (a run consuming another run's parts), learned dedupe, and manual decomposition (user-drawn regions — designed as a zero-parameter technique).

Delta from rev 1: the symmetry-related note in each technique's semantics is deleted; canonicalization happens in the shared pipeline stage, not per technique.
6. Constraint Extraction Techniques

Runs after decomposition over the emitted occurrences, in canonical frame:
gdscript
 
  
 
 
class_name ConstraintTechnique extends RefCounted
func extract(run: PipelineRun, parts: Dictionary,
             report_progress: Callable) -> Array[Constraint]
 
 

     Adjacency — neighborhood (N4/N8/custom), directional, custom offsets. (rev 1's participant_level and symmetry_action parameters are deleted — both are now consequences of the view filter.)
     Overlap Compatibility — window size, exact/tolerance matching.
     Frequency Weighting — weight_source (occurrence count / image presence), normalization, and aggregate_by: CANONICAL | PART (absorbs rev 1's weight_mode).
     Co-occurrence (n-ary, reserved) — windowed n-ary constraints; model already supports arbitrary arity.

7. UI Design

Same four-region layout (image browser / main canvas / inspector, with bottom tabs: parts grid, constraint matrix, run history, console). Changes from rev 1:

     Symmetry editor is gone as a panel. The D4 subgroup picker is a TRANSFORM_SET widget inside the auto-generated parameter inspector, with a live preview strip showing a sample part under each allowed transform. Toggling it updates the materialized view immediately (cheap post-pass).
     Part view's orbit strip → family strip: thumbnails of all family members (canonical marked). Since family members are ordinary parts, this view is just the parts grid filtered by canonical_id — one widget, two uses.
     Constraint matrix: grouping dropdown gains "canonical (family-collapsed) / expanded (per part)" — again just a grouping over the same data, no special mode.
     Graph view: parts as nodes, constraints as edges; families can be drawn as grouped containers.
     Everything remains editable through the command system; provenance (EXTRACTED/AUTHORED/EDITED) shown throughout.

(Image mode overlays, occurrence highlighting, ROI editor, evidence navigation, run history and diffing: unchanged from rev 1.)
8. Cross-Cutting Systems

     Command system: unchanged — every mutation is an undoable Command; slider drags merge; undoing a parameter change re-triggers the (now simpler) recompute.
     Dirty propagation — simplified. Rev 1 had a special symmetry-change path; now there are exactly two:

 
image / technique-parameter change ─▶ re-decompose (canonical) ─▶ re-extract constraints ─▶ re-materialize
transform-filter / view change ─────▶ re-materialize only
 
 

     Persistence: unchanged — JSON project (references, parameters, user edits, aliases, blocklists, authored constraints), binary parts cache keyed by image hash + parameter digest excluding the transform filter (it doesn't affect extraction), autosave.
     Threading: unchanged — WorkerThreadPool, atomic snapshots, call_deferred publication.

9. Project Structure
 
 
res://
├── main.tscn
├── core/
│   ├── data/        image_asset.gd, part.gd, constraint.gd, pipeline_run.gd, ids.gd
│   ├── params/      parameter_spec.gd, parameter_set.gd
│   ├── commands/    command.gd, command_stack.gd
│   ├── pipeline/    scheduler.gd, persistence.gd
│   │                 (scheduler now owns: decompose → extract → materialize)
│   └── util/
│       ├── hashing.gd          # exact + perceptual
│       └── transform_family.gd # D4 math, canonicalization, family queries,
│                                # constraint group action, closure validation
├── techniques/
│   ├── decomposition/   (base + grid_tiles, overlapping_windows, segmentation,
│   │                     quadtree, sprite_rects — all symmetry-blind)
│   └── constraints/     (base + adjacency, overlap_compat, frequency_weighting)
└── ui/                  (browser, canvas views, parts grid, matrix, history,
                          inspector + auto-widgets including TRANSFORM_SET picker,
                          console)
 
 

Deleted vs rev 1: symmetry_group.gd, part_variant.gd. Everything symmetry-related now lives in transform_family.gd (pure functions) and the scheduler's materialize step.
10. Implementation Phases

     M1 — Skeleton: data model (with transform/canonical_id from day one — retrofitting this is painful), parameter system, persistence, window shell, image import. Exit: load 3 images, save/reopen.
     M2 — First end-to-end: grid tiles + adjacency, canonicalization + dedupe, parts grid, image overlay, inspector, scheduler including materialize step and TRANSFORM_SET picker (this is now cheap enough to land in M2, where rev 1 deferred symmetry to M4). Exit: change tile size → parts/constraints update; toggle the transform set → family membership updates without re-scan.
     M3 — Editing layer: commands, overrides, enable/disable, blocklist, matrix view, evidence navigation.
     M4 — Technique breadth: remaining techniques, perceptual dedupe, remaining constraint techniques, family strip/graph view.
     M5 — Polish: run diffing, ROI editor, caching, timing console.

Future — Synthesis module: consumes the materialized view of a run (active parts + active constraints, in whatever grouping the sampler wants). Canonical storage means a synthesis algorithm that exploits symmetry (store one constraint, propagate orbits) and one that doesn't (enumerate) both read the same artifact.
11. Risks & Open Questions

     Canonical-hash determinism is now load-bearing (edit re-attachment, cache keys, cross-image dedupe). Mitigation: define the canonical form by minimal hash over the full D8 orbit unconditionally — even when the allowed set is smaller — so it never depends on filter state. Test this explicitly.
     Partial families from tolerance-dedupe: with perceptual dedupe, "equal up to transform" becomes fuzzy; two orientations might dedupe to different families. Mitigation: dedupe first, canonicalize after, and accept that near-duplicate families can coexist (visible and mergeable by hand — the alias system already covers this).
     Group-action on constraint params: each constraint type must declare how params transform (offsets rotate; some params are invariant). This is a small per-type function, but forgetting it silently corrupts materialized constraints. Mitigation: Constraint type registry requires a transform_params(g) implementation to register.
     Non-rectangular masks under rotation: pixel data rotates fine; masks are bitmaps and rotate fine; but snap-to-grid parts from segmentation (§5) may not tile exactly after transform. Mitigation: document that transformed members of masked families may carry a slightly different effective footprint; surface the footprint in the family strip UI.
     Open (unchanged): authored-constraint scope (run vs project); still leaning project-level with a UI filter.
     Open (new): should the materialized view itself be a saved, named artifact (multiple views over one extraction — e.g., "D4 view" and "identity view" of the same corpus)? The architecture makes this nearly free; decide when run-diff UI lands.
