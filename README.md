# WFCLab

WFCLab is a Godot 4 desktop application for exploring example-based procedural generation with wave-function-collapse-inspired techniques. It includes sample images, tile decomposition, adjacency constraints, and tile-collapse synthesis tools at current, with plans to add more options in the future.

## Requirements

- [Godot 4.7.1](https://godotengine.org/download/archive/4.7.1-stable/), the version used to create the current demo artifacts.
- Godot export templates for the same Godot version when creating distributable builds.

## Run from the editor

1. Import this directory in Godot.
2. Open [`project.godot`](project.godot) and run the main scene with <kbd>F6</kbd>, or run the project with <kbd>F5</kbd>.
3. Load a supplied project from [`saves/`](saves/) or add sample images from [`images/samples/`](images/samples/).

## Demo builds

The repository includes reusable `Linux` and `Windows` release presets in [`export_presets.cfg`](export_presets.cfg). Each preset embeds the resource package in its executable, so every demo is distributed as one file. Generated builds are written beneath [`build/`](build/) and deliberately excluded from version control.

For complete, repeatable command-line and editor export instructions, see [`docs/exporting.md`](docs/exporting.md).

## Project layout

- [`scenes/main.tscn`](scenes/main.tscn) — application entry scene.
- [`scripts/core/`](scripts/core/) — application data, UI, techniques, and utilities.
- [`images/samples/`](images/samples/) — example source images and tile collections.
- [`saves/`](saves/) — sample WFCLab project files.
- [`docs/design/basic_outline.md`](docs/design/basic_outline.md) — design outline.

## License

This project is distributed under the terms in [`LICENSE`](LICENSE).
