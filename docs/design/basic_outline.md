# WFC Lab — Design Document (rev 3)

Project: Interactive decomposition framework for example-based procedural generation research  
Engine: Godot 4.x  
Status: **Mixed** — Phase 1 (analysis) is largely implemented; synthesis exists in code despite being deferred in rev 2; several rev 2 abstractions are not yet implemented.

> **Reading note:** This revision keeps the rev 2 content but annotates every section with its implementation status against the current codebase. Status tags:
>
> - **[IMPLEMENTED]** — present and matches the spec closely.
> - **[DIFFERS]** — present but with different types, names, or signatures.
> - **[PARTIAL]** — some of the spec exists; the rest does not.
> - **[NOT IMPLEMENTED]** — described in the design, absent from the code.
> - **[AHEAD]** — code has something the design deferred or excluded.
> - **[UNVERIFIED]** — could not confirm against the code in the last review.

---

## 0. Revision Delta

### 0.1 rev 1 → rev 2 (unchanged from rev 2 doc)

Symmetry handling folded into the Part/Constraint model:

| rev 1 concept | rev 2 replacement |
|---|---|
| SymmetryGroup resource | TRANSFORM_SET parameter type + transform annotation on parts |
| PartVariant class | A Part is a variant: `Part.transform` + `Part.canonical_id` |
| Orbits | Transform family: parts sharing a `canonical_id` (emergent, queried) |
| Constraint symmetry modes (EXPLICIT/IMPLIED) | One mechanism: constraints stored canonically; families derived on demand |
| weight_mode (per-orbit / per-variant) | `aggregate_by` parameter of frequency weighting |
| Symmetry editor UI panel | A parameter widget (checkbox grid over D4) in the auto-generated inspector |

Deleted from the codebase plan: `symmetry_group.gd`, `part_variant.gd`.  
Added: `transform_family.gd` (D4 math, canonicalization, closure validation).

### 0.2 rev 2 → rev 3 (new)

This revision reconciles the design with the current implementation. Key changes:

- **Synthesis is no longer deferred.** A `TileCollapse` synthesis technique exists in code. This revision moves synthesis from “non-goal / future” to “partially present,” and reclassifies the non-goal list accordingly.
- **`PipelineRun` is not the state container in code.** State is held by `AppData`, using dictionaries for parts and constraints. This revision notes this and leaves the `PipelineRun` abstraction as a target.
- **`ParameterSpec` is not a class in code.** Parameter specs are plain `Dictionary` objects returned by `get_parameter_specs()`. No `live_recompute` or `tooltip` support exists yet.
- **`TRANSFORM_SET` is not implemented.** `GridTiles` exposes individual boolean parameters per D4 element instead of a single subgroup picker. No materialized view / `ViewFilter` exists.
- **Transform representation differs.** The code uses string keys (e.g. `"rot90"`) plus a `transform_sources` array, not `Transform2D` fields.
- **No `transform_family.gd`.** Transform handling is embedded in `Part` and `AdjacencyExtractor`.
- **Technique interfaces differ.** Code uses `ImageAssetData` and `Dictionary` where the design uses `ImageAsset` and `ParameterSet`.
- **Project layout differs.** Source lives under `scripts/core/...`, not `res://core/...`.
- **Type list typo fixed.** rev 2’s “Types: INT, INT,**” was truncated; the intended list is restored below as a placeholder pending the original enumeration.

---

## 1. Goals & Non-Goals

**[PARTIAL]**

### Goals

- Load images; decompose into Parts and Constraints via pluggable, parameterized techniques. **[IMPLEMENTED]**
- Browse and live-edit every derived quantity. **[PARTIAL]** — editing layer exists in part; full live-edit surface not confirmed.
- Data model ready for a future synthesis consumer. **[AHEAD]** — synthesis consumer already exists (`TileCollapse`).
- Adding a technique = implementing one interface + declaring parameters. **[DIFFERS]** — interface exists but with different signatures; parameters are dictionaries, not `ParameterSpec` objects.

### Non-Goals (rev 2)

- Synthesis — **[AHEAD]**: code includes `TileCollapse`.
- 3D input — **[UNVERIFIED]**
- Learned / interpolating decomposition — **[UNVERIFIED]**

