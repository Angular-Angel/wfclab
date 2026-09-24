# Refactoring Plan

> **Status:** 📝 Draft — not started. Baseline: 43 scripts, 10,627 LOC, 11 suites /
> 77 cases green via `./run_tests.sh`.

Plan to address the findings of the 2026-09-24 refactoring audit. Every phase is a
pure move, deletion, or dedup — **no behavior changes**. Where two copies of a
"same" algorithm differ subtly today, the difference is called out and the phase
either preserves it or pins it with a test before unifying.

Conventions applied throughout:

- Phases are ordered so each builds on the last: dead code first, then the
  layering fix everything else benefits from, then isolated dedups, then UI
  extraction. R5 → R7 and R3 → R4 are hard dependencies.
- One phase = one commit. Message follows the repo's existing convention
  (check `git log --oneline` before committing).
- When moving/renaming a script, `git mv` the `.gd` **and** its `.gd.uid`
  together (an orphaned uid makes Godot mint a fresh one and breaks uid-based
  references). New files: let Godot mint the `.gd.uid` on first scan and commit
  both files.
- Moved function bodies are verbatim unless the phase lists a delta. If a
  semantic difference between duplicate copies is discovered mid-phase, stop,
  write a pinning test, then unify.
- New source files follow the util convention: `class_name X extends RefCounted`
  with static funcs (see `scripts/core/util/pixel_hash.gd`). Tests never get
  `class_name`.
- Every phase ends with `./run_tests.sh` green (11 suites, 77 cases). Phases
  touching UI without test cover (R5, R7) additionally run the manual smoke
  checklist listed in the phase.

Findings index (audit → phase): layering inversion → **R1**; duplicated strip
algorithm → **R4**; palette popup copy-paste → **R5**; rules CRUD duplication →
**R2**; tile_collapse dead code / dual role → **R0 + R6**; parts_tab five jobs →
**R7**; RGBA8 normalization ×9 → **R3**; AppData god object → **R8**; `_mk_label` /
weighted-choice polish → **R9** (optional).

---

## R0 — TileCollapse housekeeping (~30 min, zero risk)

Delete code that nothing calls before any file it lives in gets restructured.

| # | Change | File(s) |
|---|---|---|
| 0.1 | Delete `_rebuild_domains_from_assignments()` — **zero callers anywhere** (verified by search; `try_clear` uses `_reset_attempt` + `_snapshot_state`/`_restore_state`, not this) | `tile_collapse.gd` (~860–898) |
| 0.2 | Remove the vestigial `_trail_marks` field: it is only `clear()`ed, snapshotted, and restored — never read for marks (its own comment says decisions live in `_decisions`). Drop the matching keys from `_snapshot_state`/`_restore_state` and the clears in `_reset_attempt`/`try_assign` | `tile_collapse.gd` (247, 313, 788, 806, 821, 873) |
| 0.3 | `_reset_attempt` resets `_in_queue` three redundant ways (`resize` + `fill(0)` + `clear(); resize()`). Keep `resize` + `fill(0)` (the comment rightly distrusts resize zeroing), delete the `clear(); resize()` pair | `tile_collapse.gd` (304–306) |

Acceptance: `grep -rn "_rebuild_domains_from_assignments\|_trail_marks" scripts/ tests/`
returns nothing; suite green; `tile_collapse.gd` ≈ −55 lines.

---

## R1 — Extract BitMask + index-side derivation (fixes the layering inversion)

The data layer currently depends on a technique: `ConstraintIndex` calls
`TileCollapse._ctz` (×2) and `TileCollapse.mask_full` (×2); `FamilyInspector`
calls `TileCollapse._derive_step/_derive_deltas`. The mask toolkit and the
step/delta derivation are generic math, not solver logic.

