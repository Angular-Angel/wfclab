# Exporting WFCLab demos

WFCLab is configured to export 64-bit Linux and Windows release builds using the `Linux` and `Windows` presets in [`export_presets.cfg`](../export_presets.cfg). Both presets embed the Godot resource package in the executable, producing one self-contained demo file per platform. Generated demo files are intentionally ignored by Git in [`build/`](../build/).

## Prerequisites

1. Install Godot **4.7.1**, matching the project feature version in [`project.godot`](../project.godot).
2. Install the **export templates for exactly the same version**. In the Godot editor, use **Editor > Manage Export Templates > Download and Install**. On a Linux host, this one template installation supports both Linux and Windows desktop exports.
3. Confirm that the project opens without import or script errors.

## Build both demos from the command line

Run these commands from the repository root. Replace `godot` with the path to your Godot executable if it is not on `PATH`.

```bash
mkdir -p build/linux build/windows
godot --headless --path . --import
godot --headless --path . --export-release Linux build/linux/WFCLab.x86_64
godot --headless --path . --export-release Windows build/windows/WFCLab.exe
```

The `--import` step ensures imported assets are current before the release packages are generated. `--export-release` uses the checked-in preset names, so it can be repeated without configuring paths in the editor.

Expected output:

```text
build/linux/WFCLab.x86_64
build/windows/WFCLab.exe
```

### Run the Linux build

```bash
chmod +x build/linux/WFCLab.x86_64
./build/linux/WFCLab.x86_64
```

### Package the Windows build

Zip [`WFCLab.exe`](../build/windows/WFCLab.exe) and extract it before running it on Windows. No separate `.pck` file is required.

## Build from the Godot editor

1. Open **Project > Export**.
2. Select `Linux` and click **Export Project**. Leave the configured destination as `build/linux/WFCLab.x86_64`.
3. Select `Windows` and click **Export Project**. Leave the configured destination as `build/windows/WFCLab.exe`.
4. Distribute the resulting executable for each platform. No adjacent `.pck` file is required.

## Validation checklist

- Verify the two platform executables exist after building.
- Start the Linux executable on a 64-bit Linux system.
- Start the Windows executable on a 64-bit Windows system.
- Check that a sample image can be loaded and a project can be saved and reopened.

## Troubleshooting

**No export template found**

The editor and templates do not match. Reinstall the export templates for the exact Godot version reported by `godot --version`, then retry the export.

**A preset is missing in the Export dialog**

Restore [`export_presets.cfg`](../export_presets.cfg) and reopen the project. Godot discovers named export presets from that file.