---

## 2. Core Data Model

**[PARTIAL]** — the shapes below are the design target. See per-section tags for what the code actually does.

All Resources; cross-references by stable string ID; every derived value has an optional user override.

### 2.1 Project

**[DIFFERS]** — no `Project` resource; state is held by `AppData`.

```
Project
├── image_assets: Dictionary[String, ImageAsset]
├── pipeline_runs: Dictionary[String, PipelineRun]
└── settings
```

### 2.2 ImageAsset

**[UNVERIFIED]** — the code uses `ImageAssetData` in technique signatures. Whether a distinct `ImageAsset` resource exists, and whether it matches this shape, was not confirmed.

```
ImageAsset
├── id, name, source_path
├── image: Image, texture: ImageTexture
├── regions_of_interest: Array[Region]
└── tags: Array[String]
```

### 2.3 Part

**[DIFFERS]** — the code has a `Part` class (`scripts/core/data/part.gd`) but it does **not** match this shape:

- No `mask` field.
- Occurrences stored directly in an `occurrences` array, without the `discovered_by` wrapper.
- Transform represented as a `transform_key` string (e.g. `"rot90"`) plus a `transform_sources` array, not a `Transform2D`.
- Uses separate `enabled` and `notes` variables instead of a `user_flags` dictionary.

Design target:

```
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
```

```
Occurrence
├── image_id: String
├── position: Vector2i
└── transform: Transform2D            # orientation at which it was observed (identity = canonical)
```

**Canonicalization** (deterministic, load-bearing): when two parts are pixel-equal up to a D4 transform, they join one family. The canonical member is the orientation with the lexicographically minimal hash of the eight orientations — not “whichever was found first.” This makes `canonical_id` stable across images, runs, and corpus order. **[UNVERIFIED / likely NOT IMPLEMENTED as specified]**

**Transform family** (the old “orbit”): `{ p ∈ parts : p.canonical_id == X }`. A query, not a structure. **[NOT IMPLEMENTED as a distinct query layer]**

**Weight note:** per-family vs per-part weighting is a matter of how frequency weighting aggregates (§5.3), not a model flag.

### 2.4 Constraint

**[DIFFERS]** — the code has a `Constraint` class (`scripts/core/data/constraint.gd`) but:

- No `arity` field.
- Uses a direct `enabled: bool` variable instead of `user_flags`.

Design target:

```
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
```

**Symmetry of constraints — one mechanism, no modes.** A constraint stores one concrete configuration of oriented parts. Applying a global transform `g` maps each participant to the part with the same `canonical_id` and `transform = t ∘ g`, and transforms params. The constraint’s family is its orbit under this action, computed on demand. **[NOT IMPLEMENTED]**

### 2.5 PipelineRun

**[NOT IMPLEMENTED]** — no `PipelineRun` class exists. State is managed by `AppData` (`scripts/core/app_data.gd`), using dictionaries for parts and constraints.

Design target:

```
PipelineRun
├── id, name
├── image_ids: Array[String]
├── technique_id: String
├── parameter_set: ParameterSet       # includes the allowed-transform set
├── constraint_techniques: Array[ConstraintTechniqueConfig]
├── parts: Dictionary[String, Part]              # canonical extraction result
├── constraints: Dictionary[String, Constraint]  # stored canonically
├── materialized_view: ViewFilter                # see §4
└── status: { state, progress, errors, timing }
```

---

## 3. Parameter System

**[DIFFERS]** — no `ParameterSpec` class exists. Specs are plain `Dictionary` objects returned by `get_parameter_specs()` (see `grid_tiles.gd`, `adjacency.gd`). `live_recompute` and `tooltip` are not supported.

Design target:

```
ParameterSpec { key, label, type, default, range/options, live_recompute, tooltip }
```

Types: `INT`, `INT`**, … *(the rev 2 list was truncated; restore the full enumeration from the original draft before merging.)**

---

## 4. Transform Set Parameter & The Materialized View

**[NOT IMPLEMENTED]**

