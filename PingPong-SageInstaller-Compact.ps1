param(
  [string]$ComfyUIPath = ""
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

function Find-Python {
  param([string]$Root)
  $candidates = @(
    (Join-Path $Root ".venv\Scripts\python.exe"),
    (Join-Path $Root "venv\Scripts\python.exe"),
    (Join-Path $Root "python_embeded\python.exe"),
    (Join-Path $Root "python_embedded\python.exe"),
    (Join-Path $Root "python\python.exe")
  )
  foreach ($candidate in $candidates) {
    if (Test-Path -LiteralPath $candidate) {
      return (Resolve-Path -LiteralPath $candidate).Path
    }
  }
  return $null
}

function Test-ComfyRoot {
  param([string]$Root)
  if (-not $Root -or -not (Test-Path -LiteralPath $Root)) { return $false }
  $hasPython = [bool](Find-Python $Root)
  $hasMarkers = (
    (Test-Path -LiteralPath (Join-Path $Root "main.py")) -or
    (Test-Path -LiteralPath (Join-Path $Root "comfy")) -or
    (Test-Path -LiteralPath (Join-Path $Root "custom_nodes"))
  )
  return ($hasPython -and $hasMarkers)
}

function Add-ComfyCandidate {
  param(
    [System.Collections.Generic.List[string]]$Items,
    [string]$Path
  )
  if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return }
  $resolved = (Resolve-Path -LiteralPath $Path).Path
  if ((Test-ComfyRoot $resolved) -and -not $Items.Contains($resolved)) {
    $Items.Add($resolved)
  }
}

function Get-ComfyCandidates {
  $items = New-Object System.Collections.Generic.List[string]
  $scriptDir = Split-Path -Parent $PSCommandPath
  $current = (Get-Location).Path
  foreach ($path in @(
    $ComfyUIPath,
    $current,
    $scriptDir,
    (Split-Path -Parent $scriptDir),
    "C:\comfy\ComfyUI",
    "$env:LOCALAPPDATA\ComfyUI",
    "$env:USERPROFILE\ComfyUI"
  )) {
    Add-ComfyCandidate $items $path
  }

  $searchRoots = @(
    "C:\comfy",
    "$env:USERPROFILE\Documents",
    "$env:LOCALAPPDATA",
    "$env:APPDATA",
    "$env:USERPROFILE\StabilityMatrix\Data\Packages",
    "$env:APPDATA\StabilityMatrix\Data\Packages",
    "$env:LOCALAPPDATA\StabilityMatrix\Data\Packages"
  ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique

  foreach ($root in $searchRoots) {
    Add-ComfyCandidate $items $root
    $level1 = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)
    foreach ($dir in $level1) {
      if ($dir.Name -match "Comfy|ComfyUI|Stable|Stability|Packages") {
        Add-ComfyCandidate $items $dir.FullName
      }
    }
    $likelyParents = $level1 | Where-Object { $_.Name -match "Comfy|ComfyUI|Stable|Stability|Packages|Data" }
    foreach ($parent in $likelyParents) {
      $level2 = @(Get-ChildItem -LiteralPath $parent.FullName -Directory -ErrorAction SilentlyContinue)
      foreach ($dir in $level2) {
        if ($dir.Name -match "Comfy|ComfyUI") {
          Add-ComfyCandidate $items $dir.FullName
        }
      }
    }
  }
  return $items
}

function Get-PythonInfo {
  param([string]$Python)
  $code = @'
import json
import platform
import sys
data = {"python": sys.version.split()[0], "platform": platform.platform()}
try:
    import torch
    data["torch"] = torch.__version__
    data["torch_cuda"] = torch.version.cuda
except Exception as exc:
    data["torch_error"] = repr(exc)
print(json.dumps(data))
'@
  $raw = & $Python -c $code 2>&1
  if ($LASTEXITCODE -ne 0) { throw "Could not run Python: $raw" }
  return (($raw | Select-Object -First 1) | ConvertFrom-Json)
}

