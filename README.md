# WFCLab

WFCLab is a Godot 4 desktop application for exploring example-based procedural generation with wave-function-collapse-inspired techniques. It includes sample images, tile decomposition, adjacency constraints, and tile-collapse synthesis tools at current, with plans to add more options in the future.

![WFCLab synthesis output](https://gitlab.com/AngularAngel/wfclab/-/blob/main/images/screenshots/WFC1.png)

A full walkthrough of the workflow — from input example through decomposition, constraints, and synthesis — is available in [docs/instructions.md](docs/instructions.md).

## Requirements

- [Godot 4.7.1](https://godotengine.org/download/archive/4.7.1-stable/), the version used to create the current demo artifacts.
- Godot export templates for the same Godot version when creating distributable builds.

## Run from the editor

- Import this directory in Godot.
- Open [project.godot](https://gitlab.com/AngularAngel/wfclab/-/blob/main/project.godot) and run the main scene with `F6`, or run the project with `F5`.
- Load a supplied project from [saves/](https://gitlab.com/AngularAngel/wfclab/-/tree/main/saves) or add sample images from [images/samples/](https://gitlab.com/AngularAngel/wfclab/-/tree/main/images/samples).

## Demo builds

The repository includes reusable Linux and Windows release presets in [export_presets.cfg](https://gitlab.com/AngularAngel/wfclab/-/blob/main/export_presets.cfg). Each preset embeds the resource package in its executable, so every demo is distributed as one file. Generated builds are written beneath [build/](https://gitlab.com/AngularAngel/wfclab/-/blob/main/build) and deliberately excluded from version control.

For complete, repeatable command-line and editor export instructions, see [docs/exporting.md](https://gitlab.com/AngularAngel/wfclab/-/blob/main/docs/exporting.md).

## Project layout

- [scenes/main.tscn](https://gitlab.com/AngularAngel/wfclab/-/blob/main/scenes/main.tscn) — application entry scene.
- [scripts/core/](https://gitlab.com/AngularAngel/wfclab/-/tree/main/scripts/core) — application data, UI, techniques, and utilities.
- [images/samples/](https://gitlab.com/AngularAngel/wfclab/-/tree/main/images/samples) — example source images and tile collections.
- [saves/](https://gitlab.com/AngularAngel/wfclab/-/tree/main/saves) — sample WFCLab project files.
- [docs/instructions.md](docs/instructions.md) — step-by-step usage guide with screenshots.
- [docs/design/basic_outline.md](https://gitlab.com/AngularAngel/wfclab/-/blob/main/docs/design/basic_outline.md) — design outline.

## License

This project is distributed under the terms in [LICENSE](https://gitlab.com/AngularAngel/wfclab/-/blob/main/LICENSE).