| # | Change | File(s) |
|---|---|---|
| 1.1 | New `scripts/core/util/bit_mask.gd`: `class_name BitMask extends RefCounted`. Move the statics **verbatim** from `tile_collapse.gd` (62–217), renamed per the mapping below. `_ctz_cache` moves with it (keep the caching comment) | new file |
| 1.2 | Add instance methods `derive_step() -> Vector2i` and `derive_deltas(step: Vector2i) -> Array[Vector2i]` to `ConstraintIndex` — verbatim bodies of `_derive_step`/`_derive_deltas`, which read only `tile_size` + `get_offsets()`. Keep `@warning_ignore("integer_division")` | `constraint_index.gd` |
| 1.3 | Update all call sites in `tile_collapse.gd` (`TileCollapse.mask_*` → `BitMask.*`, `TileCollapse._derive_step(_index)` → `_index.derive_step()`, `_derive_deltas` likewise), then delete the moved statics from `tile_collapse.gd` | `tile_collapse.gd` |
| 1.4 | `constraint_index.gd`: `TileCollapse._ctz` → `BitMask.ctz` (2×), `TileCollapse.mask_full` → `BitMask.full` (2×) | `constraint_index.gd` (498, 590, 617, 620) |
| 1.5 | `family_inspector.gd`: replace `TileCollapse._derive_step/_derive_deltas` with `_index.derive_step()` / `_index.derive_deltas(step)` | `family_inspector.gd` (80–81) |
| 1.6 | Repoint `test_mask_helpers_round_trip` at the new names (it currently calls `TileCollapse.mask_full/_ctz/_kth_set_bit/…` directly) | `tests/test_tile_collapse_session.gd` (57–79) |

Name mapping (1.1 / 1.6):

| TileCollapse | BitMask | Note |
|---|---|---|
| `_ctz` | `ctz` | |
| `mask_full` | `full` | |
| `mask_empty` | `empty` | |
| `mask_is_empty` | `is_empty` | |
| `mask_count` | `count` | |
| `mask_has` | `has` | |
| `mask_set` | `set_bit` | `set` collides with `Object.set()` |
| `mask_clear` | `clear_bit` | `clear` is ambiguous |
| `mask_only` | `only` | |
| `mask_first` | `first` | |
| `_kth_set_bit` | `kth` | |
| `mask_iter` | `iter` | |

Do **not** keep `TileCollapse` delegates — every caller is updated in this phase
and the suite (2.11 seed-parity, 2.1–2.11) pins the solver behavior.

Acceptance: `grep -rn "TileCollapse\." scripts/` returns only
`tile_collapse.gd`-internal `Session` references and `create_session`; suite
green.

---

## R2 — AppData rules-CRUD dedup (~30 min)

`add_rule`/`update_rule`/`remove_rule`/`_max_rule_number` and their
`*_tagging_rule` twins are pairwise identical except for array, id prefix, and
signal.

| # | Change | File(s) |
|---|---|---|
| 2.1 | Add private generics: `_rule_add(list: Array, prefix: String, rule: Dictionary, changed: Signal) -> String`, `_rule_update(list, id, fields, changed)`, `_rule_remove(list, id, changed)`, `_rule_max_number(list, prefix) -> int` | `app_data.gd` |
| 2.2 | Reduce the six public functions + two `_max_*` helpers to one-line calls. Keep both `_next_*_number` counters and the load-time `_max_*_number() + 1` re-derivation exactly as-is | `app_data.gd` (289–320, 330–361, 727–742) |

Acceptance: suite green — `test_app_data_layers.gd` and
`test_state_and_components.gd` cover rules CRUD and the save/load round trip;
`app_data.gd` ≈ −40 lines.

---

## R3 — `ImageOps.to_rgba8` (9 call sites)

The duplicate-and-convert guard (sometimes with decompress, sometimes without)
is pasted across the codebase.

