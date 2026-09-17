# How to Use WFCLab

WFCLab walks you through example-based procedural generation in four stages: **load one or more examples → decompose them into tiles & constraints → edit parts & constraints → synthesize new output**. This guide follows that workflow with screenshots from the application.

## 1. Output Example

The result of a full WFCLab synthesis run: a new, coherent layout generated from the constraints learned from the input example.

![WFCLab output example](https://gitlab.com/AngularAngel/wfclab/-/blob/main/images/screenshots/WFC1.png)

## 2. Input Example

Start by loading one or more source images. WFCLab reads the images and treats them as the "examples" the generator will decompose for parts and constraints. You can use one of the bundled samples from `images/samples/` or import your own.

![WFCLab input example](https://gitlab.com/AngularAngel/wfclab/-/blob/main/images/screenshots/WFC2.png)

## 3. Decomposition

WFCLab breaks the input image into a grid of tiles. Each tile is a small sub-region of the original image that will become a candidate during synthesis.

![WFCLab tile decomposition](https://gitlab.com/AngularAngel/wfclab/-/blob/main/images/screenshots/WFC3.png)

## 4. Parts

After decomposition, the tiles are organized into **parts** — Tiles extracted from the source image according to the decomposition settings. You can pin these for comparison and then merge them, if you want to treat them some of them as being the same  part.

![WFCLab parts view](https://gitlab.com/AngularAngel/wfclab/-/blob/main/images/screenshots/WFC4.png)

## 5. Constraints

The constraints view is where you inspect the rules WFCLab learned from the example. Each rule records which tiles may sit next to which other tiles, in which directions. You can review and adjust these before synthesis, and view where they were learned from.

![WFCLab constraints view](https://gitlab.com/AngularAngel/wfclab/-/blob/main/images/screenshots/WFC5.png)

## 6. Synthesis

Run synthesis to generate new output. WFCLab collapses the tile grid according to the adjacency constraints, producing a layout that is consistent with the original example but not identical to it.

![WFCLab synthesis in progress](https://gitlab.com/AngularAngel/wfclab/-/blob/main/images/screenshots/WFC6.png)

## 7. More Output Examples

Synthesis is not fully deterministic — running it again with the same constraints but a different seed produces different valid layouts. These two screenshots show alternative outputs generated from the same input.

![WFCLab output example 2](https://gitlab.com/AngularAngel/wfclab/-/blob/main/images/screenshots/WFC7.png)

![WFCLab output example 3](https://gitlab.com/AngularAngel/wfclab/-/blob/main/images/screenshots/WFC8.png)

## Next Steps

- Load a project from `saves/` to pick up where an earlier session left off.
- Add your own sample images under `images/samples/` and re-run the full pipeline.
- See the [project README](../README.md) for requirements and build instructions.