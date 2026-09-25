# Refactoring Plan — Round 2: UI Standardization & Shared Core

> **Status:** 📝 Approved draft — not started. Scope decided with user
> 2026-09-24: UI standardization, shared-code extraction, plus four small UI
> features (R19–R22) that build on the new helpers. Baseline: 11 suites /
> 77 cases green via `./run_tests.sh` (re-verify before R9). Supersedes
> old-R9 "optional polish" from the archived plan
> (`docs/archive/refactoring_plan.md`): its `_mk_label` dedup (then ×8; a
> 9th copy landed with round-1 R7's tag_rule_editor) and weighted-choice
> dedups are absorbed here as R9 and R13.
>
> 2026-09-24 review pass: every line citation re-verified against source;
> corrections applied to R9 (scroll/preview scoping, HINT_ALPHA,
> HEADING_COLOR, label table), R10 (acceptance grep), R13 (pinning-test
> name, second run variants), R14 (tag_matcher refs), R15 (id-scheme
> table, sort triple), R17 (registry refs, wrapper names), R18.4 (emit
> count), R22 (count), R23 (codec ref), and the dependency graph
> (R10 → R22).
>
> 2026-09-24 verification pass (independent plan-vs-source re-audit, plus
> an engine behavior check on Godot 4.7.1): corrections applied to R9
> (clear_children terrain_keys exemption, preview ×8 incl.
> parts_tab:89-93, NEAREST addition documented as a visual no-op,
> HEADING_COLOR call-site delta, smoke extended to terrain buttons), R10
> (debounce comment wording), R12 (hex serialization note), R13
> (out-of-scope block relabeled to the Find Constraints run, RunSpec
> thread field, weighted_pick allocation note), R15 (rebuild_id
> outside-variant residual), R16 (full call-site inventory + acceptance
> grep), R20 (outputs self-disables its run buttons too), R22 (exists/new
> classification, Monitor exemption rationale).

Plan to address the findings of the 2026-09-24 second audit. Two threads,
interleaved so features land on top of the helpers they need:

- **UI standardization (R9–R13, R19–R22):** every size, spacing, and color is
  a per-site magic number; construction boilerplate (`_mk_label` ×9,
  scroll+VBox panels ×5, preview factories ×8, FileDialogs ×4) is
  copy-pasted across 12 files; the run-execution choreography exists in
  three hand-rolled variants (plus two second variants kept out of scope —
  see R13).
- **Shared core (R14–R18):** verbatim-duplicated hex-color decoding,
  id schemes scattered across six files (only `p_` ×2 and the `c_`/`o_`
  constraint family are true multi-copy duplicates), an `AppData` autoload
  reach-in from technique/data code, three parallel technique base
  classes, and the rules-CRUD pairs the R2 generics of round 1 didn't
  fully close.

Conventions carried over from round 1:

- One phase = one commit. Message follows the repo convention (check
  `git log --oneline` before committing).
- `git mv` the `.gd` **and** its `.gd.uid` together; new files get
  Godot-minted `.gd.uid` committed alongside.
- Moved function bodies are verbatim unless the phase lists a delta. If a
  semantic difference between duplicate copies is discovered mid-phase,
  stop, write a pinning test, then unify.
- Call-site inventories cover `tests/` as well as `scripts/`.
- New util files follow the convention: `class_name X extends RefCounted`
  with static funcs. New UI files: `class_name X extends` the appropriate
  Control/Container type (see `scripts/core/ui/palette_picker.gd`).
- Every phase ends with `./run_tests.sh` green. UI phases without test
  cover run the manual smoke checklist listed in the phase.
- **No save-format changes:** R15 unifies id *generation* only; existing
  `.wfcproj` files and stored ids remain valid.

Findings index (audit → phase): `_mk_label`/scroll/preview/FileDialog
boilerplate → **R9**; no TabBase / selection-retain / debounce duplication →
**R10**; weight-override row ×2 → **R11**; color-list editor ×2 → **R12**;
run choreography ×3 (+ two second variants, see R13) → **R13**;
`_decode_hex` ×2 + cold color matchers →
**R14**; id schemes ×6 files → **R15**; `AppData.active_terrain_classes()`
reach-in → **R16**; technique-base trio + registry triplication → **R17**;
AppData rules/edits leftover pairs → **R18**; unconfirmed destructive
actions → **R19**; no global run lock → **R20**; copy affordance
Monitor-only → **R21**; empty-state ×3-of-8 → **R22**; util/migration test
gaps → **R23**.

---

## Phase 1 — Shared UI foundation

### R9 — `UiKit`: UI constants + widget factory (medium, low risk)

New `scripts/core/ui/ui_kit.gd`: `class_name UiKit` (static-only; a UI-side
factory rather than a util, so it lives in `ui/`, mirroring how round 1
placed `param_builder.gd`).

**Constants** (each replaces the per-site magic numbers listed):

| Constant | Value | Replaces |
|---|---|---|
| `THUMB` | `Vector2(72, 72)` | parts_tab.gd:6, synthesizers_tab.gd:684 |
| `PREVIEW` | `Vector2(160, 160)` | parts_tab.gd:7 |
| `PREVIEW_SMALL` | `Vector2(96, 96)` | constraints_tab.gd:151 |
| `SWATCH` | `Vector2(34, 26)` | terrain_keys_tab.gd:11, tag_rule_editor.gd:288 (36×28 → this) |
| `SWATCH_SQUARE` | `Vector2(30, 30)` | palette_picker.gd:10 |
| `HEADING_COLOR` | `Color("#8fa8bf")` | monitor_tab.gd:13 (a String today; becomes Color — delta: its BBCode consumer at monitor_tab.gd:229 switches to `to_html(false)`) |
| `DIFF_RED` | `Color(1.0, 0.25, 0.25)` | parts_tab.gd:496 |
| `HIGHLIGHT_AMBER` | `Color(1.0, 0.9, 0.2, …)` / cursor variant | preview_rect.gd:40-41, synthesizers_tab.gd:602-603 |
| `HINT_ALPHA` | 0.6 | synthesizers_tab.gd:160, 672 (0.55 → this). parts_tab.gd:296's 0.35 is a disabled-look button modulate — a different role, stays per-site |
| `PARAM_LABEL_W` | 110.0 | param_builder.gd:14, synthesizers_tab.gd:70 |
| `POPUP_RATIO` | 0.7 | main.gd:125-127, images_tab, outputs_tab |
| `DEBOUNCE_S` | 0.3 | parts_tab.gd:183-190, constraints_tab.gd:132-139 |
| `INDENT` | 16.0 | decomposition_tab.gd:110 |

Grid separations (4/1/3/2/6) are left per-site: they are visually distinct
choices, not drift — this phase documents that decision instead of
flattening. Same call for the six scroll containers that host non-VBox
content directly (parts grid :64-74, synthesizers preview :163-174 and
tile grid :629-637, monitor detail :82-98, family members :59-65,
palette grid :49-57): a returns-the-VBox factory can't express them
without forcing, so they stay per-site.

**Factories** (each replaces the copies listed):

| Factory | Body | Replaces |
|---|---|---|
| `label(text)` | verbatim `_mk_label` | 9 copies: parts_tab:196, constraints_tab:143, decomposition_tab:139, monitor_tab:362, outputs_tab:98, synthesizers_tab:207, terrain_keys_tab:43, family_inspector:134, tag_rule_editor:169 |
| `status_label(text)` | label + `AUTOWRAP_WORD_SMART` + expand flags | the 15+ inline autowrap sites |
| `note(text)` | status_label with muted/heading style | terrain_keys_tab:105-114, synthesizers_tab:188-200, constraints_tab:427-430, tag_rule_editor:159-165 |
| `scroll_panel(min_width)` | ScrollContainer (h-scroll disabled) + expand-fill VBox; returns the VBox | terrain_keys_tab:21-27, parts_tab:77-86, decomposition_tab:36-45/89-98, synthesizers_tab:45-53 |
| `split_shell()` | HSplitContainer + FULL_RECT, returns it | parts_tab:46, constraints_tab:43, decomposition_tab:29, images_tab:16, outputs_tab:20, monitor_tab:31, synthesizers_tab:41 |
| `preview(min_size, keep_aspect := true)` | TextureRect: `EXPAND_IGNORE_SIZE` + NEAREST, plus `KEEP_ASPECT_CENTERED` unless `keep_aspect = false` | parts_tab:89-93/202-207, constraints_tab:149-154/237-244, outputs_tab:41-45 (fill, passes false), synthesizers_tab:167-171 (fill, passes false)/694-700, family_inspector:121-127 |
| `clear_children(node)` | the free-children loop, normalized to `free()` (documented: rebuild paths run outside the container's own signal callbacks) | the ~15 clear-children sites except the two terrain_keys_tab sites (exemption in the note below) |
| `file_dialog(mode, filters, on_selected)` | ACCESS_FILESYSTEM + filters + wiring | main.gd:96-109 (×2 dialogs), images_tab:73-83, outputs_tab:85-90 |
| `confirm(owner, title, text, ok_text, on_confirmed)` | ConfirmationDialog builder | main.gd:111-119; new callers in R19 |

`clear_children` normalization note: sites currently using `queue_free()`
(palette_picker.gd:87 and others) switch to `free()` — safe because those
call sites are top-of-refresh, never inside the cleared container's own
signal callbacks; each converted site gets a one-line smoke check in this
phase. **Exempted — keep `queue_free()`:** the two terrain_keys_tab sites
(`_rebuild_editor` :75-76, `_rebuild_classes` :119-120). Their containers
hold the buttons that trigger them: "Save Key" reaches `_rebuild_editor`
synchronously via `set_terrain_key` → `terrain_key_changed` (direct
connection, app_data.gd:429), and "− class"/"− color" call
`_rebuild_classes()` inside their own `pressed` emission. `free()` during
signal emission is refused by the engine ("Object is locked and can't be
freed"; verified on Godot 4.7.1).

**Deltas, not verbatim:** the "Fit to window" vs "Fit" checkbox label
(synthesizers_tab.gd:148) unifies to "Fit to window"; its toggle logic stays
local. The `preview` factory adds `TEXTURE_FILTER_NEAREST` at the four
sites that set no filter of their own today (parts_tab:89-93/202-207,
constraints_tab:149-154/237-244). This is a visual **no-op**, not a
change: both tabs' roots already set `TEXTURE_FILTER_NEAREST`
(parts_tab.gd:44, constraints_tab.gd:41) and CanvasItem texture filtering
inherits, so the children already render nearest. Outputs'
`_apply_filter_mode` keeps overriding the filter per texture size after
the factory runs (the factory returns the TextureRect, so the override
keeps working).

| # | Change | File(s) |
|---|---|---|
| 9.1 | Create `ui_kit.gd` with constants + factories above | new file |
| 9.2 | Replace call sites per tables; delete the 9 `_mk_label`s | all files above |
| 9.3 | `file_dialog`/`confirm` adoption (pure move of the wiring) | main.gd, images_tab.gd, outputs_tab.gd |

Acceptance: `grep -rn "_mk_label" scripts/` empty; suite green; smoke: open
every tab — all 8 render, palettes/rules/terrain swatches still edit,
terrain "− class"/"− color"/"Save Key" click through with no console
errors, save/load dialogs still open.

### R10 — `TabBase`: tab lifecycle + shared rebuild machinery (medium, low risk)

New `scripts/core/ui/tab_base.gd`: `@abstract class_name TabBase extends
Control`. All 8 tabs re-derive from it. Members:

- `var status: Label` — the per-tab status line, created by `TabBase`,
  styled via `UiKit.status_label`. Tabs currently hand-roll `_status` under
  6 different names — this names it once. (Delta: each tab's `_ready` calls
  `super._ready()` first, then builds content; the base provides
  `_build_shell() -> HSplitContainer` wrapping `UiKit.split_shell()`.)
- `func _debounce_rebuild(fn: Callable)` — the 0.3 s one-shot Timer
  (parts_tab.gd:183-190, constraints_tab.gd:132-139 — identical code; the
  rationale comments differ per tab and stay local), created once in the
  base.
- `func _retain_selection(container, id_of: Callable) -> int` — the
  selection-preserved-across-rebuild pattern hand-rolled three ways
  (parts_tab.gd:221-274, outputs_tab.gd:112-121, monitor_tab.gd:116-133).
  The helper snapshots ids before `UiKit.clear_children` and re-selects
  after; monitor_tab's auto-follow-newest stays a delta in monitor_tab.
- `func _set_empty_state(text)` / `_clear_empty_state()` — placeholder for
  R22 (introduced here, used there).
- `func _find_by_metadata(list: ItemList, id: String) -> int` — dedups
  images_tab.gd:118-122 + 185-189 and outputs_tab.gd:130-134.

| # | Change | File(s) |
|---|---|---|
| 10.1 | Create `tab_base.gd` with status/debounce/retain/empty-state/find helpers | new file |
| 10.2 | Migrate Images, Outputs, Monitor (the heaviest users of `_retain_selection`/`_find_by_metadata`) | images_tab.gd, outputs_tab.gd, monitor_tab.gd |
| 10.3 | Migrate Decomposition, Parts, Constraints, Terrain Keys, Synthesizers | remaining tabs |

Acceptance: every tab's top-level base is TabBase —
`grep -rn "extends Control" scripts/core/tabs/` returns only the inner
`class SlotOverlay extends Control:` (synthesizers_tab.gd:576), which
legitimately stays; `grep -rn "one_shot = true" scripts/core/tabs/`
returns only tab_base.gd; suite green; smoke: rebuild paths on
Parts/Constraints/Outputs/Monitor preserve selection across an AppData
change; the Images occurrence jump still works.

---

## Phase 2 — Widget & choreography dedup

### R11 — `WeightOverrideEditor` (small, low risk)

The check + spin row and its two handlers are structurally identical in
parts_tab.gd:135-145/381-391 and constraints_tab.gd:100-110/351-361. New
`scripts/core/ui/weight_override_editor.gd`
(`class_name WeightOverrideEditor extends VBoxContainer`): check + SpinBox
(0…99999, step as today), signal `override_changed(enabled: bool, value:
float)`, method `set_silent(enabled, value)` for programmatic refresh.
Both tabs replace their rows and handlers; AppData writes stay in the tabs
(widget emits, tab decides — matches the PalettePicker
owner-handles-guard contract).

Acceptance: suite green; smoke: toggle override + edit weight in both tabs,
verify the Parts grid and Constraints matrix reflect the change and Clear
All Edits resets both.

### R12 — `ColorListEditor` (small, low risk)

The swatch-list editor is duplicated between terrain_keys_tab.gd:161-182/
243-263 (`MAX_CLASS_COLORS := 8`, `SWATCH := 34×26`) and
tag_rule_editor.gd:108-129/263-292 (`MAX_RULE_COLORS := 8`, 36×28 swatch),
with near-duplicate cap guard messages (terrain_keys_tab.gd:310-312 vs
tag_rule_editor.gd:300-303). New `scripts/core/ui/color_list_editor.gd`:
color rows + "+ color"/"− color" buttons, `MAX_COLORS := 8` shared const,
signal `colors_changed(colors: Array)`, `set_colors()` for refresh. Swatch
size unifies to `UiKit.SWATCH` (34×26). The two guard messages unify to one
string (delta, intentional).

Serialization note: the two sites store hex differently today — terrain
keys via `_to_hex` ("#rrggbb", terrain_keys_tab.gd:47-51), tag rules via
`to_html(false)` ("rrggbb", tag_rule_editor.gd:241). The unified editor
picks one format for both; old saves still load either way (the decoders
add a missing "#"), but new saves write the unified format for both.

Acceptance: suite green; smoke: edit terrain-key class colors and tag-rule
colors; both still sample via PalettePicker and persist through save/load.

### R13 — `RunExecutor` + `RngUtil.weighted_pick` (medium, medium risk)

**RngUtil** (`scripts/core/util/rng_util.gd`): `weighted_pick(weights:
Array[float], rng: RandomNumberGenerator) -> int` — the "sum; if total ≤ 0
uniform randi; else randf()·total walk-down" algorithm duplicated in
tile_collapse_session.gd:636-660 (`_weighted_pick`) and 663-682
(`_pick_member`). Both become thin loops over the util (the member variant
maps its per-source weights into a float array first). Both samplers are
allocation-free today (bitmask walk / packed array); routing through
`Array[float]` allocates per observation step — accepted for the dedup
(the pick is O(domain) anyway), and a packed-array overload can be added
later without call-site changes if it ever profiles. The existing
`test_tile_collapse_derives_geometry_and_matches_stepped_synthesis`
(tests/test_core_algorithms.gd:138) must stay green **unmodified** — it
pins the batch-vs-stepped semantics.

**RunExecutor** (`scripts/core/ui/run_executor.gd`): the begin_run →
disable button → "Running…" status → `WorkerThreadPool.add_task` →
`call_deferred` publish → re-enable → finish_run choreography hand-rolled
in decomposition_tab.gd:236-391, synthesizers_tab.gd:228-299, and
outputs_tab.gd:191-227 (outputs has no begin_run today — 13.2 adds it).
Two further blocks are deliberately out of scope: decomposition_tab's
manual "Find Constraints" run (:452-491, `_on_find_constraints_pressed` →
`_publish_constraints` — a second, fully independent begin_run/add_task/
finish sequence with its own run id) and synthesizers_tab's interactive
session path (:322-401, chunked stepping with its own finish/fail). The
auto-constraints continuation is *not* out of scope: `_after_decompose`'s
second `add_task` (:338-351) shares the decomposition run's id and becomes
the `publish` continuation in 13.4. API shaped around the common skeleton,
not a forcing of all variants through one template:

```gdscript
class_name RunExecutor
static func launch(owner: Control, buttons: Array[Button], status: Label,
        spec: RunSpec, worker: Callable, publish: Callable) -> int
## RunSpec: kind, title, technique_id, params, inputs, stage_plan.
## begin_run's `thread` arg is deliberately absent: every migrated path
## runs on the worker thread, so launch passes "worker" (the interactive
## session path is out of scope).
## Handles: RunMonitor.begin_run, button disable/enable, status text,
## WorkerThreadPool.add_task, end/finish/fail marshalling.
```

| # | Change | File(s) |
|---|---|---|
| 13.1 | `rng_util.gd` + tests; migrate the two session samplers | new file, tile_collapse_session.gd, tests/ |
| 13.2 | `run_executor.gd`; migrate **outputs_tab** first (smallest; its `_resynthesize` gains RunMonitor records — a deliberate, user-visible improvement; smoke-check the Monitor tab shows the resynthesis run) | outputs_tab.gd |
| 13.3 | Migrate synthesizers_tab batch path | synthesizers_tab.gd |
| 13.4 | Migrate decomposition_tab (most complex: multi-stage plan; the `_after_decompose` chaining stays a decomposition_tab callback passed as `publish`) | decomposition_tab.gd |

Acceptance: suite green (incl. batch-vs-stepped equivalence); smoke:
decomposition run with auto-constraints, synthesizer batch + single run,
Outputs re-run/Re-roll — all appear in Monitor with correct stage plans and
end states; run buttons never stay disabled after a failure.

---

## Phase 3 — Shared core

### R14 — `ColorMath` util (small, low risk)

New `scripts/core/util/color_math.gd`:

- `decode_hex(hex_colors: Array) -> Array[PackedInt32Array]` — verbatim move
  of the character-identical decoders (tag_matcher.gd:53-66, named
  `_decode` there; terrain_mapper.gd:87-100, named `_decode_hex`).
- `matches(r, g, b, targets: PackedInt32Array, tol: int) -> bool` — the
  per-channel Chebyshev match from tag_matcher.gd:32-33 (inline in
  `coverage_fraction`) and terrain_mapper.gd:105-106 (cold paths only).

**Deliberately NOT migrated:** the three hot-loop copies inside PixelOverlap
(`_match_aligned` :264-268, `_satisfied` :307-310, `_px_match` :430-438) —
inline for per-pixel performance; add a comment at each: "kept inline (hot
loop); shared logic in ColorMath.matches".

New test suite `tests/test_color_math.gd` (decode round-trips incl. missing
`#`, 3- and 6-digit forms, tolerance boundaries).

### R15 — `Ids` util (small, low risk)

New `scripts/core/util/ids.gd`, single home for the id schemes:

| Function | Scheme | Current copies |
|---|---|---|
| `part(hash_hex)` | `"p_" + hash.substr(0, 12)` | part.gd:26, app_data.gd:493 |
| `image(hash_hex)` | `"img_" + hash.substr(0, 10)` | image_asset.gd:32 (single site) |
| `constraint(a_id, b_id, offset, prefix := "c_")` | `"%s%s_%s_%d_%d" % [prefix, short(a_id), short(b_id), offset.x, offset.y]` with `short(x) = x.substr(2, 6)` | constraint.gd:47-50 (rebuild_id), adjacency.gd:258-260, pixel_overlap.gd:326-327 (prefix `"o_"`) |

`constraint.gd:42-45`'s "Must stay in sync with AdjacencyExtractor's id
scheme" comment is deleted — the sync is enforced by construction. Two
schemes stay per-site as single copies: the output id (`"out_%d_%s"`,
app_data.gd:67) and adjacency's to-outside variant (`"c_%s_out_%d_%d"`,
adjacency.gd:280 — a different format string), which routes its hash
through `Ids.short` so the substr discipline still has one home. Known
residual, pre-existing and unchanged here: `rebuild_id()` applied to a
to-outside constraint (participants[1] is `"~outside"`) yields
`"c_<short>_utside_…"` — `substr(2, 6)` of `"~outside"` — instead of the
extractor's `"c_<short>_out_…"`. It stays a unique dictionary key, so it
is harmless today; fixing it would alter which ids `constraint_edits`
bind to after merges, so it stays out of scope. The
deterministic `sort_custom(by id)` triples (grid_tiles.gd:56-58,
pixel_overlap.gd:59-61, adjacency.gd:193-194) move to a `Sort.by_id(arr)`
static in the same file — one home for both determinism disciplines.

New test `tests/test_ids.gd`: golden strings pin every format — the
guarantee behind the no-save-format-change promise.

### R16 — Layering fix: remove the `AppData` reach-in (small, medium risk)

`AppData.active_terrain_classes()` is called from a technique and a data
class (pixel_overlap.gd:53 inside `extract()`, constraint_index.gd:259
inside `_build_families`), making both autoload-dependent and untestable in
isolation (tests must snapshot/restore the autoload — tests/builders.gd:7-8).

| # | Change | File(s) |
|---|---|---|
| 16.1 | `PixelOverlap.extract(..., terrain_classes: Array)` — new trailing param; same silent-empty contract for bad params | pixel_overlap.gd |
| 16.2 | `ConstraintIndex.build(..., terrain_classes: Array)` — threaded through to `_build_families` | constraint_index.gd |
| 16.3 | Every remaining call site passes `active_terrain_classes()`: `get_constraint_index`'s `ConstraintIndex.build` (app_data.gd:56-57), `_regenerate_constraints`'s `technique.extract` (app_data.gd:553), both decomposition_tab `extract` calls (:345, :466), and family_inspector's preview `build` (:72) | app_data.gd, decomposition_tab.gd, family_inspector.gd |
| 16.4 | Test call sites updated; builders.gd terrain-key snapshot/restore deleted if no longer needed | tests/ |

Acceptance: `grep -rn "AppData\." scripts/core/techniques/
scripts/core/data/` returns nothing; `grep -rn "active_terrain_classes"
scripts/` shows only app_data.gd (definition + its own tagging use) and
the 16.3 call sites — this is what keeps family_inspector's
terrain-merge preview working; suite green (PixelOverlap terrain
cases pin behavior).

### R17 — `TechniqueBase` + generic registry (small, low risk)

`get_id()`/`get_display_name()`/`get_parameter_specs()` are declared
verbatim in all three abstract bases (constraint_technique.gd:5-9,
decomposition_technique.gd:5-11, synthesizer.gd:5-7), and
`TechniqueRegistry` keeps three structurally identical dict + register/
get/get_list triplets (technique_registry.gd:4-6, 16-67).

- New `scripts/core/techniques/technique_base.gd`:
  `@abstract class_name TechniqueBase extends RefCounted` with the trio
  (`get_parameter_specs` remaining `@abstract`). The three bases re-derive
  from it and delete their copies; concrete classes unchanged (they already
  implement the methods).
- `TechniqueRegistry`: the three parallel blocks collapse to one generic
  store; `register_decomposition`, `get_decomposition`,
  `get_decomposition_techniques` (and the constraint/synthesizer
  equivalents) stay as thin kind-parameterized wrappers — the public API
  is unchanged so tabs don't move.

Acceptance: suite green (existing `TechniqueRegistry` cases in
test_state_and_components.gd untouched and green).

### R18 — AppData: `NumberedRuleList` + edit/tag-loop dedup (medium, medium risk)

Leftovers of round-1 R2 inside app_data.gd (708 lines):

| # | Change | File(s) |
|---|---|---|
| 18.1 | Inner class `NumberedRuleList` (array + next-number + changed signal; `add/update/remove/get/max_number_scan/take_number`); rules ("rule_") and tagging_rules ("tagrule_") become two instances. The public `add_rule`/`update_rule`/… API is unchanged (thin delegates) so tabs and tests don't move | app_data.gd:289-367, 694-708 |
| 18.2 | `_edit_in(store, edits, id, key, value, signal)` merges `edit_part` (:162-168) and `edit_constraint` (:203-209) — byte-identical modulo fields | app_data.gd |
| 18.3 | `apply_tagging_rules` (:374-394) and `apply_terrain_key_tags` (:448-472) collapse into `_apply_tag_predicate(predicate: Callable, report_key: String)` — only the match predicate differs (`TagMatcher.rule_matches` vs coverage ≥ minf). Per-rule/per-class report dicts keep their existing shapes exactly (tests pin them) | app_data.gd |
| 18.4 | `load_project` emits from an enumerated `_ALL_CHANGED_SIGNALS` list (app_data.gd:683-690 — the hand-rolled eight-emit sequence that once forgot `tagging_rules_changed`) | app_data.gd |

Acceptance: suite green — test_app_data_layers.gd's CRUD/numbering/
idempotency/report-shape cases must pass **unmodified** (they are the pin);
smoke: add/edit/remove rules and tagging rules, renumber on load, apply
tagging + terrain keys, save/load round-trip.

---

## Phase 4 — New UI features (each small, built on the above)

### R19 — Confirm destructive actions (small)

`UiKit.confirm` (from R9) applied to the three unconfirmed destructive
actions: Discard Selected Image (images_tab.gd:134-140), Discard Selected
Output (outputs_tab.gd:160-166), Merge Parts (parts_tab.gd:501-506). Dialog
texts state what is discarded and that it is not undoable (no undo system
exists — AppData has only `clear_all_edits`). Smoke: each dialog cancels
cleanly and confirms the action.

### R20 — Global run-in-progress state (medium)

Today nothing prevents editing parts/constraints mid-run, and each tab
only disables its own buttons for its own runs (decomposition,
synthesizers, and outputs' two re-synthesize buttons). `RunMonitor` gains:

- `signal busy_changed` (next to `runs_changed`), emitted on the
  running→terminal transitions.
- `func has_running() -> bool` — any record with `status == "running"`.

main.gd adds a one-line status strip under the menu bar: hidden when idle;
"⟳ Running: {title}…" while active (poll-free: wired to `busy_changed`).
Tabs with AppData-mutating buttons (Parts override/tag/merge, Constraints
rule edits, Images discard, Outputs discard/resynthesize) bind their
buttons' `disabled` state via a `TabBase` helper
`_bind_run_lock(buttons)`; decomposition/synthesizers keep their existing
run-button choreography (already covered by RunExecutor). Smoke: start a
decomposition, verify the banner shows and edit buttons disable; finish and
verify re-enable.

### R21 — Copy button for run status (small)

Monitor's copy-to-clipboard pattern (monitor_tab.gd:176-201) becomes
`UiKit.copy_button(get_text: Callable)`; Decomposition and Synthesizers
status lines each gain one. Smoke: copy from a finished run, paste into a
text editor.

### R22 — Standardized empty-state hints (small)

`TabBase._set_empty_state` (from R10) applied everywhere. Existing
messages move to the helper: Parts ("No parts. Run a decomposition
first."), Constraints (same), Synthesizers (its parts-empty message at
synthesizers_tab.gd:233), Terrain Keys (its "No classes defined." note,
terrain_keys_tab.gd:78-84). New: Images ("No images loaded."),
Decomposition (pre-run), Outputs ("No outputs yet. Run a synthesis." — a
list-side hint; the right pane's existing "No synthesis yet." meta label
stays). Monitor is exempt (its list is empty by design until the first
run; the detail pane already shows its own "No run selected."
placeholder). Smoke: fresh project shows a hint on every tab; hints clear
on first data.

---

## Phase 5 — Test backfill & wrap-up

### R23 — Test backfill + docs (small)

- `tests/test_project_codec.gd` (new): round-trip plus the **legacy
  terrain_keys migration** (project_codec.gd:60-72) — real v1-save logic
  currently untested.
- Direct suites for `BitMask` (`kth`/`only`/`first`/ctz-cache edges) and
  `StripUtil` (`side()` on non-square parts, `classes()` with empty map).
- Adversarial `JsonCodec` case: a user dictionary legitimately containing
  `{"__v2i": [...]}` (documents the collision behavior; fix only if
  trivially namespaceable).
- `tests/test_ids.gd`, `test_color_math.gd`, rng tests land with their
  phases (R15, R14, R13).
- Full `./run_tests.sh`; manual end-to-end smoke: load sample project →
  decompose → constraints → synthesize → outputs → monitor → save/load.
- Move this file to `docs/archive/` with a completion-status header, per
  repo convention.

---

## Dependency graph

```
R9 ──► R10 ──► R11, R12 (independent of each other)
R9, R10 ──► R13 ──► R20, R21
R9 ──► R19
R10 ──► R22
R14, R15, R16, R17 (independent of UI phases)
R18 (independent)
R23 last
```

Suggested execution order: R9 → R10 → R11 → R12 → R13 → R14 → R15 → R16 →
R17 → R18 → R19 → R20 → R21 → R22 → R23. No phase reorders work done by a
later phase; phases may be executed partially and resumed.