- `TRANSFORM_SET` is not implemented. `GridTiles` exposes individual boolean parameters (`rotation_0`, `rotation_90`, `reflect_horizontal`, etc.) instead of a single D4 subgroup picker.
- No `ViewFilter`, no materialized view, no closure validation.

Design target (unchanged):

1. Decomposition techniques compute in **canonical frame**: extract, canonicalize, dedupe by `canonical_hash`, record occurrences with observed transform. The allowed-transform parameter is **not** consulted during extraction.
2. `TRANSFORM_SET` (a D4 subgroup picker, 3×3 toggle grid) defines a `ViewFilter`: which family members are materialized as active parts, and (by the group action of §2.4) which constraint family members are materialized as active constraints.
3. Applying/changing the filter is a cheap post-pass — no image re-scan, no re-segmentation.

```
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
        Active parts + active constraints ─▶ UI / synthesis
```

**Closure requirement:** the allowed-transform set must be a group. Two options: (a) expose only the 10 subgroups of D4; (b) allow arbitrary sets and auto-expand to closure with a warning. Recommend (a).

**Weight filter interaction:** `aggregate_by: CANONICAL | PART`.

---

## 5. Decomposition Techniques

**[DIFFERS / PARTIAL]**

Current interface in code:

```gdscript
class_name DecompositionTechnique extends RefCounted
func get_id() -> StringName
func get_display_name() -> String
func get_parameter_specs() -> Array        # plain Dictionaries, not ParameterSpec
func decompose(images: Array[ImageAssetData], params: Dictionary) -> Dictionary
```

Design target (rev 2):

```gdscript
class_name DecompositionTechnique extends RefCounted
func get_id() -> StringName
func get_display_name() -> String
func get_parameter_specs() -> Array[ParameterSpec]
func decompose(images: Array[ImageAsset], params: ParameterSet,
               report_progress: Callable) -> DecompositionResult
```

Technique status:

| Technique | Status |
|---|---|
| Grid Tiles | **[IMPLEMENTED]** — but exposes per-axis booleans, not `TRANSFORM_SET` |
| Overlapping Windows | **[UNVERIFIED / likely NOT IMPLEMENTED]** |
| Segmentation | **[UNVERIFIED / likely NOT IMPLEMENTED]** |
| Quadtree | **[UNVERIFIED / likely NOT IMPLEMENTED]** |
| Sprite / Rect Detection | **[UNVERIFIED / likely NOT IMPLEMENTED]** |
| Perceptual hashing utility | **[UNVERIFIED]** |

**Reserved (unchanged):** hierarchical decomposition, learned dedupe, manual decomposition.

---

## 6. Constraint Extraction Techniques

**[DIFFERS / PARTIAL]**

Current interface in code:

```gdscript
class_name ConstraintTechnique extends RefCounted
func extract(parts: Array[Part], images: Array[ImageAssetData],
             params: Dictionary) -> Array[Constraint]     # no PipelineRun
```

Design target (rev 2):

```gdscript
class_name ConstraintTechnique extends RefCounted
func extract(run: PipelineRun, parts: Dictionary,
             report_progress: Callable) -> Array[Constraint]
```

Technique status:

| Technique | Status |
|---|---|
| Adjacency | **[IMPLEMENTED]** — parameters differ from rev 2 (participant_level/symmetry_action consequences not present) |
| Overlap Compatibility | **[UNVERIFIED / likely NOT IMPLEMENTED]** |
| Frequency Weighting (`aggregate_by`) | **[UNVERIFIED / likely NOT IMPLEMENTED]** |
| Co-occurrence (n-ary, reserved) | **[NOT IMPLEMENTED]** |

---

## 7. UI Design

**[PARTIAL / NOT IMPLEMENTED for symmetry-specific items]**

- Symmetry editor panel: **gone as a panel** in the design; **not replaced** in code by a `TRANSFORM_SET` widget. Individual booleans appear in the auto-generated inspector.
- Family strip: **[NOT IMPLEMENTED]**
- Constraint matrix grouping dropdown: **[NOT IMPLEMENTED as specified]**
- Graph view: **[UNVERIFIED]**
- Command system / provenance: **[UNVERIFIED]**

