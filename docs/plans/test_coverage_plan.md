# Test Coverage Plan

Plan to close the gaps identified in the test-suite audit (baseline: 4 suites,
25 cases, all green via `./run_tests.sh`). Phases are ordered by risk: each
targets code that can silently corrupt synthesis output today.

Conventions applied throughout:

- New suites live in `tests/`, named `test_<subject>.gd`, extending
  `GdUnitTestSuite`, **no `class_name`** (keeps the global class registry clean
  and matches `test_core_algorithms.gd` / `test_state_and_components.gd`).
- Tests assert through **public APIs** (`extract()`, `synthesize()`,
  `create_session()`, `get_result()`, `ConstraintIndex.build/prepare`) the same
  way the existing suites do. Private-state pokes are allowed only where no
  public seam exists (the current rules tests already do this for
  `nb_mask`/`nb_empty`).
- Deterministic fixtures only: fixed seeds (`RandomNumberGenerator.seed = N`),
  tiny images (≤ 4×4), explicit color grids. No timing or thread assertions.
- Every phase ends with `./run_tests.sh` green.

---

## P0 — Suite hygiene (prereq, ~30 min)

Small fixes so later phases build on a clean base.

| # | Change | File(s) |
|---|---|---|
| 0.1 | Rename `text_constraint_index_rules.gd` → `test_constraint_index_rules.gd` (use `git mv`; also rename the `.uid` if Godot regenerates it) | `tests/` |
| 0.2 | Drop `class_name TagMatcherTest` and `class_name ConstraintIndexRulesTest` | `tests/test_tag_matcher.gd`, `tests/test_constraint_index_rules.gd` |
| 0.3 | Remove dead construct `return null if false else c` → `return c` | `tests/test_constraint_index_rules.gd` |
| 0.4 | Fix stale header/usage comment (mentions `test_swap_behavior.gd` and the wrong project name) | `run_tests.sh` |
| 0.5 | Extract shared fixture builders into `tests/builders.gd` (static helpers: `solid_image`, `grid_image`, `make_part`, `make_constraint`, `make_asset`, plus terrain-key save/restore helpers for the `AppData` autoload — see the P1 note); update existing suites to use them | `tests/builders.gd` + 3 suites |

Acceptance: `./run_tests.sh` discovers **4** suites, 25/25 pass, no
`class_name` under `tests/`.

---

## P1 — PixelOverlap (new suite `tests/test_pixel_overlap.gd`)

Highest-risk gap: ~500 lines of matcher logic with zero coverage. All tests
drive `PixelOverlap.new().extract(parts, [], params, noop)` and assert on the
returned `Array[Constraint]` (ids, participants, `params.offset`,
`evidence.size()`).

Fixture recipe: 2×2 parts built from explicit color grids via the P0 builders.
Left/right strips are 1px wide at depth 1 — a part whose right column is red
matches a part whose left column is red.

| # | Test | Pins / asserts |
|---|---|---|
| 1.1 | `test_strict_strip_match_emits_horizontal_constraint` | matching right/left columns → exactly 1 constraint, `type == &"pixel_overlap"`, offset `(2, 0)`, id `o_…` |
| 1.2 | `test_strict_mismatch_emits_nothing` | differing columns → empty result |
| 1.3 | `test_tolerance_is_per_channel_and_inclusive` | delta == tolerance matches; +1 does not (mirrors TagMatcher semantics) |
| 1.4 | `test_allowed_omissions_budgets_single_pixel_failures` | 1 bad pixel + `allowed_omissions = 1` → match; budget 0 → no match |
| 1.5 | `test_flex_permits_seam_displacement_within_budget` | column pattern shifted by 1 along the seam matches with `flex ≥ 1`, fails with `flex = 0`; verify two-sidedness by mirroring the shift to the other side |
| 1.6 | `test_vertical_pairs_use_vertical_offsets` | matching bottom/top rows → offset `(0, 2)` |
| 1.7 | `test_extraction_order_does_not_change_output` | reversed input array → identical id set (determinism) |
| 1.8 | `test_parts_smaller_than_depth_are_skipped` | 1×2 part with `overlap_layers = 2` → no constraints, no crash |
| 1.9 | `test_terrain_class_rewrites_unify_colors` | two colors registered as one terrain class match strictly; proves strip classification rewires bytes. `extract()` reads the `AppData` **autoload** singleton (registered in `project.godot`), not test-local instances — set `AppData.terrain_key_classes` on the autoload via the P0 save/restore helpers |
| 1.10 | `test_symmetric_pair_records_both_directions` | A~B and B~A each produce their own directed constraint |

