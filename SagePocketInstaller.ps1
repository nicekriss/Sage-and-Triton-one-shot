param(
  [string]$ComfyUIPath = ""
)

$ErrorActionPreference = "Stop"

try {
  [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
  $OutputEncoding = [System.Text.Encoding]::UTF8
} catch {}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

$SageAttentionRelease = "v2.2.0-windows.post4"
$SageAttentionBaseUrl = "https://github.com/woct0rdho/SageAttention/releases/download/$SageAttentionRelease"
$SageAttentionWheelMap = @{
  "cu128" = "sageattention-2.2.0+cu128torch2.9.0andhigher.post4-cp39-abi3-win_amd64.whl"
  "cu130" = "sageattention-2.2.0+cu130torch2.9.0andhigher.post4-cp39-abi3-win_amd64.whl"
}
$UpgradePipToolsOnFailure = $true

$ScriptDir = Split-Path -Parent $PSCommandPath
$LogDir = Join-Path $ScriptDir "logs"
try {
  if (-not (Test-Path -LiteralPath $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
  }
} catch {
  $LogDir = Join-Path $env:TEMP "SagePocket\logs"
  if (-not (Test-Path -LiteralPath $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
  }
}
$RunLog = Join-Path $LogDir ("sage_pocket_{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmmss"))

function Write-RunLog {
  param([string]$Message)
  $line = "[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $Message
  Add-Content -LiteralPath $RunLog -Value $line -Encoding UTF8
}

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
  foreach ($path in @(
    $ComfyUIPath,
    (Get-Location).Path,
    $ScriptDir,
    (Split-Path -Parent $ScriptDir),
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
  $jsonLine = @($raw | ForEach-Object { [string]$_ } | Where-Object {
    $line = $_.Trim()
    $line.StartsWith("{") -and $line.EndsWith("}")
  } | Select-Object -Last 1)

  if (-not $jsonLine) {
    Write-RunLog "Python environment detection raw output:"
    foreach ($line in $raw) { Write-RunLog ([string]$line) }
    throw "Environment detection failed. Check the log for the Python output."
  }

  try {
    return ($jsonLine | ConvertFrom-Json)
  } catch {
    Write-RunLog "Python environment JSON parse failed:"
    foreach ($line in $raw) { Write-RunLog ([string]$line) }
    throw "Environment detection failed. Check the log for the Python output."
  }
}

function Resolve-SageAttentionWheel {
  param([string]$CudaText)

  if ([string]::IsNullOrWhiteSpace($CudaText)) {
    throw "This PyTorch build does not report CUDA. SageAttention wheels require CUDA 12.x or 13.x."
  }

  $variant = $null
  if ($CudaText -like "13.*") {
    $variant = "cu130"
  } elseif ($CudaText -like "12.*") {
    $variant = "cu128"
  }

  if (-not $variant -or -not $SageAttentionWheelMap.ContainsKey($variant)) {
    $known = ($SageAttentionWheelMap.Keys | Sort-Object) -join ", "
    throw "No SageAttention wheel is mapped for CUDA $CudaText. Known variants: $known. Please download the latest tool version."
  }

  return [pscustomobject]@{
    Variant = $variant
    FileName = $SageAttentionWheelMap[$variant]
    Url = "$SageAttentionBaseUrl/$($SageAttentionWheelMap[$variant])"
    Release = $SageAttentionRelease
  }
}

function Get-InstallPlan {
  param($Info)
  if ($Info.torch_error) { throw "Torch is not importable: $($Info.torch_error)" }
  $torchVersionText = ([string]$Info.torch -split "\+")[0]
  $torchVersion = [version]$torchVersionText
  $cudaText = [string]$Info.torch_cuda

  if ($torchVersion -lt [version]"2.9.0") {
    throw "Torch $torchVersionText is too old for this helper. Use Torch 2.9+."
  }

  if ($torchVersion -ge [version]"2.10.0") {
    $tritonSpec = "triton-windows<3.7"
  } else {
    $tritonSpec = "triton-windows<3.6"
  }
  $sageWheel = Resolve-SageAttentionWheel -CudaText $cudaText

  return [pscustomobject]@{
    Python = $Info.python
    Torch = $Info.torch
    Cuda = $cudaText
    TritonSpec = $tritonSpec
    SageVariant = $sageWheel.Variant
    SageRelease = $sageWheel.Release
    SageUrl = $sageWheel.Url
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
  if ($exitCode -ne 0) { throw "$FilePath exited with code $exitCode" }
}

function Install-PipPackage {
  param(
    [string]$Python,
    [string[]]$PipArgs,
    [scriptblock]$Log,
    [string]$FailureHint = ""
  )

  try {
    Run-LoggedProcess $Python (@("-m", "pip", "install", "-U") + $PipArgs) $Log
  } catch {
    if (-not $UpgradePipToolsOnFailure) {
      if ($FailureHint) { & $Log $FailureHint }
      throw
    }

    & $Log "pip install failed; updating pip tools once, then retrying"
    Run-LoggedProcess $Python @("-m", "pip", "install", "--upgrade", "pip", "setuptools", "wheel") $Log

    try {
      Run-LoggedProcess $Python (@("-m", "pip", "install", "-U") + $PipArgs) $Log
    } catch {
      if ($FailureHint) { & $Log $FailureHint }
      throw
    }
  }
}

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Sage &amp; Triton One Shot"
        Width="720" Height="470"
        WindowStartupLocation="CenterScreen"
        WindowStyle="None"
        ResizeMode="NoResize"
        AllowsTransparency="True"
        Background="Transparent"
        FontFamily="Segoe UI">
  <Window.Resources>
    <SolidColorBrush x:Key="Cream" Color="#EFE6D5"/>
    <SolidColorBrush x:Key="Shell" Color="#222C2E"/>
    <SolidColorBrush x:Key="Shell2" Color="#303B3D"/>
    <SolidColorBrush x:Key="Dark" Color="#061012"/>
    <SolidColorBrush x:Key="Mint" Color="#8BE8CA"/>
    <SolidColorBrush x:Key="Coral" Color="#F27163"/>
    <SolidColorBrush x:Key="Yellow" Color="#F6C85F"/>
    <SolidColorBrush x:Key="Ink" Color="#1D2527"/>
    <SolidColorBrush x:Key="SoftGreen" Color="#D2E8D5"/>
    <SolidColorBrush x:Key="Muted" Color="#66736E"/>
    <Style x:Key="PocketButton" TargetType="Button">
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border CornerRadius="15" Background="{TemplateBinding Background}">
              <Border.Effect>
                <DropShadowEffect Color="#111111" BlurRadius="6" ShadowDepth="2" Opacity="0.14"/>
              </Border.Effect>
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Border Background="{StaticResource Cream}" CornerRadius="18" BorderBrush="#D4C9B8" BorderThickness="1">
    <Border.Effect>
      <DropShadowEffect Color="#24362F" BlurRadius="32" ShadowDepth="16" Opacity="0.18"/>
    </Border.Effect>
    <Grid ClipToBounds="True">
      <Grid.RowDefinitions>
        <RowDefinition Height="38"/>
        <RowDefinition Height="*"/>
      </Grid.RowDefinitions>

      <Border x:Name="TopBar" Grid.Row="0" Background="{StaticResource Ink}" CornerRadius="18,18,0,0">
        <Grid>
          <StackPanel Orientation="Horizontal" VerticalAlignment="Center" Margin="20,0,0,0">
            <Ellipse Width="10" Height="10" Fill="#EF665C" Margin="0,0,8,0"/>
            <Ellipse Width="10" Height="10" Fill="#F4C75D" Margin="0,0,8,0"/>
            <Ellipse Width="10" Height="10" Fill="#82D9B7" Margin="0,0,22,0"/>
            <TextBlock Text="Sage &amp; Triton One Shot" Foreground="#F7F1E6" FontWeight="Bold" FontSize="18" VerticalAlignment="Center"/>
          </StackPanel>
          <TextBlock x:Name="WindowStateText" Text="READY" Foreground="{StaticResource Mint}" FontWeight="Bold" FontSize="18" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,30,0"/>
        </Grid>
      </Border>

      <Grid Grid.Row="1">
        <Border Width="664" Height="364" Background="{StaticResource SoftGreen}" CornerRadius="26" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,2,0,4" BorderBrush="#A9C5B1" BorderThickness="1"/>
        <Border Width="580" Height="14" Background="#2C000000" CornerRadius="7" HorizontalAlignment="Center" VerticalAlignment="Bottom" Margin="0,0,0,20"/>

        <Border Width="548" Height="334" Background="{StaticResource Shell}" CornerRadius="26" HorizontalAlignment="Center" VerticalAlignment="Center" BorderBrush="#111718" BorderThickness="2">
          <Border.Effect>
            <DropShadowEffect Color="#162620" BlurRadius="30" ShadowDepth="15" Opacity="0.24"/>
          </Border.Effect>
          <Grid>
            <Border Width="372" Height="166" Background="{StaticResource Shell2}" CornerRadius="22" HorizontalAlignment="Center" VerticalAlignment="Top" Margin="0,30,0,0" BorderBrush="#0F1516" BorderThickness="2">
              <Border.Effect>
                <DropShadowEffect Color="#000000" BlurRadius="18" ShadowDepth="7" Opacity="0.18"/>
              </Border.Effect>
              <Grid>
                <Border Width="340" Height="138" Background="#182123" CornerRadius="16" HorizontalAlignment="Center" VerticalAlignment="Center" BorderBrush="#48575A" BorderThickness="1"/>
                <Border Width="308" Height="110" Background="{StaticResource Dark}" CornerRadius="11" HorizontalAlignment="Center" VerticalAlignment="Center" BorderBrush="#557DE2C2" BorderThickness="1">
                  <Grid>
                    <Rectangle Width="280" Height="1" Fill="#557DE2C2" HorizontalAlignment="Center" VerticalAlignment="Top" Margin="0,28,0,0"/>
                    <Rectangle Width="1" Height="70" Fill="#367DE2C2" HorizontalAlignment="Center" VerticalAlignment="Top" Margin="0,28,0,0"/>
                    <TextBlock Text="INSTALL LOG" Foreground="{StaticResource Mint}" FontSize="13" FontWeight="Bold" Margin="14,10,0,0"/>
                    <Rectangle Width="5" Height="34" Fill="{StaticResource Yellow}" RadiusX="3" RadiusY="3" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="18,48,0,0"/>
                    <Rectangle Width="5" Height="34" Fill="{StaticResource Coral}" RadiusX="3" RadiusY="3" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,60,18,0"/>
                    <Ellipse Width="11" Height="11" Fill="#F7F1E6" Stroke="{StaticResource Mint}" StrokeThickness="2" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,50,56,0"/>
                    <TextBox x:Name="LogBox" Text="&gt; scan or choose ComfyUI&#x0a;&gt; A installs into selected venv"
                             Background="Transparent" BorderThickness="0" Foreground="#DDFDEB"
                             FontFamily="Consolas" FontSize="12" Margin="34,39,52,10"
                             TextWrapping="Wrap" AcceptsReturn="True" VerticalScrollBarVisibility="Auto"
                             IsReadOnly="True"/>
                  </Grid>
                </Border>
              </Grid>
            </Border>

            <Border Width="86" Height="15" Background="#111719" CornerRadius="8" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="134,200,0,0"/>
            <Border Width="86" Height="15" Background="#111719" CornerRadius="8" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,200,134,0"/>

            <Border Width="428" Height="94" Background="#F7F1E6" CornerRadius="22" HorizontalAlignment="Center" VerticalAlignment="Top" Margin="0,218,0,0" BorderBrush="#111718" BorderThickness="2">
              <Grid>
                <ComboBox x:Name="PathBox" Width="176" Height="28" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="24,18,0,0" FontSize="12" IsEditable="True"/>
                <Button x:Name="ScanButton" Content="SCAN" Width="44" Height="20" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="154,21,0,0" Style="{StaticResource PocketButton}" Background="{StaticResource Mint}" Foreground="#10231F" FontSize="11"/>
                <Button x:Name="BrowseButton" Content="..." Width="30" Height="20" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="208,21,0,0" Style="{StaticResource PocketButton}" Background="{StaticResource Yellow}" Foreground="#2C210B" FontSize="11"/>
                <TextBlock x:Name="EnvText" Text="No ComfyUI selected." Foreground="#5B6A65" FontSize="10" FontWeight="SemiBold" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="24,54,0,0"/>
                <Border Width="214" Height="8" Background="#D9E1DD" CornerRadius="4" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="24,73,0,0"/>
                <Border x:Name="ProgressFill" Width="0" Height="8" Background="{StaticResource Mint}" CornerRadius="4" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="24,73,0,0"/>
                <Ellipse x:Name="ProgressBall" Width="22" Height="22" Fill="#F7F1E6" Stroke="{StaticResource Mint}" StrokeThickness="3" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="13,66,0,0"/>
                <TextBlock x:Name="PercentText" Text="0%" Foreground="{StaticResource Shell}" FontSize="13" FontWeight="Bold" Width="40" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="198,62,0,0" TextAlignment="Right"/>

                <Border Width="48" Height="18" Background="#111719" CornerRadius="7" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="272,38,0,0"/>
                <Border Width="18" Height="48" Background="#111719" CornerRadius="7" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="287,23,0,0"/>
                <Button x:Name="InstallButton" Content="A" Width="38" Height="32" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="348,18,0,0" Style="{StaticResource PocketButton}" Background="{StaticResource Mint}" Foreground="#10231F" FontSize="15"/>
                <Button x:Name="VerifyButton" Content="B" Width="34" Height="28" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="328,56,0,0" Style="{StaticResource PocketButton}" Background="{StaticResource Coral}" Foreground="#2D1110" FontSize="14"/>
                <Button x:Name="CloseButton" Content="C" Width="30" Height="24" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="370,64,0,0" Style="{StaticResource PocketButton}" Background="{StaticResource Yellow}" Foreground="#2C210B" FontSize="12"/>
                <TextBlock Text="A install   B verify   C close" Foreground="{StaticResource Muted}" FontSize="8" FontWeight="SemiBold" Width="132" TextAlignment="Center" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="274,77,0,0"/>
              </Grid>
            </Border>

            <TextBlock Text="SAGE POCKET" Foreground="#6F7E79" FontWeight="Bold" FontSize="9" HorizontalAlignment="Center" VerticalAlignment="Bottom" Margin="0,0,0,8"/>
          </Grid>
        </Border>
      </Grid>
    </Grid>
  </Border>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)

$TopBar = $window.FindName("TopBar")
$WindowStateText = $window.FindName("WindowStateText")
$LogBox = $window.FindName("LogBox")
$PathBox = $window.FindName("PathBox")
$ScanButton = $window.FindName("ScanButton")
$BrowseButton = $window.FindName("BrowseButton")
$EnvText = $window.FindName("EnvText")
$ProgressFill = $window.FindName("ProgressFill")
$ProgressBall = $window.FindName("ProgressBall")
$PercentText = $window.FindName("PercentText")
$InstallButton = $window.FindName("InstallButton")
$VerifyButton = $window.FindName("VerifyButton")
$CloseButton = $window.FindName("CloseButton")

$TopBar.Add_MouseLeftButtonDown({
  if ($_.ButtonState -eq [System.Windows.Input.MouseButtonState]::Pressed) {
    $window.DragMove()
  }
})

function Append-Log {
  param([string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) { return }
  $LogBox.AppendText("`n> $Text")
  $LogBox.ScrollToEnd()
  Write-RunLog $Text
}

function Set-Progress {
  param([int]$Value)
  $v = [Math]::Max(0, [Math]::Min(100, $Value))
  $ProgressFill.Width = [Math]::Round(214 * ($v / 100), 0)
  [System.Windows.Controls.Canvas]::SetLeft($ProgressBall, 13 + [Math]::Round(203 * ($v / 100), 0))
  $ProgressBall.Margin = New-Object System.Windows.Thickness((13 + [Math]::Round(203 * ($v / 100), 0)), 66, 0, 0)
  $PercentText.Text = "$v%"
}

function Set-Busy {
  param([bool]$Busy)
  $ScanButton.IsEnabled = -not $Busy
  $BrowseButton.IsEnabled = -not $Busy
  $InstallButton.IsEnabled = -not $Busy
  $VerifyButton.IsEnabled = -not $Busy
  $CloseButton.IsEnabled = -not $Busy
  $PathBox.IsEnabled = -not $Busy
}

function Get-CurrentComfyPath {
  $path = [string]$PathBox.Text
  if ([string]::IsNullOrWhiteSpace($path) -and $null -ne $PathBox.SelectedItem) {
    $path = [string]$PathBox.SelectedItem
  }
  return $path.Trim('"').Trim()
}

function Apply-Candidates {
  param([string[]]$Paths)
  $PathBox.Items.Clear()
  foreach ($path in $Paths) { [void]$PathBox.Items.Add($path) }
  if ($PathBox.Items.Count -gt 0) {
    $PathBox.SelectedIndex = 0
    $WindowStateText.Text = "FOUND"
    Append-Log "found $($PathBox.Items.Count) install(s)"
  } else {
    $WindowStateText.Text = "MISS"
    Append-Log "no install found"
  }
}

function Start-Scan {
  if ($scanWorker.IsBusy) { return }
  $WindowStateText.Text = "SCAN..."
  Append-Log "scanning ComfyUI paths"
  $ScanButton.IsEnabled = $false
  $BrowseButton.IsEnabled = $false
  $scanWorker.RunWorkerAsync()
}

function Update-Preview {
  $path = Get-CurrentComfyPath
  if ([string]::IsNullOrWhiteSpace($path)) { return }
  try {
    $python = Find-Python $path
    $info = Get-PythonInfo $python
    $plan = Get-InstallPlan $info
    $EnvText.Text = "PY $($plan.Python)  |  TORCH $($plan.Torch)  |  CUDA $($plan.Cuda)"
    Append-Log "target: $path"
    Append-Log "triton: $($plan.TritonSpec)"
    Append-Log "sage: $($plan.SageVariant) $($plan.SageRelease)"
  } catch {
    $EnvText.Text = $_.Exception.Message
    Append-Log $_.Exception.Message
  }
}

$scanWorker = New-Object System.ComponentModel.BackgroundWorker
$scanWorker.Add_DoWork({
  param($sender, $eventArgs)
  $eventArgs.Result = @(Get-ComfyCandidates)
})
$scanWorker.Add_RunWorkerCompleted({
  param($sender, $eventArgs)
  $ScanButton.IsEnabled = -not $worker.IsBusy
  $BrowseButton.IsEnabled = -not $worker.IsBusy
  if ($eventArgs.Error) {
    $WindowStateText.Text = "ERR"
    Append-Log $eventArgs.Error.Message
  } else {
    Apply-Candidates -Paths ([string[]]$eventArgs.Result)
  }
})

$PathBox.Add_SelectionChanged({ Update-Preview })
$PathBox.Add_LostFocus({ Update-Preview })
$ScanButton.Add_Click({ Start-Scan })
$BrowseButton.Add_Click({
  $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
  $dialog.Description = "Select a ComfyUI folder"
  if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
  $selected = $dialog.SelectedPath
  if (-not (Test-ComfyRoot $selected)) {
    [System.Windows.MessageBox]::Show(
      "That folder does not look like a ComfyUI install with a Python environment.",
      "ComfyUI not found",
      "OK",
      "Warning"
    ) | Out-Null
    return
  }
  if (-not $PathBox.Items.Contains($selected)) {
    [void]$PathBox.Items.Add($selected)
  }
  $PathBox.Text = $selected
  Update-Preview
})
$CloseButton.Add_Click({ $window.Close() })

$worker = New-Object System.ComponentModel.BackgroundWorker
$worker.WorkerReportsProgress = $true

$verifyWorker = New-Object System.ComponentModel.BackgroundWorker
$verifyWorker.WorkerReportsProgress = $true

$verifyWorker.Add_DoWork({
  param($sender, $eventArgs)
  $path = [string]$eventArgs.Argument
  $report = { param([int]$pct, [string]$message) $sender.ReportProgress($pct, $message) }
  & $report 75 "verifying triton"
  $python = Find-Python $path
  if (-not $python) { throw "Could not find Python under $path" }
  Run-LoggedProcess $python @("-c", "import triton; print('triton OK', getattr(triton, '__version__', 'unknown'))") { param($line) & $report 82 $line }
  & $report 90 "verifying sageattention"
  Run-LoggedProcess $python @("-c", "import sageattention; print('sageattention OK')") { param($line) & $report 96 $line }
  & $report 100 "verification complete"
})

$verifyWorker.Add_ProgressChanged({
  param($sender, $eventArgs)
  Set-Progress $eventArgs.ProgressPercentage
  Append-Log ([string]$eventArgs.UserState)
})

$verifyWorker.Add_RunWorkerCompleted({
  param($sender, $eventArgs)
  Set-Busy $false
  if ($eventArgs.Error) {
    $WindowStateText.Text = "ERR"
    Append-Log $eventArgs.Error.Message
  } else {
    $WindowStateText.Text = "WIN"
  }
})

$VerifyButton.Add_Click({
  if ($worker.IsBusy -or $verifyWorker.IsBusy) { return }
  $path = Get-CurrentComfyPath
  if ([string]::IsNullOrWhiteSpace($path)) {
    Append-Log "choose ComfyUI first"
    return
  }
  $WindowStateText.Text = "CHECK"
  Set-Busy $true
  $verifyWorker.RunWorkerAsync($path)
})

$worker.Add_DoWork({
  param($sender, $eventArgs)
  $path = [string]$eventArgs.Argument
  $report = { param([int]$pct, [string]$message) $sender.ReportProgress($pct, $message) }

  & $report 8 "reading environment"
  $python = Find-Python $path
  if (-not $python) { throw "Could not find Python under $path" }
  $info = Get-PythonInfo $python
  $plan = Get-InstallPlan $info

  & $report 15 "torch $($info.torch), cuda $($info.torch_cuda)"
  & $report 45 "installing triton"
  Install-PipPackage $python @($plan.TritonSpec) { param($line) & $report 55 $line } "Triton install failed. Check the tool version and your PyTorch version."

  & $report 70 "installing sageattention"
  Install-PipPackage $python @($plan.SageUrl) { param($line) & $report 80 $line } "SageAttention wheel install failed. Check whether a newer tool version supports this CUDA/PyTorch build."

  & $report 90 "verifying imports"
  Run-LoggedProcess $python @("-c", "import triton; import sageattention; print('imports OK')") { param($line) & $report 95 $line }
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
    $WindowStateText.Text = "ERR"
    Append-Log $eventArgs.Error.Message
    [System.Windows.MessageBox]::Show($eventArgs.Error.Message, "Install failed", "OK", "Error") | Out-Null
  } else {
    $WindowStateText.Text = "WIN"
    [System.Windows.MessageBox]::Show("Done. Start ComfyUI with --use-sage-attention.", "Install complete", "OK", "Information") | Out-Null
  }
})

$InstallButton.Add_Click({
  if ($worker.IsBusy -or $verifyWorker.IsBusy) { return }
  $path = Get-CurrentComfyPath
  if ([string]::IsNullOrWhiteSpace($path)) {
    Append-Log "choose ComfyUI first"
    return
  }
  $answer = [System.Windows.MessageBox]::Show(
    "Close ComfyUI first. Install into:`n`n$path",
    "Serve install?",
    "YesNo",
    "Question"
  )
  if ($answer -ne [System.Windows.MessageBoxResult]::Yes) {
    Append-Log "cancelled"
    return
  }
  Set-Progress 0
  $WindowStateText.Text = "PLAY"
  Set-Busy $true
  $worker.RunWorkerAsync($path)
})

$window.Add_SourceInitialized({
  Start-Scan
})

[void]$window.ShowDialog()
