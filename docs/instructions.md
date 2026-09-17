# How to Use WFCLab

WFCLab walks you through example-based procedural generation in four stages: **load one or more examples → decompose them into tiles & constraints → edit parts & constraints → synthesize new output**. This guide follows that workflow with screenshots from the application.

## Application Layout

![WFCLab output example](https://gitlab.com/AngularAngel/wfclab/-/blob/main/images/screenshots/WFC1.png)

The main window consists of a menu bar at the top and a tab container with six tabs: **Images**, **Decomposition**, **Parts**, **Constraints**, **Synthesizers**, and **Outputs**. The **File** menu provides **Save Project...** and **Load Project...** options, while the **Edit** menu offers **Clear All Edits...** to discard manual edits (enabled flags, weight overrides, and part merges).

---

## 1. Images Tab

![WFCLab input example](https://gitlab.com/AngularAngel/wfclab/-/blob/main/images/screenshots/WFC2.png)

The Images tab is where you load and manage the source images that WFCLab will decompose into parts and constraints.

### Load Images...

Opens a file dialog that accepts **PNG**, **JPEG**, **WebP**, and **BMP** image formats. You can select multiple files at once.

### Discard Selected Image

Removes the currently selected image from the project. This button is disabled until an image is selected in the list.

### Image List

Displays all loaded images with 96×96 pixel thumbnails. Selecting an image shows a large preview on the right side of the tab.

### Fit to Window

When checked (the default), the preview image is scaled to fit the available window space. Uncheck it to view the image at its native pixel resolution, with scrollbars appearing as needed.

### Preview Area

Shows the currently selected image at full resolution (or fitted, depending on the **Fit to Window** setting). A label above the preview displays the image's dimensions and other metadata.

---

## 2. Decomposition Tab

![WFCLab tile decomposition](https://gitlab.com/AngularAngel/wfclab/-/blob/main/images/screenshots/WFC3.png)

The Decomposition tab is where you configure and execute a decomposition run, which breaks input images into tiles (parts) and extracts adjacency constraints.

### Technique (Decomposition Technique)

A dropdown menu listing all available decomposition techniques registered in the `TechniqueRegistry`. Each technique has a display name and a unique ID. The selected technique determines how the input image is broken into tiles. Different techniques may produce different tile shapes, sizes, or overlapping behavior.

### Parameters

A dynamically generated parameter section that changes based on the selected decomposition technique. Each technique declares its own parameter specifications (via `get_parameter_specs()`), and the UI builds appropriate widgets (spin boxes, check boxes, dropdowns, etc.) for each one.

Currently, only the **Grid Tiles** technique is implemented.

**Grid Tiles**:
- **Tile size / Grid dimensions**: Controls the size of each extracted tile. Smaller tiles produce more granular decompositions but may lead to a larger number of unique parts.
- **Stride**: How far apart the beginning of each tile are. If set to the same values as the tile size, then it will break the image up into evenly spaced tiles; if set to a smaller value, then tiles will partially overlap.
- **Edge Handling**: How edge tiles are treated. *Discard Partial* – tiles that would extend beyond the image edge are skipped. *Clamp* – partial-edge tiles are pulled inward so they stay within the image.
- **Dedupe Identical Tiles**: When true, identical tiles (within tolerance) are merged into a single part with multiple occurrences, and all constraints will reference that part.
- **Dedupe Tolerance**: Maximum per-pixel difference allowed for two tiles to be considered identical. Only used when dedupe is true.
- **Rotation & Reflection toggles**: Include rotated and reflected variations of the loaded tiles, with a separate toggle for each individual rotation & reflection.

### Constraint Extraction

This section lists all available constraint extraction techniques as check buttons. Each technique can be independently enabled or disabled, and each has its own expandable parameter section.

Constraint extraction techniques analyze the decomposed tiles and learn which tiles may sit next to which other tiles in which directions. Currently, only the **Adjacency** technique is included.

**Adjacency**:
- **Neighborhood**: N4 uses the four orthogonal neighbours (up, down, left, right). N8 adds the four diagonal neighbours.
- **Directional**: When true, constraints are directional (A→B is distinct from B→A). When false, adjacency is treated as undirected.
- **Grid Step**: Tile Size uses the tile size from the decomposition as the step between adjacent parts. Custom lets you specify a separate step via `custom_step`.
- **Custom Step**: Only active when `step_mode` is Custom. The pixel offset between adjacent slots.
- **Image Edge Evidence**: How to treat adjacency at image edges. Ignore – edges are not considered. Wrap (tiling) – edges wrap around (toroidal). Border-anchored – edges are treated as fixed borders.

### Images (click to toggle inclusion)

An item list showing all loaded images. The list uses multi-selection mode, allowing you to click images to toggle their inclusion in the decomposition run. Only images selected here will be processed.

### Run Decomposition

Executes the decomposition and constraint extraction pipeline. The status label below the button reports progress or any errors. After completion, the Parts and Constraints tabs are populated with the results.

---

## 3. Parts Tab

![WFCLab parts view](https://gitlab.com/AngularAngel/wfclab/-/blob/main/images/screenshots/WFC4.png)

The Parts tab lets you browse the parts (tiles) extracted from the last decomposition run, inspect them, edit their properties, compare them, and merge them.

### Parts Grid

The main area displays a grid of tile thumbnails (72×72 pixels each), with up to 500 tiles shown at once. Each thumbnail represents a unique part extracted from the source images. Click a part to select it and see its details in the inspector on the right.

### Selected Part Inspector

When you select a part in the grid, the right panel shows:

#### Preview

A large preview (160×160 pixels) of the selected part, displayed with nearest-neighbor filtering to preserve pixel accuracy.

#### Info

Displays metadata about the part, including its ID, canonical ID, hash, and canonical hash.

#### Enabled

A toggle that controls whether this part is available for synthesis. Disabled parts are excluded from the tile set during synthesis. This is useful for removing unwanted or redundant tiles.

#### Transforms for source part

A set of check boxes for each possible D4 transform: **rot90**, **rot180**, **rot270**, **flip_h**, and **flip_v** (identity is implicitly included). Checking a transform means that orientation of the part is considered valid for synthesis. When two parts are pixel-equal up to a D4 transform, they join the same "transform family" (formerly called an orbit). The canonical member is chosen as the orientation with the lexicographically minimal hash of the eight orientations, ensuring stable IDs across images and runs.

#### Weight override

A check box that, when enabled, allows you to manually override the derived weight of the part. The adjacent spin box (0.0 to 99999.0) sets the override value. The weight controls how frequently a part is selected during synthesis. Higher weights make a part more likely to appear in the output.

#### Pin for comparison

Pins the currently selected part for side-by-side comparison with another part. Pinning a part does not change the project state; it is a temporary UI feature for inspection.

#### Comparison: pinned vs selected

When a part is pinned and another part is selected, this section shows three preview images: the pinned part, the selected part, and a diff image highlighting pixel differences. Below the previews, the **Merge selected INTO pinned** button becomes available. Merging treats the selected part as being the same as the pinned part, which is useful when you want to unify visually similar tiles that were not automatically grouped into the same transform family.

#### Neighbors

Lists neighboring parts: tiles that appear adjacent to the selected part in the source image, along with the direction and frequency of each adjacency. This gives you a quick view of the learned constraints involving this part.

#### Occurrences

Lists all occurrences of the selected part in the source images, each with the image ID and pixel position. Selecting an occurrence in this list navigates to that location in the Images tab.

---

## 4. Constraints Tab

![WFCLab constraints view](https://gitlab.com/AngularAngel/wfclab/-/blob/main/images/screenshots/WFC5.png)

The Constraints tab is where you inspect and adjust the rules WFCLab learned from the example. Each rule records which tiles may sit next to which other tiles, in which directions. You can review and adjust these before synthesis and view where they were learned from.

The constraints view organizes rules by direction (north, south, east, west) and by part. For each part, you can see which other parts are allowed to appear adjacent in each direction, along with the frequency with which that adjacency was observed in the source. You can enable or disable individual constraints to fine-tune the synthesizer's behavior.

---

## 5. Synthesizers Tab

![WFCLab synthesis in progress](https://gitlab.com/AngularAngel/wfclab/-/blob/main/images/screenshots/WFC6.png)

The Synthesizers tab is where you configure and run a synthesizer over the current parts and constraints, producing a layout that is consistent with the original example but not identical to it.

### Synthesizer

A dropdown menu listing all available synthesizer techniques registered in the `TechniqueRegistry`. The synthesizer implements the actual wave-function-collapse algorithm that generates new layouts from the learned constraints.

### Parameters

A dynamically generated parameter section that changes based on the selected synthesizer technique. Each synthesizer declares its own parameter specifications. Common parameters may include:

- **Output width / height**: The dimensions of the generated grid, in tiles.
- **Contradiction Strategy**: What to do when no valid part can be placed in a slot. *Stop immediately* – abort the run. *Restart* – clear the grid and start over (up to `max_recovery_attempts`). *Backtracking* – undo recent assignments and try alternatives.
- **Max Recovery Attempts**: Maximum number of times the synthesizer may restart or backtrack before giving up. Only relevant for the Restart and Backtracking strategies.
- **Unobserved = Free**: When true, slots that have not yet been observed are considered to have a full domain of possible parts (i.e., they are free). When false, unobserved slots are treated as unconstrained only if no constraint touches them.

### Seed

A spin box (0 to 999999) that sets the random seed for the synthesis run. The same seed with the same parts and constraints will always produce the same output. A **Random** button beside it generates a random seed. Running with a different seed produces a different valid layout, as synthesis is not fully deterministic.

### Interactive (step through)

When checked, the synthesizer runs on the main thread with **Step** and **Play** controls instead of running on a worker thread. This mode lets you watch the synthesis process unfold and interact with it. The same seed and same result still apply — interactive mode does not change the output, only how it is presented.

### Synthesize

Runs the synthesizer in one pass and produces an output. When **Interactive** is unchecked, this is the primary button to start synthesis.

### Interactive Session Controls

When **Interactive** is checked and synthesis starts, the following controls become visible:

- **Step**: Performs one observation and full propagation step. Click repeatedly to step through the synthesis process.
- **Micro-step**: When checked, each **Step** click performs either one observation or one propagation queue entry instead of a full observation-plus-propagation cycle. This gives you finer control over the algorithm's execution.
- **Play**: Starts automatic stepping at the selected speed.
- **Speed**: A dropdown with options **1/s**, **4/s**, **15/s**, **60/s**, and **Max** (unlimited). The default is 15/s.
- **Restart**: Starts a new session with the current seed, resetting the grid to its initial state.
- **Close**: Stops the interactive session and hides the session controls.

### Live Preview

The right side of the Synthesizers tab shows a live preview of the synthesis grid. As the algorithm runs (whether in one pass or interactively), the preview updates to show the current state.

- **Fit**: When checked (default), the preview is scaled to fit the available space. Uncheck for a native-resolution view with scrollbars.
- **Entropy view**: When checked, the preview shows the entropy (uncertainty) of each cell instead of the collapsed tiles. Cells with high entropy have many possible candidates; cells with low entropy have few or none. This is useful for understanding where the algorithm is uncertain or has reached a contradiction.
- **Click a slot to place/clear**: In interactive mode, you can click on a cell in the preview to manually place the currently selected candidate or clear the cell. Arrow keys move the cursor between cells, and **Enter** picks a candidate.

---

## 6. Outputs Tab

![WFCLab output example 2](https://gitlab.com/AngularAngel/wfclab/-/blob/main/images/screenshots/WFC7.png)

![WFCLab output example 3](https://gitlab.com/AngularAngel/wfclab/-/blob/main/images/screenshots/WFC8.png)

The Outputs tab displays the last synthesis result and allows you to manage and re-run syntheses without returning to the Synthesizers tab.

### Fit to window

When checked (default), the output preview is scaled to fit the available space. Uncheck for a native-resolution view with scrollbars.

### Dimensions

A label showing the width and height of the current output, in tiles.

### Output Preview

The main area shows the most recent synthesis output as a rendered image, with nearest-neighbor filtering to preserve pixel accuracy.

### Last Synthesis

A list of all synthesis outputs produced in the current session, each with a 96×96 thumbnail. Selecting an output displays it in the preview and enables the **Discard Selected Output** button.

### Discard Selected Output

Removes the selected output from the session. This button is disabled until an output is selected.

### Meta Label

Displays metadata about the current output, including the synthesizer used, the seed, and the output dimensions. When no synthesis has been run yet, it shows "No synthesis yet. Run one from the Synthesizers tab.".

### Re-synthesize (same seed)

Re-runs the synthesizer with the same seed and the same parts and constraints, producing an identical output. This is useful for refreshing the preview or for testing that the synthesis pipeline is deterministic.

### Synthesize (new seed)

Re-runs the synthesizer with a fresh random seed, producing a different but still valid layout. This is the quickest way to explore variations without returning to the Synthesizers tab.

---

## Workflow Summary

1. **Load images** in the **Images** tab (bundled samples or your own).
2. **Configure and run decomposition** in the **Decomposition** tab, choosing a decomposition technique and one or more constraint extraction techniques.
3. **Inspect and edit parts** in the **Parts** tab: enable/disable tiles, adjust weights, pin and merge similar parts, and review neighbors and occurrences.
4. **Review constraints** in the **Constraints** tab, adjusting adjacency rules as needed.
5. **Configure and run synthesis** in the **Synthesizers** tab, choosing a synthesizer (currently **TileCollapse**), setting a seed, and optionally using interactive mode.
6. **Explore and manage outputs** in the **Outputs** tab, re-synthesizing with the same or a new seed.
7. **Save your project** via **File → Save Project...** to preserve your parts, constraints, and edits for later sessions.

---

## File Formats

- **Project files** use the `.wfcproj` extension and store the full project state, including image assets, decomposition runs, parts, constraints, and manual edits.
- **Source images** can be PNG, JPEG, WebP, or BMP.
- **Sample projects** are available in the `saves/` directory, and **sample images** are in `images/samples/`.

## Next Steps

- Load a project from `saves/` to pick up where an earlier session left off.
- Add your own sample images under `images/samples/` and re-run the full pipeline.
- See the [project README](../README.md) for requirements and build instructions.