| # | Change | File(s) |
|---|---|---|
| 3.1 | New `scripts/core/util/image_ops.gd`: `class_name ImageOps extends RefCounted`, `static func to_rgba8(img: Image) -> Image` — **never mutates the input**: if compressed or format ≠ RGBA8 → `duplicate()`, `decompress()` if compressed, `convert(FORMAT_RGBA8)`; otherwise return `img` unchanged. This adopts `PixelHash.of`'s semantics, the strongest of the nine (see its doc comment) | new file |
| 3.2 | Replace the guards in: `palette_extractor.gd` (23–24), `tag_matcher.gd` (21–22), `pixel_hash.gd` (7–12, keep the quantize tail), `terrain_mapper.gd` (63–64 — verify it owns the image first; if it mutates a caller's image today, fix to the no-mutate contract), `image_asset.gd` (20–21), `synthesizers_tab.gd` `_tile_button` (694–696), `tile_collapse.gd` `_render` (112–115) | 7 files |
| 3.3 | `constraint_index._edge_signature_key` (423–426) and `pixel_overlap.extract` (74–77) keep their own `duplicate()` (they own the copy and pass `get_data()` out of it) but route the decompress/convert through `ImageOps` — final shape decided in R4 when their shared preamble is unified | 2 files |

**Called-out strictening:** sites that previously skipped `decompress()`
(palette_extractor, tag_matcher, terrain_mapper, image_asset) now decompress.
Runtime images come from PNG loads and are never compressed, so this is latent-
bug hardening, not a behavior change. `Image.get_format()`/`is_compressed()`
behavior on every input stays pinned by the existing palette/tagger/hash suites.

Acceptance: suite green; `grep -rn "convert(Image.FORMAT_RGBA8)" scripts/` hits
only `image_ops.gd`.

---

## R4 — Unify the seam-strip algorithm (depends on R3)

`PixelOverlap._strip()` and `ConstraintIndex._edge_bytes()` are the same
depth×span walk; `_strip_classes()` duplicates the class-id loop inside
`_edge_signature_key()`; and both files hand-roll the same four-side geometry
and RGBA8+classify preamble.

| # | Change | File(s) |
|---|---|---|
| 4.1 | New `scripts/core/util/strip_util.gd`: `class_name StripUtil extends RefCounted` with: `static func bytes(data: PackedByteArray, img_w: int, depth: int, start: Vector2i, along: Vector2i, inward: Vector2i, span: int) -> PackedByteArray` (verbatim body of `pixel_overlap._strip` == `constraint_index._edge_bytes`), `static func classes(cls_map: PackedInt32Array, img_w: int, depth, start, along, inward, span) -> PackedInt32Array` (verbatim `_strip_classes`), and `static func side(side: String, part_size: Vector2i) -> Dictionary` returning `{start, along, inward, span}` for `"right"/"left"/"bottom"/"top"` | new file |
| 4.2 | `pixel_overlap.extract`: build the four strips by looping `StripUtil.SIDES` + `side()` instead of the four inline `_strip`/`_strip_classes` call groups (the `strips[p.id]` dict keys stay `"right"`, `"right_cls"`, `"right_loose"`, …). Delete `_strip`/`_strip_classes`. `_strip_loose` stays (no twin) | `pixel_overlap.gd` (76–107, 297–317, 378–395) |
| 4.3 | `constraint_index._edge_signature_key`: replace the local `sides` array + `_edge_bytes` + inline class loop with `StripUtil.side()` + `StripUtil.bytes/classes`. **Preserve the difference:** this site uses `d_eff = mini(depth, mini(size.x, size.y))` (clamped depth) while pixel_overlap skips parts smaller than depth entirely — keep each caller's own depth handling. Delete `_edge_bytes` | `constraint_index.gd` (412–480) |
| 4.4 | Both callers' preamble (own-duplicate → `ImageOps.to_rgba8` semantics → optional `TerrainMapper.apply_mapped`) ends up identical; share it as `static func classified_rgba8(img: Image, decoded: Array) -> PackedInt32Array` on `StripUtil` (returns the cls map; empty when `decoded` is empty) | `pixel_overlap.gd` (74–80), `constraint_index.gd` (423–429) |

Geometry parity is the risk here: the two copies' start/along/inward/span
arguments were verified identical in the audit, and behavior is pinned by
`test_pixel_overlap.gd` (1.1–1.10, esp. 1.9 terrain-class rewriting),
`test_constraint_index_rules.gd` (family formation), and
`test_core_algorithms.gd`.

Acceptance: suite green; `grep -n "func _strip\b\|_edge_bytes" scripts/` empty;
combined ≈ −70 lines.

---

## R5 — `PalettePicker` component (UI; manual smoke required)

`parts_tab` and `terrain_keys_tab` each carry ~100 lines of palette popup:
same construction, same swatch buttons, same `_all_palette_cache`/`_valid`
invalidation — only the color sources and the pick target differ.

| # | Change | File(s) |
|---|---|---|
| 5.1 | New `scripts/core/ui/palette_picker.gd`: `class_name PalettePicker extends PopupPanel`, `signal color_picked(hex: String)`. Config: `setup(sources: Array)` where each source is `{label: String, images: Callable}` (Callable returns `Array[Image]`); owns the OptionButton, status label, swatch grid (30×30 StyleBoxFlat buttons, tooltips, 8-column grid, 360×440 popup — all as today), and the all-tiles cache with invalidation on `AppData.parts_changed` | new file |
| 5.2 | `parts_tab`: delete `_build_palette_popup`/`_populate_palette`/`_on_swatch_pressed` + cache fields; wire `color_picked` to the existing add-color-to-rule logic (8-button cap message stays) | `parts_tab.gd` (52–57, 148–149, 337–432) |
| 5.3 | `terrain_keys_tab`: same; `color_picked` writes into `_draft[_palette_target_ci]` with the existing already-in-class and `MAX_CLASS_COLORS` guards | `terrain_keys_tab.gd` (18–25, 292–390) |

Manual smoke (in-editor, both tabs): open popup from each source; click swatch
→ lands in rule/class; cap message at 8 colors / `MAX_CLASS_COLORS`;
already-in-class message; close/reopen — "All tiles" is cached (instant);
re-run decomposition → cache invalidated.

Acceptance: suite green + smoke checklist passes; ≈ −130 lines net.

---

## R6 — Split `TileCollapse.Session` into its own file (~30 min)

Post-R1, `tile_collapse.gd` still mixes the Synthesizer adapter with the ~900-
line solver. Mechanical move only.

| # | Change | File(s) |
|---|---|---|
| 6.1 | New `scripts/core/techniques/tile_collapse_session.gd`: `class_name TileCollapseSession extends SynthesisSession`; move the `Session` class body verbatim; `TileCollapse.create_session` returns `TileCollapseSession.new(...)`. No delegates needed — tests go through `create_session` | new file, `tile_collapse.gd` |

Acceptance: suite green; `tile_collapse.gd` ≈ 250 lines (adapter + render),
solver independently openable.

---

## R7 — Decompose `parts_tab.gd` (largest UI churn; depends on R5)

923 lines doing five jobs. Extract child controls following the existing
`ParamBuilder`/`PreviewRect` pattern in `scripts/core/ui/`.

| # | Change | File(s) |
|---|---|---|
| 7.1 | New `scripts/core/ui/tag_rule_editor.gd`: `class_name TagRuleEditor extends VBoxContainer` — the auto-tag rules list + editor (`_build_tag_rule_editor`, color-button rows, `_tag_rule_summary`, add/edit/save/cancel/strip/delete/apply handlers, `signal status_message(text: String)` for the status line). Uses `PalettePicker` from R5 | new file, `parts_tab.gd` (129–152, 227–321, 639–791) |
| 7.2 | New `scripts/core/ui/neighbors_panel.gd`: `class_name NeighborsPanel extends VBoxContainer` — `_refresh_neighbors` + `MAX_NEIGHBOR_*` constants; API `show_part(part: Part)`, `signal part_selected(part: Part)` for the click-through to `_show_part` | new file, `parts_tab.gd` (39–41, 203–205, 828–891) |
| 7.3 | `parts_tab` keeps: grid + tag filter, selection preview, enabled/weight/transforms, pin/compare/merge, occurrences. After R5, only `_on_add_color_pressed` creates `ColorPickerButton`s directly; if more than one construction site remains, dedup into `_mk_color_button(color)` | `parts_tab.gd` |

Manual smoke: select part; tag add/remove; tag filter; rule add → pick colors →
save → apply → strip → edit → delete; transform toggles (incl. square-only
note); weight override drag (debounced rebuild); pin → compare → merge;
neighbors click-through; occurrence select jumps to Images.

Acceptance: suite green + smoke; `parts_tab.gd` ≤ ~550 lines.

---

## R8 — Extract persistence from AppData (~1–2 h)

`app_data.gd` (742 lines) mixes twelve responsibilities; the cleanest cut is
persistence.

| # | Change | File(s) |
|---|---|---|
| 8.1 | New `scripts/core/project_codec.gd`: `class_name ProjectCodec extends RefCounted`, static: `encode(images: Array, state: Dictionary) -> Dictionary` (the version-2 payload builder, 618–634), `write(path: String, data: Dictionary) -> bool`, `read(path: String) -> Dictionary` (JSON open/parse, empty on failure), `decode(payload: Variant) -> Dictionary` (JsonCodec.decode + `_decode_tag_edits` + rules/tag-rules/terrain adoption incl. the legacy `terrain_keys` fallback, 714–742 + 670–692) | new file |
| 8.2 | `AppData.save_project` = gather state → `ProjectCodec.encode/write`. `load_project` = `ProjectCodec.read/decode` → **AppData keeps** the state reset, counter re-derivation, image loading, and all eight signal emissions (641–711 stays; only the decode tail moves) | `app_data.gd` (616–742) |

`test_app_data_layers.gd` pins the save/load round trip (incl. version-2 format
and legacy-key adoption).

Acceptance: suite green; `app_data.gd` ≈ −100 lines; no signal-order change
(the load-signal block is famous for past staleness bugs — move nothing across
the codec seam).

---

## R9 — Optional polish (deferrable, no ordering constraints)

| # | Change | File(s) |
|---|---|---|
| 9.1 | `UiFactory` (`label(text)`, `status_label(text)` with autowrap, `vscroll(content)`) replacing the 8× `_mk_label` copies and repeated ScrollContainer boilerplate | new file + 8 tabs/inspector |
| 9.2 | `WeightedChoice` helper unifying `_weighted_pick`/`_pick_member` total→roll→walk incl. fallbacks — **only if** it can keep the documented RNG-consumption contract (one `randf` per non-degenerate pick; seed parity tests 2.11 must stay green) | `tile_collapse_session.gd` post-R6 |
| 9.3 | Add the "hot paths avoid `BitMask.iter`'s allocation on purpose" comment next to the remaining `v & -v` loops | `tile_collapse_session.gd`, `constraint_index.gd` |

---

## Sequencing & effort

```
R0 → R1 → R6          (tile_collapse track; R6 optional but cheap after R1)
R2                     (independent, anytime)
R3 → R4                (image/strip track)
R5 → R7                (UI track)
R8                     (independent, anytime after R2 touches the same file)
R9                     (optional)
```

| Phase | Est. | Risk | Coverage |
|---|---|---|---|
| R0 | 30 min | none | suite |
| R1 | 1–2 h | low (mechanical renames; solver pinned by 2.1–2.11) | suite |
| R2 | 30 min | none | suite |
| R3 | 45 min | low (strictening called out) | suite |
| R4 | 1–2 h | medium (geometry parity; pinned by 3 suites) | suite |
| R5 | 1–2 h | medium (no tests) | manual smoke |
| R6 | 30 min | none | suite |
| R7 | 3–4 h | medium (no tests) | manual smoke |
| R8 | 1–2 h | low (round-trip pinned) | suite |
| R9 | optional | — | mixed |

Totals when R0–R8 land: ≈ −400 duplicated lines, `tile_collapse.gd`
1137 → ~250 + its session file, `parts_tab.gd` 923 → ~550, `app_data.gd`
742 → ~600, one architectural inversion removed, and every remaining
duplication single-sourced behind a tested util.

## Definition of done (whole plan)

1. `./run_tests.sh` green (same 77 cases, no skips added).
2. `grep -rn "TileCollapse\." scripts/` → only adapter/session-internal uses.
3. `grep -rn "convert(Image.FORMAT_RGBA8)" scripts/` → only `image_ops.gd`.
4. No `_mk_label` outside `UiFactory` (if R9.1 taken).
5. In-editor smoke checklists (R5, R7) walked through once, including loading a
   `saves/*.wfcproj` and re-running a synthesis end-to-end.
6. Each phase committed separately; plan status header updated per phase; on
   completion, move this file to `docs/archive/` (following
   `test_coverage_plan.md` precedent).
