# Refactoring Plan — Round 3: Pane Standardization & Shared View Components

> **Status:** In progress. Baseline re-run green before R24 (17 suites /
> 111 cases) plus headless construction smoke of the main scene (all 8
> tabs build, no script errors). Same cadence after every phase; one
> commit per phase.

Plan triggered by the 2026-09-25 review of the tab layer. Two threads:

- **Pane standardization (R24, R25, R28):** the right-hand inspector
  panes disagree on scrolling — Parts scrolls (`UiKit.scroll_panel`),
  Constraints and Outputs are plain VBoxes that clip their content on
  short windows with no way to reach it. Along the way: one dead
  `ScrollContainer` in images_tab, a hand-rolled Monitor detail scroll,
  and the post-run "jump to tab" dance triplicated.
- **Shared view components (R26, R27):** the fit/1:1 view-mode logic is
  triplicated verbatim across Images/Outputs/Synthesizers, and the
  technique OptionButton + parameters-box rebuild is duplicated between
  Decomposition and Synthesizers.

R29 bundles the simple UI features requested alongside the refactor —
each a direct combination of pieces that already exist.

---

## R24 — UiKit: `button`, `thumb_grid`, `status_copy_row`; dead-scroll removal

**Files:** `scripts/core/ui/ui_kit.gd`, `scripts/core/tabs/*.gd`,
`scripts/core/ui/palette_picker.gd`, `scripts/core/ui/neighbors_panel.gd`

- `UiKit.button(text, tooltip, handler)` — the 4-line Button
  construction (text/tooltip/pressed/add) repeated across every tab;
  absorbs monitor_tab's private `_mk_button`.
- `UiKit.thumb_grid(columns, hsep := 4, vsep := 4)` — GridContainer
  configured for thumbnail cells; used by the parts grid, PalettePicker
  swatch grid, NeighborsPanel grids, and SlotPicker grid.
- `UiKit.status_copy_row(get_text)` — HBox + status label + Copy button
  wired together (the R21 pattern on the two run tabs).
- images_tab `_ready`: delete the never-referenced `scroll`
  ScrollContainer added above the real `_scroll`.

Acceptance: suite green + smoke; `grep -n "var scroll" images_tab.gd`
returns only the real one; no `_mk_button` left in monitor_tab.gd.

## R25 — Every stacked inspector pane scrolls

**Files:** `constraints_tab.gd`, `outputs_tab.gd`, `monitor_tab.gd`,
`ui_kit.gd`

- `UiKit.scroll_panel` gains a Container-aware branch: when `parent` is
  a Container and no min width is given, use vertical EXPAND_FILL
  instead of FULL_RECT anchoring (previously the 0-width case assumed
  root hosting). The split-pane case (`min_width > 0`) is unchanged.
- Constraints right pane: plain VBox → `UiKit.scroll_panel(split, 300)`.
  The matrix (left) already scrolls; now the inspector does too — the
  reported clipping on short windows is fixed.
- Outputs right pane: plain VBox → `UiKit.scroll_panel(split, 260)`.
- Monitor detail pane: hand-rolled ScrollContainer → factory call
  (horizontal stays disabled; RichTextLabel settings unchanged).

ItemList min heights inside the panes keep working exactly as the Parts
tab's occurrence list already does: lists hold their minimum height and
the pane scrolls when the window is short. That is the standard this
round establishes: **stacked inspector content always lives in a scroll
panel; viewports (image previews) keep their dedicated scroll.**

Acceptance: suite green + smoke; each tab's inspector reachable by
keyboard scroll on a short window (manual check listed at the bottom).

## R26 — `PreviewPane` shared component

**Files:** new `scripts/core/ui/preview_pane.gd`; `images_tab.gd`,
`outputs_tab.gd`, `synthesizers_tab.gd`

`PreviewPane extends VBoxContainer` owns the toolbar row (Fit-to-window
check + dims label + caller-added extras), the ScrollContainer, and a
`PreviewRect` preview. It centralizes:

- `_apply_view_mode` — KEEP_ASPECT_CENTERED fit vs KEEP 1:1 with
  texture-sized minimum (three verbatim copies today; the synthesizers
  variant's null-texture guard becomes the shared behavior).
- `_apply_filter_mode` — NEAREST when the texture is upscaled,
  LINEAR when downscaled. Now applies uniformly; Synthesizers
  previously stayed NEAREST always (its outputs are the same kind of
  pixel images as Outputs, which already switched).
- `scroll_to_region(rect)` — center a pixel region in 1:1 mode
  (from images_tab's occurrence jump).

API: `preview` (the PreviewRect — Synthesizers adds its overlay and
input wiring there), `dims_label`, `set_fit_enabled`, signal
`view_changed` (Synthesizers redraws its slot overlay), and
`scroll_to_region`. Images keeps its occurrence flash-highlight via the
PreviewRect child.

Acceptance: suite green + smoke; Fit toggle, 1:1 scrollbars, and (Images)
occurrence jump behave as before on all three tabs.

## R27 — `TechniquePanel` shared by Decomposition / Synthesizers

**Files:** new `scripts/core/ui/technique_panel.gd`;
`decomposition_tab.gd`, `synthesizers_tab.gd`

VBox with the technique label, the registry-populated OptionButton
(display name shown, id in metadata), a "Parameters" label, and the
params box. Signal `technique_selected(id: StringName)`; method
`rebuild_params(specs, values, initial)` wraps the clear + ParamBuilder
dance. `select_initial()` picks item 0 and emits. Tabs keep their own
selection handlers (Decomposition's `apply_config` flow is untouched).

Acceptance: suite green + smoke; technique switching and project
load (apply_config) unchanged.

## R28 — `TabBase.switch_to_tab(name)`

**Files:** `tab_base.gd`, `decomposition_tab.gd` ×2, `synthesizers_tab.gd`

The `get_parent() as TabContainer → get_node_or_null → current_tab`
dance after publish becomes `switch_to_tab("Constraints")` etc. Lookup
stays name-based (tabs are named in main.gd).

Acceptance: suite green + smoke; post-run tab jumps unchanged.

## R29 — Simple features (extensions of existing pieces)

1. **Parts grid id filter** — a "Filter:" LineEdit beside the tag
   filter; case-insensitive substring on part ids, composing with the
   tag filter; the grid status line reports the filtered count exactly
   as the tag filter already does.
2. **Inspector copy buttons** — the Parts info line and the Constraints
   pair-info line gain the shared `UiKit.copy_button` (R21 pattern):
   one-click copy of the id/size/weight text that bug reports want.
3. **Outputs "Save All as PNG..."** — beside the existing per-output
   save: a FILE_MODE_OPEN_DIR dialog, then saves every output with the
   same name-sanitization as `_on_save_png`; the meta label reports the
   count. Reuses the existing file-dialog factory and output list.

Acceptance: suite green + smoke; manual checklist below.

---

## Manual smoke checklist (in-editor, once at the end)

- Short window (resize below content height): Constraints and Outputs
  inspectors scroll; Parts still scrolls; nothing else regressed.
- Images: load multi-select, fit toggle, 1:1 + occurrence jump from
  Parts/Constraints still centers and flashes.
- Outputs: fit toggle, save one, save all, discard confirm.
- Synthesizers: interactive session, entropy view, slot picker; fit
  toggle redraws the overlay.
- Decomposition: full run + project save/load round-trip (apply_config
  path through TechniquePanel).
- Monitor: report scroll + copy buttons.
