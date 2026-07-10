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

function Get-FixedDriveRoots {
  [System.IO.DriveInfo]::GetDrives() |
    Where-Object { $_.DriveType -eq [System.IO.DriveType]::Fixed -and $_.IsReady } |
    ForEach-Object { $_.RootDirectory.FullName }
}

function Get-ComfyCandidates {
  $items = New-Object System.Collections.Generic.List[string]
  $driveRoots = @(Get-FixedDriveRoots)
  $driveCandidates = foreach ($drive in $driveRoots) {
    Join-Path $drive "ComfyUI"
    Join-Path $drive "comfy\ComfyUI"
    Join-Path $drive "AI\ComfyUI"
    Join-Path $drive "AIWORK\ComfyUI"
    Join-Path $drive "Apps\ComfyUI"
    Join-Path $drive "SM\Data\Packages\ComfyUI"
    Join-Path $drive "StabilityMatrix\Data\Packages\ComfyUI"
  }

  foreach ($path in @(
    $ComfyUIPath,
    (Get-Location).Path,
    $ScriptDir,
    (Split-Path -Parent $ScriptDir),
    "C:\comfy\ComfyUI",
    "$env:LOCALAPPDATA\ComfyUI",
    "$env:USERPROFILE\ComfyUI"
  ) + $driveCandidates) {
    Add-ComfyCandidate $items $path
  }

  # ComfyUI Desktop keeps installs at Comfy-Desktop\ComfyUI-Installs\<instance>\ComfyUI.
  # Instance names are user-defined, so enumerate every instance instead of name matching.
  $desktopInstallRoots = @(
    "$env:LOCALAPPDATA\Comfy-Desktop\ComfyUI-Installs",
    "$env:APPDATA\Comfy-Desktop\ComfyUI-Installs"
  ) + ($driveRoots | ForEach-Object { Join-Path $_ "Comfy-Desktop\ComfyUI-Installs" })
  foreach ($installRoot in ($desktopInstallRoots | Where-Object { $_ -and (Test-Path -LiteralPath $_) })) {
    foreach ($instance in @(Get-ChildItem -LiteralPath $installRoot -Directory -ErrorAction SilentlyContinue)) {
      Add-ComfyCandidate $items (Join-Path $instance.FullName "ComfyUI")
      Add-ComfyCandidate $items $instance.FullName
    }
  }

  $searchRoots = @(
    $driveRoots,
    "C:\comfy",
    ($driveRoots | ForEach-Object { Join-Path $_ "comfy" }),
    ($driveRoots | ForEach-Object { Join-Path $_ "AI" }),
    ($driveRoots | ForEach-Object { Join-Path $_ "AIWORK" }),
    ($driveRoots | ForEach-Object { Join-Path $_ "Apps" }),
    ($driveRoots | ForEach-Object { Join-Path $_ "SM\Data\Packages" }),
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
    $likelyParents = $level1 | Where-Object { $_.Name -match "Comfy|ComfyUI|Stable|Stability|Packages|Data|AI|AIWORK|Apps|Tools" }
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
data = {'python': sys.version.split()[0], 'platform': platform.platform()}
try:
    import torch
    data['torch'] = torch.__version__
    data['torch_cuda'] = torch.version.cuda
except Exception as exc:
    data['torch_error'] = repr(exc)
print(json.dumps(data))
'@
  $probePath = Join-Path $env:TEMP ("sage_env_probe_{0}.py" -f ([guid]::NewGuid().ToString("N")))
  Set-Content -LiteralPath $probePath -Value $code -Encoding UTF8
  $rawLines = New-Object System.Collections.Generic.List[string]
  try {
    Run-LoggedProcess $Python @($probePath) { param($line) [void]$rawLines.Add([string]$line) }
  } finally {
    Remove-Item -LiteralPath $probePath -Force -ErrorAction SilentlyContinue
  }
  $raw = @($rawLines)
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
  function ConvertTo-ProcessArgument {
    param([string]$Argument)
    if ($null -eq $Argument) { return '""' }
    if ($Argument -notmatch '[\s"&|<>\^\(\)]') { return $Argument }
    return '"' + ($Argument -replace '"', '\"') + '"'
  }

  $id = [guid]::NewGuid().ToString("N")
  $stdoutPath = Join-Path $env:TEMP "sage_process_$id.out.log"
  $stderrPath = Join-Path $env:TEMP "sage_process_$id.err.log"

  New-Item -ItemType File -Path $stdoutPath -Force | Out-Null
  New-Item -ItemType File -Path $stderrPath -Force | Out-Null

  $argumentText = ($Arguments | ForEach-Object { ConvertTo-ProcessArgument $_ }) -join " "
  $commandText = "{0} {1} > {2} 2> {3}" -f `
    (ConvertTo-ProcessArgument $FilePath),
    $argumentText,
    (ConvertTo-ProcessArgument $stdoutPath),
    (ConvertTo-ProcessArgument $stderrPath)
  $startInfo = New-Object System.Diagnostics.ProcessStartInfo
  $startInfo.FileName = $env:ComSpec
  $startInfo.Arguments = "/d /s /c `"$commandText`""
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $process = [System.Diagnostics.Process]::Start($startInfo)

  $positions = @{
    $stdoutPath = 0L
    $stderrPath = 0L
  }

  function Read-NewProcessLogLines {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
      [void]$stream.Seek($positions[$Path], [System.IO.SeekOrigin]::Begin)
      $reader = New-Object System.IO.StreamReader($stream)
      while (-not $reader.EndOfStream) {
        $line = $reader.ReadLine()
        if (-not [string]::IsNullOrWhiteSpace($line)) {
          & $Log $line
        }
      }
      $positions[$Path] = $stream.Position
    } finally {
      $stream.Close()
    }
  }

  while (-not $process.HasExited) {
    Read-NewProcessLogLines $stdoutPath
    Read-NewProcessLogLines $stderrPath
    Start-Sleep -Milliseconds 250
    [System.Windows.Forms.Application]::DoEvents()
  }

  $process.WaitForExit()
  $process.Refresh()
  Read-NewProcessLogLines $stdoutPath
  Read-NewProcessLogLines $stderrPath

  Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue

  $exitCode = $process.ExitCode
  if ($exitCode -ne 0) {
    throw "$FilePath exited with code $exitCode"
  }
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
        Width="980" Height="640"
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
      <Setter Property="Padding" Value="12,0"/>
      <Setter Property="SnapsToDevicePixels" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border CornerRadius="15" Background="{TemplateBinding Background}">
              <Border.Effect>
                <DropShadowEffect Color="#111111" BlurRadius="6" ShadowDepth="2" Opacity="0.14"/>
              </Border.Effect>
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="{TemplateBinding Padding}"/>
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
        <RowDefinition Height="42"/>
        <RowDefinition Height="*"/>
      </Grid.RowDefinitions>

      <Border x:Name="TopBar" Grid.Row="0" Background="{StaticResource Ink}" CornerRadius="18,18,0,0">
        <Grid>
          <StackPanel Orientation="Horizontal" VerticalAlignment="Center" Margin="20,0,0,0">
            <Ellipse Width="10" Height="10" Fill="#EF665C" Margin="0,0,8,0"/>
            <Ellipse Width="10" Height="10" Fill="#F4C75D" Margin="0,0,8,0"/>
            <Ellipse Width="10" Height="10" Fill="#82D9B7" Margin="0,0,22,0"/>
            <TextBlock Text="Sage &amp; Triton One Shot" Foreground="#F7F1E6" FontWeight="Bold" FontSize="19" VerticalAlignment="Center"/>
          </StackPanel>
          <TextBlock x:Name="WindowStateText" Text="READY" Foreground="{StaticResource Mint}" FontWeight="Bold" FontSize="18" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,92,0"/>
          <Button x:Name="TitleCloseButton" Content="X" Width="44" Height="24" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,14,0" Style="{StaticResource PocketButton}" Background="{StaticResource Coral}" Foreground="#2D1110" FontSize="11"/>
        </Grid>
      </Border>

      <Grid Grid.Row="1">
        <Border Width="880" Height="520" Background="{StaticResource SoftGreen}" CornerRadius="28" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,2,0,6" BorderBrush="#A9C5B1" BorderThickness="1"/>
        <Border Width="760" Height="14" Background="#2C000000" CornerRadius="7" HorizontalAlignment="Center" VerticalAlignment="Bottom" Margin="0,0,0,24"/>

        <Border Width="800" Height="488" Background="{StaticResource Shell}" CornerRadius="28" HorizontalAlignment="Center" VerticalAlignment="Center" BorderBrush="#111718" BorderThickness="2">
          <Border.Effect>
            <DropShadowEffect Color="#162620" BlurRadius="30" ShadowDepth="15" Opacity="0.24"/>
          </Border.Effect>
          <Grid>
            <Border Width="704" Height="260" Background="{StaticResource Shell2}" CornerRadius="22" HorizontalAlignment="Center" VerticalAlignment="Top" Margin="0,28,0,0" BorderBrush="#0F1516" BorderThickness="2">
              <Border.Effect>
                <DropShadowEffect Color="#000000" BlurRadius="18" ShadowDepth="7" Opacity="0.18"/>
              </Border.Effect>
              <Grid>
                <Border Width="670" Height="228" Background="#182123" CornerRadius="16" HorizontalAlignment="Center" VerticalAlignment="Center" BorderBrush="#48575A" BorderThickness="1"/>
                <Border Width="634" Height="198" Background="{StaticResource Dark}" CornerRadius="11" HorizontalAlignment="Center" VerticalAlignment="Center" BorderBrush="#557DE2C2" BorderThickness="1">
                  <Grid>
                    <Rectangle Width="590" Height="1" Fill="#557DE2C2" HorizontalAlignment="Center" VerticalAlignment="Top" Margin="0,30,0,0"/>
                    <Rectangle Width="1" Height="140" Fill="#367DE2C2" HorizontalAlignment="Center" VerticalAlignment="Top" Margin="0,30,0,0"/>
                    <TextBlock Text="INSTALL LOG" Foreground="{StaticResource Mint}" FontSize="13" FontWeight="Bold" Margin="14,10,0,0"/>
                    <Rectangle Width="5" Height="70" Fill="{StaticResource Yellow}" RadiusX="3" RadiusY="3" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="18,64,0,0"/>
                    <Rectangle Width="5" Height="70" Fill="{StaticResource Coral}" RadiusX="3" RadiusY="3" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,76,18,0"/>
                    <Ellipse Width="11" Height="11" Fill="#F7F1E6" Stroke="{StaticResource Mint}" StrokeThickness="2" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,58,56,0"/>
                    <TextBox x:Name="LogBox" Text="&gt; choose a ComfyUI folder&#x0a;&gt; press Install when ready"
                             Background="Transparent" BorderThickness="0" Foreground="#DDFDEB"
                             FontFamily="Consolas" FontSize="12" Margin="36,42,54,14"
                             TextWrapping="Wrap" AcceptsReturn="True" VerticalScrollBarVisibility="Auto"
                             IsReadOnly="True"/>
                  </Grid>
                </Border>
              </Grid>
            </Border>

            <Border Width="704" Height="168" Background="#F7F1E6" CornerRadius="22" HorizontalAlignment="Center" VerticalAlignment="Top" Margin="0,300,0,0" BorderBrush="#111718" BorderThickness="2">
              <Grid Margin="28,18,28,16">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="410"/>
                  <ColumnDefinition Width="28"/>
                  <ColumnDefinition Width="210"/>
                </Grid.ColumnDefinitions>

                <Grid Grid.Column="0">
                  <TextBlock Text="ComfyUI folder" Foreground="{StaticResource Muted}" FontSize="10" FontWeight="Bold" HorizontalAlignment="Left" VerticalAlignment="Top"/>
                  <ComboBox x:Name="PathBox" Width="240" Height="32" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="0,24,0,0" FontSize="12" IsEditable="True"/>
                  <Button x:Name="ScanButton" Content="Rescan" Width="80" Height="32" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="250,24,0,0" Style="{StaticResource PocketButton}" Background="{StaticResource Mint}" Foreground="#10231F" FontSize="11"/>
                  <Button x:Name="BrowseButton" Content="Browse" Width="80" Height="32" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="330,24,0,0" Style="{StaticResource PocketButton}" Background="{StaticResource Yellow}" Foreground="#2C210B" FontSize="11"/>
                  <TextBlock x:Name="EnvText" Text="No ComfyUI selected." Foreground="#5B6A65" FontSize="10" FontWeight="SemiBold" Width="410" TextTrimming="CharacterEllipsis" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="0,66,0,0"/>
                  <Border Width="330" Height="8" Background="#D9E1DD" CornerRadius="4" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="11,106,0,0"/>
                  <Border x:Name="ProgressFill" Width="0" Height="8" Background="{StaticResource Mint}" CornerRadius="4" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="11,106,0,0"/>
                  <Ellipse x:Name="ProgressBall" Width="22" Height="22" Fill="#F7F1E6" Stroke="{StaticResource Mint}" StrokeThickness="3" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="0,99,0,0"/>
                  <TextBlock x:Name="PercentText" Text="0%" Foreground="{StaticResource Shell}" FontSize="13" FontWeight="Bold" Width="58" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="352,98,0,0" TextAlignment="Right"/>
                </Grid>

                <Grid Grid.Column="2">
                  <Button x:Name="InstallButton" Content="Install" Width="196" Height="42" HorizontalAlignment="Center" VerticalAlignment="Top" Style="{StaticResource PocketButton}" Background="{StaticResource Mint}" Foreground="#10231F" FontSize="16"/>
                  <Button x:Name="VerifyButton" Content="Verify" Width="196" Height="34" HorizontalAlignment="Center" VerticalAlignment="Top" Margin="0,50,0,0" Style="{StaticResource PocketButton}" Background="{StaticResource Coral}" Foreground="#2D1110" FontSize="13"/>
                  <Button x:Name="CloseButton" Content="Close" Width="196" Height="34" HorizontalAlignment="Center" VerticalAlignment="Top" Margin="0,92,0,0" Style="{StaticResource PocketButton}" Background="{StaticResource Yellow}" Foreground="#2C210B" FontSize="13"/>
                </Grid>
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
$TitleCloseButton = $window.FindName("TitleCloseButton")

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
  $ProgressFill.Width = [Math]::Round(330 * ($v / 100), 0)
  $ProgressBall.Margin = New-Object System.Windows.Thickness(([Math]::Round(330 * ($v / 100), 0)), 99, 0, 0)
  $PercentText.Text = "$v%"
}