Notes: 1.9 must mutate the `AppData` autoload singleton — `PixelOverlap.extract`
calls `AppData.active_terrain_classes()` on the autoload registered in
`project.godot`, so terrain classes set on a fresh `auto_free` AppData node
(like the existing state tests build) are never consulted. Snapshot
`AppData.terrain_key_classes` before the test and restore it unconditionally
in `after_test` so a failed assertion cannot leak classes into tests 1.1–1.8.

---

## P2 — TileCollapse session behavior (new suite `tests/test_tile_collapse_session.gd`)

Pins the solver's recovery, border, and interactive-editing contracts. Fixture
pattern reuses the existing `_part`/`_constraint` helpers (move to
`tests/builders.gd` in P0): build a `ConstraintIndex`, then a
`TileCollapse.new().create_session(index, params, rng)`.

| # | Test | Pins / asserts |
|---|---|---|
| 2.1 | `test_mask_helpers_round_trip` | table-test `mask_full/empty/is_empty/count/has/set/clear/only/first/iter/_kth_set_bit/_ctz` incl. multiword masks: craft 2-word masks directly with bits in word 1 (every helper is a static taking explicit `nwords`, so no ≥ 65-family fixture is needed) |
| 2.2 | `test_stop_strategy_fails_fast_on_impossible_index` | shared fixture (see the semantics notes below): constraint A→B at (1, 0) plus A—OUTSIDE evidence at (1, 0), 1×2 grid, dominant `A` weight + fixed seed. A is picked first and demands B to its right, but the border pass bans B from the edge slot (only OUTSIDE-evidenced families are border-ok) → step-time contradiction, phase FAILED, `get_result() == {}`, `contradictions ≥ 1` |
| 2.3 | `test_restart_strategy_respects_recovery_budget` | same index, strategy 1, `max_recovery_attempts = 3`: every restart re-derives the same state and re-picks dominant A (weight ratio ≥ 10⁶:1 keeps the surviving-branch first pick at ≤ 10⁻⁶ probability) → budget exhausted → FAILED, `restarts == 3` |
| 2.4 | `test_backtracking_strategy_recovers_when_a_later_pick_exists` | same index, strategy 2: the dominant first pick dead-ends, backtracking removes it and the surviving branch (B at slot 0, A at the edge) completes → DONE, `backtracks ≥ 1` |
| 2.5 | `test_outside_evidence_forbids_interior_border_violations` | part P with OUTSIDE evidence only at LEFT + part Q unconstrained: in a 2-wide grid, column 0 slots may only take P (the right edge stays unenforced — no family has OUTSIDE evidence on that delta). The FAILED side is the 2.2 fixture: a family demanded into an edge slot it lacks OUTSIDE evidence for is wiped at setup. A single-family index can never border-fail: the family that activates a delta's border is itself border-ok there |
| 2.6 | `test_try_assign_pin_and_rejection_rollback` | pin a legal part → `true`, `get_slot_assignment` reflects it, `get_progress` bumps; pin an incompatible part → `false`, domain + `assigned` + `_collapsed` unchanged (read via `get_slot_domain`/`get_slot_assignment`), `last_rejection` non-empty |
| 2.7 | `test_try_clear_unpins_and_rebuilds_domain` | pin, clear → domain of the slot contains families again, re-pin still possible |
| 2.8 | `test_describe_pin_reports_reasons` | out-of-range slot, unknown part, domain-miss → exact message strings |
| 2.9 | `test_unknown_free_false_constrains_unobserved_offsets` | offset only observed for one pair; `unknown_free = false` → output never places an unobserved pair (assert via final `assigned` neighbors or a FAILED on a forcing grid) |
| 2.10 | `test_render_geometry_with_overlap_step` | 2 slots, step `(2, 1)`, tile 3×2 → image size `((2-1)*2+3, 2)`; blit positions from `slot_rect` |
| 2.11 | `test_same_seed_reproduces_identical_output` | batch twice + stepped once, all three PixelHash-equal (extends the existing parity test with a *constrained* index so propagation actually runs) |