Unchanged from rev 1: image mode overlays, occurrence highlighting, ROI editor, evidence navigation, run history and diffing.

---

## 8. Cross-Cutting Systems

**[PARTIAL / DIFFERS]**

- Command system: **[UNVERIFIED]**
- Dirty propagation: rev 1’s symmetry-change path is gone in the design; in code, changing tile-size parameters re-runs decomposition, and there is **no** transform-filter / re-materialize path because `TRANSFORM_SET` is not implemented.
- Persistence: JSON project + binary parts cache — **[UNVERIFIED]**, but the `.wfcproj` extension **is** used in `main.gd` FileDialog filters.
- Threading: `WorkerThreadPool`, atomic snapshots, `call_deferred` publication — **[UNVERIFIED]**

---

## 9. Project Structure

**[DIFFERS]**

Design target:

```
res://
├── main.tscn
├── core/
│   ├── data/        image_asset.gd, part.gd, constraint.gd, pipeline_run.gd, ids.gd
│   ├── params/      parameter_spec.gd, parameter_set.gd
│   ├── commands/    command.gd, command_stack.gd
│   ├── pipeline/    scheduler.gd, persistence.gd
│   └── util/
│       ├── hashing.gd
│       └── transform_family.gd
├── techniques/
│   ├── decomposition/   (base + grid_tiles, overlapping_windows, segmentation,
│   │                     quadtree, sprite_rects — all symmetry-blind)
│   └── constraints/     (base + adjacency, overlap_compat, frequency_weighting)
└── ui/
```

Actual layout observed in code:

```
res://
└── scripts/
    └── core/
        ├── data/         part.gd, constraint.gd, app_data.gd
        ├── techniques/   decomposition_technique.gd, constraint_technique.gd,
        │                 grid_tiles.gd, adjacency.gd, tile_collapse.gd
        └── ...
```

Deleted vs rev 1: `symmetry_group.gd`, `part_variant.gd`.  
Added (design): `transform_family.gd` — **[NOT IMPLEMENTED]**.

---

## 10. Implementation Phases

**[REVISED]**

| Phase | Design target | Actual status |
|---|---|---|
| M1 — Skeleton | data model with transform/canonical_id from day one; parameter system; persistence; window shell; image import | **[PARTIAL]** — data model exists but simpler; no `canonical_id`/`transform: Transform2D` as specified |
| M2 — First end-to-end | grid tiles + adjacency, canonicalization + dedupe, parts grid, image overlay, inspector, scheduler with materialize step, `TRANSFORM_SET` picker | **[PARTIAL]** — grid tiles + adjacency + parts grid + inspector exist; canonicalization + materialize + picker do not |
| M3 — Editing layer | commands, overrides, enable/disable, blocklist, matrix view, evidence navigation | **[UNVERIFIED]** |
| M4 — Technique breadth | remaining techniques, perceptual dedupe, remaining constraint techniques, family strip/graph view | **[NOT IMPLEMENTED]** |
| M5 — Polish | run diffing, ROI editor, caching, timing console | **[UNVERIFIED]** |
| Future — Synthesis module | consumes materialized view | **[AHEAD]** — `TileCollapse` already exists |

---

## 11. Risks & Open Questions

Unchanged from rev 2, with one addition:

- **Doc-vs-code drift is now the top risk.** The design describes abstractions (`PipelineRun`, `ParameterSpec`, `transform_family.gd`, materialized view) that the code does not yet have. Mitigation: keep this annotated revision as the single source of truth, and update status tags every time a milestone lands.
- Canonical-hash determinism is load-bearing. **[UNVERIFIED in code]**
- Partial families from tolerance-dedupe. **[UNVERIFIED]**
- Group-action on constraint params. **[NOT IMPLEMENTED]**
- Non-rectangular masks under rotation. **[NOT IMPLEMENTED]**
- Open (unchanged): authored-constraint scope (run vs project).
- Open (new in rev 2): should the materialized view be a saved, named artifact?
- Open (new in rev 3): should synthesis be promoted from “future” to an explicit phase, given `TileCollapse` already exists? Or should `TileCollapse` be considered a prototype and frozen until M3/M4 land?