function Get-InstallPlan {
  param($Info)
  if ($Info.torch_error) {
    throw "Torch is not importable: $($Info.torch_error)"
  }

  $torchVersionText = ([string]$Info.torch -split "\+")[0]
  $torchVersion = [version]$torchVersionText
  $cudaText = [string]$Info.torch_cuda

  if ($torchVersion -lt [version]"2.9.0") {
    throw "Torch $torchVersionText is too old for this wheel helper. Use Torch 2.9+."
  }

  if ($torchVersion -ge [version]"2.10.0") {
    $tritonSpec = "triton-windows<3.7"
  } elseif ($torchVersion -ge [version]"2.9.0") {
    $tritonSpec = "triton-windows<3.6"
  } elseif ($torchVersion -ge [version]"2.8.0") {
    $tritonSpec = "triton-windows<3.5"
  } else {
    $tritonSpec = "triton-windows<3.4"
  }

  if ($cudaText -like "13.*") {
    $sageUrl = "https://github.com/woct0rdho/SageAttention/releases/download/v2.2.0-windows.post4/sageattention-2.2.0+cu130torch2.9.0andhigher.post4-cp39-abi3-win_amd64.whl"
  } elseif ($cudaText -like "12.*") {
    $sageUrl = "https://github.com/woct0rdho/SageAttention/releases/download/v2.2.0-windows.post4/sageattention-2.2.0+cu128torch2.9.0andhigher.post4-cp39-abi3-win_amd64.whl"
  } else {
    throw "Unsupported Torch CUDA value: $cudaText. Expected CUDA 12.x or 13.x."
  }

  return [pscustomobject]@{
    TritonSpec = $tritonSpec
    SageUrl = $sageUrl
    Torch = $Info.torch
    Cuda = $cudaText
    Python = $Info.python
  }
}

function Run-LoggedProcess {
  param(
    [string]$FilePath,
    [string[]]$Arguments,
    [scriptblock]$Log
  )
  $output = & $FilePath @Arguments 2>&1
  $exitCode = $LASTEXITCODE
  foreach ($line in $output) { & $Log ([string]$line) }
  if ($exitCode -ne 0) {
    throw "$FilePath exited with code $exitCode"
  }
}

function New-Button {
  param(
    [string]$Text,
    [int]$X,
    [int]$Y,
    [int]$W,
    [int]$H,
    [System.Drawing.Color]$Back,
    [System.Drawing.Color]$Fore
  )
  $button = New-Object System.Windows.Forms.Button
  $button.Text = $Text
  $button.Location = New-Object System.Drawing.Point($X, $Y)
  $button.Size = New-Object System.Drawing.Size($W, $H)
  $button.FlatStyle = "Flat"
  $button.FlatAppearance.BorderSize = 0
  $button.BackColor = $Back
  $button.ForeColor = $Fore
  $button.Font = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Bold)
  $button.Cursor = [System.Windows.Forms.Cursors]::Hand
  return $button
}

$cream = [System.Drawing.Color]::FromArgb(244, 239, 225)
$shell = [System.Drawing.Color]::FromArgb(34, 40, 43)
$face = [System.Drawing.Color]::FromArgb(247, 243, 232)
$screenColor = [System.Drawing.Color]::FromArgb(8, 16, 18)
$panel = [System.Drawing.Color]::FromArgb(23, 34, 37)
$mint = [System.Drawing.Color]::FromArgb(134, 231, 199)
$coral = [System.Drawing.Color]::FromArgb(242, 113, 99)
$yellow = [System.Drawing.Color]::FromArgb(246, 200, 95)
$muted = [System.Drawing.Color]::FromArgb(157, 172, 166)
$ink = [System.Drawing.Color]::FromArgb(28, 34, 36)

$form = New-Object System.Windows.Forms.Form
$form.Text = "SageAttention Pocket Installer"
$form.StartPosition = "CenterScreen"
$form.ClientSize = New-Object System.Drawing.Size(720, 470)
$form.BackColor = $cream
$form.FormBorderStyle = "FixedSingle"
$form.MaximizeBox = $false
$form.Font = New-Object System.Drawing.Font("Segoe UI", 9)

$title = New-Object System.Windows.Forms.Label
$title.Text = "SageAttention Pocket Installer"
$title.Location = New-Object System.Drawing.Point(26, 18)
$title.Size = New-Object System.Drawing.Size(430, 30)
$title.Font = New-Object System.Drawing.Font("Segoe UI", 17, [System.Drawing.FontStyle]::Bold)
$title.ForeColor = $ink
$form.Controls.Add($title)

$sub = New-Object System.Windows.Forms.Label
$sub.Text = "Tiny retro helper for Triton + SageAttention in a ComfyUI venv."
$sub.Location = New-Object System.Drawing.Point(29, 48)
$sub.Size = New-Object System.Drawing.Size(520, 22)
$sub.ForeColor = [System.Drawing.Color]::FromArgb(76, 88, 84)
$form.Controls.Add($sub)

$shellPanel = New-Object System.Windows.Forms.Panel
$shellPanel.Location = New-Object System.Drawing.Point(28, 82)
$shellPanel.Size = New-Object System.Drawing.Size(664, 330)
$shellPanel.BackColor = $shell
$shellPanel.BorderStyle = "FixedSingle"
$form.Controls.Add($shellPanel)