Engine semantics the 2.2–2.5 fixtures rely on (verified against
`tile_collapse.gd` / `constraint_index.gd`): positive arcs are permissions
and their reverse arcs are materialized, so an out-of-grid obligation exists
only where the index has OUTSIDE evidence on that exact delta
(`delta_has_outside` gates the border wipe) — borders are the only
deterministic contradiction source. A session that fails during
construction reports `contradictions == 0` and `restarts == 0` (those
counters only track step-time recovery), which is why 2.2–2.4 force the
contradiction at the first observation via a border-banned target plus
dominant weight; residual seed dependence is bounded by the weight ratio.
Keep the seed pinned; if a fixture turns out ambiguous, enlarge to 3×3 and
add explicit weights rather than loosening assertions.

---

## P3 — AppData layers (new suite `tests/test_app_data_layers.gd`)

Covers materialization, merges, tags/rules/terrain-key, persistence. Uses the
existing `AppData` instantiation pattern (`auto_free` + `_ready()`), plus
`last_run_config` seeding to steer `_materialize_parts`.

| # | Test | Pins / asserts |
|---|---|---|
| 3.1 | `test_materialize_expands_enabled_transform_variants` | raw part + `rotation_90: true` in `last_run_config.params` → materialized set contains a rotated variant sharing occurrences; `rot90` on a non-square part is skipped |
| 3.2 | `test_run_transform_enabled_matrix` | `rot180` implied by `reflect_horizontal && reflect_vertical`; explicit flags win; identity always true |
| 3.3 | `test_merge_parts_rewrites_participants_and_rebuilds_ids` | alias a→b: a vanishes, b inherits occurrences/weight, constraints referencing a now point at b with rebuilt id; chain a→b then b→c resolves transitively |
| 3.4 | `test_clear_all_edits_keeps_tags_and_rules` | edits wiped, `tag_edits`/`rules` survive |
| 3.5 | `test_tag_crud_and_strip_everywhere` | add (dedupe/strip/empty rejected), remove, `get_all_tags` sorted; `strip_tag_everywhere` returns count and emits once |
| 3.6 | `test_authored_rule_crud_and_numbering` | add returns `rule_1/2…`, update patches fields except id, remove; after load, numbering continues past the max restored id |
| 3.7 | `test_apply_tagging_rules_is_idempotent_and_reports` | second call adds 0; per-rule counts; disabled rule skipped; signal spy: exactly one `edits_changed` on the first application, zero on the idempotent second (emission is conditional on `tagged_parts > 0`) |
| 3.8 | `test_terrain_key_filters_and_regen` | `active_terrain_classes` drops disabled classes; `set_terrain_key` emits `terrain_key_changed` and refreshes constraints; `apply_terrain_key_tags` honors `min_fraction`. Seed `last_run_config.constraint_jobs` with adjacency only — pixel_overlap regeneration reads the `AppData` autoload's key, not this instance's |
| 3.9 | `test_save_and_load_project_round_trip` | save to `user://test_project.wfcproj`, load into a fresh AppData → edits/tags/rules/terrain key equal; legacy `terrain_keys` array migrates first enabled key; missing file → `{}`; `_decode_tag_edits` drops empty/non-string entries |
| 3.10 | `test_remove_output_clears_last_synthesis` | removing the current output id resets `last_synthesis` and emits; removing another output leaves it |

Cleanup: 3.9 must delete the temp file in the test (use `DirAccess.open("user://").remove("test_project.wfcproj")`) so runs stay hermetic.

---

## P4 — AdjacencyExtractor completeness (extend `tests/test_core_algorithms.gd`)

| # | Test | Pins / asserts |
|---|---|---|
| 4.1 | `test_n8_neighborhood_emits_diagonal_offsets` | 2×2 tiles, `neighborhood = 1` → offsets `(step, 0)`, `(0, step)`, `(step, step)`, `(step, -step)` |
| 4.2 | `test_wrap_evidence_links_seam_and_skips_interior_holes` | 3×1 grid: right-edge pair wraps to column 0; a deliberately missing interior tile produces no pair |
| 4.3 | `test_non_directional_constraints_are_symmetric_and_canonical` | `directional = false` → `params.symmetric == true`, participant order independent of input order |
| 4.4 | `test_transform_variants_map_offsets` | canonical A and B each with an enabled `rot90` variant — variant pairs emit only when both sides share the transform key: expect the base pair at `(1, 0)` **and** the variant pair at `(0, 1)` (rot90 mapping `(x,y) → (-y,x)`), with variant part ids as participants |
| 4.5 | `test_weight_equals_evidence_count` | same pair observed at two positions → `weight == 2`, `evidence.size() == 2` |