function Set-Busy {
  param([bool]$Busy)
  $ScanButton.IsEnabled = -not $Busy
  $BrowseButton.IsEnabled = -not $Busy
  $InstallButton.IsEnabled = -not $Busy
  $VerifyButton.IsEnabled = -not $Busy
  $CloseButton.IsEnabled = -not $Busy
  $TitleCloseButton.IsEnabled = -not $Busy
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
    Append-Log "ComfyUI Desktop? pick AppData\Local\Comfy-Desktop\ComfyUI-Installs\<name>\ComfyUI with ..."
  }
}

function Start-Scan {
  $WindowStateText.Text = "SCAN..."
  $EnvText.Text = "Scanning common ComfyUI locations..."
  $PercentText.Text = "..."
  $window.Cursor = [System.Windows.Input.Cursors]::Wait
  Append-Log "scanning ComfyUI paths"
  $ScanButton.IsEnabled = $false
  $BrowseButton.IsEnabled = $false
  $window.UpdateLayout()
  $window.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Render)
  try {
    Apply-Candidates -Paths ([string[]]@(Get-ComfyCandidates))
  } catch {
    $WindowStateText.Text = "ERR"
    Append-Log $_.Exception.Message
  } finally {
    $window.Cursor = $null
    $PercentText.Text = ("{0}%" -f [Math]::Round(($ProgressFill.Width / 330) * 100, 0))
    $ScanButton.IsEnabled = -not $script:IsBusy
    $BrowseButton.IsEnabled = -not $script:IsBusy
  }
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
$TitleCloseButton.Add_Click({ $window.Close() })