$facePanel = New-Object System.Windows.Forms.Panel
$facePanel.Location = New-Object System.Drawing.Point(20, 20)
$facePanel.Size = New-Object System.Drawing.Size(624, 260)
$facePanel.BackColor = $face
$shellPanel.Controls.Add($facePanel)

$leftPanel = New-Object System.Windows.Forms.Panel
$leftPanel.Location = New-Object System.Drawing.Point(18, 44)
$leftPanel.Size = New-Object System.Drawing.Size(86, 172)
$leftPanel.BackColor = [System.Drawing.Color]::FromArgb(42, 52, 55)
$facePanel.Controls.Add($leftPanel)

$dpadH = New-Object System.Windows.Forms.Panel
$dpadH.Location = New-Object System.Drawing.Point(19, 47)
$dpadH.Size = New-Object System.Drawing.Size(48, 18)
$dpadH.BackColor = [System.Drawing.Color]::FromArgb(15, 20, 22)
$leftPanel.Controls.Add($dpadH)
$dpadV = New-Object System.Windows.Forms.Panel
$dpadV.Location = New-Object System.Drawing.Point(34, 32)
$dpadV.Size = New-Object System.Drawing.Size(18, 48)
$dpadV.BackColor = [System.Drawing.Color]::FromArgb(15, 20, 22)
$leftPanel.Controls.Add($dpadV)

$scanButton = New-Button "SCAN" 14 105 58 25 $mint ([System.Drawing.Color]::FromArgb(10, 31, 25))
$manualButton = New-Button "..." 14 135 58 25 $yellow ([System.Drawing.Color]::FromArgb(36, 24, 8))
$leftPanel.Controls.Add($scanButton)
$leftPanel.Controls.Add($manualButton)

$rightPanel = New-Object System.Windows.Forms.Panel
$rightPanel.Location = New-Object System.Drawing.Point(520, 44)
$rightPanel.Size = New-Object System.Drawing.Size(86, 172)
$rightPanel.BackColor = [System.Drawing.Color]::FromArgb(42, 52, 55)
$facePanel.Controls.Add($rightPanel)

$installButton = New-Button "A" 16 24 54 38 $mint ([System.Drawing.Color]::FromArgb(10, 31, 25))
$verifyButton = New-Button "B" 16 70 54 38 $coral ([System.Drawing.Color]::FromArgb(44, 15, 14))
$closeButton = New-Button "C" 16 116 54 38 $yellow ([System.Drawing.Color]::FromArgb(36, 24, 8))
$rightPanel.Controls.Add($installButton)
$rightPanel.Controls.Add($verifyButton)
$rightPanel.Controls.Add($closeButton)

$topStrip = New-Object System.Windows.Forms.Panel
$topStrip.Location = New-Object System.Drawing.Point(128, 30)
$topStrip.Size = New-Object System.Drawing.Size(368, 44)
$topStrip.BackColor = $panel
$facePanel.Controls.Add($topStrip)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = "READY  00 : 00"
$statusLabel.Location = New-Object System.Drawing.Point(14, 8)
$statusLabel.Size = New-Object System.Drawing.Size(170, 27)
$statusLabel.Font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
$statusLabel.ForeColor = $mint
$topStrip.Controls.Add($statusLabel)

$miniLegend = New-Object System.Windows.Forms.Label
$miniLegend.Text = "A install   B verify   C close"
$miniLegend.Location = New-Object System.Drawing.Point(190, 13)
$miniLegend.Size = New-Object System.Drawing.Size(160, 18)
$miniLegend.ForeColor = $face
$miniLegend.Font = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Bold)
$miniLegend.TextAlign = "MiddleRight"
$topStrip.Controls.Add($miniLegend)

$screen = New-Object System.Windows.Forms.Panel
$screen.Location = New-Object System.Drawing.Point(128, 86)
$screen.Size = New-Object System.Drawing.Size(368, 130)
$screen.BackColor = $screenColor
$screen.BorderStyle = "FixedSingle"
$facePanel.Controls.Add($screen)

$screenRule = New-Object System.Windows.Forms.Panel
$screenRule.Location = New-Object System.Drawing.Point(12, 30)
$screenRule.Size = New-Object System.Drawing.Size(342, 1)
$screenRule.BackColor = [System.Drawing.Color]::FromArgb(58, 115, 100)
$screen.Controls.Add($screenRule)