---

## P5 — Utils and small modules (new suites)

### `tests/test_terrain_mapper.gd`

| # | Test | Pins / asserts |
|---|---|---|
| 5.1 | `test_prepare_filters_disabled_and_inert_classes` | disabled classes and empty/invalid color lists dropped; `flex` clamped to `0..64`; tolerance clamped to `0..255` |
| 5.2 | `test_apply_mapped_rewrites_and_records_class_ids` | pixel in class → rewritten to representative color + class id recorded; transparent pixels untouched with id −1; first matching class wins |
| 5.3 | `test_apply_converts_non_rgba8_input` | feed FORMAT_RGB8; output format RGBA8, same classification |

### `tests/test_palette_extractor.gd`

| # | Test | Pins / asserts |
|---|---|---|
| 5.4 | `test_transparent_pixels_are_excluded` | alpha-0 pixels never counted |
| 5.5 | `test_coalescing_picks_most_frequent_exact_color` | bucket members merge onto the most frequent exact color |
| 5.6 | `test_output_sorted_by_count_then_color_and_capped` | deterministic order; `total` counts pre-truncation; `bucket_bits = 0` disables coalescing |

### `tests/test_small_modules.gd`

| # | Test | Pins / asserts |
|---|---|---|
| 5.7 | `test_pixel_hash_is_format_independent` | same pixels as FORMAT_RGB8, L8, RGBA8 → identical hash (the documented core claim) |
| 5.8 | `test_pixel_hash_handles_compressed_source` | compressed (WebP/PNG-lossy path or `compress()`), decompressed-equivalent hash |
| 5.9 | `test_image_asset_from_image_derives_id_and_hash` | `img_` + first 10 hash chars; `load_from_path` on a missing/empty file → `null` |
| 5.10 | `test_json_codec_edge_cases` | `{"__v2i": …}` with extra keys is NOT decoded as a vector; float ≥ 2³¹ stays float; nested arrays |
| 5.11 | `test_run_monitor_stage_lifecycle` | begin → stage begin/report/end → finish: statuses, `progress` recomputation, `rev` bumps, `clear_finished` keeps running runs. Call the `_`-prefixed deferred impls directly to avoid frame awaits |

### Extend `tests/test_constraint_index_rules.gd` (renamed in P0)

| # | Test | Pins / asserts |
|---|---|---|
| 5.12 | `test_offset_metrics_manhattan_and_euclidean` | rule distance 3: manhattan yields the 24-offset diamond (no (±2, ±2)), euclidean the 28-offset disc — at distance 2 both metrics coincide, so assert the differing `delta_list` contents at 3 |
| 5.13 | `test_duplicate_pair_constraints_accumulate_weight` | two constraints, same pair+offset → `get_neighbors` weight is the sum |
| 5.14 | `test_family_layer_groups_identical_parts` | two parts with identical neighbor behavior → `family_count == 1`, `family_weights[0] == sum`, `family_of_part_id` resolves both, `largest_family_size == 2` |
| 5.15 | `test_unknown_rule_types_and_tags_warn_but_do_not_throw` | rule with `type: "bogus"` and exclusion referencing a missing tag → index still builds, no deltas added |

---

## P6 — End-to-end smoke (stretch, `tests/test_synthesis_smoke.gd`)

One decomposition → extraction → index → synthesis pipeline over a tiny
authored image (e.g. 4×1 checkerboard), asserting:

- parts dedupe to the expected count; constraints include expected pairs;
- batch synthesis with a fixed seed completes with `stats.families >= 1` and a
  rendered image whose size matches `get_render_size()`;
- the same pipeline with one exclusion rule never places the excluded pair
  adjacent (scan the final `assigned` grid).

This is the cheapest regression net for "the whole app still generates" and
guards future refactors of the family layer.

---

## Execution order & validation

1. P0 (hygiene) — required first; renames the rules suite.
2. P1, P2 in either order (both are self-contained new suites).
3. P3, P4 next.
4. P5 fills the long tail; P6 last.

Validation after each phase: `./run_tests.sh` green, suite count grows as
planned, and total runtime stays well under a second (current suites run in
~100 ms; all proposed tests are deterministic and sub-millisecond apart from
the P6 smoke).

Estimated total: ~30 new test cases across 6 new suites plus 3 extended ones.