$script:IsBusy = $false

function Report-Step {
  param(
    [int]$Percent,
    [string]$Message
  )
  Set-Progress $Percent
  Append-Log $Message
  $window.UpdateLayout()
}

$VerifyButton.Add_Click({
  if ($script:IsBusy) { return }
  $path = Get-CurrentComfyPath
  if ([string]::IsNullOrWhiteSpace($path)) {
    Append-Log "choose ComfyUI first"
    return
  }
  $WindowStateText.Text = "CHECK"
  Set-Busy $true
  $script:IsBusy = $true
  try {
    Report-Step 75 "verifying triton"
    $python = Find-Python $path
    if (-not $python) { throw "Could not find Python under $path" }
    Run-LoggedProcess $python @("-c", "import triton; print('triton OK', getattr(triton, '__version__', 'unknown'))") { param($line) Report-Step 82 $line }
    Report-Step 90 "verifying sageattention"
    Run-LoggedProcess $python @("-c", "import sageattention; print('sageattention OK')") { param($line) Report-Step 96 $line }
    Report-Step 100 "verification complete"
    $WindowStateText.Text = "WIN"
  } catch {
    $WindowStateText.Text = "ERR"
    Append-Log $_.Exception.Message
  } finally {
    $script:IsBusy = $false
    Set-Busy $false
  }
})