$logBox = New-Object System.Windows.Forms.RichTextBox
$logBox.Location = New-Object System.Drawing.Point(14, 38)
$logBox.Size = New-Object System.Drawing.Size(340, 78)
$logBox.BackColor = $screenColor
$logBox.BorderStyle = "None"
$logBox.ForeColor = [System.Drawing.Color]::FromArgb(215, 255, 232)
$logBox.Font = New-Object System.Drawing.Font("Consolas", 8)
$logBox.ReadOnly = $true
$logBox.Text = "> scan or choose ComfyUI`n> A installs into selected venv`n"
$screen.Controls.Add($logBox)

$screenTitle = New-Object System.Windows.Forms.Label
$screenTitle.Text = "MATCH LOG"
$screenTitle.Location = New-Object System.Drawing.Point(14, 10)
$screenTitle.Size = New-Object System.Drawing.Size(100, 16)
$screenTitle.ForeColor = $mint
$screenTitle.Font = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Bold)
$screen.Controls.Add($screenTitle)

$ball = New-Object System.Windows.Forms.Label
$ball.Text = "o"
$ball.Location = New-Object System.Drawing.Point(320, 8)
$ball.Size = New-Object System.Drawing.Size(24, 20)
$ball.ForeColor = $yellow
$ball.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
$ball.TextAlign = "MiddleCenter"
$screen.Controls.Add($ball)

$pathCombo = New-Object System.Windows.Forms.ComboBox
$pathCombo.Location = New-Object System.Drawing.Point(128, 226)
$pathCombo.Size = New-Object System.Drawing.Size(368, 24)
$pathCombo.DropDownStyle = "DropDownList"
$facePanel.Controls.Add($pathCombo)

$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Location = New-Object System.Drawing.Point(28, 296)
$progressBar.Size = New-Object System.Drawing.Size(608, 12)
$progressBar.Minimum = 0
$progressBar.Maximum = 100
$shellPanel.Controls.Add($progressBar)

$envLabel = New-Object System.Windows.Forms.Label
$envLabel.Text = "No ComfyUI selected."
$envLabel.Location = New-Object System.Drawing.Point(30, 420)
$envLabel.Size = New-Object System.Drawing.Size(560, 22)
$envLabel.ForeColor = [System.Drawing.Color]::FromArgb(76, 88, 84)
$form.Controls.Add($envLabel)

$pctLabel = New-Object System.Windows.Forms.Label
$pctLabel.Text = "0%"
$pctLabel.Location = New-Object System.Drawing.Point(622, 416)
$pctLabel.Size = New-Object System.Drawing.Size(64, 28)
$pctLabel.Font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
$pctLabel.ForeColor = $ink
$pctLabel.TextAlign = "MiddleRight"
$form.Controls.Add($pctLabel)

function Append-Log {
  param([string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) { return }
  $logBox.AppendText("> $Text`n")
  $logBox.SelectionStart = $logBox.TextLength
  $logBox.ScrollToCaret()
}

function Set-Progress {
  param([int]$Value)
  $v = [Math]::Max(0, [Math]::Min(100, $Value))
  $progressBar.Value = $v
  $pctLabel.Text = "$v%"
}

function Set-Busy {
  param([bool]$Busy)
  $scanButton.Enabled = -not $Busy
  $manualButton.Enabled = -not $Busy
  $installButton.Enabled = -not $Busy
  $verifyButton.Enabled = -not $Busy
  $pathCombo.Enabled = -not $Busy
}

function Refresh-Candidates {
  $pathCombo.Items.Clear()
  Append-Log "scanning"
  $paths = @(Get-ComfyCandidates)
  foreach ($path in $paths) { [void]$pathCombo.Items.Add($path) }
  if ($pathCombo.Items.Count -gt 0) {
    $pathCombo.SelectedIndex = 0
    $statusLabel.Text = "FOUND  01 : 00"
    Append-Log "found $($pathCombo.Items.Count)"
  } else {
    $statusLabel.Text = "MISS   00 : 01"
    Append-Log "use manual path"
  }
}

function Update-Preview {
  if ($pathCombo.SelectedItem -eq $null) { return }
  try {
    $path = [string]$pathCombo.SelectedItem
    $python = Find-Python $path
    $info = Get-PythonInfo $python
    $plan = Get-InstallPlan $info
    $envLabel.Text = "Python $($plan.Python) | Torch $($plan.Torch) | CUDA $($plan.Cuda)"
    Append-Log "court: $path"
    Append-Log "serve: $($plan.TritonSpec)"
  } catch {
    $envLabel.Text = $_.Exception.Message
    Append-Log $_.Exception.Message
  }
}

$pathCombo.Add_SelectedIndexChanged({ Update-Preview })
$scanButton.Add_Click({ Refresh-Candidates })
$manualButton.Add_Click({
  $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
  $dialog.Description = "Select a ComfyUI folder"
  if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
    if (-not (Test-ComfyRoot $dialog.SelectedPath)) {
      [System.Windows.Forms.MessageBox]::Show("That folder does not look like a ComfyUI install with Python.", "ComfyUI not found", "OK", "Warning") | Out-Null
      return
    }
    if (-not $pathCombo.Items.Contains($dialog.SelectedPath)) {
      [void]$pathCombo.Items.Add($dialog.SelectedPath)
    }
    $pathCombo.SelectedItem = $dialog.SelectedPath
  }
})
$closeButton.Add_Click({ $form.Close() })

