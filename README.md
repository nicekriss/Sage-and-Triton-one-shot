# Sage and Triton One Shot

A tiny retro-style Windows installer for adding **Triton** and **SageAttention** to a ComfyUI Python environment.

It opens like a small pocket game console: choose a ComfyUI install, press **A**, and install into that ComfyUI virtual environment.

## What It Does

- Finds local ComfyUI installs in the background.
- Lets you choose the target ComfyUI folder from the dropdown.
- Lets you manually select a folder with the `...` button.
- Detects that ComfyUI's Python, PyTorch, and CUDA versions.
- Installs a matching `triton-windows` package.
- Installs a matching Windows SageAttention wheel from `woct0rdho/SageAttention`.
- Verifies that `triton` and `sageattention` can be imported.

It installs into the selected ComfyUI environment only. It does not install into your global Windows Python.

## Requirements

- Windows
- Windows PowerShell 5.1 or newer
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

## Windows Security Warnings

Windows may block scripts downloaded from the internet.

- If the ZIP is blocked: right-click the ZIP, open **Properties**, check **Unblock**, then extract it again.
- If SmartScreen appears: choose **More info**, then **Run anyway**.
- You do not need to permanently change your PowerShell execution policy. The launcher runs only this tool with `-ExecutionPolicy Bypass`.

## Environment Matching

The installer reads `torch.__version__` and `torch.version.cuda` from the selected ComfyUI Python.

Current package mapping:

- PyTorch `>= 2.10`: `triton-windows<3.7`
- PyTorch `>= 2.9` and `< 2.10`: `triton-windows<3.6`
- CUDA `13.x`: SageAttention `cu130` wheel
- CUDA `12.x`: SageAttention `cu128` wheel

The SageAttention release is pinned in `SagePocketInstaller.ps1`. If your CUDA/PyTorch combination is not supported, the installer stops with a clear message. In that case, check whether a newer release of this tool exists.

## Logs

The installer writes logs to a `logs` folder next to the script. If that location is not writable, it falls back to:

```text
%TEMP%\SagePocket\logs
```

## Files

- `PingPong-SageInstaller.bat`: double-click launcher.
- `SagePocketInstaller.ps1`: polished pocket-console GUI.
- `PingPong-SageInstaller-Compact.ps1`: older compact prototype, kept for reference.
- `scripts/build_release_zip.ps1`: release ZIP builder.

## Credits

This helper installs packages published by other projects:

- [`triton-windows`](https://github.com/woct0rdho/triton-windows)
- [`woct0rdho/SageAttention`](https://github.com/woct0rdho/SageAttention)

Please check those projects for their own licenses, release notes, and compatibility details.

## Safety

This is a small PowerShell/Batch utility, so you can inspect the source before running it. The installer runs package commands through the selected ComfyUI Python, for example:

```powershell
path\to\ComfyUI\.venv\Scripts\python.exe -m pip install ...
```

## License

MIT