function Install-SelectedComfy {
  param([string]$Path)
  Report-Step 8 "reading environment"
  $python = Find-Python $Path
  if (-not $python) { throw "Could not find Python under $Path" }
  $info = Get-PythonInfo $python
  $plan = Get-InstallPlan $info

  Report-Step 15 "torch $($info.torch), cuda $($info.torch_cuda)"
  Report-Step 45 "installing triton"
  Install-PipPackage $python @($plan.TritonSpec) { param($line) Report-Step 55 $line } "Triton install failed. Check the tool version and your PyTorch version."

  Report-Step 70 "installing sageattention"
  Install-PipPackage $python @($plan.SageUrl) { param($line) Report-Step 80 $line } "SageAttention wheel install failed. Check whether a newer tool version supports this CUDA/PyTorch build."

  Report-Step 90 "verifying imports"
  Run-LoggedProcess $python @("-c", "import triton; import sageattention; print('imports OK')") { param($line) Report-Step 95 $line }
  Report-Step 100 "done"
}

function Complete-Install {
  param([System.Management.Automation.ErrorRecord]$ErrorRecord)
  Set-Busy $false
  $script:IsBusy = $false
  if ($ErrorRecord) {
    $WindowStateText.Text = "ERR"
    Append-Log $ErrorRecord.Exception.Message
    [System.Windows.MessageBox]::Show($ErrorRecord.Exception.Message, "Install failed", "OK", "Error") | Out-Null
  } else {
    $WindowStateText.Text = "WIN"
    [System.Windows.MessageBox]::Show("Done. Start ComfyUI with --use-sage-attention.", "Install complete", "OK", "Information") | Out-Null
  }
}

$InstallButton.Add_Click({
  if ($script:IsBusy) { return }
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
  $script:IsBusy = $true
  try {
    Install-SelectedComfy $path
    Complete-Install $null
  } catch {
    Complete-Install $_
  }
})

$window.Add_SourceInitialized({
  Start-Scan
})

[void]$window.ShowDialog()