$verifyButton.Add_Click({
  if ($pathCombo.SelectedItem -eq $null) {
    Append-Log "choose ComfyUI first"
    return
  }
  try {
    Set-Progress 75
    $python = Find-Python ([string]$pathCombo.SelectedItem)
    Run-LoggedProcess $python @("-c", "import triton; print('triton OK', getattr(triton, '__version__', 'unknown'))") { param($line) Append-Log $line }
    Run-LoggedProcess $python @("-c", "import sageattention; print('sageattention OK')") { param($line) Append-Log $line }
    Set-Progress 100
    $statusLabel.Text = "WIN    02 : 10"
    Append-Log "verify complete"
  } catch {
    $statusLabel.Text = "ERR    00 : 01"
    Append-Log $_.Exception.Message
  }
})

$worker = New-Object System.ComponentModel.BackgroundWorker
$worker.WorkerReportsProgress = $true

$worker.Add_DoWork({
  param($sender, $eventArgs)
  $path = [string]$eventArgs.Argument
  $report = {
    param([int]$pct, [string]$message)
    $sender.ReportProgress($pct, $message)
  }

  & $report 8 "reading env"
  $python = Find-Python $path
  if (-not $python) { throw "Could not find Python under $path" }
  $info = Get-PythonInfo $python
  $plan = Get-InstallPlan $info

  & $report 15 "torch $($info.torch), cuda $($info.torch_cuda)"
  & $report 25 "updating pip tools"
  Run-LoggedProcess $python @("-m", "pip", "install", "--upgrade", "pip", "setuptools", "wheel") {
    param($line) & $report 30 $line
  }

  & $report 45 "installing triton"
  Run-LoggedProcess $python @("-m", "pip", "install", "-U", $plan.TritonSpec) {
    param($line) & $report 55 $line
  }

  & $report 70 "installing sageattention"
  Run-LoggedProcess $python @("-m", "pip", "install", "-U", $plan.SageUrl) {
    param($line) & $report 80 $line
  }

  & $report 90 "verifying"
  Run-LoggedProcess $python @("-c", "import triton; import sageattention; print('imports OK')") {
    param($line) & $report 95 $line
  }

  & $report 100 "done"
})

$worker.Add_ProgressChanged({
  param($sender, $eventArgs)
  Set-Progress $eventArgs.ProgressPercentage
  Append-Log ([string]$eventArgs.UserState)
})

$worker.Add_RunWorkerCompleted({
  param($sender, $eventArgs)
  Set-Busy $false
  if ($eventArgs.Error) {
    $statusLabel.Text = "ERR    00 : 01"
    Append-Log $eventArgs.Error.Message
    [System.Windows.Forms.MessageBox]::Show($eventArgs.Error.Message, "Install failed", "OK", "Error") | Out-Null
  } else {
    $statusLabel.Text = "WIN    02 : 10"
    [System.Windows.Forms.MessageBox]::Show("Done. Start ComfyUI with --use-sage-attention.", "Install complete", "OK", "Information") | Out-Null
  }
})

$installButton.Add_Click({
  if ($worker.IsBusy) { return }
  if ($pathCombo.SelectedItem -eq $null) {
    Append-Log "choose ComfyUI first"
    return
  }
  $answer = [System.Windows.Forms.MessageBox]::Show(
    "Close ComfyUI first. Install into:`n`n$($pathCombo.SelectedItem)",
    "Serve install?",
    "YesNo",
    "Question"
  )
  if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
    Append-Log "cancelled"
    return
  }
  Set-Progress 0
  $statusLabel.Text = "PLAY   01 : 01"
  Set-Busy $true
  $worker.RunWorkerAsync([string]$pathCombo.SelectedItem)
})

$form.Add_Shown({ Refresh-Candidates })
[void][System.Windows.Forms.Application]::Run($form)
