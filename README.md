# Sage and Triton One Shot

A tiny retro-style Windows installer for adding **Triton** and **SageAttention** to a ComfyUI Python environment.

It is meant to feel like a compact pocket game console: choose a ComfyUI install, press **A**, and let it install into that ComfyUI virtual environment.

## What It Does

- Finds local ComfyUI installs.
- Lets you choose the target ComfyUI folder.
- Detects that ComfyUI's Python, PyTorch, and CUDA versions.
- Installs a matching `triton-windows` package.
- Installs a matching Windows SageAttention wheel from `woct0rdho/SageAttention`.
- Verifies that `triton` and `sageattention` can be imported.

It installs into the selected ComfyUI environment only. It does not install into your global Windows Python.

## Requirements

- Windows
- ComfyUI with a Python environment such as `.venv`
- PyTorch 2.9 or newer
- CUDA 12.x or CUDA 13.x PyTorch build
- Internet connection

Close ComfyUI before installing.

## Quick Start

1. Download this repository as a ZIP, then extract it.
2. Double-click `PingPong-SageInstaller.bat`.
3. Pick your ComfyUI folder from the dropdown, or use `...` to select it manually.
4. Press **A** to install.
5. Press **B** to verify imports.
6. Start ComfyUI with `--use-sage-attention`.

In the ComfyUI log, look for a Sage Attention message such as `Using sage attention`.

## Buttons

- `SCAN`: Search common ComfyUI locations again.
- `...`: Manually select a ComfyUI folder.
- `A`: Install Triton and SageAttention.
- `B`: Verify imports.
- `C`: Close the installer.

## Notes

This helper currently targets the Windows wheels published by:

- `triton-windows`
- `woct0rdho/SageAttention`

The exact package choice is based on your selected ComfyUI environment's PyTorch and CUDA versions.

## Safety

This is a small PowerShell/Batch utility, so you can inspect the source before running it. The installer runs package commands through the selected ComfyUI Python, for example:

```powershell
path\to\ComfyUI\.venv\Scripts\python.exe -m pip install ...
```

## License

MIT
