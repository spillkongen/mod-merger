<#
.SYNOPSIS
Twilight Princess themed, borderless WinForms GUI for merging texture pack folders.

.DESCRIPTION
Two merge modes (both require two folders):

  Replace matching files
    For every file in the destination whose name also exists somewhere in the
    source tree, overwrite the destination file with the source file.

  Append missing files
    Copy every source file whose name does NOT exist anywhere in the
    destination tree. Files are copied into the destination using their
    relative path from the source, with "-Imported" appended to each
    subfolder name (e.g. "ui\icons\foo.dds" -> "ui-Imported\icons-Imported\foo.dds").

A few specific filenames are excluded by default (loading-screen / boot-screen
textures that should normally never be swapped).
#>

# StrictMode Latest breaks WinForms click handlers; 3.0 keeps safety without killing events.
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$script:GuiBuildTag = '2026-05-18zb'
$script:UiHandlers = [System.Collections.ArrayList]::new()
$script:glassLog = $null
$script:IsoInstallDlg = $null

# WinForms events run as PowerShell scriptblocks. A bare "return" inside an event handler
# stops the pipeline and throws PipelineStoppedException (often seen on MouseMove).
function Test-IsPipelineStopped {
    param($ErrorRecord)
    if ($ErrorRecord.Exception -is [System.Management.Automation.PipelineStoppedException]) { return $true }
    if ($ErrorRecord.FullyQualifiedErrorId -eq 'PipelineStopped') { return $true }
    return ($ErrorRecord.Exception.Message -match 'pipeline has been stopped')
}

function Wrap-SafeUiEvent {
    param([Parameter(Mandatory)][scriptblock]$Handler)
    $handlerIndex = $script:UiHandlers.Count
    [void]$script:UiHandlers.Add($Handler)
    $capturedIndex = $handlerIndex
    return {
        param($s, $e)
        $handler = $script:UiHandlers[$capturedIndex]
        if ($null -eq $handler) { }
        else {
            try {
                if ($null -ne $e) { & $handler $s $e }
                else { & $handler $s }
            }
            catch {
                if (-not (Test-IsPipelineStopped $_)) {
                    try {
                        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                            Write-Log ("UI event: $($_.Exception.Message)") $ColorErr
                        }
                    } catch { }
                }
            }
        }
    }.GetNewClosure()
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
# Hide the PowerShell console after startup (launchers must not use -WindowStyle Hidden — that can hide WinForms too).
try {
    if (-not ('NativeConsole' -as [type])) {
        Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class NativeConsole {
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}
'@
    }
    $consoleHwnd = [NativeConsole]::GetConsoleWindow()
    if ($consoleHwnd -ne [IntPtr]::Zero) { [void][NativeConsole]::ShowWindow($consoleHwnd, 0) }
} catch { }
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)
# Must be set before any controls are created on this thread.
[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
$script:UiThreadExceptionHandler = {
    param($sender, $e)
    $ex = $e.Exception
    if ($ex -is [System.Management.Automation.PipelineStoppedException]) { }
    elseif ($ex.Message -match 'pipeline has been stopped') { }
}
[System.Windows.Forms.Application]::add_ThreadException($script:UiThreadExceptionHandler)

# Title-bar drag in C# - PowerShell MouseMove handlers often throw PipelineStoppedException to WinForms.
$script:BorderlessFormDragReady = $false
if (-not ('BorderlessFormDrag' -as [type])) {
    $dragDll = Join-Path $env:TEMP 'TexturepackMerge-BorderlessFormDrag-v3.dll'
    $dragCs = @'
using System;
using System.Drawing;
using System.Windows.Forms;

public sealed class BorderlessFormDrag
{
    readonly Form _form;
    readonly int _titleBarHeight;
    readonly int _excludeRightPx;
    bool _dragging;
    Point _dragStart;

    public BorderlessFormDrag(Form form, int titleBarHeightPx, int excludeRightPx)
    {
        _form = form;
        _titleBarHeight = titleBarHeightPx;
        _excludeRightPx = excludeRightPx;
        _form.MouseDown += OnMouseDown;
        _form.MouseMove += OnMouseMove;
        _form.MouseUp += OnMouseUp;
        _form.MouseLeave += OnMouseLeave;
    }

    void OnMouseDown(object sender, MouseEventArgs e)
    {
        int dragMaxX = _form.ClientSize.Width - _excludeRightPx;
        if (e.Button == MouseButtons.Left && e.Y < _titleBarHeight && e.X < dragMaxX)
        {
            _dragging = true;
            _dragStart = new Point(e.X, e.Y);
        }
    }

    void OnMouseMove(object sender, MouseEventArgs e)
    {
        if (!_dragging) return;
        _form.Location = new Point(
            _form.Location.X + e.X - _dragStart.X,
            _form.Location.Y + e.Y - _dragStart.Y);
    }

    void OnMouseUp(object sender, MouseEventArgs e) { _dragging = false; }
    void OnMouseLeave(object sender, EventArgs e) { _dragging = false; }
}
'@
    try {
        $dragLoaded = $false
        if (Test-Path -LiteralPath $dragDll) {
            try { Add-Type -Path $dragDll; $dragLoaded = $true } catch { $dragLoaded = $false }
        }
        if (-not $dragLoaded) {
            try {
                Add-Type -TypeDefinition $dragCs -OutputAssembly $dragDll -ReferencedAssemblies @(
                    'System.Windows.Forms', 'System.Drawing'
                )
            } catch {
                Add-Type -TypeDefinition $dragCs -ReferencedAssemblies @(
                    'System.Windows.Forms', 'System.Drawing'
                )
            }
        }
        if ('BorderlessFormDrag' -as [type]) { $script:BorderlessFormDragReady = $true }
    } catch {
        $script:BorderlessFormDragReady = $false
    }
} else {
    $script:BorderlessFormDragReady = $true
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

$script:ExcludedFileNames = @(
    'tex1_608x100_0c1c70378fb8cb46_6.dds',
    'tex1_224x29_175aea04816c34a7_2.dds'
)

# Twilight Princess inspired palette
# Deep night + warm amber/gold (Hyrule twilight) + Midna teal accents
$ColorBg          = [System.Drawing.Color]::FromArgb(14, 10, 6)      # deep night
$ColorBgAlt       = [System.Drawing.Color]::FromArgb(36, 26, 18)     # raised surface
$ColorBgCard      = [System.Drawing.Color]::FromArgb(20, 14, 10)     # card / panel (very dark, opaque)
$ColorPanelChild  = [System.Drawing.Color]::FromArgb(28, 20, 14)     # solid fill for controls on themed panels (avoids WinForms ghosting)
$ColorBgTitle     = [System.Drawing.Color]::FromArgb(8, 6, 4)        # near-black for right-side controls
$ColorBgInput     = [System.Drawing.Color]::FromArgb(52, 38, 26)     # input field
$ColorLogBg       = [System.Drawing.Color]::FromArgb(24, 18, 12)      # log fallback (opaque)
$ColorLogGlass    = [System.Drawing.Color]::FromArgb(72, 14, 10, 6)  # log inner tint (semi-transparent)
$ColorFg          = [System.Drawing.Color]::White
$ColorFgDim       = [System.Drawing.Color]::FromArgb(245, 245, 245)  # hint text (still white, slightly soft)
$ColorAccent      = [System.Drawing.Color]::FromArgb(255, 170, 60)   # twilight amber
$ColorAccentHover = [System.Drawing.Color]::FromArgb(255, 200, 100)  # brighter amber
$ColorAccent2     = [System.Drawing.Color]::FromArgb(110, 230, 230)  # Midna teal
$ColorBorder      = [System.Drawing.Color]::FromArgb(140, 95, 60)    # weathered bronze (brighter)
$ColorBorderGlow  = [System.Drawing.Color]::FromArgb(200, 140, 70)
$ColorOk          = [System.Drawing.Color]::FromArgb(140, 255, 160)
$ColorWarn        = [System.Drawing.Color]::FromArgb(255, 220, 100)
$ColorErr         = [System.Drawing.Color]::FromArgb(255, 130, 115)
$ColorCloseHover  = [System.Drawing.Color]::FromArgb(190, 55, 55)

$FontMain    = New-Object System.Drawing.Font('Segoe UI', 10.5, [System.Drawing.FontStyle]::Bold)
$FontBold    = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
$FontHint    = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)
$FontMono    = New-Object System.Drawing.Font('Consolas', 10, [System.Drawing.FontStyle]::Bold)
$FontIcon    = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)
$FontHero    = New-Object System.Drawing.Font('Georgia', 18, [System.Drawing.FontStyle]::Bold)
$FontChip    = New-Object System.Drawing.Font('Segoe UI Semibold', 11, [System.Drawing.FontStyle]::Bold)

$TitleBarHeight = 52
$script:LogoRightReserve = 330

# Enable TLS 1.2+ so HTTPS downloads from GameBanana work on older PS hosts
try {
    [System.Net.ServicePointManager]::SecurityProtocol =
        [System.Net.ServicePointManager]::SecurityProtocol -bor
        [System.Net.SecurityProtocolType]::Tls12
} catch {}

# ---------------------------------------------------------------------------
# GameBanana / texconv / extra-mods helpers (ported from ger.ps1)
# ---------------------------------------------------------------------------

$script:TexconvPath = $null
$script:AppRoot = $null
$script:ExcludedFileNamesForMerge = @(
    'tex1_608x100_0c1c70378fb8cb46_6.dds',
    'tex1_224x29_175aea04816c34a7_2.dds'
)

# Allowlist: ONLY final mod texture files are merged into a pack.
# Everything else (.pdn / .psd / .bak / readme.txt / preview .png / .ini / etc.)
# is silently dropped during the merge step. PNG to DDS conversion runs BEFORE
# merge, so by the time we copy files, real textures already exist as .dds.
$script:AllowedExtensionsForMerge = @('.dds')

function Test-IsAllowedForMerge {
    param([Parameter(Mandatory)][System.IO.FileInfo]$File)
    $ext = $File.Extension.ToLowerInvariant()
    if ([string]::IsNullOrEmpty($ext)) { return $false }
    return ($script:AllowedExtensionsForMerge -contains $ext)
}

function Find-Texconv {
    if ($script:TexconvPath -and (Test-Path -LiteralPath $script:TexconvPath -PathType Leaf)) {
        return $script:TexconvPath
    }
    $root = $script:AppRoot
    if (-not $root) { $root = if ($PSScriptRoot) { $PSScriptRoot } else { $scriptDir } }
    $candidates = @(
        (Join-Path $root 'texconv.exe'),
        (Join-Path $root 'DuskModConverter\texconv.exe'),
        (Join-Path $PSScriptRoot 'texconv.exe'),
        (Join-Path $PSScriptRoot 'DuskModConverter\texconv.exe'),
        "$env:USERPROFILE\Desktop\DuskModConverter\texconv.exe",
        'C:\Users\marti\Desktop\DuskModConverter\texconv.exe'
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) {
            $script:TexconvPath = (Resolve-Path -LiteralPath $c).Path
            return $script:TexconvPath
        }
    }
    return $null
}

function Test-PngHasAlpha {
    param([string]$Path)
    try {
        $bmp = [System.Drawing.Bitmap]::new($Path)
        try { return ($bmp.PixelFormat -band [System.Drawing.Imaging.PixelFormat]::Alpha) -ne 0 }
        finally { $bmp.Dispose() }
    } catch { return $true }
}

function Test-IsPreviewPngName {
    param([string]$FileName)
    # Mod textures are named tex1_... etc. Any other PNG is a preview picture for picking styles.
    return ($FileName -notmatch '^tex')
}

function Test-IsModTexturePngName {
    param([string]$FileName)
    return ($FileName -match '^tex')
}

function Get-StylePreviewPngs {
    param([string]$Folder)
    @(Get-ChildItem -LiteralPath $Folder -File -Recurse -Filter '*.png' -ErrorAction SilentlyContinue |
      Where-Object { Test-IsPreviewPngName $_.Name })
}

function Get-ModStyleChoices {
    param([string]$RootFolder)
    $root = (Resolve-Path -LiteralPath $RootFolder).Path
    $choices = New-Object System.Collections.Generic.List[object]
    $childDirs = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)
    if ($childDirs.Count -gt 0) {
        foreach ($dir in $childDirs) {
            $previews = @(Get-StylePreviewPngs -Folder $dir.FullName)
            if ($previews.Count -eq 0) { continue }
            $preview = $previews | Sort-Object Name | Select-Object -First 1
            [void]$choices.Add([pscustomobject]@{
                StyleName    = $dir.Name
                FolderPath   = $dir.FullName
                PreviewPath  = $preview.FullName
                PreviewCount = $previews.Count
            })
        }
    }
    if ($choices.Count -eq 0) {
        $previews = @(Get-StylePreviewPngs -Folder $root)
        if ($previews.Count -gt 0) {
            $preview = $previews | Sort-Object Name | Select-Object -First 1
            [void]$choices.Add([pscustomobject]@{
                StyleName    = Split-Path $root -Leaf
                FolderPath   = $root
                PreviewPath  = $preview.FullName
                PreviewCount = $previews.Count
            })
        }
    }
    return @($choices.ToArray())
}

function New-StylePreviewThumbnail {
    param([string]$ImagePath, [int]$Size = 96)
    $bmp = New-Object System.Drawing.Bitmap $Size, $Size
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.Clear($ColorBgAlt)
    if ($ImagePath -and (Test-Path -LiteralPath $ImagePath)) {
        try {
            $img = [System.Drawing.Image]::FromFile($ImagePath)
            $g.DrawImage($img, 0, 0, $Size, $Size)
            $img.Dispose()
        } catch { }
    }
    $g.Dispose()
    return $bmp
}

function Show-ModStylePickerDialog {
    param([array]$Styles)
    if (-not $Styles -or $Styles.Count -eq 0) { return @() }

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Choose texture style(s) to convert'
    $dlg.Size = New-Object System.Drawing.Size(760, 560)
    $dlg.MinimumSize = New-Object System.Drawing.Size(640, 480)
    $dlg.StartPosition = 'CenterParent'
    $dlg.BackColor = $ColorBg
    $dlg.ForeColor = $ColorFg
    $dlg.Font = $FontMain
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = 'Each folder is a style (e.g. a shield variant). Check the ones to convert. Preview PNGs = any .png that does NOT start with tex (mod files start with tex).'
    $lbl.Location = New-Object System.Drawing.Point(16, 12)
    $lbl.Size = New-Object System.Drawing.Size(720, 40)
    $lbl.ForeColor = $ColorFg
    $dlg.Controls.Add($lbl)

    $lv = New-Object System.Windows.Forms.ListView
    $lv.Location = New-Object System.Drawing.Point(16, 56)
    $lv.Size = New-Object System.Drawing.Size(720, 380)
    $lv.Anchor = 'Top,Bottom,Left,Right'
    $lv.View = 'LargeIcon'
    $lv.CheckBoxes = $true
    $lv.BackColor = $ColorBgInput
    $lv.ForeColor = $ColorFg
    $lv.Font = $FontMain
    $lv.BorderStyle = 'FixedSingle'
    $lv.MultiSelect = $false

    $imgList = New-Object System.Windows.Forms.ImageList
    $imgList.ImageSize = New-Object System.Drawing.Size(96, 96)
    $imgList.ColorDepth = [System.Windows.Forms.ColorDepth]::Depth32Bit

    foreach ($s in $Styles) {
        $thumb = New-StylePreviewThumbnail -ImagePath $s.PreviewPath
        [void]$imgList.Images.Add($s.StyleName, $thumb)
        $item = $lv.Items.Add($s.StyleName, $s.StyleName)
        $item.Tag = $s
        $item.Checked = $true
    }
    $lv.LargeImageList = $imgList
    $dlg.Controls.Add($lv)

    $selAllBtn = New-Object System.Windows.Forms.Button
    $selAllBtn.Text = 'Select all'
    $selAllBtn.Location = New-Object System.Drawing.Point(16, 448)
    $selAllBtn.Size = New-Object System.Drawing.Size(100, 28)
    $selAllBtn.Anchor = 'Bottom,Left'
    $selAllBtn.FlatStyle = 'Flat'
    $selAllBtn.BackColor = $ColorBgAlt
    $selAllBtn.ForeColor = $ColorFg
    $selAllBtn.Add_Click({ foreach ($i in $lv.Items) { $i.Checked = $true } })
    $dlg.Controls.Add($selAllBtn)

    $selNoneBtn = New-Object System.Windows.Forms.Button
    $selNoneBtn.Text = 'Select none'
    $selNoneBtn.Location = New-Object System.Drawing.Point(122, 448)
    $selNoneBtn.Size = New-Object System.Drawing.Size(100, 28)
    $selNoneBtn.Anchor = 'Bottom,Left'
    $selNoneBtn.FlatStyle = 'Flat'
    $selNoneBtn.BackColor = $ColorBgAlt
    $selNoneBtn.ForeColor = $ColorFg
    $selNoneBtn.Add_Click({ foreach ($i in $lv.Items) { $i.Checked = $false } })
    $dlg.Controls.Add($selNoneBtn)

    $okBtn = New-Object System.Windows.Forms.Button
    $okBtn.Text = 'Convert selected'
    $okBtn.Location = New-Object System.Drawing.Point(536, 448)
    $okBtn.Size = New-Object System.Drawing.Size(120, 28)
    $okBtn.Anchor = 'Bottom,Right'
    $okBtn.FlatStyle = 'Flat'
    $okBtn.BackColor = $ColorAccent
    $okBtn.ForeColor = [System.Drawing.Color]::FromArgb(20, 14, 8)
    $okBtn.Font = $FontBold
    $okBtn.DialogResult = 'OK'
    $dlg.Controls.Add($okBtn)
    $dlg.AcceptButton = $okBtn

    $cancelBtn = New-Object System.Windows.Forms.Button
    $cancelBtn.Text = 'Cancel'
    $cancelBtn.Location = New-Object System.Drawing.Point(662, 448)
    $cancelBtn.Size = New-Object System.Drawing.Size(74, 28)
    $cancelBtn.Anchor = 'Bottom,Right'
    $cancelBtn.FlatStyle = 'Flat'
    $cancelBtn.BackColor = $ColorBgAlt
    $cancelBtn.ForeColor = $ColorFg
    $cancelBtn.DialogResult = 'Cancel'
    $dlg.Controls.Add($cancelBtn)
    $dlg.CancelButton = $cancelBtn

    if ($form) {
        $dlg.Owner = $form
        $dlg.StartPosition = 'CenterParent'
        try {
            $form.Activate()
            $form.BringToFront()
        } catch { }
    } else {
        $dlg.StartPosition = 'CenterScreen'
    }
    $dlg.TopMost = $true
    if ($dlg.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) { return @() }
    $dlg.TopMost = $false
    $picked = @()
    foreach ($item in $lv.Items) {
        if ($item.Checked) { $picked += $item.Tag }
    }
    return $picked
}

function Test-IsPathUnderFolder {
    param([string]$FilePath, [string]$FolderPath)
    $folder = $FolderPath.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    return $FilePath.StartsWith($folder, [System.StringComparison]::OrdinalIgnoreCase)
}

function Resolve-ModContentRoot {
    param([string]$ExtractedFolder)
    $root = (Resolve-Path -LiteralPath $ExtractedFolder).Path
    if (@(Get-ModStyleChoices -RootFolder $root).Count -gt 0) { return $root }
    $childDirs = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)
    if ($childDirs.Count -eq 1) {
        $inner = $childDirs[0].FullName
        if (@(Get-ModStyleChoices -RootFolder $inner).Count -gt 0) { return $inner }
    }
    return $root
}

function Get-ModAppendFileEntries {
    param(
        [string]$ModRoot,
        [string[]]$LimitToStyleFolders
    )
    $entries = New-Object System.Collections.Generic.List[object]
    $allFiles = @(Get-ChildItem -LiteralPath $ModRoot -File -Recurse -ErrorAction SilentlyContinue)
    foreach ($f in $allFiles) {
        if ($f.Name -in $script:ExcludedFileNamesForMerge) { continue }
        if (-not (Test-IsAllowedForMerge -File $f)) { continue }
        if (Test-IsPreviewPngName $f.Name) { continue }
        if ($LimitToStyleFolders -and $LimitToStyleFolders.Count -gt 0) {
            $under = $false
            foreach ($sf in $LimitToStyleFolders) {
                if (Test-IsPathUnderFolder -FilePath $f.FullName -FolderPath $sf) {
                    $under = $true
                    break
                }
            }
            if (-not $under) { continue }
        }
        [void]$entries.Add([pscustomobject]@{ File = $f; Root = $ModRoot })
    }
    return @($entries.ToArray())
}

function Open-FolderInExplorer {
    param(
        [string]$Path,
        # Short wait after heavy file ops (e.g. texconv) so Explorer does not open on a half-updated folder and snap shut.
        [int]$DelayMs = 0
    )
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $target = $null
    try {
        $openPath = $Path.Trim()
        if (Test-Path -LiteralPath $openPath -PathType Leaf) {
            $openPath = Split-Path -LiteralPath $openPath -Parent
        }
        if (-not (Test-Path -LiteralPath $openPath -PathType Container)) { return $false }
        $target = (Resolve-Path -LiteralPath $openPath).Path
        if ($DelayMs -gt 0) {
            Start-Sleep -Milliseconds $DelayMs
            [System.Windows.Forms.Application]::DoEvents()
        }
        # Invoke-Item uses correct quoting for paths with spaces; raw explorer.exe args often mis-parse and windows vanish.
        Invoke-Item -LiteralPath $target
        return $true
    } catch {
        if (-not $target) { return $false }
        try {
            $shellApp = New-Object -ComObject Shell.Application
            $null = $shellApp.Explore($target)
            [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($shellApp)
            return $true
        } catch {
            return $false
        }
    }
}

function Get-ExplorerPathFromConvertResult {
    param($ConvertResult)
    if (-not $ConvertResult) { return $null }
    if ($ConvertResult.SelectedStyleFolders -and $ConvertResult.SelectedStyleFolders.Count -eq 1) {
        return $ConvertResult.SelectedStyleFolders[0]
    }
    if ($ConvertResult.ContentRoot) { return $ConvertResult.ContentRoot }
    return $null
}

function Open-ExplorerForAppendPlan {
    param($Plan, [string]$TargetFolder)
    $items = @($Plan)
    if ($items.Count -eq 0) {
        Open-FolderInExplorer $TargetFolder | Out-Null
        return
    }
    $destDirs = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($p in $items) {
        $dir = Split-Path -Path $p.Destination -Parent
        if ($dir) { [void]$destDirs.Add((Resolve-Path -LiteralPath $dir).Path) }
    }
    $dirs = @($destDirs | Sort-Object)
    if ($dirs.Count -eq 1) {
        Open-FolderInExplorer $dirs[0] | Out-Null
    } else {
        Open-FolderInExplorer $TargetFolder | Out-Null
    }
}

function Get-AppendEntriesForSourceRoot {
    param(
        [string]$Root,
        [string[]]$SelectedStyleFolders
    )
    $contentRoot = Resolve-ModContentRoot -ExtractedFolder $Root
    $styles = @(Get-ModStyleChoices -RootFolder $contentRoot)
    if ($styles.Count -ge 2) {
        $stylePaths = @($SelectedStyleFolders | Where-Object { $_ })
        if ($stylePaths.Count -eq 0) {
            $stylePaths = @($styles | ForEach-Object { $_.FolderPath })
            Write-Log ("Multiple style folders found — using all $($stylePaths.Count) for merge scan.") $ColorFgDim
        }
        return @(Get-ModAppendFileEntries -ModRoot $contentRoot -LimitToStyleFolders $stylePaths)
    }
    return @(Get-ModAppendFileEntries -ModRoot $contentRoot -LimitToStyleFolders @($contentRoot))
}

function Invoke-PngToDdsForFolder {
    param(
        [string]$Folder,
        [scriptblock]$LogFn,
        $ProgressBar,
        [bool]$PromptForStyle = $true,
        [bool]$IncludeAllPngs = $false,
        [bool]$EntireTree = $false
    )
    $contentRoot = Resolve-ModContentRoot -ExtractedFolder $Folder
    $styles = @(Get-ModStyleChoices -RootFolder $contentRoot)
    $targetFolders = @()

    if ($EntireTree) {
        if ($LogFn) {
            & $LogFn 'Converting all tex*.png in folder and subfolders (preview PNGs are skipped).' 'dim'
        }
        $total = Convert-PngsInFolderToDds -Folder $contentRoot -LogFn $LogFn -ProgressBar $ProgressBar -IncludeAllPngs:$IncludeAllPngs
        return [pscustomobject]@{
            Count                = $total
            SelectedStyleFolders = @($contentRoot)
            ContentRoot          = $contentRoot
        }
    }

        if ($styles.Count -ge 2 -and $PromptForStyle) {
        if ($form) {
            try {
                $form.Activate()
                $form.BringToFront()
            } catch { }
        }
        if ($LogFn) {
            & $LogFn ("Found $($styles.Count) style folder(s) with preview PNGs.") 'accent'
            & $LogFn 'Pick which style(s) to use (preview = PNG not starting with tex). Only tex*.png become DDS.' 'dim'
        }
        $picked = @(Show-ModStylePickerDialog -Styles $styles)
        if ($picked.Count -eq 0) {
            if ($LogFn) { & $LogFn 'No style selected - skipped.' 'warn' }
            return [pscustomobject]@{ Count = 0; SelectedStyleFolders = @(); ContentRoot = $contentRoot }
        }
        $targetFolders = @($picked | ForEach-Object { $_.FolderPath })
        foreach ($p in $picked) {
            if ($LogFn) { & $LogFn ("  Style: $($p.StyleName)") 'ok' }
        }
    } elseif ($styles.Count -eq 1) {
        $targetFolders = @($styles[0].FolderPath)
        if ($LogFn) { & $LogFn ("Style folder: $($styles[0].StyleName)") 'dim' }
    } else {
        $targetFolders = @($contentRoot)
    }

    $total = 0
    foreach ($tf in $targetFolders) {
        if ($LogFn) { & $LogFn ("--- PNG -> DDS: $(Split-Path $tf -Leaf) ---") 'accent' }
        $total += Convert-PngsInFolderToDds -Folder $tf -LogFn $LogFn -ProgressBar $ProgressBar -IncludeAllPngs:$IncludeAllPngs
    }
    return [pscustomobject]@{
        Count                 = $total
        SelectedStyleFolders  = @($targetFolders)
        ContentRoot           = $contentRoot
    }
}

function Invoke-TexconvOnPng {
    param(
        [string]$TexconvExe,
        [string]$PngPath,
        [string]$Format
    )
    $outDir = [System.IO.Path]::GetDirectoryName($PngPath)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $TexconvExe
    $psi.Arguments = "-nologo -f $Format -o `"$outDir`" -y `"$PngPath`""
    $psi.WorkingDirectory = $outDir
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $p.WaitForExit()
    return @{
        ExitCode = $p.ExitCode
        StdOut   = $p.StandardOutput.ReadToEnd()
        StdErr   = $p.StandardError.ReadToEnd()
    }
}

function Convert-PngsInFolderToDds {
    param(
        [string]$Folder,
        [scriptblock]$LogFn,
        $ProgressBar,
        [bool]$IncludeAllPngs = $false
    )
    $allPngs = @(Get-ChildItem -LiteralPath $Folder -File -Recurse -Filter '*.png' -ErrorAction SilentlyContinue)
    if ($allPngs.Count -eq 0) {
        if ($LogFn) { & $LogFn 'No .png files found in this folder (including subfolders).' 'warn' }
        return 0
    }
    if ($IncludeAllPngs) {
        $pngs = @($allPngs)
        if ($LogFn) { & $LogFn ("Converting all $($pngs.Count) PNG file(s) to DDS.") 'dim' }
    } else {
        $pngs = @($allPngs | Where-Object { Test-IsModTexturePngName $_.Name })
        if ($LogFn) {
            & $LogFn ("Found $($allPngs.Count) PNG(s); $($pngs.Count) are mod textures (name starts with tex).") 'dim'
        }
        if ($pngs.Count -eq 0) {
            if ($LogFn) {
                & $LogFn 'No tex*.png files to convert. Preview PNGs are skipped (use checkbox to convert all PNGs).' 'warn'
            }
            return 0
        }
    }
    $texconv = Find-Texconv
    if (-not $texconv) {
        if ($LogFn) { & $LogFn 'texconv.exe not found. Place it in DuskModConverter\texconv.exe next to this app.' 'err' }
        return 0
    }
    if ($ProgressBar) { Reset-GlowProgress -Bar $ProgressBar -Max $pngs.Count }
    if ($LogFn) { & $LogFn (">>> Converting $($pngs.Count) PNG file(s) to DDS") 'accent' }
    if ($LogFn) { & $LogFn ("Using: $texconv") 'dim' }
    $ok = 0
    $done = 0
    foreach ($png in $pngs) {
        $hasAlpha = Test-PngHasAlpha -Path $png.FullName
        $fmt = if ($hasAlpha) { 'DXT5' } else { 'DXT1' }
        try {
            $run = Invoke-TexconvOnPng -TexconvExe $texconv -PngPath $png.FullName -Format $fmt
            $dds = [System.IO.Path]::ChangeExtension($png.FullName, '.dds')
            if (Test-Path -LiteralPath $dds) {
                Remove-Item -LiteralPath $png.FullName -Force -ErrorAction SilentlyContinue
                $ok++
                if ($LogFn) { & $LogFn ("  [$ok/$($pngs.Count)] $($png.Name) -> $fmt") 'dim' }
            } elseif ($LogFn) {
                $detail = ($run.StdErr + $run.StdOut).Trim()
                if ([string]::IsNullOrWhiteSpace($detail)) { $detail = "exit code $($run.ExitCode)" }
                & $LogFn ("  texconv did not create DDS for $($png.Name): $detail") 'err'
            }
        } catch {
            if ($LogFn) { & $LogFn ("  texconv FAILED on $($png.Name): $($_.Exception.Message)") 'err' }
        }
        $done++
        if ($ProgressBar) {
            Set-GlowProgressState -Bar $ProgressBar -Value $done
            [System.Windows.Forms.Application]::DoEvents()
        }
    }
    if ($LogFn) { & $LogFn ("PNG -> DDS done: $ok of $($pngs.Count) converted") 'ok' }
    return $ok
}

function Test-IsZipArchive {
    param([string]$Path)
    try {
        $fs = [System.IO.File]::OpenRead($Path)
        try {
            $b = New-Object byte[] 4
            $r = $fs.Read($b, 0, 4)
            if ($r -lt 4) { return $false }
            return ($b[0] -eq 0x50 -and $b[1] -eq 0x4B) -and
                   (($b[2] -in 3, 5, 7) -and ($b[3] -in 4, 6, 8))
        } finally { $fs.Close() }
    } catch { return $false }
}

function Expand-ZipToFolderGui {
    param([string]$ZipPath, [string]$DestinationFolder)
    if (Test-Path -LiteralPath $DestinationFolder) {
        Remove-Item -LiteralPath $DestinationFolder -Recurse -Force
    }
    New-Item -ItemType Directory -Path $DestinationFolder -Force | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    [System.IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $DestinationFolder)
}

function Get-ModMergerAppFolder {
    # Always the folder that contains Texturepack-Merge-GUI.ps1 (portable — any drive/path).
    if ($script:AppRoot) { return $script:AppRoot }
    if ($scriptDir) { return $scriptDir }
    if ($PSScriptRoot) { return $PSScriptRoot }
    if ($PSCommandPath) { return (Split-Path -Path $PSCommandPath -Parent) }
    return (Get-Location).Path
}

function Get-GameBananaLinksFilePath {
    param([string]$Root = '')
    if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Get-ModMergerAppFolder }
    return Join-Path $Root 'gamebanana-mods.txt'
}

function Get-GameBananaDownloadFolder {
    return Get-ModMergerAppFolder
}

function Ensure-GameBananaLinksFile {
    param(
        [string]$Root = '',
        [switch]$ForceNew,
        [scriptblock]$LogFn
    )
    $path = Get-GameBananaLinksFilePath -Root $Root
    if ((Test-Path -LiteralPath $path -PathType Leaf) -and -not $ForceNew) {
        return $path
    }
    $template = @'
# GameBanana mods to download
# ---------------------------------------------------------------
# Keep this file in the SAME FOLDER as Start Mod Merger.vbs / the app.
# Downloaded mod .zip files are saved in that same folder (works on any PC/path).
#
# One DIRECT download URL per line (not the mod page link).
# GOOD:  https://gamebanana.com/dl/1234567
# BAD:   https://gamebanana.com/mods/12345
#
# Lines starting with #, //, or ; are notes. Blank lines are OK.
# ---------------------------------------------------------------

# Paste your links below (one per line):

'@
    $parent = Split-Path -Parent $path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    Set-Content -LiteralPath $path -Value $template -Encoding UTF8
    if ($LogFn) { & $LogFn "Created GameBanana links file: $path" 'ok' }
    return $path
}

function Get-GameBananaLinksFromFile {
    param([string]$Path)
    $links = @()
    foreach ($line in (Get-Content -LiteralPath $Path)) {
        $t = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($t)) { continue }
        if ($t.StartsWith('#') -or $t.StartsWith('//') -or $t.StartsWith(';')) { continue }
        if ($t -match '^https?://') { $links += $t }
    }
    return @($links)
}

function Get-SanitizedFileNameGui {
    param([string]$Name)
    foreach ($c in [System.IO.Path]::GetInvalidFileNameChars()) {
        $Name = $Name.Replace([string]$c, '_')
    }
    return $Name.Trim()
}

function Save-WebFileToFolderGui {
    param([string]$Url, [string]$DestinationFolder, [scriptblock]$LogFn)
    if ($Url -match '^https?://(?:www\.)?gamebanana\.com/(?:mods|tools|wips|sounds|skins|maps|effects|gamefiles|gamesyncs|crafts|guis|sprays|textures|threads)/\d+/?(?:\?.*)?$') {
        if ($LogFn) { & $LogFn ("Skipping mod PAGE URL (not a direct download): $Url") 'warn' }
        return $null
    }
    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) GameBananaModDownloader/1.0'
    $req.Accept = 'application/octet-stream, application/zip, application/x-zip-compressed, */*;q=0.5'
    $req.AllowAutoRedirect = $true
    $req.Timeout = 60000
    try { $resp = $req.GetResponse() } catch {
        if ($LogFn) { & $LogFn ("Download failed: $($_.Exception.Message)") 'err' }
        return $null
    }
    $ct = $resp.ContentType
    if ($ct -and ($ct.ToLowerInvariant().StartsWith('text/html'))) {
        if ($LogFn) { & $LogFn ("Skipping - server returned HTML page (Content-Type: $ct)") 'warn' }
        try { $resp.Close() } catch {}
        return $null
    }
    $fileName = $null
    $cd = $resp.Headers['Content-Disposition']
    if ($cd) {
        if ($cd -match "filename\*\s*=\s*UTF-8''([^;]+)") {
            try { $fileName = [System.Uri]::UnescapeDataString($matches[1].Trim()) } catch { $fileName = $matches[1].Trim() }
        } elseif ($cd -match 'filename\s*=\s*"([^"]+)"') { $fileName = $matches[1].Trim() }
        elseif ($cd -match 'filename\s*=\s*([^;]+)') { $fileName = $matches[1].Trim() }
    }
    if (-not $fileName) { try { $fileName = [System.IO.Path]::GetFileName($resp.ResponseUri.LocalPath) } catch {} }
    if (-not $fileName) { $fileName = "gamebanana-$([guid]::NewGuid().ToString('N').Substring(0,8)).bin" }
    $fileName = Get-SanitizedFileNameGui -Name $fileName
    $destPath = Join-Path $DestinationFolder $fileName
    $i = 1
    while (Test-Path -LiteralPath $destPath) {
        $base = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
        $ext  = [System.IO.Path]::GetExtension($fileName)
        $destPath = Join-Path $DestinationFolder ("$base ($i)$ext")
        $i++
    }
    if ($LogFn) { & $LogFn ("  -> $(Split-Path $destPath -Leaf)") 'dim' }
    $stream = $resp.GetResponseStream()
    $fs = [System.IO.File]::OpenWrite($destPath)
    try {
        $buf = New-Object byte[] 65536
        while (($r = $stream.Read($buf, 0, $buf.Length)) -gt 0) { $fs.Write($buf, 0, $r) }
    } finally { $fs.Close(); $stream.Close(); $resp.Close() }
    return $destPath
}

function Get-ImportedRelativePathGui {
    param([string]$RelativePath)
    $f = [System.IO.Path]::GetFileName($RelativePath)
    $d = [System.IO.Path]::GetDirectoryName($RelativePath)
    if ([string]::IsNullOrWhiteSpace($d)) { return $f }
    $segs = @($d -split '[\\/]' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { "$_-Imported" })
    return Join-Path ([System.IO.Path]::Combine([string[]]$segs)) $f
}

function Add-ModFolderToDestinationGui {
    param(
        [string]$ModFolder,
        [string]$TargetFolder,
        [string]$ModLabel,
        [scriptblock]$LogFn,
        $ProgressBar,
        [bool]$OpenExplorer = $true
    )
    if (-not (Test-Path -LiteralPath $ModFolder -PathType Container)) {
        if ($LogFn) { & $LogFn ("Mod folder not found: $ModFolder") 'err' }
        return
    }
    if (-not $ModLabel) { $ModLabel = Split-Path $ModFolder -Leaf }
    if ($LogFn) { & $LogFn ("=== Adding mod: $ModLabel ===") 'accent' }

    $contentRoot = Resolve-ModContentRoot -ExtractedFolder $ModFolder
    $convert = Invoke-PngToDdsForFolder -Folder $ModFolder -LogFn $LogFn -ProgressBar $ProgressBar -PromptForStyle $true
    $styleLimit = @($convert.SelectedStyleFolders)

    if (@(Get-ModStyleChoices -RootFolder $contentRoot).Count -ge 2 -and $styleLimit.Count -eq 0) {
        if ($LogFn) { & $LogFn 'No style chosen - mod not appended.' 'warn' }
        return
    }
    if ($styleLimit.Count -eq 0) { $styleLimit = @($contentRoot) }

    foreach ($sf in $styleLimit) {
        $leaf = Split-Path $sf -Leaf
        $destPreview = Join-Path $TargetFolder (ConvertTo-ImportedRelativePath -RelativePath $leaf)
        if ($LogFn) { & $LogFn ("  -> append into: $destPreview") 'dim' }
    }

    $entries = @(Get-ModAppendFileEntries -ModRoot $contentRoot -LimitToStyleFolders $styleLimit)
    if ($entries.Count -eq 0) {
        if ($LogFn) { & $LogFn ("No mod files to append after style filter (preview PNGs skipped).") 'warn' }
        return
    }
    $targetFiles = @(Get-ChildItem -LiteralPath $TargetFolder -File -Recurse -ErrorAction SilentlyContinue)
    $plan = New-Object System.Collections.Generic.List[object]
    $already = @{}
    Add-AppendEntriesToPlan -PlanList $plan -SourceEntries $entries -TargetFolder $TargetFolder `
        -TargetFiles $targetFiles -AlreadyPlannedByName $already
    if ($plan.Count -eq 0) {
        if ($LogFn) { & $LogFn ("Nothing new to add - all files already exist in destination.") 'warn' }
        return
    }
    if ($LogFn) { & $LogFn ("Appending $($plan.Count) file(s) with -Imported folder names...") 'accent' }
    Invoke-Plan -Plan @($plan)
    if ($OpenExplorer) {
        Open-ExplorerForAppendPlan -Plan @($plan) -TargetFolder $TargetFolder
        if ($LogFn) { & $LogFn 'Opened destination folder in File Explorer.' 'dim' }
    }
}

function Invoke-GameBananaDownloadToCache {
    param(
        [string]$LinksFile,
        [string]$DownloadFolder,
        [string]$TargetFolder,
        [scriptblock]$LogFn,
        $ProgressBar
    )
    if ([string]::IsNullOrWhiteSpace($DownloadFolder)) {
        $DownloadFolder = Get-GameBananaDownloadFolder
    }
    $cache = $DownloadFolder
    if (-not (Test-Path -LiteralPath $cache)) { New-Item -ItemType Directory -Path $cache -Force | Out-Null }
    $links = @(Get-GameBananaLinksFromFile -Path $LinksFile)
    if ($links.Count -eq 0) {
        if ($LogFn) { & $LogFn ("No URLs found in $LinksFile") 'warn' }
        return @()
    }
    if ($ProgressBar) { Reset-GlowProgress -Bar $ProgressBar -Max $links.Count }
    if ($LogFn) { & $LogFn ("Downloading $($links.Count) mod(s) to cache: $cache") 'accent' }
    $downloaded = @()
    for ($i = 0; $i -lt $links.Count; $i++) {
        if ($LogFn) { & $LogFn ("[$($i+1)/$($links.Count)] $($links[$i])") 'fg' }
        $f = Save-WebFileToFolderGui -Url $links[$i] -DestinationFolder $cache -LogFn $LogFn
        if ($f) { $downloaded += $f }
        if ($ProgressBar) {
            Set-GlowProgressState -Bar $ProgressBar -Value ($i + 1)
            [System.Windows.Forms.Application]::DoEvents()
        }
    }
    return @($downloaded)
}

function Invoke-GameBananaExtractAndMerge {
    param(
        [string]$TargetFolder,
        [string]$DownloadFolder,
        [scriptblock]$LogFn,
        $ProgressBar,
        [string[]]$DownloadedFiles
    )
    if ([string]::IsNullOrWhiteSpace($DownloadFolder)) {
        $DownloadFolder = Get-GameBananaDownloadFolder
    }
    $cache = $DownloadFolder
    if ($DownloadedFiles -and $DownloadedFiles.Count -gt 0) {
        $files = @($DownloadedFiles)
    } else {
        $files = @(Get-ChildItem -LiteralPath $cache -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    }
    if ($files.Count -eq 0) {
        if ($LogFn) { & $LogFn 'No downloaded archives in cache to extract.' 'warn' }
        return
    }
    if ($LogFn) { & $LogFn ("Unzipping $($files.Count) archive(s), style picker, PNG to DDS, append missing (-Imported folders)...") 'accent' }
    if ($ProgressBar) { Reset-GlowProgress -Bar $ProgressBar -Max $files.Count }
    $knownZipExt = @('.zip', '.ziparchive', '.zipx', '.pk3', '.pk4')
    $archiveIdx = 0
    foreach ($file in $files) {
        $archiveIdx++
        try {
            $ext = [System.IO.Path]::GetExtension($file).ToLowerInvariant()
            $modName = [System.IO.Path]::GetFileNameWithoutExtension($file)
            $isZip = ($ext -in $knownZipExt) -or (Test-IsZipArchive -Path $file)
            if (-not $isZip) {
                if ($LogFn) { & $LogFn ("Skipping '$modName' - not a recognized archive.") 'warn' }
                continue
            }
            $extracted = Join-Path $cache ($modName + '_extracted')
            try { Expand-ZipToFolderGui -ZipPath $file -DestinationFolder $extracted }
            catch {
                if ($LogFn) { & $LogFn ("Extract failed for '$modName': $($_.Exception.Message)") 'err' }
                continue
            }
            Add-ModFolderToDestinationGui -ModFolder $extracted -TargetFolder $TargetFolder -ModLabel $modName `
                -LogFn $LogFn -ProgressBar $ProgressBar -OpenExplorer $false
        }
        finally {
            if ($ProgressBar) {
                Set-GlowProgressState -Bar $ProgressBar -Value $archiveIdx
                [System.Windows.Forms.Application]::DoEvents()
            }
        }
    }
    if ($LogFn) { & $LogFn 'Opening base pack in File Explorer...' 'dim' }
    Open-FolderInExplorer $TargetFolder | Out-Null
}

function Invoke-GameBananaBatchFromFile {
    param(
        [string]$LinksFile,
        [string]$TargetFolder,
        [scriptblock]$LogFn,
        $ProgressBar,
        [switch]$DownloadOnly
    )
    $dlFolder = Get-GameBananaDownloadFolder
    $downloaded = @(Invoke-GameBananaDownloadToCache -LinksFile $LinksFile -DownloadFolder $dlFolder -LogFn $LogFn -ProgressBar $ProgressBar)
    if ($DownloadOnly) {
        if ($LogFn) { & $LogFn 'Download complete (mods saved in app folder).' 'ok' }
        Open-FolderInExplorer $dlFolder | Out-Null
        return
    }
    Invoke-GameBananaExtractAndMerge -TargetFolder $TargetFolder -DownloadFolder $dlFolder -LogFn $LogFn -ProgressBar $ProgressBar -DownloadedFiles $downloaded
}

# ---------------------------------------------------------------------------
# Load background art (next to the script). Graceful fallback if missing.
# ---------------------------------------------------------------------------

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot }
    elseif ($PSCommandPath) { Split-Path -Path $PSCommandPath -Parent }
    else { (Get-Location).Path }
$script:AppRoot = $scriptDir
$script:GcmInstallPy = Join-Path $scriptDir 'tools\InstallModToGcm.py'

function Get-GclibSearchPaths {
    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($p in @(
            (Join-Path $scriptDir 'GCFT'),
            (Join-Path $scriptDir 'GCFT\gclib'),
            (Join-Path $scriptDir 'tools\GCFT'),
            (Join-Path $scriptDir 'tools\GCFT\gclib'),
            $env:GCFT_PATH,
            $env:GCLIB_PATH
        )) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        if ((Test-Path -LiteralPath $p -PathType Container) -and ($paths -notcontains $p)) {
            [void]$paths.Add($p)
        }
    }
    return @($paths.ToArray())
}

function Resolve-GcmModExtractRoot {
    param([string]$ExtractedPath)
    if (-not (Test-Path -LiteralPath $ExtractedPath -PathType Container)) {
        throw "Folder not found: $ExtractedPath"
    }
    $root = (Resolve-Path -LiteralPath $ExtractedPath).Path
    $names = @(Get-ChildItem -LiteralPath $root -Force | ForEach-Object { $_.Name })
    $nameSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$names, [StringComparer]::OrdinalIgnoreCase)
    if ($nameSet.Contains('files') -and $nameSet.Contains('sys') -and $nameSet.Count -eq 2) {
        $dirs = @(Get-ChildItem -LiteralPath $root -Directory -Force)
        if ($dirs.Count -eq 2) { return $root }
    }
    $subdirs = @(Get-ChildItem -LiteralPath $root -Directory -Force)
    if ($subdirs.Count -eq 1) {
        $inner = $subdirs[0].FullName
        $innerNames = @(Get-ChildItem -LiteralPath $inner -Force | ForEach-Object { $_.Name })
        $innerSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$innerNames, [StringComparer]::OrdinalIgnoreCase)
        if ($innerSet.Contains('files') -and $innerSet.Contains('sys') -and $innerSet.Count -eq 2) {
            return $inner
        }
    }
    throw "Mod archive must contain only 'files' and 'sys' at the top (or inside one folder), like a GCFT extract."
}

$script:GcmAllowedSysFiles = @(
    'apploader.img', 'bi2.bin', 'boot.bin', 'fst.bin', 'main.dol'
)
$script:GcmRiskySysFiles = @('boot.bin', 'main.dol', 'fst.bin', 'bi2.bin')
$script:GcmBlockedModExtensions = @(
    '.exe', '.bat', '.cmd', '.com', '.scr', '.ps1', '.vbs', '.js', '.msi', '.reg', '.lnk', '.dll'
)
$script:GcmZipMaxEntries = 25000
$script:GcmZipMaxUncompressedBytes = 3GB
$script:GcmZipMaxSingleFileBytes = 512MB

function Test-GcmZipEntryPathSafe {
    param([string]$EntryName)
    if ([string]::IsNullOrWhiteSpace($EntryName)) { return $true }
    $n = $EntryName.Replace('\', '/').Trim().TrimStart('/')
    if ($n -match '(^|/)\.\.(/|$)') { return $false }
    if ($n -match '^[a-zA-Z]:') { return $false }
    return $true
}

function Test-GcmModZipArchive {
    param([string]$ZipPath)
    $errors = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $ZipPath -PathType Leaf)) {
        [void]$errors.Add("ZIP not found: $ZipPath")
        return @{ Ok = $false; Errors = @($errors); Warnings = @(); Stats = @{} }
    }
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    } catch {
        [void]$errors.Add('Cannot load ZIP support on this PC.')
        return @{ Ok = $false; Errors = @($errors); Warnings = @(); Stats = @{} }
    }
    $zip = $null
    $entryCount = 0
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
        if ($zip.Entries.Count -eq 0) {
            [void]$errors.Add('ZIP archive is empty.')
            return @{ Ok = $false; Errors = @($errors); Warnings = @(); Stats = @{} }
        }
        if ($zip.Entries.Count -gt $script:GcmZipMaxEntries) {
            [void]$errors.Add("ZIP has too many entries ($($zip.Entries.Count)) — possible zip bomb.")
        }
        $entryCount = $zip.Entries.Count
        $totalLen = [int64]0
        $hasFilesDir = $false
        $hasSysDir = $false
        $hasJunkMeta = $false
        foreach ($entry in $zip.Entries) {
            if (-not (Test-GcmZipEntryPathSafe -EntryName $entry.FullName)) {
                [void]$errors.Add("Unsafe ZIP path: $($entry.FullName)")
                continue
            }
            $norm = $entry.FullName.Replace('\', '/').TrimEnd('/')
            if ($norm -match '(^|/)(files|sys)(/|$)') {
                if ($norm -match '(^|/)files(/|$)') { $hasFilesDir = $true }
                if ($norm -match '(^|/)sys(/|$)') { $hasSysDir = $true }
            }
            if ($norm -match '(^|/)(__MACOSX|desktop\.ini)(/|$)') { $hasJunkMeta = $true }
            if ($entry.Name) {
                $ext = [System.IO.Path]::GetExtension($entry.Name).ToLowerInvariant()
                if ($ext -in $script:GcmBlockedModExtensions) {
                    [void]$errors.Add("Blocked file type in ZIP: $norm")
                }
            }
            if ($entry.Length -gt $script:GcmZipMaxSingleFileBytes) {
                [void]$errors.Add("File too large in ZIP: $norm")
            }
            $totalLen += [int64]$entry.Length
        }
        if ($totalLen -gt $script:GcmZipMaxUncompressedBytes) {
            [void]$errors.Add('ZIP uncompressed size is too large — refused for safety.')
        }
        if (-not $hasFilesDir) {
            [void]$errors.Add("ZIP has no 'files/' folder — not a valid GameCube mod layout.")
        }
        if (-not $hasSysDir) {
            [void]$warnings.Add("ZIP has no 'sys/' folder (files/ only mods are OK if you know the ISO layout).")
        }
        if ($hasJunkMeta) {
            [void]$warnings.Add('ZIP contains Mac/Windows metadata — check you selected the correct archive.')
        }
    }
    catch {
        [void]$errors.Add("Cannot read ZIP: $($_.Exception.Message)")
    }
    finally {
        if ($zip) { $zip.Dispose() }
    }
    $ok = ($errors.Count -eq 0)
    return @{
        Ok       = $ok
        Errors   = @($errors.ToArray())
        Warnings = @($warnings.ToArray())
        Stats    = @{ EntryCount = $entryCount }
    }
}

function Invoke-ScanGcmModZip {
    param(
        [string]$ZipPath,
        [string]$GcmPath = '',
        [string]$PythonExeHint = '',
        [scriptblock]$LogFn
    )
    $zipCheck = Test-GcmModZipArchive -ZipPath $ZipPath
    $errors = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]
    foreach ($e in $zipCheck.Errors) { [void]$errors.Add($e) }
    foreach ($w in $zipCheck.Warnings) { [void]$warnings.Add($w) }

    $stats = @{
        ModRoot       = $null
        FilesCount    = 0
        ReplaceCount  = 0
        AddCount      = 0
        SysFiles      = @()
    }

    if ($errors.Count -gt 0) {
        return @{ Ok = $false; Errors = @($errors); Warnings = @($warnings); Stats = $stats }
    }

    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("ModMerger-scan-" + [guid]::NewGuid().ToString('N'))
    $extractDir = Join-Path $tempRoot 'mod'
    New-Item -ItemType Directory -Path $extractDir -Force | Out-Null
    try {
        if ($LogFn) { & $LogFn "Scanning ZIP: $(Split-Path $ZipPath -Leaf)" 'dim' }
        Expand-Archive -LiteralPath $ZipPath -DestinationPath $extractDir -Force
        $modRoot = Resolve-GcmModExtractRoot -ExtractedPath $extractDir
        $stats.ModRoot = $modRoot
        if ($LogFn) { & $LogFn "Mod root: $modRoot" 'dim' }

        $filesDir = Join-Path $modRoot 'files'
        $sysDir = Join-Path $modRoot 'sys'
        $gameFiles = @(Get-ChildItem -LiteralPath $filesDir -File -Recurse -ErrorAction SilentlyContinue)
        $stats.FilesCount = $gameFiles.Count
        if ($gameFiles.Count -eq 0) {
            [void]$errors.Add('No files under files/ — this ZIP is not a usable mod for ISO import.')
        }
        foreach ($f in $gameFiles) {
            $ext = $f.Extension.ToLowerInvariant()
            if ($ext -in $script:GcmBlockedModExtensions) {
                [void]$errors.Add("Blocked file type: $($f.FullName.Substring($modRoot.Length).TrimStart('\','/'))")
            }
        }

        if (Test-Path -LiteralPath $sysDir) {
            foreach ($sf in @(Get-ChildItem -LiteralPath $sysDir -File -ErrorAction SilentlyContinue)) {
                $stats.SysFiles += $sf.Name
                if ($sf.Name -notin $script:GcmAllowedSysFiles) {
                    [void]$errors.Add(
                        "Invalid sys/$($sf.Name) — only allowed: $($script:GcmAllowedSysFiles -join ', ')")
                }
                elseif ($sf.Name -in $script:GcmRiskySysFiles) {
                    [void]$warnings.Add(
                        "Mod includes sys/$($sf.Name) — incorrect file can prevent the game from booting.")
                }
            }
        }

        $rootExtra = @(Get-ChildItem -LiteralPath $modRoot -Force | Where-Object {
                $_.Name -notin @('files', 'sys')
            })
        if ($rootExtra.Count -gt 0) {
            [void]$errors.Add(
                ('Unexpected items at mod root: ' + (($rootExtra | ForEach-Object { $_.Name }) -join ', ')))
        }

        if (-not [string]::IsNullOrWhiteSpace($GcmPath) -and (Test-Path -LiteralPath $GcmPath -PathType Leaf) -and ($errors.Count -eq 0)) {
            $py = Find-PythonForGcmInstall -PreferredExe $PythonExeHint
            if ($py) {
                if ($LogFn) { & $LogFn 'Cross-checking paths against your ISO (gclib)...' 'dim' }
                $gclibArgs = @()
                foreach ($gp in @(Get-GclibSearchPaths)) { $gclibArgs += @('--gclib-path', $gp) }
                $valArgs = [System.Collections.Generic.List[string]]::new()
                foreach ($a in $py.ArgsPrefix) { [void]$valArgs.Add($a) }
                [void]$valArgs.Add($script:GcmInstallPy)
                [void]$valArgs.Add('--validate-only')
                [void]$valArgs.Add('--gcm')
                [void]$valArgs.Add($GcmPath)
                [void]$valArgs.Add('--source')
                [void]$valArgs.Add($modRoot)
                foreach ($a in $gclibArgs) { [void]$valArgs.Add($a) }
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName = $py.Exe
                $argParts = foreach ($a in $valArgs) {
                    if ($a -match '[\s"]') { '"' + ($a.Replace('"', '\"')) + '"' } else { $a }
                }
                $psi.Arguments = $argParts -join ' '
                $psi.UseShellExecute = $false
                $psi.CreateNoWindow = $true
                $psi.RedirectStandardOutput = $true
                $psi.RedirectStandardError = $true
                $proc = [System.Diagnostics.Process]::Start($psi)
                $stdout = $proc.StandardOutput.ReadToEnd()
                $stderr = $proc.StandardError.ReadToEnd()
                $proc.WaitForExit()
                foreach ($line in @($stdout -split "`r?`n")) {
                    if ([string]::IsNullOrWhiteSpace($line)) { continue }
                    if ($line -like 'WARN=*') {
                        [void]$warnings.Add($line.Substring(5))
                        if ($LogFn) { & $LogFn $line.Substring(5) 'warn' }
                    }
                    elseif ($line -like 'ERR=*') {
                        [void]$errors.Add($line.Substring(4))
                        if ($LogFn) { & $LogFn $line.Substring(4) 'err' }
                    }
                    elseif ($line -like 'STAT_FILES=*') {
                        $stats.FilesCount = [int]$line.Split('=', 2)[1]
                    }
                    elseif ($line -like 'STAT_REPLACE=*') {
                        $stats.ReplaceCount = [int]$line.Split('=', 2)[1]
                    }
                    elseif ($line -like 'STAT_ADD=*') {
                        $stats.AddCount = [int]$line.Split('=', 2)[1]
                    }
                    elseif ($LogFn) { & $LogFn $line 'dim' }
                }
                if ($proc.ExitCode -ne 0 -and $stderr) {
                    if ($LogFn) { & $LogFn $stderr.Trim() 'warn' }
                    if ($errors.Count -eq 0) {
                        [void]$warnings.Add('ISO cross-check failed (is gclib installed?). Structure scan still passed.')
                    }
                }
            }
            elseif ($LogFn) {
                & $LogFn 'Skipping ISO cross-check — Python/gclib not available (structure scan only).' 'warn'
            }
        }
    }
    catch {
        [void]$errors.Add($_.Exception.Message)
    }
    finally {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    $ok = ($errors.Count -eq 0)
    if ($ok -and $LogFn) {
        $msg = "Scan OK: $($stats.FilesCount) file(s) under files/"
        if ($stats.ReplaceCount -gt 0 -or $stats.AddCount -gt 0) {
            $msg += ", $($stats.ReplaceCount) replace / $($stats.AddCount) add on ISO"
        }
        & $LogFn $msg 'ok'
    }
    return @{
        Ok       = $ok
        Errors   = @($errors.ToArray())
        Warnings = @($warnings.ToArray())
        Stats    = $stats
    }
}

function Find-PythonForGcmInstall {
    param([string]$PreferredExe = '')
    $candidates = New-Object System.Collections.Generic.List[object]
    if (-not [string]::IsNullOrWhiteSpace($PreferredExe) -and $PreferredExe -notmatch '^Leave empty') {
        [void]$candidates.Add(@{ Exe = $PreferredExe.Trim(); Prefix = @() })
    }
    [void]$candidates.Add(@{ Exe = 'py'; Prefix = @('-3.12') })
    [void]$candidates.Add(@{ Exe = 'py'; Prefix = @('-3') })
    [void]$candidates.Add(@{ Exe = 'python'; Prefix = @() })
    [void]$candidates.Add(@{ Exe = 'python3'; Prefix = @() })
    foreach ($c in $candidates) {
        try {
            $checkArgs = $c.Prefix + @('-c', 'import sys; sys.exit(0 if sys.version_info[:2] >= (3, 10) else 1)')
            & $c.Exe @checkArgs 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                return @{ Exe = $c.Exe; ArgsPrefix = @($c.Prefix) }
            }
        } catch { }
    }
    return $null
}

function Invoke-InstallZipToGcm {
    param(
        [string]$GcmPath,
        [string]$ZipPath,
        [bool]$InPlace,
        [string]$PythonExeHint,
        [scriptblock]$LogFn
    )
    if (-not (Test-Path -LiteralPath $script:GcmInstallPy -PathType Leaf)) {
        throw "Missing helper: $script:GcmInstallPy"
    }
    if (-not (Test-Path -LiteralPath $GcmPath -PathType Leaf)) {
        throw "Choose a valid GameCube ISO (.iso / .gcm)."
    }
    if (-not (Test-Path -LiteralPath $ZipPath -PathType Leaf)) {
        throw "Choose a valid mod .zip archive."
    }
    $ext = [System.IO.Path]::GetExtension($GcmPath).ToLowerInvariant()
    if ($ext -notin @('.iso', '.gcm')) {
        throw 'ISO path should end with .iso or .gcm'
    }

    $py = Find-PythonForGcmInstall -PreferredExe $PythonExeHint
    if (-not $py) {
        throw @"
Python 3.12+ is required for GCM install (uses gclib, same engine as GCFT).
Install Python from https://www.python.org/downloads/ or place a GCFT clone in:
  $(Join-Path $scriptDir 'GCFT')
Then run: py -3.12 -m pip install "gclib @ git+https://github.com/LagoLunatic/gclib.git"
"@
    }

    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("ModMerger-gcm-" + [guid]::NewGuid().ToString('N'))
    $extractDir = Join-Path $tempRoot 'mod'
    New-Item -ItemType Directory -Path $extractDir -Force | Out-Null
    try {
        if ($LogFn) { & $LogFn "Extracting ZIP: $(Split-Path $ZipPath -Leaf)" 'dim' }
        Expand-Archive -LiteralPath $ZipPath -DestinationPath $extractDir -Force
        $modRoot = Resolve-GcmModExtractRoot -ExtractedPath $extractDir
        if ($LogFn) { & $LogFn "Mod root: $modRoot" 'dim' }

        $gclibArgs = @()
        foreach ($gp in @(Get-GclibSearchPaths)) {
            $gclibArgs += @('--gclib-path', $gp)
        }

        $outputIso = $null
        $installArgs = [System.Collections.Generic.List[string]]::new()
        foreach ($a in $py.ArgsPrefix) { [void]$installArgs.Add($a) }
        [void]$installArgs.Add($script:GcmInstallPy)
        [void]$installArgs.Add('--gcm')
        [void]$installArgs.Add($GcmPath)
        [void]$installArgs.Add('--source')
        [void]$installArgs.Add($modRoot)
        foreach ($a in $gclibArgs) { [void]$installArgs.Add($a) }
        if ($InPlace) {
            [void]$installArgs.Add('--in-place')
            if ($LogFn) { & $LogFn 'Installing into ISO (backup saved as .bak next to the ISO).' 'accent' }
            $outputIso = $GcmPath
        } else {
            $base = [System.IO.Path]::GetFileNameWithoutExtension($GcmPath)
            $dir = [System.IO.Path]::GetDirectoryName($GcmPath)
            $outputIso = Join-Path $dir ($base + '.patched.gcm')
            [void]$installArgs.Add('--output')
            [void]$installArgs.Add($outputIso)
            if ($LogFn) { & $LogFn "Writing patched ISO: $outputIso" 'accent' }
        }

        if ($LogFn) { & $LogFn 'Running gclib import (GCFT-compatible)...' 'dim' }
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $py.Exe
        $argParts = foreach ($a in $installArgs) {
            if ($a -match '[\s"]') { '"' + ($a.Replace('"', '\"')) + '"' } else { $a }
        }
        $psi.Arguments = $argParts -join ' '
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        $stdout = $proc.StandardOutput.ReadToEnd()
        $stderr = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()
        foreach ($line in @($stdout -split "`r?`n")) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            if ($LogFn) { & $LogFn $line 'dim' }
        }
        if ($proc.ExitCode -ne 0) {
            if ($stderr -and $LogFn) { & $LogFn $stderr.Trim() 'err' }
            throw "GCM install failed (exit $($proc.ExitCode)). See log."
        }
        if ($LogFn) { & $LogFn 'ISO updated successfully.' 'ok' }
        return $outputIso
    }
    finally {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Show-TextureGlitchyDialog {
    if ($null -ne $script:IsoInstallDlg) {
        try {
            if (-not $script:IsoInstallDlg.IsDisposed) {
                $script:IsoInstallDlg.Dispose()
            }
        } catch { }
        $script:IsoInstallDlg = $null
    }

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Install mod into ISO (GCFT)'
    $dlg.Size = New-Object System.Drawing.Size(860, 340)
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.BackColor = $ColorBg
    $dlg.ForeColor = $ColorFg
    $dlg.Font = $FontMain
    $dlg.ShowInTaskbar = $false

    $card = New-ThemedPanel -Title 'Install mod ZIP into GameCube ISO  -  GCFT / gclib'
    $card.Location = New-Object System.Drawing.Point(16, 12)
    $card.Size = New-Object System.Drawing.Size(812, 268)
    $card.Anchor = 'Top,Left,Right,Bottom'
    $dlg.Controls.Add($card)

    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = 'Install a mod into your GameCube ISO. Use Scan ZIP safety first — checks layout, blocked file types, and matches paths on your ISO.'
    $hint.Location = New-Object System.Drawing.Point(20, 30)
    $hint.Size = New-Object System.Drawing.Size(770, 36)
    $hint.ForeColor = $ColorFgDim
    $hint.Font = $FontHint
    $card.Controls.Add($hint)
    Set-ThemedChildSurface $hint

    $isoBox = New-Object System.Windows.Forms.TextBox
    $isoBox.Location = New-Object System.Drawing.Point(120, 70)
    $isoBox.Size = New-Object System.Drawing.Size(560, 24)
    $isoBox.Anchor = 'Top,Left,Right'
    $isoBox.BackColor = $ColorBgInput
    $isoBox.ForeColor = $ColorFg
    $isoBox.BorderStyle = 'FixedSingle'
    $card.Controls.Add($isoBox)

    $isoBrowse = New-Object System.Windows.Forms.Button
    $isoBrowse.Text = 'Browse...'
    $isoBrowse.Location = New-Object System.Drawing.Point(690, 67)
    $isoBrowse.Size = New-Object System.Drawing.Size(100, 28)
    $isoBrowse.Anchor = 'Top,Right'
    $isoBrowse.FlatStyle = 'Flat'
    $isoBrowse.BackColor = $ColorBgAlt
    $isoBrowse.ForeColor = $ColorFg
    $isoBrowse.FlatAppearance.BorderColor = $ColorBorderGlow
    $isoBrowse.FlatAppearance.MouseOverBackColor = $ColorBorder
    $card.Controls.Add($isoBrowse)

    $zipBox = New-Object System.Windows.Forms.TextBox
    $zipBox.Location = New-Object System.Drawing.Point(120, 106)
    $zipBox.Size = New-Object System.Drawing.Size(560, 24)
    $zipBox.Anchor = 'Top,Left,Right'
    $zipBox.BackColor = $ColorBgInput
    $zipBox.ForeColor = $ColorFg
    $zipBox.BorderStyle = 'FixedSingle'
    $card.Controls.Add($zipBox)

    $zipBrowse = New-Object System.Windows.Forms.Button
    $zipBrowse.Text = 'Browse...'
    $zipBrowse.Location = New-Object System.Drawing.Point(690, 103)
    $zipBrowse.Size = New-Object System.Drawing.Size(100, 28)
    $zipBrowse.Anchor = 'Top,Right'
    $zipBrowse.FlatStyle = 'Flat'
    $zipBrowse.BackColor = $ColorBgAlt
    $zipBrowse.ForeColor = $ColorFg
    $zipBrowse.FlatAppearance.BorderColor = $ColorBorderGlow
    $zipBrowse.FlatAppearance.MouseOverBackColor = $ColorBorder
    $card.Controls.Add($zipBrowse)

    $inPlaceBox = New-Object System.Windows.Forms.CheckBox
    $inPlaceBox.Text = 'Replace original ISO (creates .bak backup first)'
    $inPlaceBox.Location = New-Object System.Drawing.Point(20, 142)
    $inPlaceBox.Size = New-Object System.Drawing.Size(420, 22)
    $inPlaceBox.ForeColor = $ColorFg
    $inPlaceBox.Font = $FontHint
    $inPlaceBox.Checked = $true
    $inPlaceBox.UseVisualStyleBackColor = $false
    $inPlaceBox.BackColor = [System.Drawing.Color]::Transparent
    $card.Controls.Add($inPlaceBox)
    Set-ThemedChildSurface $inPlaceBox

    $installBtn = New-Object System.Windows.Forms.Button
    $installBtn.Text = 'Install ZIP into ISO'
    $installBtn.Location = New-Object System.Drawing.Point(20, 172)
    $installBtn.Size = New-Object System.Drawing.Size(200, 34)
    $installBtn.FlatStyle = 'Flat'
    $installBtn.BackColor = $ColorAccent
    $installBtn.ForeColor = [System.Drawing.Color]::FromArgb(20, 14, 8)
    $installBtn.Font = $FontBold
    $installBtn.FlatAppearance.BorderColor = $ColorAccentHover
    $installBtn.FlatAppearance.MouseOverBackColor = $ColorAccentHover
    $card.Controls.Add($installBtn)

    $scanZipBtn = New-Object System.Windows.Forms.Button
    $scanZipBtn.Text = 'Scan ZIP safety'
    $scanZipBtn.Location = New-Object System.Drawing.Point(230, 172)
    $scanZipBtn.Size = New-Object System.Drawing.Size(180, 34)
    $scanZipBtn.FlatStyle = 'Flat'
    $scanZipBtn.BackColor = $ColorBgAlt
    $scanZipBtn.ForeColor = $ColorAccent2
    $scanZipBtn.Font = $FontBold
    $scanZipBtn.FlatAppearance.BorderColor = $ColorAccent2
    $scanZipBtn.FlatAppearance.MouseOverBackColor = $ColorBorder
    $card.Controls.Add($scanZipBtn)

    $closeDlgBtn = New-Object System.Windows.Forms.Button
    $closeDlgBtn.Text = 'Close'
    $scanResultLbl = New-Object System.Windows.Forms.Label
    $scanResultLbl.Text = 'Pick ISO + ZIP, then Scan ZIP safety before install.'
    $scanResultLbl.Location = New-Object System.Drawing.Point(20, 214)
    $scanResultLbl.Size = New-Object System.Drawing.Size(770, 60)
    $scanResultLbl.ForeColor = $ColorFgDim
    $scanResultLbl.Font = $FontHint
    $card.Controls.Add($scanResultLbl)
    Set-ThemedChildSurface $scanResultLbl

    $closeDlgBtn.Location = New-Object System.Drawing.Point(690, 172)
    $closeDlgBtn.Size = New-Object System.Drawing.Size(100, 34)
    $closeDlgBtn.Anchor = 'Top,Right'
    $closeDlgBtn.FlatStyle = 'Flat'
    $closeDlgBtn.BackColor = $ColorBgAlt
    $closeDlgBtn.ForeColor = $ColorFg
    $closeDlgBtn.FlatAppearance.BorderColor = $ColorBorder
    $closeDlgBtn.FlatAppearance.MouseOverBackColor = $ColorBorder
    $card.Controls.Add($closeDlgBtn)

    $isoLbl = New-Object System.Windows.Forms.Label
    $isoLbl.Text = 'GameCube ISO'
    $isoLbl.Location = New-Object System.Drawing.Point(20, 72)
    $isoLbl.Size = New-Object System.Drawing.Size(100, 22)
    $isoLbl.ForeColor = $ColorFg
    $isoLbl.Font = $FontBold
    $card.Controls.Add($isoLbl)
    Set-ThemedChildSurface $isoLbl

    $zipLbl = New-Object System.Windows.Forms.Label
    $zipLbl.Text = 'Mod ZIP'
    $zipLbl.Location = New-Object System.Drawing.Point(20, 108)
    $zipLbl.Size = New-Object System.Drawing.Size(100, 22)
    $zipLbl.ForeColor = $ColorFg
    $zipLbl.Font = $FontBold
    $card.Controls.Add($zipLbl)
    Set-ThemedChildSurface $zipLbl

    $isoBrowse.Add_Click({
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Title = 'Select GameCube ISO / GCM'
        $ofd.Filter = 'GameCube images (*.iso;*.gcm)|*.iso;*.gcm|All files (*.*)|*.*'
        if ($isoBox.Text -and (Test-Path -LiteralPath (Split-Path $isoBox.Text -Parent))) {
            $ofd.InitialDirectory = Split-Path -Path $isoBox.Text -Parent
        }
        if ($ofd.ShowDialog($dlg) -eq [System.Windows.Forms.DialogResult]::OK) { $isoBox.Text = $ofd.FileName }
    })

    $zipBrowse.Add_Click({
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Title = 'Select mod ZIP archive'
        $ofd.Filter = 'ZIP archives (*.zip)|*.zip|All files (*.*)|*.*'
        if ($zipBox.Text -and (Test-Path -LiteralPath (Split-Path $zipBox.Text -Parent))) {
            $ofd.InitialDirectory = Split-Path -Path $zipBox.Text -Parent
        }
        if ($ofd.ShowDialog($dlg) -eq [System.Windows.Forms.DialogResult]::OK) { $zipBox.Text = $ofd.FileName }
    })

    $closeDlgBtn.Add_Click({ $dlg.Close() })

    $runIsoZipScan = {
        param([bool]$QuietLog)
        $zip = $zipBox.Text.Trim()
        $iso = $isoBox.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($zip) -or -not (Test-Path -LiteralPath $zip -PathType Leaf)) {
            $scanResultLbl.ForeColor = $ColorWarn
            $scanResultLbl.Text = 'Choose a mod ZIP file first.'
            return $null
        }
        $logFn = $null
        if (-not $QuietLog) {
            $logFn = {
                param($msg, $kind)
                $color = switch ($kind) {
                    'err' { $ColorErr }; 'warn' { $ColorWarn }; 'ok' { $ColorOk }
                    'accent' { $ColorAccent }; 'dim' { $ColorFgDim }; default { $ColorFg }
                }
                Write-Log $msg $color
            }
            if ($script:glassLog) { $script:glassLog.ClearLines() }
            & $logFn '=== Mod ZIP safety scan ===' 'accent'
        }
        $gcmForScan = ''
        if (-not [string]::IsNullOrWhiteSpace($iso) -and (Test-Path -LiteralPath $iso -PathType Leaf)) {
            $gcmForScan = $iso
        }
        $scan = Invoke-ScanGcmModZip -ZipPath $zip -GcmPath $gcmForScan -LogFn $logFn
        if ($scan.Ok) {
            $scanResultLbl.ForeColor = $ColorOk
            $sum = "Scan passed: $($scan.Stats.FilesCount) file(s) under files/."
            if ($scan.Stats.ReplaceCount -gt 0 -or $scan.Stats.AddCount -gt 0) {
                $sum += " Would replace $($scan.Stats.ReplaceCount) and add $($scan.Stats.AddCount) on ISO."
            }
            if ($scan.Warnings.Count -gt 0) {
                $sum += " Warnings: " + ($scan.Warnings.Count)
            }
            $scanResultLbl.Text = $sum
        } else {
            $scanResultLbl.ForeColor = $ColorErr
            $scanResultLbl.Text = 'Scan failed: ' + (($scan.Errors | Select-Object -First 2) -join '; ')
        }
        return $scan
    }

    $scanZipBtn.Add_Click({
        $scanZipBtn.Enabled = $false
        try { [void](& $runIsoZipScan $false) }
        finally { $scanZipBtn.Enabled = $true }
    })

    $installBtn.Add_Click({
        $iso = $isoBox.Text.Trim()
        $zip = $zipBox.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($iso) -or -not (Test-Path -LiteralPath $iso -PathType Leaf)) {
            [void][System.Windows.Forms.MessageBox]::Show($dlg, 'Choose a valid GameCube .iso or .gcm file.', 'Install to ISO',
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
            return
        }
        if ([string]::IsNullOrWhiteSpace($zip) -or -not (Test-Path -LiteralPath $zip -PathType Leaf)) {
            [void][System.Windows.Forms.MessageBox]::Show($dlg, 'Choose a valid mod .zip archive.', 'Install to ISO',
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
            return
        }
        $scan = & $runIsoZipScan $true
        if ($null -eq $scan) { return }
        if (-not $scan.Ok) {
            $detail = ($scan.Errors -join [Environment]::NewLine)
            [void][System.Windows.Forms.MessageBox]::Show(
                $dlg,
                "This mod ZIP failed the safety scan and will not be installed:`n`n$detail",
                'Install blocked',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error)
            return
        }
        if ($scan.Warnings.Count -gt 0) {
            $wtxt = ($scan.Warnings -join [Environment]::NewLine)
            $wConfirm = [System.Windows.Forms.MessageBox]::Show(
                $dlg,
                "Scan passed with warnings:`n`n$wtxt`n`nInstall anyway?",
                'Safety warnings',
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Warning,
                [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
            if ($wConfirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        }
        $inPlace = $inPlaceBox.Checked
        $warn = if ($inPlace) {
            "Replace files inside this ISO?`n`n$iso`n`nA .bak backup is created first if one does not exist yet."
        } else {
            "Write a new patched .gcm next to the ISO?`n`nSource: $iso`nMod ZIP: $(Split-Path $zip -Leaf)"
        }
        $confirm = [System.Windows.Forms.MessageBox]::Show($dlg, $warn, 'Confirm ISO install',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning,
            [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
        if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }

        $installBtn.Enabled = $false
        if ($isoInstallBtn) { $isoInstallBtn.Enabled = $false }
        $scanBtn.Enabled = $false; $runBtn.Enabled = $false; $convertPngBtn.Enabled = $false
        $gbDownloadBtn.Enabled = $false; $testBarBtn.Enabled = $false; $isoInstallBtn.Enabled = $false; $aboutBtn.Enabled = $false
        try {
            if ($script:glassLog) { $script:glassLog.ClearLines() }
            Reset-GlowProgress -Bar $progress -Max 1
            Set-Status 'Installing mod into ISO...' $ColorAccent2
            $logFn = {
                param($msg, $kind)
                $color = switch ($kind) {
                    'err' { $ColorErr }; 'warn' { $ColorWarn }; 'ok' { $ColorOk }
                    'accent' { $ColorAccent }; 'dim' { $ColorFgDim }; default { $ColorFg }
                }
                Write-Log $msg $color
            }
            & $logFn '=== Install mod into ISO (GCFT) ===' 'accent'
            $outPath = Invoke-InstallZipToGcm -GcmPath $iso -ZipPath $zip -InPlace $inPlace -LogFn $logFn
            Set-GlowProgressState -Bar $progress -Value 1
            Set-Status 'ISO install finished.' $ColorOk
            if ($outPath -and (Test-Path -LiteralPath $outPath)) {
                Open-FolderInExplorer -Path (Split-Path -LiteralPath $outPath -Parent) -DelayMs 400 | Out-Null
            }
        }
        catch {
            $em = $_.Exception.Message
            Write-Log "ISO install failed: $em" $ColorErr
            Set-Status 'ISO install failed - see log.' $ColorErr
            [void][System.Windows.Forms.MessageBox]::Show($dlg, $em, 'Install to ISO',
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        }
        finally {
            $installBtn.Enabled = $true
            if ($isoInstallBtn) { $isoInstallBtn.Enabled = $true }
            $scanBtn.Enabled = $true; $runBtn.Enabled = $true; $convertPngBtn.Enabled = $true
            $gbDownloadBtn.Enabled = $true; $testBarBtn.Enabled = $true; $isoInstallBtn.Enabled = $true; $aboutBtn.Enabled = $true
        }
    })

    $script:IsoInstallDlg = $dlg
    $dlg.Owner = $form
    [void]$dlg.ShowDialog($form)
}

function Import-GlassLogView {
    if ('GlassLogView' -as [type]) { return $true }
    $glassCsPath = Join-Path $scriptDir '_GlassLogView.cs'
    if (-not (Test-Path -LiteralPath $glassCsPath)) {
        $script:GlassLogLoadError = "Missing file: $glassCsPath"
        return $false
    }
    $glassCs = Get-Content -LiteralPath $glassCsPath -Raw
        $glassDll = Join-Path $env:TEMP 'TexturepackMerge-GlassLogView-v13.dll'
    $refs = @('System.Windows.Forms', 'System.Drawing')
    try {
        if ((Test-Path -LiteralPath $glassDll) -and
            ((Get-Item -LiteralPath $glassCsPath).LastWriteTimeUtc -le (Get-Item -LiteralPath $glassDll).LastWriteTimeUtc)) {
            [void][System.Reflection.Assembly]::LoadFrom($glassDll)
            if ('GlassLogView' -as [type]) { return $true }
        }
    } catch { }
    try {
        Add-Type -TypeDefinition $glassCs -OutputAssembly $glassDll -ReferencedAssemblies $refs
        [void][System.Reflection.Assembly]::LoadFrom($glassDll)
        if ('GlassLogView' -as [type]) { return $true }
    } catch {
        $script:GlassLogLoadError = $_.Exception.Message
    }
    try {
        Add-Type -TypeDefinition $glassCs -ReferencedAssemblies $refs
        return [bool]('GlassLogView' -as [type])
    } catch {
        if (-not $script:GlassLogLoadError) { $script:GlassLogLoadError = $_.Exception.Message }
        return $false
    }
}

# Custom glass log (wallpaper + tinted glass + colored text - tested in _test-glass-log.ps1).
$script:GlassLogLoadError = $null
$script:GlassLogReady = $false
try {
    $script:GlassLogReady = Import-GlassLogView
} catch {
    $script:GlassLogLoadError = $_.Exception.Message
    $script:GlassLogReady = $false
}

$bgImagePath = Join-Path -Path $scriptDir -ChildPath 'Texturepack-Merge-Background.png'
$bgImage = $null
if (Test-Path -LiteralPath $bgImagePath) {
    try { $bgImage = [System.Drawing.Image]::FromFile($bgImagePath) } catch { $bgImage = $null }
}

$logoImagePath = Join-Path -Path $scriptDir -ChildPath 'Texturepack-Merge-Logo.png'
$logoImage = $null
if (Test-Path -LiteralPath $logoImagePath) {
    try { $logoImage = [System.Drawing.Image]::FromFile($logoImagePath) } catch { $logoImage = $null }
}

# ---------------------------------------------------------------------------
# Merge helpers
# ---------------------------------------------------------------------------

function Get-RelativePathFromFolder {
    param([string]$BaseFolder, [string]$FullPath)
    $baseWithSep = $BaseFolder.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    return $FullPath.Substring($baseWithSep.Length)
}

function ConvertTo-ImportedRelativePath {
    param([string]$RelativePath)
    $fileName = [System.IO.Path]::GetFileName($RelativePath)
    $folderPath = [System.IO.Path]::GetDirectoryName($RelativePath)
    if ([string]::IsNullOrWhiteSpace($folderPath)) { return $fileName }

    $importedSegments = @(
        $folderPath -split '[\\/]' |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { "$_-Imported" }
    )
    $importedFolderPath = [System.IO.Path]::Combine([string[]]$importedSegments)
    return Join-Path -Path $importedFolderPath -ChildPath $fileName
}

function Get-ImportedDestinationPath {
    param([string]$SourceFolder, [string]$TargetFolder, [System.IO.FileInfo]$SourceFile)
    $rel = Get-RelativePathFromFolder -BaseFolder $SourceFolder -FullPath $SourceFile.FullName
    $importedRel = ConvertTo-ImportedRelativePath -RelativePath $rel
    return Join-Path -Path $TargetFolder -ChildPath $importedRel
}

function Get-ReplacementMatchKey {
    param([Parameter(Mandatory)][System.IO.FileInfo]$File)
    $extension = $File.Extension.ToLowerInvariant()
    if ($extension -eq '.dds' -or $extension -eq '.png') {
        return [System.IO.Path]::GetFileNameWithoutExtension($File.Name)
    }
    return $File.Name
}

function Test-DdsOrPngFile {
    param([Parameter(Mandatory)][System.IO.FileInfo]$File)
    $ext = $File.Extension.ToLowerInvariant()
    return ($ext -eq '.dds' -or $ext -eq '.png')
}

function Add-AppendEntriesToPlan {
    param(
        [Parameter(Mandatory)]$PlanList,
        [Parameter(Mandatory)]$SourceEntries,
        [Parameter(Mandatory)][string]$TargetFolder,
        [Parameter(Mandatory)][System.IO.FileInfo[]]$TargetFiles,
        [Parameter(Mandatory)][hashtable]$AlreadyPlannedByName
    )
    $targetNames = @{}
    $targetTexturesByKey = @{}
    foreach ($t in $TargetFiles) {
        $targetNames[$t.Name] = $true
        if (Test-DdsOrPngFile -File $t) {
            $mk = Get-ReplacementMatchKey -File $t
            $targetTexturesByKey[$mk] = $true
        }
    }
    foreach ($e in $SourceEntries) {
        $sf = $e.File
        if ($targetNames.ContainsKey($sf.Name)) { continue }
        if (Test-DdsOrPngFile -File $sf) {
            $mk = Get-ReplacementMatchKey -File $sf
            if ($targetTexturesByKey.ContainsKey($mk)) { continue }
        }
        if ($AlreadyPlannedByName.ContainsKey($sf.Name)) { continue }
        $dest = Get-ImportedDestinationPath -SourceFolder $e.Root -TargetFolder $TargetFolder -SourceFile $sf
        $PlanList.Add([pscustomobject]@{
            Source      = $sf
            Destination = $dest
            Action      = 'Append'
        })
        $AlreadyPlannedByName[$sf.Name] = $true
    }
}

function New-OpacitySlider {
    param(
        [int]$Minimum = 40,
        [int]$Maximum = 100,
        [int]$Value = 97,
        [scriptblock]$OnChange
    )
    $p = New-Object System.Windows.Forms.Panel
    $ss = [System.Windows.Forms.Control].GetMethod('SetStyle',
        [System.Reflection.BindingFlags]'Instance,NonPublic')
    $flags = [System.Windows.Forms.ControlStyles]::OptimizedDoubleBuffer -bor `
             [System.Windows.Forms.ControlStyles]::AllPaintingInWmPaint -bor `
             [System.Windows.Forms.ControlStyles]::UserPaint
    [void]$ss.Invoke($p, @($flags, $true))
    $p.BackColor = $ColorBgTitle
    $p.Cursor = 'Hand'
    $p | Add-Member NoteProperty _min $Minimum
    $p | Add-Member NoteProperty _max $Maximum
    $p | Add-Member NoteProperty _value $Value
    $p | Add-Member NoteProperty _dragging $false
    $p | Add-Member NoteProperty _onChange $OnChange

    $setFromX = {
        param($bar, $x)
        $pad = 8
        $trackW = [Math]::Max(20, $bar.Width - ($pad * 2))
        $ratio = ($x - $pad) / $trackW
        if ($ratio -lt 0) { $ratio = 0 } elseif ($ratio -gt 1) { $ratio = 1 }
        $bar._value = [int]($bar._min + $ratio * ($bar._max - $bar._min))
        $bar.Invalidate()
        if ($bar._onChange) {
            try { & $bar._onChange $bar._value } catch { }
        }
    }
    $p | Add-Member NoteProperty _setFromX $setFromX

    $p.Add_Paint({
        param($s, $e)
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $w = $s.ClientSize.Width
        $h = $s.ClientSize.Height
        $padX = 8
        $trackY = [int]($h / 2)
        $trackH = 6
        $trackW = [Math]::Max(20, $w - ($padX * 2))

        $range = $s._max - $s._min
        $pct = if ($range -gt 0) { ([double]($s._value - $s._min)) / $range } else { 0 }
        if ($pct -lt 0) { $pct = 0 } elseif ($pct -gt 1) { $pct = 1 }

        $trackRect = New-Object System.Drawing.Rectangle $padX, ($trackY - 3), $trackW, $trackH
        $trackBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(200, 28, 20, 14))
        $g.FillRectangle($trackBrush, $trackRect)
        $trackBrush.Dispose()
        $trackPen = New-Object System.Drawing.Pen $ColorBorder, 1
        $g.DrawRectangle($trackPen, $trackRect)
        $trackPen.Dispose()

        $fillW = [Math]::Max(0, [int]($trackW * $pct))
        if ($fillW -gt 0) {
            $fillRect = New-Object System.Drawing.Rectangle $padX, ($trackY - 3), $fillW, $trackH
            $fillBrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
                $fillRect,
                [System.Drawing.Color]::FromArgb(255, 200, 120, 50),
                [System.Drawing.Color]::FromArgb(255, 255, 180, 80),
                0.0)
            $g.FillRectangle($fillBrush, $fillRect)
            $fillBrush.Dispose()
        }

        $thumbX = $padX + [int]($trackW * $pct)
        $thumbBrush = New-Object System.Drawing.SolidBrush $ColorAccent
        $g.FillEllipse($thumbBrush, ($thumbX - 7), ($trackY - 7), 14, 14)
        $thumbBrush.Dispose()
        $thumbRing = New-Object System.Drawing.Pen $ColorAccentHover, 2
        $g.DrawEllipse($thumbRing, ($thumbX - 7), ($trackY - 7), 14, 14)
        $thumbRing.Dispose()
    })

    # Opacity slider: direct handlers (no Wrap-SafeUiEvent) so onChange always runs.
    $p.Add_MouseDown({
        param($s, $e)
        try {
            if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
                $s._dragging = $true
                & $s._setFromX $s $e.X
            }
        } catch { }
    })
    $p.Add_MouseMove({
        param($s, $e)
        try {
            if ($s._dragging) { & $s._setFromX $s $e.X }
        } catch { }
    })
    $p.Add_MouseUp({ param($s, $e) try { $s._dragging = $false } catch { } })
    $p.Add_MouseLeave({ param($s, $e) try { $s._dragging = $false } catch { } })

    return $p
}

function New-ThemedVScrollBar {
    param(
        [int]$Maximum = 0,
        [int]$Value = 0,
        [scriptblock]$OnChange
    )
    $p = New-Object System.Windows.Forms.Panel
    $ss = [System.Windows.Forms.Control].GetMethod('SetStyle',
        [System.Reflection.BindingFlags]'Instance,NonPublic')
    $flags = [System.Windows.Forms.ControlStyles]::OptimizedDoubleBuffer -bor `
             [System.Windows.Forms.ControlStyles]::AllPaintingInWmPaint -bor `
             [System.Windows.Forms.ControlStyles]::UserPaint
    [void]$ss.Invoke($p, @($flags, $true))
    $p.BackColor = [System.Drawing.Color]::FromArgb(120, 14, 10, 6)
    $p.Cursor = 'Hand'
    $p | Add-Member NoteProperty _min 0
    $p | Add-Member NoteProperty _max $Maximum
    $p | Add-Member NoteProperty _value $Value
    $p | Add-Member NoteProperty _dragging $false
    $p | Add-Member NoteProperty _onChange $OnChange

    $setFromY = {
        param($bar, $y)
        $pad = 8
        $thumbR = 7
        $trackH = [Math]::Max(24, $bar.Height - ($pad * 2) - ($thumbR * 2))
        $ratio = ($y - ($pad + $thumbR)) / $trackH
        if ($ratio -lt 0) { $ratio = 0 } elseif ($ratio -gt 1) { $ratio = 1 }
        $range = $bar._max - $bar._min
        $bar._value = [int]($bar._min + $ratio * $range)
        $bar.Invalidate()
        if ($bar._onChange) { & $bar._onChange $bar._value }
    }
    $p | Add-Member NoteProperty _setFromY $setFromY

    $p.Add_Paint({
        param($s, $e)
        $g = $e.Graphics
        $g.SetClip($s.ClientRectangle)
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $w = $s.ClientSize.Width
        $h = $s.ClientSize.Height
        $padY = 8
        $trackX = [int](($w - 8) / 2)
        $trackW = 8
        $thumbR = 7
        $trackH = [Math]::Max(24, $h - ($padY * 2) - ($thumbR * 2))

        $range = $s._max - $s._min
        $pct = if ($range -gt 0) { ([double]($s._value - $s._min)) / $range } else { 0 }
        if ($pct -lt 0) { $pct = 0 } elseif ($pct -gt 1) { $pct = 1 }

        $trackRect = New-Object System.Drawing.Rectangle ($trackX - 4), $padY, $trackW, ($trackH + ($thumbR * 2))
        $trackBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(210, 28, 20, 14))
        $g.FillRectangle($trackBrush, $trackRect)
        $trackBrush.Dispose()
        $trackPen = New-Object System.Drawing.Pen $ColorBorder, 1
        $g.DrawRectangle($trackPen, $trackRect)
        $trackPen.Dispose()

        $thumbY = $padY + $thumbR + [int]($trackH * $pct)
        $thumbBrush = New-Object System.Drawing.SolidBrush $ColorAccent
        $g.FillEllipse($thumbBrush, ($trackX - $thumbR), ($thumbY - $thumbR), ($thumbR * 2), ($thumbR * 2))
        $thumbBrush.Dispose()
        $thumbRing = New-Object System.Drawing.Pen $ColorAccentHover, 2
        $g.DrawEllipse($thumbRing, ($trackX - $thumbR), ($thumbY - $thumbR), ($thumbR * 2), ($thumbR * 2))
        $thumbRing.Dispose()
    })

    $p.Add_MouseDown({
        param($s, $e)
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left -and $s._max -gt $s._min) {
            $s._dragging = $true
            $s.Capture = $true
            & $s._setFromY $s $e.Y
        }
    })
    $p.Add_MouseMove({
        param($s, $e)
        if ($s._dragging) { & $s._setFromY $s $e.Y }
    })
    $p.Add_MouseUp({
        param($s, $e)
        $s._dragging = $false
        $s.Capture = $false
    })
    $p.Add_MouseLeave({
        param($s, $e)
        if (-not $s.Capture) { $s._dragging = $false }
    })

    return $p
}

# ---------------------------------------------------------------------------
# Form
# ---------------------------------------------------------------------------

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Mod Merger Download and Converter Tool'
$form.Size = New-Object System.Drawing.Size(1060, 1040)
$form.MinimumSize = New-Object System.Drawing.Size(960, 1000)
$form.StartPosition = 'CenterScreen'
$form.BackColor = $ColorBg
$form.ForeColor = $ColorFg
$form.Font = $FontMain
$form.FormBorderStyle = 'None'
$form.Opacity = 0.97
$form.KeyPreview = $true
if ($bgImage) {
    $form.BackgroundImage = $bgImage
    $form.BackgroundImageLayout = 'Stretch'
}
# DoubleBuffered is protected; flip via SetStyle reflection so we still get flicker-free repaint
$dblFlags = [System.Windows.Forms.ControlStyles]::OptimizedDoubleBuffer -bor `
            [System.Windows.Forms.ControlStyles]::AllPaintingInWmPaint -bor `
            [System.Windows.Forms.ControlStyles]::UserPaint
$setStyle = [System.Windows.Forms.Control].GetMethod('SetStyle',
    [System.Reflection.BindingFlags]'Instance,NonPublic')
$setStyle.Invoke($form, @($dblFlags, $true))

# Whole-form paint: title strip + title text + amber border (no full-form dim - background should be visible)
$form.Add_Paint({
    param($s, $e)
    $g = $e.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias

    $w = $form.ClientSize.Width
    $h = $form.ClientSize.Height

    # Light tinted strip across the top for the title bar - background still shows through
    $tbrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(150, 8, 6, 4))
    $g.FillRectangle($tbrush, 0, 0, $w, $TitleBarHeight)
    $tbrush.Dispose()

    # Thin amber line under the title strip
    $linePen = New-Object System.Drawing.Pen $ColorAccent, 1
    $g.DrawLine($linePen, 0, $TitleBarHeight, $w, $TitleBarHeight)
    $linePen.Dispose()

    # Title logo banner (Texturepack-Merge-Logo.png - MOD MERGER by Martinnes)
    if ($logoImage) {
        $maxH = $TitleBarHeight - 6
        $maxW = [Math]::Max(220, $w - $script:LogoRightReserve)
        $scale = [Math]::Min(($maxH / $logoImage.Height), ($maxW / $logoImage.Width))
        $lw = [int]($logoImage.Width * $scale)
        $lh = [int]($logoImage.Height * $scale)
        $lx = 12
        $ly = [int](($TitleBarHeight - $lh) / 2)
        $oldMode = $g.InterpolationMode
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.DrawImage($logoImage, $lx, $ly, $lw, $lh)
        $g.InterpolationMode = $oldMode
    } else {
        $tflags = [System.Windows.Forms.TextFormatFlags]::NoPrefix -bor `
                  [System.Windows.Forms.TextFormatFlags]::NoPadding
        $titlePoint = New-Object System.Drawing.Point 12, 10
        [System.Windows.Forms.TextRenderer]::DrawText(
            $g, 'MOD MERGER DOWNLOAD AND CONVERTER TOOL BY MARTINNES', $FontChip, $titlePoint, $ColorAccent, $tflags) | Out-Null
    }

    # Outer 1 px amber border for the borderless window
    $borderPen = New-Object System.Drawing.Pen $ColorBorder, 1
    $borderRect = New-Object System.Drawing.Rectangle 0, 0, ($w - 1), ($h - 1)
    $g.DrawRectangle($borderPen, $borderRect)
    $borderPen.Dispose()
})
$form.Add_Resize({ $form.Invalidate() })

# ---------- Title-bar controls (placed directly on the form) ----------

$closeBtn = New-Object System.Windows.Forms.Button
$closeBtn.Text = [string][char]0x2715
$closeBtn.Font = $FontIcon
$closeBtn.ForeColor = $ColorFg
$closeBtn.BackColor = $ColorBgTitle
$closeBtn.FlatStyle = 'Flat'
$closeBtn.FlatAppearance.BorderSize = 0
$closeBtn.FlatAppearance.MouseOverBackColor = $ColorCloseHover
$closeBtn.TextAlign = 'MiddleCenter'
$closeBtn.Size = New-Object System.Drawing.Size(46, $TitleBarHeight)
$closeBtn.Cursor = 'Hand'
$closeBtn.TabStop = $false
$form.Controls.Add($closeBtn)
$closeBtn.Add_Click({
    try { $form.Close() } catch { try { $form.Dispose() } catch { } }
})

$minBtn = New-Object System.Windows.Forms.Label
$minBtn.Text = [string][char]0x2013
$minBtn.Font = $FontIcon
$minBtn.ForeColor = $ColorFg
$minBtn.BackColor = $ColorBgTitle
$minBtn.TextAlign = 'MiddleCenter'
$minBtn.Size = New-Object System.Drawing.Size(46, $TitleBarHeight)
$minBtn.Cursor = 'Hand'
$form.Controls.Add($minBtn)
$minBtn.Add_MouseEnter((Wrap-SafeUiEvent { $minBtn.BackColor = $ColorBgAlt }))
$minBtn.Add_MouseLeave((Wrap-SafeUiEvent { $minBtn.BackColor = $ColorBgTitle }))
$minBtn.Add_Click({ $form.WindowState = 'Minimized' })

# Opacity strip - custom slider (no default blue Win32 trackbar)
$script:OpacityStripWidth = 218
$opacityStrip = New-Object System.Windows.Forms.Panel
$opacityStrip.Size = New-Object System.Drawing.Size($script:OpacityStripWidth, $TitleBarHeight)
$opacityStrip.BackColor = $ColorBgTitle
$form.Controls.Add($opacityStrip)

$opacityLabel = New-Object System.Windows.Forms.Label
$opacityLabel.Text = 'Opacity'
$opacityLabel.Font = $FontMain
$opacityLabel.ForeColor = $ColorFg
$opacityLabel.BackColor = $ColorBgTitle
$opacityLabel.AutoSize = $false
$opacityLabel.TextAlign = 'MiddleCenter'
$opacityLabel.Size = New-Object System.Drawing.Size(54, $TitleBarHeight)
$opacityLabel.Location = New-Object System.Drawing.Point(0, 0)
$opacityStrip.Controls.Add($opacityLabel)

$opacityValueLabel = New-Object System.Windows.Forms.Label
$opacityValueLabel.Text = '97%'
$opacityValueLabel.Font = $FontBold
$opacityValueLabel.ForeColor = $ColorFg
$opacityValueLabel.BackColor = $ColorBgTitle
$opacityValueLabel.AutoSize = $false
$opacityValueLabel.TextAlign = 'MiddleLeft'
$opacityValueLabel.Size = New-Object System.Drawing.Size(52, $TitleBarHeight)
$opacityValueLabel.Location = New-Object System.Drawing.Point(166, 0)
$opacityStrip.Controls.Add($opacityValueLabel)

function Set-FormOpacityPercent {
    param([int]$Percent)
    if ($Percent -lt 40) { $Percent = 40 }
    elseif ($Percent -gt 100) { $Percent = 100 }
    $form.Opacity = $Percent / 100.0
    $opacityValueLabel.Text = "$Percent%"
}

$opacitySlider = New-OpacitySlider -Minimum 40 -Maximum 100 -Value 97 -OnChange {
    param($val)
    Set-FormOpacityPercent -Percent $val
}
$opacitySlider.Size = New-Object System.Drawing.Size(112, $TitleBarHeight)
$opacitySlider.Location = New-Object System.Drawing.Point(54, 0)
$opacityStrip.Controls.Add($opacitySlider)
$opacitySlider.BringToFront()
$opacityStrip.BringToFront()

function Set-TitleBarControlsOnTop {
    if (-not $form -or -not $closeBtn) { return }
    try {
        $top = $form.Controls.Count - 1
        if ($opacityStrip) { $form.Controls.SetChildIndex($opacityStrip, $top); $top-- }
        if ($minBtn) { $form.Controls.SetChildIndex($minBtn, $top); $top-- }
        if ($closeBtn) { $form.Controls.SetChildIndex($closeBtn, $top) }
    } catch {
        if ($closeBtn) { $closeBtn.BringToFront() }
        if ($minBtn) { $minBtn.BringToFront() }
        if ($opacityStrip) { $opacityStrip.BringToFront() }
    }
}

function Update-RightControls {
    $rightEdge = $form.ClientSize.Width
    $closeBtn.Location   = New-Object System.Drawing.Point(($rightEdge - 46), 0)
    $minBtn.Location     = New-Object System.Drawing.Point(($rightEdge - 92), 0)
    $opacityStrip.Location = New-Object System.Drawing.Point(($rightEdge - 92 - $script:OpacityStripWidth), 0)
    Set-TitleBarControlsOnTop
}
Update-RightControls

# ---------- Window dragging on the title strip (native C# - avoids PipelineStoppedException) ----------
if ($script:BorderlessFormDragReady) {
    $null = [BorderlessFormDrag]::new($form, $TitleBarHeight, ($script:OpacityStripWidth + 8))
}

$form.Add_DoubleClick((Wrap-SafeUiEvent {
    param($s, $e)
    if ($e -and ($e | Get-Member -Name Y) -and $e.Y -lt $TitleBarHeight) {
        if ($form.WindowState -eq 'Maximized') { $form.WindowState = 'Normal' }
        else { $form.WindowState = 'Maximized' }
    }
}))

$form.Add_KeyDown((Wrap-SafeUiEvent {
    param($s, $e)
    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $form.Close() }
}))

# ---------------------------------------------------------------------------
# Helper: glowing pill-shaped progress bar with sparkles + percentage text
# ---------------------------------------------------------------------------

function New-PillPath {
    param([int]$X, [int]$Y, [int]$Width, [int]$Height)
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $diam = $Height
    if ($Width -le $diam) {
        # Degenerate small case - just an ellipse
        $path.AddEllipse($X, $Y, [Math]::Max(1, $Width), [Math]::Max(1, $Height))
    } else {
        $path.AddArc($X, $Y, $diam, $diam, 90, 180)
        $path.AddArc(($X + $Width - $diam), $Y, $diam, $diam, 270, 180)
        $path.CloseFigure()
    }
    return $path
}

function New-GlowProgress {
    $p = New-Object System.Windows.Forms.Panel
    $ss = [System.Windows.Forms.Control].GetMethod('SetStyle',
        [System.Reflection.BindingFlags]'Instance,NonPublic')
    $flags = [System.Windows.Forms.ControlStyles]::SupportsTransparentBackColor -bor `
             [System.Windows.Forms.ControlStyles]::OptimizedDoubleBuffer -bor `
             [System.Windows.Forms.ControlStyles]::AllPaintingInWmPaint -bor `
             [System.Windows.Forms.ControlStyles]::UserPaint
    [void]$ss.Invoke($p, @($flags, $true))
    $p.BackColor = [System.Drawing.Color]::Transparent

    # State
    $p | Add-Member -MemberType NoteProperty -Name _min -Value 0
    $p | Add-Member -MemberType NoteProperty -Name _max -Value 100
    $p | Add-Member -MemberType NoteProperty -Name _value -Value 0

    # Deterministic random sparkle positions (so they look natural but consistent)
    $sparkles = New-Object 'System.Collections.ArrayList'
    $rng = New-Object System.Random 1337
    for ($i = 0; $i -lt 22; $i++) {
        [void]$sparkles.Add([pscustomobject]@{
            X = $rng.NextDouble()                          # 0..1 across bar width
            Y = 0.18 + ($rng.NextDouble() * 0.64)          # 0.18..0.82 vertically inside fill
            S = 1 + $rng.Next(3)                           # 1..3 px size
        })
    }
    $p | Add-Member -MemberType NoteProperty -Name _sparkles -Value $sparkles

    # ScriptProperty wrappers so existing $progress.Value = ... calls work and auto-invalidate
    $p | Add-Member -MemberType ScriptProperty -Name Value `
        -Value { $this._value } `
        -SecondValue { param($v) $this._value = [int]$v; $this.Invalidate() }
    $p | Add-Member -MemberType ScriptProperty -Name Minimum `
        -Value { $this._min } `
        -SecondValue { param($v) $this._min = [int]$v; $this.Invalidate() }
    $p | Add-Member -MemberType ScriptProperty -Name Maximum `
        -Value { $this._max } `
        -SecondValue { param($v) $this._max = [int]$v; $this.Invalidate() }

    $p.Add_Paint({
        param($s, $e)
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias

        $w = $s.ClientSize.Width
        $h = $s.ClientSize.Height

        # Vertical glow padding around the actual bar
        $padY = 4
        $barH = $h - ($padY * 2)
        if ($barH -lt 8) { $barH = 8 }
        $barY = $padY
        $barW = $w

        # Outer purple glow (4 passes, fading outwards)
        for ($i = 4; $i -ge 1; $i--) {
            $alpha = [int](70 / $i)
            $glowPath = New-PillPath -X (-$i) -Y ($barY - $i) -Width ($barW + ($i * 2)) -Height ($barH + ($i * 2))
            $glowBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb($alpha, 150, 90, 255))
            $g.FillPath($glowBrush, $glowPath)
            $glowBrush.Dispose()
            $glowPath.Dispose()
        }

        # Dark pill background
        $bgPath = New-PillPath -X 0 -Y $barY -Width $barW -Height $barH
        $bgBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(240, 14, 8, 20))
        $g.FillPath($bgBrush, $bgPath)
        $bgBrush.Dispose()

        # Progress fraction
        $range = $s._max - $s._min
        $pct = 0.0
        if ($range -gt 0) { $pct = ([double]($s._value - $s._min)) / $range }
        if ($pct -lt 0) { $pct = 0.0 } elseif ($pct -gt 1) { $pct = 1.0 }
        $fillW = [int]($barW * $pct)

        if ($fillW -gt 2) {
            # Clip everything fill-related to the rounded pill shape
            $g.SetClip($bgPath)

            # Horizontal glowing gradient fill (purple -> blue -> bright pink)
            $fillRect = New-Object System.Drawing.Rectangle 0, $barY, $barW, $barH
            $gradBrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
                $fillRect,
                [System.Drawing.Color]::FromArgb(255, 140, 80, 255),
                [System.Drawing.Color]::FromArgb(255, 220, 130, 255),
                0.0)
            $cb = New-Object System.Drawing.Drawing2D.ColorBlend
            $cb.Colors = @(
                [System.Drawing.Color]::FromArgb(255, 140, 80, 255),
                [System.Drawing.Color]::FromArgb(255, 80, 160, 255),
                [System.Drawing.Color]::FromArgb(255, 220, 130, 255)
            )
            $cb.Positions = @(0.0, 0.5, 1.0)
            $gradBrush.InterpolationColors = $cb

            $clipFill = New-Object System.Drawing.Rectangle 0, $barY, $fillW, $barH
            $g.FillRectangle($gradBrush, $clipFill)
            $gradBrush.Dispose()

            # Top "shine" - lighter horizontal highlight on the upper third.
            # NOTE: the [int](...) cast MUST be assigned to a variable first because
            # in argument mode (positional args to New-Object) PowerShell parses
            # `[int](expr)` as two separate tokens rather than a cast, which causes
            # an "A positional parameter cannot be found that accepts argument" error.
            $shineH = [int]($barH * 0.45)
            $shineRect = New-Object System.Drawing.Rectangle 0, ($barY + 1), $fillW, $shineH
            if ($shineRect.Width -gt 0 -and $shineRect.Height -gt 0) {
                $shineBrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
                    $shineRect,
                    [System.Drawing.Color]::FromArgb(120, 255, 255, 255),
                    [System.Drawing.Color]::FromArgb(0,   255, 255, 255),
                    [System.Drawing.Drawing2D.LinearGradientMode]::Vertical)
                $g.FillRectangle($shineBrush, $shineRect)
                $shineBrush.Dispose()
            }

            # Sparkles within fill area
            $sparkBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(230, 255, 255, 255))
            foreach ($spk in $s._sparkles) {
                $sx = [int]($spk.X * $barW)
                if ($sx -lt $fillW) {
                    $sy = $barY + [int]($spk.Y * $barH)
                    $sz = [int]$spk.S
                    $g.FillEllipse($sparkBrush, $sx, $sy, $sz, $sz)
                }
            }
            $sparkBrush.Dispose()

            $g.ResetClip()
        }

        # Thin amber inner rim around the pill for definition
        $rimPen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(180, 180, 110, 255)), 1
        $g.DrawPath($rimPen, $bgPath)
        $rimPen.Dispose()

        # Percentage text centered inside the bar
        $pctText = ('{0}%' -f [int][Math]::Round($pct * 100))
        $textFont = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
        $tflags = [System.Windows.Forms.TextFormatFlags]::NoPrefix -bor `
                  [System.Windows.Forms.TextFormatFlags]::NoPadding
        $tsz = [System.Windows.Forms.TextRenderer]::MeasureText($g, $pctText, $textFont, [System.Drawing.Size]::Empty, $tflags)
        $tx = [int](($w - $tsz.Width) / 2)
        $ty = $barY + [int](($barH - $tsz.Height) / 2) - 1

        $shadowPoint = New-Object System.Drawing.Point ($tx + 1), ($ty + 1)
        [System.Windows.Forms.TextRenderer]::DrawText($g, $pctText, $textFont, $shadowPoint, [System.Drawing.Color]::Black, $tflags) | Out-Null
        $textPoint = New-Object System.Drawing.Point $tx, $ty
        [System.Windows.Forms.TextRenderer]::DrawText($g, $pctText, $textFont, $textPoint, [System.Drawing.Color]::White, $tflags) | Out-Null
        $textFont.Dispose()

        $bgPath.Dispose()
    })

    return $p
}

function Set-GlowProgressState {
    param(
        [Parameter(Mandatory)]$Bar,
        [int]$Minimum = -1,
        [int]$Maximum = -1,
        [int]$Value = -1
    )
    if ($Minimum -ge 0) { $Bar._min = $Minimum }
    if ($Maximum -ge 0) { $Bar._max = [Math]::Max(1, $Maximum) }
    if ($Value -ge 0) { $Bar._value = [int]$Value }
    $Bar.Invalidate()
}

function Step-GlowProgress {
    param([Parameter(Mandatory)]$Bar)
    $cap = [Math]::Max(1, $Bar._max)
    $next = [Math]::Min($cap, $Bar._value + 1)
    Set-GlowProgressState -Bar $Bar -Value $next
}

function Reset-GlowProgress {
    param([Parameter(Mandatory)]$Bar, [int]$Max = 100)
    Set-GlowProgressState -Bar $Bar -Minimum 0 -Maximum $Max -Value 0
}

# ---------------------------------------------------------------------------
# Helper: themed group box with painted amber border + dark fill
# ---------------------------------------------------------------------------

function Set-ThemedChildSurface {
    param([System.Windows.Forms.Control]$Control)
    $Control.BackColor = $ColorPanelChild
    if ($Control -is [System.Windows.Forms.RadioButton] -or $Control -is [System.Windows.Forms.CheckBox]) {
        $Control.UseVisualStyleBackColor = $false
    }
}

function Set-ThemedButton {
    param(
        [System.Windows.Forms.Button]$Button,
        [System.Drawing.Color]$Back,
        [System.Drawing.Color]$Border,
        [System.Drawing.Color]$Fore,
        [System.Drawing.Color]$HoverBack = $null
    )
    if (-not $HoverBack) {
        $HoverBack = [System.Drawing.Color]::FromArgb(
            [Math]::Min(255, $Back.R + 18),
            [Math]::Min(255, $Back.G + 14),
            [Math]::Min(255, $Back.B + 10))
    }
    $Button.FlatStyle = 'Flat'
    $Button.UseVisualStyleBackColor = $false
    $Button.BackColor = $Back
    $Button.ForeColor = $Fore
    $Button.Font = $FontBold
    $Button.FlatAppearance.BorderSize = 1
    $Button.FlatAppearance.BorderColor = $Border
    $Button.FlatAppearance.MouseOverBackColor = $HoverBack
    $Button.FlatAppearance.MouseDownBackColor = $HoverBack
}

function New-LogGlassCard {
    param([string]$Title)
    $p = New-Object System.Windows.Forms.Panel
    $ss = [System.Windows.Forms.Control].GetMethod('SetStyle',
        [System.Reflection.BindingFlags]'Instance,NonPublic')
    $tflags = [System.Windows.Forms.ControlStyles]::SupportsTransparentBackColor -bor `
              [System.Windows.Forms.ControlStyles]::OptimizedDoubleBuffer -bor `
              [System.Windows.Forms.ControlStyles]::AllPaintingInWmPaint -bor `
              [System.Windows.Forms.ControlStyles]::UserPaint
    [void]$ss.Invoke($p, @($tflags, $true))
    try { $p.BackColor = [System.Drawing.Color]::Transparent } catch { $p.BackColor = $ColorLogBg }
    $p.Tag = $Title
    $p.Add_Paint({
        param($s, $e)
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $pen = New-Object System.Drawing.Pen $ColorBorder, 1
        $rect = New-Object System.Drawing.Rectangle 0, 0, ($s.ClientSize.Width - 1), ($s.ClientSize.Height - 1)
        $g.DrawRectangle($pen, $rect)
        $pen.Dispose()
        if ($s.Tag) {
            $tflags = [System.Windows.Forms.TextFormatFlags]::NoPrefix -bor `
                      [System.Windows.Forms.TextFormatFlags]::NoPadding
            $titleStr = "  $($s.Tag)  "
            $tsz = [System.Windows.Forms.TextRenderer]::MeasureText($g, $titleStr, $FontChip, [System.Drawing.Size]::Empty, $tflags)
            $chipRect = New-Object System.Drawing.Rectangle 10, -1, ($tsz.Width + 2), ($tsz.Height + 2)
            $chipBg = New-Object System.Drawing.SolidBrush $ColorBgTitle
            $g.FillRectangle($chipBg, $chipRect)
            $chipBg.Dispose()
            $chipPen = New-Object System.Drawing.Pen $ColorAccent, 1
            $g.DrawRectangle($chipPen, $chipRect)
            $chipPen.Dispose()
            $textPoint = New-Object System.Drawing.Point 11, 1
            [System.Windows.Forms.TextRenderer]::DrawText($g, $titleStr, $FontChip, $textPoint, $ColorFg, $tflags) | Out-Null
        }
    })
    return $p
}

function New-ThemedPanel {
    param([string]$Title)
    $p = New-Object System.Windows.Forms.Panel
    # Enable transparent-backcolor support, then set a SEMI-transparent dark fill
    # so the form's background image shows through the panel (frosted glass effect).
    $ss = [System.Windows.Forms.Control].GetMethod('SetStyle',
        [System.Reflection.BindingFlags]'Instance,NonPublic')
    $tflags = [System.Windows.Forms.ControlStyles]::SupportsTransparentBackColor -bor `
              [System.Windows.Forms.ControlStyles]::OptimizedDoubleBuffer -bor `
              [System.Windows.Forms.ControlStyles]::AllPaintingInWmPaint -bor `
              [System.Windows.Forms.ControlStyles]::UserPaint
    [void]$ss.Invoke($p, @($tflags, $true))
    # Semi-transparent tint (background art still visible). Opaque enough to avoid control ghosting.
    $p.BackColor = [System.Drawing.Color]::FromArgb(165, 14, 10, 6)
    $p.Tag = $Title
    $p.Add_Paint({
        param($s, $e)
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias

        # amber border
        $pen = New-Object System.Drawing.Pen $ColorBorder, 1
        $rect = New-Object System.Drawing.Rectangle 0, 0, ($s.ClientSize.Width - 1), ($s.ClientSize.Height - 1)
        $g.DrawRectangle($pen, $rect)
        $pen.Dispose()

        # title chip in top-left, rendered crisply via TextRenderer
        if ($s.Tag) {
            $tflags = [System.Windows.Forms.TextFormatFlags]::NoPrefix -bor `
                      [System.Windows.Forms.TextFormatFlags]::NoPadding
            $titleStr = "  $($s.Tag)  "
            $tsz = [System.Windows.Forms.TextRenderer]::MeasureText($g, $titleStr, $FontChip, [System.Drawing.Size]::Empty, $tflags)
            $chipRect = New-Object System.Drawing.Rectangle 10, -1, ($tsz.Width + 2), ($tsz.Height + 2)

            # solid dark backing chip
            $chipBg = New-Object System.Drawing.SolidBrush $ColorBgTitle
            $g.FillRectangle($chipBg, $chipRect)
            $chipBg.Dispose()

            # subtle amber border around chip
            $chipPen = New-Object System.Drawing.Pen $ColorAccent, 1
            $g.DrawRectangle($chipPen, $chipRect)
            $chipPen.Dispose()

            $textPoint = New-Object System.Drawing.Point 11, 1
            [System.Windows.Forms.TextRenderer]::DrawText($g, $titleStr, $FontChip, $textPoint, $ColorFg, $tflags) | Out-Null
        }
    })
    return $p
}

# ---------- Main content (no scroll — tall window shows everything) ----------
$script:FooterHeight = 48
$script:LogPanelHeight = 200
$script:MainContentHeight = 720

$contentFrame = New-Object System.Windows.Forms.Panel
$initViewH = $form.ClientSize.Height - $TitleBarHeight - $script:FooterHeight
$contentFrame.Location = New-Object System.Drawing.Point(0, $TitleBarHeight)
$contentFrame.Size = New-Object System.Drawing.Size($form.ClientSize.Width, $initViewH)
$contentFrame.Anchor = 'Top,Bottom,Left,Right'
$contentFrame.BackColor = [System.Drawing.Color]::Transparent
$form.Controls.Add($contentFrame)
Set-TitleBarControlsOnTop

$mainPanel = New-Object System.Windows.Forms.Panel
$mainPanel.Location = New-Object System.Drawing.Point(0, 0)
$mainPanel.Size = New-Object System.Drawing.Size($contentFrame.Width, $script:MainContentHeight)
$mainPanel.Anchor = 'Top,Left,Right'
$mainPanel.AutoScroll = $false
$mainPanel.BackColor = [System.Drawing.Color]::Transparent
$contentFrame.Controls.Add($mainPanel)
$mainPanel.BringToFront()

function Update-FooterLayout {
    param([int]$Cw, [int]$Ch)
    $yBtn = $Ch - 40
    $yStat = $Ch - 36
    $btnBlockW = 96 + 138 + 80 + 24
    $statusMinW = 220
    $progMax = [Math]::Max(160, $Cw - $btnBlockW - $statusMinW - 36)
    $progW = [Math]::Min(360, $progMax)
    if ($progress) {
        $progress.Location = New-Object System.Drawing.Point(20, ($Ch - 42))
        $progress.Width = $progW
    }
    $x = 20 + $progW + 12
    if ($testBarBtn) {
        $testBarBtn.Location = New-Object System.Drawing.Point($x, $yBtn)
        $x += $testBarBtn.Width + 8
    }
    if ($isoInstallBtn) {
        $isoInstallBtn.Location = New-Object System.Drawing.Point($x, $yBtn)
        $x += $isoInstallBtn.Width + 8
    }
    if ($aboutBtn) {
        $aboutBtn.Location = New-Object System.Drawing.Point($x, $yBtn)
        $x += $aboutBtn.Width + 12
    }
    if ($statusLabel) {
        $statusW = [Math]::Max($statusMinW, $Cw - $x - 12)
        $statusLabel.Location = New-Object System.Drawing.Point($x, $yStat)
        $statusLabel.Size = New-Object System.Drawing.Size($statusW, 22)
    }
}

function Update-MainLayout {
    $cw = $form.ClientSize.Width
    $ch = $form.ClientSize.Height
    $viewH = $ch - $TitleBarHeight - $script:FooterHeight
    $contentFrame.Size = New-Object System.Drawing.Size $cw, $viewH
    $contentW = [Math]::Max(480, $cw - 40)
    $mainH = $script:MainContentHeight
    if ($mainPanel) {
        $mainPanel.Location = New-Object System.Drawing.Point 0, 0
        $mainPanel.Size = New-Object System.Drawing.Size ([Math]::Max(200, $cw)), $mainH
    }
    if ($logCard) {
        $logH = [Math]::Max(120, $viewH - $mainH)
        $logCard.Location = New-Object System.Drawing.Point(20, $mainH)
        $logCard.Size = New-Object System.Drawing.Size $contentW, $logH
    }
    if ($null -ne $script:glassLog -and $logCard) {
        $script:glassLog.Location = New-Object System.Drawing.Point(10, 26)
        $script:glassLog.Size = New-Object System.Drawing.Size([Math]::Max(100, $logCard.Width - 20), [Math]::Max(80, $logCard.Height - 32))
        $script:glassLog.Invalidate()
    }
    if ($modeCard) { $modeCard.Width = $contentW }
    if ($folderCard) { $folderCard.Width = $contentW }
    if ($actionsCard) {
        $actionsCard.Width = $contentW
        if ($script:actionsBtnRow) {
            $script:actionsBtnRow.Width = [Math]::Max(200, $contentW - 20)
        }
    }
    if ($gbCard) { $gbCard.Width = $contentW }
    if ($pngCard) { $pngCard.Width = $contentW }
    Update-FooterLayout -Cw $cw -Ch $ch
    Update-RightControls
    $form.Invalidate()
}

# ---------- Mode card ----------
$contentTop = 14

$modeCard = New-ThemedPanel -Title 'Step 1  -  Choose merge mode'
$modeCard.Location = New-Object System.Drawing.Point(20, $contentTop)
$modeCard.Size = New-Object System.Drawing.Size(($form.ClientSize.Width - 40), 110)
$modeCard.Anchor = 'Top,Left,Right'
$mainPanel.Controls.Add($modeCard)

$rbReplace = New-Object System.Windows.Forms.RadioButton
$rbReplace.Text = 'Replace matching files  -  overwrite destination files that share a name with source files'
$rbReplace.Location = New-Object System.Drawing.Point(20, 34)
$rbReplace.Size = New-Object System.Drawing.Size(820, 26)
$rbReplace.ForeColor = $ColorFg
$rbReplace.Font = $FontBold
$rbReplace.Checked = $false
$modeCard.Controls.Add($rbReplace)
Set-ThemedChildSurface $rbReplace

$rbAppend = New-Object System.Windows.Forms.RadioButton
$rbAppend.Text = 'Append missing files  -  add new textures from other pack(s) into your base pack (keeps existing files)'
$rbAppend.Location = New-Object System.Drawing.Point(20, 66)
$rbAppend.Size = New-Object System.Drawing.Size(820, 26)
$rbAppend.ForeColor = $ColorFg
$rbAppend.Font = $FontBold
$rbAppend.Checked = $true
$modeCard.Controls.Add($rbAppend)
Set-ThemedChildSurface $rbAppend

# ---------- Folders card ----------
$script:FolderLabelWidth = 118
$script:FolderFieldX = 138

$folderCard = New-ThemedPanel -Title 'Step 2  -  Choose the folders (pick your GZ2 folders)'
$folderCard.Location = New-Object System.Drawing.Point(20, ($contentTop + 122))
$folderCard.Size = New-Object System.Drawing.Size(($form.ClientSize.Width - 40), 228)
$folderCard.Anchor = 'Top,Left,Right'
$mainPanel.Controls.Add($folderCard)

$folderIntro = New-Object System.Windows.Forms.Label
$folderIntro.Text = 'Append mode: pick YOUR main pack first, then the OTHER pack to pull missing files from. Always choose the GZ2 folder inside each pack.'
$folderIntro.Location = New-Object System.Drawing.Point(20, 28)
$folderIntro.Size = New-Object System.Drawing.Size(820, 32)
$folderIntro.ForeColor = $ColorFgDim
$folderIntro.Font = $FontHint
$folderCard.Controls.Add($folderIntro)
Set-ThemedChildSurface $folderIntro

# 1. Base pack (destination) - shown first so it is obvious
$dstLabel = New-Object System.Windows.Forms.Label
$dstLabel.Text = '1. Base pack'
$dstLabel.Location = New-Object System.Drawing.Point(20, 62)
$dstLabel.Size = New-Object System.Drawing.Size(118, 22)
$dstLabel.ForeColor = $ColorAccent2
$dstLabel.Font = $FontBold
$folderCard.Controls.Add($dstLabel)
Set-ThemedChildSurface $dstLabel

$dstBox = New-Object System.Windows.Forms.TextBox
$dstBox.Location = New-Object System.Drawing.Point($script:FolderFieldX, 60)
$dstBox.Size = New-Object System.Drawing.Size(587, 24)
$dstBox.Anchor = 'Top,Left,Right'
$dstBox.BackColor = $ColorBgInput
$dstBox.ForeColor = $ColorFg
$dstBox.BorderStyle = 'FixedSingle'
$folderCard.Controls.Add($dstBox)

$dstBtn = New-Object System.Windows.Forms.Button
$dstBtn.Text = 'Browse...'
$dstBtn.Location = New-Object System.Drawing.Point(735, 57)
$dstBtn.Size = New-Object System.Drawing.Size(110, 28)
$dstBtn.Anchor = 'Top,Right'
$dstBtn.FlatStyle = 'Flat'
$dstBtn.BackColor = $ColorBgAlt
$dstBtn.ForeColor = $ColorFg
$dstBtn.FlatAppearance.BorderColor = $ColorBorderGlow
$dstBtn.FlatAppearance.MouseOverBackColor = $ColorBorder
$folderCard.Controls.Add($dstBtn)

$dstHint = New-Object System.Windows.Forms.Label
$dstHint.Text = 'YOUR main pack (keeps its files). Example: Henriko\GZ2  OR  TPHD\GZ2 if that is the one you want to keep.'
$dstHint.Location = New-Object System.Drawing.Point(20, 86)
$dstHint.Size = New-Object System.Drawing.Size(820, 28)
$dstHint.ForeColor = $ColorFgDim
$dstHint.Font = $FontHint
$folderCard.Controls.Add($dstHint)
Set-ThemedChildSurface $dstHint

# 2. Add from (first source)
$srcLabel = New-Object System.Windows.Forms.Label
$srcLabel.Text = '2. Add from'
$srcLabel.Location = New-Object System.Drawing.Point(20, 118)
$srcLabel.Size = New-Object System.Drawing.Size(118, 22)
$srcLabel.ForeColor = $ColorFg
$srcLabel.Font = $FontBold
$folderCard.Controls.Add($srcLabel)
Set-ThemedChildSurface $srcLabel

$srcBox = New-Object System.Windows.Forms.TextBox
$srcBox.Location = New-Object System.Drawing.Point($script:FolderFieldX, 116)
$srcBox.Size = New-Object System.Drawing.Size(587, 24)
$srcBox.Anchor = 'Top,Left,Right'
$srcBox.BackColor = $ColorBgInput
$srcBox.ForeColor = $ColorFg
$srcBox.BorderStyle = 'FixedSingle'
$folderCard.Controls.Add($srcBox)

$srcBtn = New-Object System.Windows.Forms.Button
$srcBtn.Text = 'Browse...'
$srcBtn.Location = New-Object System.Drawing.Point(735, 113)
$srcBtn.Size = New-Object System.Drawing.Size(110, 28)
$srcBtn.Anchor = 'Top,Right'
$srcBtn.FlatStyle = 'Flat'
$srcBtn.BackColor = $ColorBgAlt
$srcBtn.ForeColor = $ColorFg
$srcBtn.FlatAppearance.BorderColor = $ColorBorderGlow
$srcBtn.FlatAppearance.MouseOverBackColor = $ColorBorder
$folderCard.Controls.Add($srcBtn)

$srcHint = New-Object System.Windows.Forms.Label
$srcHint.Text = 'The OTHER pack (missing files are copied FROM here INTO your base pack). Example: if base is Henriko\GZ2, put TPHD\GZ2 here.'
$srcHint.Location = New-Object System.Drawing.Point(20, 142)
$srcHint.Size = New-Object System.Drawing.Size(820, 28)
$srcHint.ForeColor = $ColorFgDim
$srcHint.Font = $FontHint
$folderCard.Controls.Add($srcHint)
Set-ThemedChildSurface $srcHint

# 3. Optional second source
$outLabel = New-Object System.Windows.Forms.Label
$outLabel.Text = '3. Output folder'
$outLabel.Location = New-Object System.Drawing.Point(20, 174)
$outLabel.Size = New-Object System.Drawing.Size(118, 22)
$outLabel.ForeColor = $ColorAccent
$outLabel.Font = $FontBold
$folderCard.Controls.Add($outLabel)
Set-ThemedChildSurface $outLabel

$outBox = New-Object System.Windows.Forms.TextBox
$outBox.Location = New-Object System.Drawing.Point($script:FolderFieldX, 172)
$outBox.Size = New-Object System.Drawing.Size(587, 24)
$outBox.Anchor = 'Top,Left,Right'
$outBox.BackColor = $ColorBgInput
$outBox.ForeColor = $ColorFg
$outBox.BorderStyle = 'FixedSingle'
$folderCard.Controls.Add($outBox)

$outBtn = New-Object System.Windows.Forms.Button
$outBtn.Text = 'Browse...'
$outBtn.Location = New-Object System.Drawing.Point(735, 169)
$outBtn.Size = New-Object System.Drawing.Size(110, 28)
$outBtn.Anchor = 'Top,Right'
$outBtn.FlatStyle = 'Flat'
$outBtn.BackColor = $ColorBgAlt
$outBtn.ForeColor = $ColorFg
$outBtn.FlatAppearance.BorderColor = $ColorBorderGlow
$outBtn.FlatAppearance.MouseOverBackColor = $ColorBorder
$folderCard.Controls.Add($outBtn)

$outHint = New-Object System.Windows.Forms.Label
$outHint.Text = 'Leave empty to merge IN PLACE into the base pack. Or pick a folder to save the merged result there (base pack stays untouched — folder is created if missing).'
$outHint.Location = New-Object System.Drawing.Point(20, 198)
$outHint.Size = New-Object System.Drawing.Size(820, 18)
$outHint.ForeColor = $ColorFgDim
$outHint.Font = $FontHint
$folderCard.Controls.Add($outHint)
Set-ThemedChildSurface $outHint

# ---------- Merge actions (Step 3) — directly under folder picker so buttons stay visible ----------
$script:ActionsCardHeight = 150
$actionsCardY = $contentTop + 122 + 228 + 12
$actionsCard = New-ThemedPanel -Title 'Step 3  -  Run merge (download, convert, add to pack)'
$actionsCard.Location = New-Object System.Drawing.Point(20, $actionsCardY)
$actionsCard.Size = New-Object System.Drawing.Size(($form.ClientSize.Width - 40), $script:ActionsCardHeight)
$actionsCard.Anchor = 'Top,Left,Right'
$mainPanel.Controls.Add($actionsCard)

# Opaque strip for buttons — stops semi-transparent panel from bleeding through Flat buttons.
$script:actionsBtnRow = New-Object System.Windows.Forms.Panel
$script:actionsBtnRow.Location = New-Object System.Drawing.Point(10, 86)
$script:actionsBtnRow.Size = New-Object System.Drawing.Size(($actionsCard.Width - 20), 40)
$script:actionsBtnRow.Anchor = 'Top,Left,Right'
$script:actionsBtnRow.BackColor = $ColorPanelChild
$actionsCard.Controls.Add($script:actionsBtnRow)

$dryRunBox = New-Object System.Windows.Forms.CheckBox
$dryRunBox.Text = 'Dry run only  -  preview in log, NO files copied (leave OFF to merge for real)'
$dryRunBox.Location = New-Object System.Drawing.Point(12, 24)
$dryRunBox.Size = New-Object System.Drawing.Size(520, 22)
$dryRunBox.ForeColor = $ColorFgDim
$dryRunBox.Font = $FontHint
$dryRunBox.Checked = $false
$actionsCard.Controls.Add($dryRunBox)
Set-ThemedChildSurface $dryRunBox
$dryRunBox.Add_CheckedChanged({
    if ($dryRunBox.Checked) {
        $dryRunBox.ForeColor = $ColorWarn
        $dryRunBox.Font = $FontBold
    } else {
        $dryRunBox.ForeColor = $ColorFgDim
        $dryRunBox.Font = $FontHint
    }
})

$skipConfirmBox = New-Object System.Windows.Forms.CheckBox
$skipConfirmBox.Text = 'Skip confirm popups  -  just run (uncheck to confirm each step)'
$skipConfirmBox.Location = New-Object System.Drawing.Point(12, 48)
$skipConfirmBox.Size = New-Object System.Drawing.Size(800, 22)
$skipConfirmBox.ForeColor = $ColorAccent2
$skipConfirmBox.Font = $FontHint
$skipConfirmBox.Checked = $true
$actionsCard.Controls.Add($skipConfirmBox)
Set-ThemedChildSurface $skipConfirmBox

$includeGbMergeBox = New-Object System.Windows.Forms.CheckBox
$includeGbMergeBox.Text = 'Also download GameBanana mods (off = merge your two folders only)'
$includeGbMergeBox.Location = New-Object System.Drawing.Point(12, 68)
$includeGbMergeBox.Size = New-Object System.Drawing.Size(800, 22)
$includeGbMergeBox.ForeColor = $ColorFgDim
$includeGbMergeBox.Font = $FontHint
$includeGbMergeBox.Checked = $false
$actionsCard.Controls.Add($includeGbMergeBox)
Set-ThemedChildSurface $includeGbMergeBox

$scanBtn = New-Object System.Windows.Forms.Button
$scanBtn.Text = 'Scan / Preview'
$scanBtn.Size = New-Object System.Drawing.Size(130, 34)
$scanBtn.Anchor = 'Top,Right'
$scanBtn.Location = New-Object System.Drawing.Point(($script:actionsBtnRow.Width - 406), 3)
Set-ThemedButton -Button $scanBtn -Back $ColorBgAlt -Border $ColorBorder -Fore $ColorFg
$script:actionsBtnRow.Controls.Add($scanBtn)

$runBtn = New-Object System.Windows.Forms.Button
$runBtn.Text = 'Run Full Merge'
$runBtn.Size = New-Object System.Drawing.Size(140, 34)
$runBtn.Anchor = 'Top,Right'
$runBtn.Location = New-Object System.Drawing.Point(($script:actionsBtnRow.Width - 268), 3)
Set-ThemedButton -Button $runBtn -Back $ColorAccent -Border $ColorAccentHover -Fore ([System.Drawing.Color]::FromArgb(20, 14, 8)) -HoverBack $ColorAccentHover
$script:actionsBtnRow.Controls.Add($runBtn)

$clearBtn = New-Object System.Windows.Forms.Button
$clearBtn.Text = 'Clear Log'
$clearBtn.Size = New-Object System.Drawing.Size(120, 34)
$clearBtn.Anchor = 'Top,Right'
$clearBtn.Location = New-Object System.Drawing.Point(($script:actionsBtnRow.Width - 124), 3)
Set-ThemedButton -Button $clearBtn -Back $ColorBgAlt -Border $ColorBorder -Fore $ColorFg
$script:actionsBtnRow.Controls.Add($clearBtn)

# Status for merge — below button strip
$runFeedbackLbl = New-Object System.Windows.Forms.Label
$runFeedbackLbl.Text = 'Ready — fill folders above, then Run Full Merge.'
$runFeedbackLbl.Location = New-Object System.Drawing.Point(12, 130)
$runFeedbackLbl.Size = New-Object System.Drawing.Size(820, 18)
$runFeedbackLbl.ForeColor = $ColorFgDim
$runFeedbackLbl.Font = $FontHint
$actionsCard.Controls.Add($runFeedbackLbl)
Set-ThemedChildSurface $runFeedbackLbl
$script:actionsBtnRow.BringToFront()
foreach ($b in @($scanBtn, $runBtn, $clearBtn)) { $b.BringToFront() }

# ---------- GameBanana downloader (Step 4 - optional) ----------
$script:GbCardHeight = 118
$script:PngCardHeight = 146
$gbCardY = $actionsCardY + $script:ActionsCardHeight + 12
$gbCard = New-ThemedPanel -Title 'GameBanana downloader  -  optional, separate from merge'
$gbCard.Location = New-Object System.Drawing.Point(20, $gbCardY)
$gbCard.Size = New-Object System.Drawing.Size(($form.ClientSize.Width - 40), $script:GbCardHeight)
$gbCard.Anchor = 'Top,Left,Right'
$mainPanel.Controls.Add($gbCard)

$gbHint = New-Object System.Windows.Forms.Label
$gbHint.Text = 'Put gamebanana-mods.txt next to Start Mod Merger.vbs — mod zips download to that same folder on any PC. One https://gamebanana.com/dl/... URL per line.'
$gbHint.Location = New-Object System.Drawing.Point(20, 30)
$gbHint.Size = New-Object System.Drawing.Size(820, 36)
$gbHint.ForeColor = $ColorFg
$gbHint.Font = $FontHint
$gbCard.Controls.Add($gbHint)
Set-ThemedChildSurface $gbHint

$gbLinksLbl = New-Object System.Windows.Forms.Label
$gbLinksLbl.Text = 'Links file'
$gbLinksLbl.Location = New-Object System.Drawing.Point(20, 72)
$gbLinksLbl.Size = New-Object System.Drawing.Size(72, 22)
$gbLinksLbl.ForeColor = $ColorFg
$gbLinksLbl.Font = $FontBold
$gbCard.Controls.Add($gbLinksLbl)
Set-ThemedChildSurface $gbLinksLbl

$gbLinksBox = New-Object System.Windows.Forms.TextBox
$gbLinksBox.Location = New-Object System.Drawing.Point(96, 70)
$gbLinksBox.Size = New-Object System.Drawing.Size(545, 24)
$gbLinksBox.Anchor = 'Top,Left,Right'
$gbLinksBox.BackColor = $ColorBgInput
$gbLinksBox.ForeColor = $ColorFg
$gbLinksBox.BorderStyle = 'FixedSingle'
$gbLinksBox.Text = Ensure-GameBananaLinksFile -Root (Get-ModMergerAppFolder)
$gbCard.Controls.Add($gbLinksBox)

$gbLinksBrowse = New-Object System.Windows.Forms.Button
$gbLinksBrowse.Text = 'Browse...'
$gbLinksBrowse.Location = New-Object System.Drawing.Point(655, 67)
$gbLinksBrowse.Size = New-Object System.Drawing.Size(100, 28)
$gbLinksBrowse.Anchor = 'Top,Right'
$gbLinksBrowse.FlatStyle = 'Flat'
$gbLinksBrowse.BackColor = $ColorBgAlt
$gbLinksBrowse.ForeColor = $ColorFg
$gbLinksBrowse.FlatAppearance.BorderColor = $ColorBorderGlow
$gbLinksBrowse.FlatAppearance.MouseOverBackColor = $ColorBorder
$gbCard.Controls.Add($gbLinksBrowse)

$gbDownloadBtn = New-Object System.Windows.Forms.Button
$gbDownloadBtn.Text = 'Download mods'
$gbDownloadBtn.Location = New-Object System.Drawing.Point(765, 67)
$gbDownloadBtn.Size = New-Object System.Drawing.Size(115, 28)
$gbDownloadBtn.Anchor = 'Top,Right'
$gbDownloadBtn.FlatStyle = 'Flat'
$gbDownloadBtn.BackColor = $ColorBgAlt
$gbDownloadBtn.ForeColor = $ColorFg
$gbDownloadBtn.Font = $FontBold
$gbDownloadBtn.FlatAppearance.BorderColor = $ColorAccent2
$gbDownloadBtn.FlatAppearance.MouseOverBackColor = $ColorBorder
$gbCard.Controls.Add($gbDownloadBtn)

# ---------- Manual PNG -> DDS ----------
$pngCardY = $gbCardY + $script:GbCardHeight + 12
$pngCard = New-ThemedPanel -Title 'PNG -> DDS  -  manual convert (uses texconv)'
$pngCard.Location = New-Object System.Drawing.Point(20, $pngCardY)
$pngCard.Size = New-Object System.Drawing.Size(($form.ClientSize.Width - 40), $script:PngCardHeight)
$pngCard.Anchor = 'Top,Left,Right'
$mainPanel.Controls.Add($pngCard)

$pngHint = New-Object System.Windows.Forms.Label
$pngHint.Text = 'Convert opens the thumbnail style picker when this folder has several style subfolders (like before). Check options below to skip that or convert every PNG.'
$pngHint.Location = New-Object System.Drawing.Point(20, 28)
$pngHint.Size = New-Object System.Drawing.Size(820, 36)
$pngHint.ForeColor = $ColorFg
$pngHint.Font = $FontHint
$pngCard.Controls.Add($pngHint)
Set-ThemedChildSurface $pngHint

$pngConvertAllBox = New-Object System.Windows.Forms.CheckBox
$pngConvertAllBox.Text = 'Convert all PNG files (not only tex*.png)'
$pngConvertAllBox.Location = New-Object System.Drawing.Point(480, 34)
$pngConvertAllBox.Size = New-Object System.Drawing.Size(330, 22)
$pngConvertAllBox.ForeColor = $ColorFg
$pngConvertAllBox.Font = $FontHint
$pngConvertAllBox.Checked = $false
$pngConvertAllBox.UseVisualStyleBackColor = $false
$pngConvertAllBox.BackColor = [System.Drawing.Color]::Transparent
$pngCard.Controls.Add($pngConvertAllBox)
Set-ThemedChildSurface $pngConvertAllBox

$pngFolderBox = New-Object System.Windows.Forms.TextBox
$pngFolderBox.Location = New-Object System.Drawing.Point(20, 66)
$pngFolderBox.Size = New-Object System.Drawing.Size(450, 26)
$pngFolderBox.Anchor = 'Top,Left'
$pngFolderBox.BackColor = $ColorBgInput
$pngFolderBox.ForeColor = $ColorFg
$pngFolderBox.Font = $FontMain
$pngFolderBox.BorderStyle = 'FixedSingle'
$pngCard.Controls.Add($pngFolderBox)

$pngNoPickerBox = New-Object System.Windows.Forms.CheckBox
$pngNoPickerBox.Text = 'Convert all subfolders at once (skip style picture picker)'
$pngNoPickerBox.Location = New-Object System.Drawing.Point(20, 96)
$pngNoPickerBox.Size = New-Object System.Drawing.Size(420, 22)
$pngNoPickerBox.ForeColor = $ColorFg
$pngNoPickerBox.Font = $FontHint
$pngNoPickerBox.Checked = $false
$pngNoPickerBox.UseVisualStyleBackColor = $false
$pngNoPickerBox.BackColor = [System.Drawing.Color]::Transparent
$pngCard.Controls.Add($pngNoPickerBox)
Set-ThemedChildSurface $pngNoPickerBox

$pngBrowseBtn = New-Object System.Windows.Forms.Button
$pngBrowseBtn.Text = 'Browse...'
$pngBrowseBtn.Location = New-Object System.Drawing.Point(480, 65)
$pngBrowseBtn.Size = New-Object System.Drawing.Size(85, 28)
$pngBrowseBtn.Anchor = 'Top,Right'
$pngBrowseBtn.FlatStyle = 'Flat'
$pngBrowseBtn.BackColor = $ColorBgAlt
$pngBrowseBtn.ForeColor = $ColorFg
$pngBrowseBtn.FlatAppearance.BorderColor = $ColorBorderGlow
$pngBrowseBtn.FlatAppearance.MouseOverBackColor = $ColorBorder
$pngCard.Controls.Add($pngBrowseBtn)

$pngPreviewBtn = New-Object System.Windows.Forms.Button
$pngPreviewBtn.Text = 'Style pictures only'
$pngPreviewBtn.Location = New-Object System.Drawing.Point(565, 65)
$pngPreviewBtn.Size = New-Object System.Drawing.Size(120, 28)
$pngPreviewBtn.Anchor = 'Top,Right'
$pngPreviewBtn.FlatStyle = 'Flat'
$pngPreviewBtn.BackColor = $ColorBgAlt
$pngPreviewBtn.ForeColor = $ColorAccent2
$pngPreviewBtn.FlatAppearance.BorderColor = $ColorAccent2
$pngPreviewBtn.FlatAppearance.MouseOverBackColor = $ColorBorder
$pngCard.Controls.Add($pngPreviewBtn)

$convertPngBtn = New-Object System.Windows.Forms.Button
$convertPngBtn.Text = 'Convert PNG -> DDS'
$convertPngBtn.Location = New-Object System.Drawing.Point(695, 65)
$convertPngBtn.Size = New-Object System.Drawing.Size(125, 28)
$convertPngBtn.Anchor = 'Top,Right'
$convertPngBtn.FlatStyle = 'Flat'
$convertPngBtn.BackColor = $ColorBgAlt
$convertPngBtn.ForeColor = $ColorFg
$convertPngBtn.Font = $FontBold
$convertPngBtn.FlatAppearance.BorderColor = $ColorAccent
$convertPngBtn.FlatAppearance.MouseOverBackColor = $ColorBorder
$pngCard.Controls.Add($convertPngBtn)
$pngBrowseBtn.BringToFront()
$pngPreviewBtn.BringToFront()
$convertPngBtn.BringToFront()

$script:MainContentHeight = $pngCardY + $script:PngCardHeight + 12

if ($mainPanel) {
    $mainPanel.Height = $script:MainContentHeight
}

# ---------- Log card (fixed at bottom - shows form background through text area) ----------
$logCard = New-LogGlassCard -Title 'Log'
$logCard.Location = New-Object System.Drawing.Point(20, $script:MainContentHeight)
$logCard.Size = New-Object System.Drawing.Size(($form.ClientSize.Width - 40), $script:LogPanelHeight)
$logCard.Anchor = 'Top,Bottom,Left,Right'
$contentFrame.Controls.Add($logCard)
$logCard.BringToFront()

if (-not $script:GlassLogReady) {
    $glassErr = if ($script:GlassLogLoadError) { $script:GlassLogLoadError } else { 'Unknown compile/load error.' }
    $errPath = Join-Path $scriptDir '_err.txt'
    $glassMsg = @(
        'Glass log control failed to load.',
        "Look for _GlassLogView.cs in:",
        $scriptDir,
        '',
        $glassErr
    ) -join [Environment]::NewLine
    Set-Content -LiteralPath $errPath -Value $glassMsg -Encoding UTF8
    [System.Windows.Forms.MessageBox]::Show($glassMsg, 'Mod Merger', 'OK', 'Warning') | Out-Null
    exit 1
}
$script:glassLog = New-Object GlassLogView
$script:glassLog.Location = New-Object System.Drawing.Point(10, 26)
$script:glassLog.Size = New-Object System.Drawing.Size(400, 160)
$script:glassLog.Anchor = 'Top,Bottom,Left,Right'
$logCard.Controls.Add($script:glassLog)
$logBox = $script:glassLog

$form.Add_Load({
    if ($script:glassLog) { $script:glassLog.Invalidate() }
    $app = Get-ModMergerAppFolder
    if ($gbLinksBox) {
        $p = Ensure-GameBananaLinksFile -Root $app
        if ([string]::IsNullOrWhiteSpace($gbLinksBox.Text)) { $gbLinksBox.Text = $p }
    }
    if ($dstBox -and [string]::IsNullOrWhiteSpace($dstBox.Text)) {
        $gz2 = Join-Path $app 'GZ2'
        if (Test-Path -LiteralPath $gz2 -PathType Container) { $dstBox.Text = $gz2 }
    }
    if ($srcBox -and [string]::IsNullOrWhiteSpace($srcBox.Text)) {
        $tphd = Join-Path $app 'tphd'
        if (Test-Path -LiteralPath $tphd -PathType Container) { $srcBox.Text = $tphd }
    }
    Write-Log ("Build $($script:GuiBuildTag) — folders auto-filled from app folder when present.") $ColorFgDim
})
$form.Add_Resize({ if ($script:glassLog) { $script:glassLog.Invalidate() } })
$logCard.Add_Resize({ if ($script:glassLog) { $script:glassLog.Invalidate() } })

# Log scroll handled inside GlassLogView.OnMouseWheel (correct extent + transform).

# ---------- Status / glowing progress pill / test button ----------
$progress = New-GlowProgress
$progress.Location = New-Object System.Drawing.Point(20, ($form.ClientSize.Height - 42))
$progress.Size = New-Object System.Drawing.Size(400, 32)
$progress.Anchor = 'Bottom,Left'
$form.Controls.Add($progress)

$testBarBtn = New-Object System.Windows.Forms.Button
$testBarBtn.Text = 'Test Bar'
$testBarBtn.Location = New-Object System.Drawing.Point(428, ($form.ClientSize.Height - 40))
$testBarBtn.Size = New-Object System.Drawing.Size(90, 28)
$testBarBtn.Anchor = 'Bottom,Left'
$testBarBtn.FlatStyle = 'Flat'
$testBarBtn.BackColor = $ColorBgAlt
$testBarBtn.ForeColor = $ColorFg
$testBarBtn.Font = $FontBold
$testBarBtn.FlatAppearance.BorderColor = $ColorAccent2
$testBarBtn.FlatAppearance.MouseOverBackColor = $ColorBorder
$form.Controls.Add($testBarBtn)

$isoInstallBtn = New-Object System.Windows.Forms.Button
$isoInstallBtn.Text = 'Install to ISO'
$isoInstallBtn.Location = New-Object System.Drawing.Point(524, ($form.ClientSize.Height - 40))
$isoInstallBtn.Size = New-Object System.Drawing.Size(138, 28)
$isoInstallBtn.AutoEllipsis = $true
$isoInstallBtn.Anchor = 'Bottom,Left'
$isoInstallBtn.FlatStyle = 'Flat'
$isoInstallBtn.BackColor = $ColorBgAlt
$isoInstallBtn.ForeColor = $ColorAccent2
$isoInstallBtn.Font = $FontBold
$isoInstallBtn.FlatAppearance.BorderColor = $ColorAccent2
$isoInstallBtn.FlatAppearance.MouseOverBackColor = $ColorBorder
$form.Controls.Add($isoInstallBtn)

$aboutBtn = New-Object System.Windows.Forms.Button
$aboutBtn.Text = 'About'
$aboutBtn.Location = New-Object System.Drawing.Point(662, ($form.ClientSize.Height - 40))
$aboutBtn.Size = New-Object System.Drawing.Size(72, 28)
$aboutBtn.Anchor = 'Bottom,Left'
$aboutBtn.FlatStyle = 'Flat'
$aboutBtn.BackColor = $ColorBgAlt
$aboutBtn.ForeColor = $ColorFg
$aboutBtn.Font = $FontBold
$aboutBtn.FlatAppearance.BorderColor = $ColorAccent
$aboutBtn.FlatAppearance.MouseOverBackColor = $ColorBorder
$form.Controls.Add($aboutBtn)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = 'Ready.'
$statusLabel.Location = New-Object System.Drawing.Point(610, ($form.ClientSize.Height - 36))
$statusLabel.Size = New-Object System.Drawing.Size(240, 22)
$statusLabel.Anchor = 'Bottom,Right'
$statusLabel.ForeColor = $ColorFg
$statusLabel.BackColor = [System.Drawing.Color]::Transparent
$statusLabel.Font = $FontBold
$statusLabel.TextAlign = 'MiddleRight'
$form.Controls.Add($statusLabel)

$form.Add_Resize({ Update-MainLayout })
Update-MainLayout
Set-TitleBarControlsOnTop
$progress.BringToFront()
$testBarBtn.BringToFront()
$isoInstallBtn.BringToFront()
$aboutBtn.BringToFront()
$statusLabel.BringToFront()

$isoInstallBtn.Add_Click({
    try {
        Show-TextureGlitchyDialog
    }
    catch {
        $em = $_.Exception.Message
        [void][System.Windows.Forms.MessageBox]::Show($form, $em, 'Install to ISO',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error)
    }
})
$aboutBtn.Add_Click({ Show-AboutTool })

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------

function Write-RunLogFile {
    param([string]$Message)
    try {
        $path = Join-Path (Get-ModMergerAppFolder) 'merge-run.log'
        $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
        Add-Content -LiteralPath $path -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch { }
}

function Write-Log {
    param([string]$Message, [System.Drawing.Color]$Color = $ColorFg)
    if ($script:glassLog) {
        $script:glassLog.AppendLine($Message, $Color)
    }
    [System.Windows.Forms.Application]::DoEvents()
}

function Test-FolderHasTexPng {
    param([string]$Folder)
    if ([string]::IsNullOrWhiteSpace($Folder) -or -not (Test-Path -LiteralPath $Folder)) { return $false }
    $root = Resolve-ModContentRoot -ExtractedFolder $Folder
    return [bool](Get-ChildItem -LiteralPath $root -Filter 'tex*.png' -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1)
}

function Set-Status {
    param([string]$Text, [System.Drawing.Color]$Color = $ColorFg)
    $statusLabel.Text = $Text
    $statusLabel.ForeColor = $Color
    [System.Windows.Forms.Application]::DoEvents()
}

function Show-AboutTool {
    $gbTxtPath = Join-Path $scriptDir 'gamebanana-mods.txt'
    $aboutText = @"
MOD MERGER - DOWNLOAD AND CONVERTER TOOL
by Martinnes

WHAT THIS APP DOES
  Builds one finished Twilight Princess / Dusk texture pack (GZ2 folder)
  from your base pack, another pack, and optional GameBanana mods.

GAMECUBE MOD INJECTOR (Install to ISO)  *** EASY GUIDE ***
  This is SEPARATE from the texture pack merge above.
  It puts a mod INSIDE your GameCube game disc file (.iso or .gcm)
  so Dolphin or a real console can play the modded game.

  WHEN TO USE IT
    - You have a full game ISO (your Twilight Princess disc image).
    - You downloaded a mod that comes as a .zip made for ISO patching.
    - You do NOT use this for normal GZ2 texture folders (use Run Full Merge for those).

  HOW TO OPEN IT
    Click the "Install to ISO" button at the bottom of the main window
    (next to About).

  WHAT TO DO (STEP BY STEP)
    1. GameCube ISO = Browse and pick your .iso or .gcm game file.
    2. Mod ZIP = Browse and pick the mod .zip file.
    3. Click "Scan ZIP safety" first.
       The app checks the zip is a real mod layout and not dangerous junk.
       Green message = good. Red = do not install.
    4. Leave "Replace original ISO" ON if you want to update that same file
       (the app makes a .bak backup once before changing it).
    5. Click "Install ZIP into ISO" and confirm.

  WHAT A GOOD MOD ZIP LOOKS LIKE
    When you open the zip, you should see two folders:
      files  (game data — textures, models, etc.)
      sys    (sometimes empty or small — system files)
    Sometimes they are inside one extra folder — that is OK.

  WHAT THE SCAN CHECKS (IN SIMPLE WORDS)
    - Zip is not empty or broken.
    - No weird PC virus-style files (.exe, .bat, etc.).
    - Has a proper files folder with real game files inside.
    - sys folder only has safe GameCube system files (if any).
    - If you picked an ISO, it also checks the mod actually matches that disc.

  IF INSTALL FAILS
    You need Python on your PC (install from python.org).
    First time only, open Command Prompt and run:
      py -3.12 -m pip install "gclib @ git+https://github.com/LagoLunatic/gclib.git"
    Always keep a backup copy of your ISO before patching.


THE LINKS TXT FILE (gamebanana-mods.txt)  *** IMPORTANT ***
  This is a plain text file that lists GameBanana mods to download.

  WHERE IT LIVES
    Default name: gamebanana-mods.txt
    Same folder as Start Mod Merger.vbs (portable — copy the whole folder anywhere).
    Full path on this PC:
      $gbTxtPath
    Downloaded mod .zip files are saved in that same folder.

  WHERE YOU SET IT IN THE APP
    Scroll to the "GameBanana downloader" card.
    The "Links file" box should show that path (or Browse... to pick
    another .txt file). Run Full Merge uses whatever path is shown there.

  HOW TO CREATE OR EDIT IT
    1. Open Notepad.
    2. Paste one direct download URL per line (see examples below).
    3. Save as gamebanana-mods.txt in the app folder (same place as
       Launch.bat), OR save anywhere and use Browse... in the app.

  WHAT TO PUT IN THE FILE (RULES)
    - ONE direct download URL per line.
    - Use links that look like: https://gamebanana.com/dl/1234567
    - Do NOT use mod PAGE links like: https://gamebanana.com/mods/12345
      (those are skipped - the app needs the real file download link).
    - Blank lines are OK.
    - Lines starting with # or // or ; are comments (notes for you).

  HOW TO GET THE CORRECT /dl/ LINK
    1. Open the mod on GameBanana in your browser.
    2. Click Download and start the file download.
    3. Copy the URL from the browser address bar or download list.
       It should contain /dl/ not /mods/.

  EXAMPLE gamebanana-mods.txt
    # My Twilight Princess texture mods
    https://gamebanana.com/dl/1688162
    https://gamebanana.com/dl/1648116

  IF YOU SKIP THE TXT FILE
    Leave the Links file empty, or delete the path - folder merge still
    works. GameBanana download steps are simply skipped.

  AFTER DOWNLOAD
    .zip files land in the app folder (same place as the .txt file).
    Run Full Merge also unzips, converts PNG to DDS, and appends into your
    base pack (Step 2) when you set a destination folder.


QUICK START (EASIEST PATH)
  1. Step 1: Choose "Append missing files".
  2. Step 2 (top to bottom):
     1. Base pack = YOUR main GZ2 folder (example: Henriko\GZ2).
     2. Add from = the OTHER pack GZ2 folder (example: TPHD\GZ2).
     You can swap them - base is always the pack you want to KEEP.
  3. Edit gamebanana-mods.txt (see section above) OR use Browse...
  4. Check the Links file path in the GameBanana card.
  5. Turn ON "Dry run" and click "Scan / Preview".
  6. Turn dry run OFF and click "Run Full Merge".


WHAT "RUN FULL MERGE" DOES (IN ORDER)
  1. Downloads mods from your links .txt file (if path is set).
  2. Converts PNG to DDS in the "Add from" folder(s).
  3. Merges missing files from other pack(s) INTO your base pack.
  4. Converts PNG to DDS in the base pack.
  5. Unzips downloaded mods, converts PNG to DDS, appends into base pack.

  New files go into -Imported subfolders.


OTHER BUTTONS
  Scan / Preview - Plan only. No files copied.
  Download mods - GameBanana only (uses the same links .txt file).
  Convert PNG to DDS - Manual folder convert (needs texconv.exe).
  Test Bar - Checks the progress bar.


FOLDER TIP (HENRIKO + TPHD)
  Row 1 Base pack = the pack you keep (Henriko\GZ2 OR TPHD\GZ2).
  Row 2 Add from = the other pack's GZ2 folder.
  Row 3 Optional = only if you have a third pack.


NEEDS TEXCONV FOR PNG
  DuskModConverter\texconv.exe next to this app.


SAFETY
  Keep backups. Use Dry run first. Read the Log at the bottom.
"@

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'About this tool'
    $dlg.Size = New-Object System.Drawing.Size(700, 640)
    $dlg.MinimumSize = New-Object System.Drawing.Size(560, 480)
    $dlg.StartPosition = 'CenterParent'
    $dlg.BackColor = $ColorBg
    $dlg.ForeColor = $ColorFg
    $dlg.Font = $FontMain
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false

    $box = New-Object System.Windows.Forms.RichTextBox
    $box.Location = New-Object System.Drawing.Point(16, 16)
    $box.Size = New-Object System.Drawing.Size(652, 540)
    $box.Anchor = 'Top,Bottom,Left,Right'
    $box.ReadOnly = $true
    $box.BackColor = $ColorBgInput
    $box.ForeColor = $ColorFg
    $box.Font = $FontMain
    $box.BorderStyle = 'FixedSingle'
    $box.Text = $aboutText
    $box.DetectUrls = $false
    $box.WordWrap = $true
    $box.ScrollBars = 'Vertical'
    $dlg.Controls.Add($box)

    $okBtn = New-Object System.Windows.Forms.Button
    $okBtn.Text = 'Close'
    $okBtn.Location = New-Object System.Drawing.Point(568, 564)
    $okBtn.Size = New-Object System.Drawing.Size(100, 32)
    $okBtn.Anchor = 'Bottom,Right'
    $okBtn.FlatStyle = 'Flat'
    $okBtn.BackColor = $ColorAccent
    $okBtn.ForeColor = [System.Drawing.Color]::FromArgb(20, 14, 8)
    $okBtn.Font = $FontBold
    $okBtn.DialogResult = 'OK'
    $dlg.Controls.Add($okBtn)
    $dlg.AcceptButton = $okBtn

    [void]$dlg.ShowDialog($form)
}

# ---------------------------------------------------------------------------
# Folder browse helper
# ---------------------------------------------------------------------------

function Select-FolderInteractive {
    param([string]$Description, [string]$InitialPath)

    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = $Description
    $dlg.ShowNewFolderButton = $false
    if ($InitialPath -and (Test-Path -LiteralPath $InitialPath -PathType Container)) {
        $dlg.SelectedPath = $InitialPath
    }
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        return $dlg.SelectedPath
    }
    return $null
}

$dstBtn.Add_Click({
    $p = Select-FolderInteractive -Description '1. BASE PACK - Your main GZ2 folder (the pack you KEEP and build on). Example: Henriko\GZ2 or TPHD\GZ2' -InitialPath $dstBox.Text
    if ($p) {
        $dstBox.Text = $p
        if ($pngFolderBox -and [string]::IsNullOrWhiteSpace($pngFolderBox.Text)) { $pngFolderBox.Text = $p }
    }
})

$srcBtn.Add_Click({
    $p = Select-FolderInteractive -Description '2. ADD FROM - The OTHER pack GZ2 folder (missing files copy FROM here into your base pack). Example: the pack that is NOT your base' -InitialPath $srcBox.Text
    if ($p) { $srcBox.Text = $p }
})

$outBtn.Add_Click({
    $p = Select-FolderInteractive -Description '3. OUTPUT FOLDER - Where the merged pack is saved (leave empty to merge in place into the base pack)' -InitialPath $outBox.Text
    if ($p) { $outBox.Text = $p }
})

$pngBrowseBtn.Add_Click({
    $p = Select-FolderInteractive -Description 'Folder to convert all PNG files to DDS (searches subfolders)' -InitialPath $pngFolderBox.Text
    if ($p) { $pngFolderBox.Text = $p }
})

function Get-PngConvertFolder {
    $folder = $pngFolderBox.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($folder) -and -not [string]::IsNullOrWhiteSpace($dstBox.Text)) {
        $folder = $dstBox.Text.Trim()
        $pngFolderBox.Text = $folder
    }
    if ([string]::IsNullOrWhiteSpace($folder) -or -not (Test-Path -LiteralPath $folder -PathType Container)) {
        return $null
    }
    return (Resolve-Path -LiteralPath $folder).Path
}

$pngPreviewBtn.Add_Click((Wrap-SafeUiEvent {
    $folder = Get-PngConvertFolder
    if (-not $folder) {
        [System.Windows.Forms.MessageBox]::Show(
            'Choose a valid folder first (or set Base pack in Step 2).',
            'Style pictures', 'OK', 'Warning') | Out-Null
    }
    else {
        $contentRoot = Resolve-ModContentRoot -ExtractedFolder $folder
        $styles = @(Get-ModStyleChoices -RootFolder $contentRoot)
        if ($styles.Count -lt 2) {
            [System.Windows.Forms.MessageBox]::Show(
                "This folder does not have multiple style subfolders with preview PNGs.`n`nFound $($styles.Count) style group(s). You can still use Convert PNG -> DDS for tex*.png files.",
                'Preview styles', 'OK', 'Information') | Out-Null
        }
        else {
            $picked = @(Show-ModStylePickerDialog -Styles $styles)
            if ($picked.Count -gt 0) {
                Write-Log ("Style preview: selected $($picked.Count) style(s) for convert.") $ColorOk
                foreach ($p in $picked) { Write-Log ("  - $($p.StyleName)") $ColorFgDim }
            } else {
                Write-Log 'Style preview closed (no styles selected).' $ColorWarn
            }
        }
    }
}))

$convertPngBtn.Add_Click({
    param($s, $e)
    try {
        if ($statusLabel) {
            Set-Status 'PNG convert: starting…' $ColorAccent
            [System.Windows.Forms.Application]::DoEvents()
        }
        Write-Log '--- Manual PNG -> DDS ---' $ColorAccent

        $folder = Get-PngConvertFolder
        if (-not $folder) {
            $pathHint = if ($pngFolderBox) { $pngFolderBox.Text.Trim() } else { '(empty)' }
            [void][System.Windows.Forms.MessageBox]::Show(
                $form,
                "Choose a valid folder for PNG convert.`n`nTip: Browse, or set Base pack in Step 2 so the path fills automatically.`n`nCurrent box:`n$pathHint",
                'PNG convert',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning)
            Set-Status 'PNG convert: choose a valid folder first.' $ColorWarn
        } else {
            $logFn = {
                param($msg, $kind)
                $color = switch ($kind) {
                    'err' { $ColorErr }; 'warn' { $ColorWarn }; 'ok' { $ColorOk }
                    'accent' { $ColorAccent }; 'dim' { $ColorFgDim }; default { $ColorFg }
                }
                Write-Log $msg $color
            }
            $includeAll = $false
            if ($pngConvertAllBox) { $includeAll = $pngConvertAllBox.Checked }
            $entireTreeNoPicker = $false
            if ($pngNoPickerBox) { $entireTreeNoPicker = $pngNoPickerBox.Checked }

            $convertPngBtn.Enabled = $false
            $scanBtn.Enabled = $false; $runBtn.Enabled = $false; $gbDownloadBtn.Enabled = $false; $testBarBtn.Enabled = $false; $isoInstallBtn.Enabled = $false; $aboutBtn.Enabled = $false
            try {
                & $logFn "Folder: $folder" 'dim'
                Set-Status 'Converting PNG to DDS…' $ColorFg
                Reset-GlowProgress -Bar $progress -Max 1
                $convertResult = Invoke-PngToDdsForFolder -Folder $folder -LogFn $logFn -ProgressBar $progress `
                    -PromptForStyle (-not $entireTreeNoPicker) -EntireTree $entireTreeNoPicker -IncludeAllPngs:$includeAll
                $nConv = 0
                if ($null -ne $convertResult -and $null -ne $convertResult.Count) { $nConv = [int]$convertResult.Count }
                if ($nConv -gt 0) {
                    Set-Status "Converted $nConv PNG file(s) to DDS." $ColorOk
                    $explorePath = Get-ExplorerPathFromConvertResult $convertResult
                    if (-not $explorePath) { $explorePath = $folder }
                    if (Open-FolderInExplorer -Path $explorePath -DelayMs 550) {
                        & $logFn "Opened in Explorer: $explorePath" 'dim'
                    }
                } else {
                    Set-Status 'No PNG files converted — see log or check folder/texconv.' $ColorWarn
                    [void][System.Windows.Forms.MessageBox]::Show(
                        $form,
                        "No files were converted.`n`nCommon causes:`n- Canceled the style picker`n- No tex*.png files (enable 'Convert all PNG files')`n- texconv.exe missing`n`nSee the Log panel for details.",
                        'PNG convert',
                        [System.Windows.Forms.MessageBoxButtons]::OK,
                        [System.Windows.Forms.MessageBoxIcon]::Information)
                }
            }
            catch {
                $em = $_.Exception.Message
                & $logFn ("ERROR: $em") 'err'
                if ($_.ScriptStackTrace) { & $logFn $_.ScriptStackTrace 'dim' }
                Set-Status 'PNG convert failed — see log.' $ColorErr
                [void][System.Windows.Forms.MessageBox]::Show($form, $em, 'PNG convert error',
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Error)
            }
            finally {
                $convertPngBtn.Enabled = $true
                $scanBtn.Enabled = $true; $runBtn.Enabled = $true; $gbDownloadBtn.Enabled = $true; $testBarBtn.Enabled = $true; $isoInstallBtn.Enabled = $true; $aboutBtn.Enabled = $true
            }
        }
    }
    catch {
        $em = $_.Exception.Message
        try { Write-Log "PNG convert (outer): $em" $ColorErr } catch { }
        [void][System.Windows.Forms.MessageBox]::Show($form, $em, 'PNG convert',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error)
        Set-Status 'PNG convert failed.' $ColorErr
    }
})

$clearBtn.Add_Click({ if ($script:glassLog) { $script:glassLog.ClearLines() }; Set-Status 'Ready.' $ColorFg })

$gbLinksBrowse.Add_Click({
    $ofd = New-Object System.Windows.Forms.OpenFileDialog
    $ofd.Title = 'Select .txt file with GameBanana direct download links'
    $ofd.Filter = 'Text files (*.txt)|*.txt|All files (*.*)|*.*'
    if ($gbLinksBox.Text -and (Test-Path -LiteralPath $gbLinksBox.Text)) {
        $ofd.InitialDirectory = Split-Path -Path $gbLinksBox.Text -Parent
        $ofd.FileName = [System.IO.Path]::GetFileName($gbLinksBox.Text)
    }
    if ($ofd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $gbLinksBox.Text = $ofd.FileName
    }
})

$gbDownloadBtn.Add_Click((Wrap-SafeUiEvent {
    if ([string]::IsNullOrWhiteSpace($gbLinksBox.Text) -or -not (Test-Path -LiteralPath $gbLinksBox.Text -PathType Leaf)) {
        [System.Windows.Forms.MessageBox]::Show(
            'Choose a .txt file with one direct GameBanana download URL per line.',
            'Links file required', 'OK', 'Warning') | Out-Null
    }
    else {
    $gbDownloadBtn.Enabled = $false
    $convertPngBtn.Enabled = $false
    $scanBtn.Enabled = $false; $runBtn.Enabled = $false; $testBarBtn.Enabled = $false; $isoInstallBtn.Enabled = $false; $aboutBtn.Enabled = $false
    Reset-GlowProgress -Bar $progress -Max 1
    $statusLabel.ForeColor = $ColorFg
    $statusLabel.Text = 'Downloading GameBanana mods...'
    $logFn = {
        param($msg, $kind)
        $color = switch ($kind) {
            'err'    { $ColorErr }
            'warn'   { $ColorWarn }
            'ok'     { $ColorOk }
            'accent' { $ColorFg }
            'dim'    { $ColorFg }
            default  { $ColorFg }
        }
        Write-Log $msg $color
    }
    try {
        $dlFolder = Get-GameBananaDownloadFolder
        & $logFn '--- GameBanana downloader ---' 'accent'
        & $logFn "Download folder (app folder): $dlFolder" 'dim'
        & $logFn "Links file: $($gbLinksBox.Text)" 'dim'
        $hasDst = (-not [string]::IsNullOrWhiteSpace($dstBox.Text)) -and (Test-Path -LiteralPath $dstBox.Text -PathType Container)
        if ($hasDst) {
            $dst = (Resolve-Path -LiteralPath $dstBox.Text).Path
            & $logFn "Merge into base pack: $dst" 'dim'
            Invoke-GameBananaBatchFromFile -LinksFile $gbLinksBox.Text -TargetFolder $dst -LogFn $logFn -ProgressBar $progress
        } else {
            & $logFn 'No base pack set — downloading only (zips saved in app folder).' 'warn'
            Invoke-GameBananaBatchFromFile -LinksFile $gbLinksBox.Text -LogFn $logFn -ProgressBar $progress -DownloadOnly
        }
        $statusLabel.Text = 'GameBanana download finished.'
        $statusLabel.ForeColor = $ColorOk
    }
    catch {
        & $logFn ("ERROR: $($_.Exception.Message)") 'err'
        if ($_.ScriptStackTrace) { & $logFn $_.ScriptStackTrace 'dim' }
        $statusLabel.Text = 'Download failed - see log.'
        $statusLabel.ForeColor = $ColorErr
    }
    finally {
        $gbDownloadBtn.Enabled = $true
        $convertPngBtn.Enabled = $true
        $scanBtn.Enabled = $true; $runBtn.Enabled = $true; $testBarBtn.Enabled = $true; $isoInstallBtn.Enabled = $true; $aboutBtn.Enabled = $true
    }
    }
}))

$testBarBtn.Add_Click({
    try {
        Write-Log 'Testing progress bar...' $ColorAccent
        Reset-GlowProgress -Bar $progress -Max 100
        for ($i = 0; $i -le 100; $i += 5) {
            Set-GlowProgressState -Bar $progress -Value $i
            Set-Status ("Testing progress... $i%") $ColorFg
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 25
        }
        Set-Status 'Test complete.' $ColorOk
        Write-Log 'Progress bar test complete.' $ColorOk
    }
    catch {
        Write-Log ("Test bar error: $($_.Exception.Message)") $ColorErr
        Set-Status 'Test failed - see log.' $ColorErr
    }
})

# ---------------------------------------------------------------------------
# Duplicate filename resolver
# ---------------------------------------------------------------------------

function Select-DuplicateSourceFile {
    param([string]$FileName, [System.IO.FileInfo[]]$Files)

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Choose source for '$FileName'"
    $dlg.Size = New-Object System.Drawing.Size(700, 380)
    $dlg.StartPosition = 'CenterParent'
    $dlg.BackColor = $ColorBg
    $dlg.ForeColor = $ColorFg
    $dlg.Font = $FontMain
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = "Multiple source files share the name '$FileName'. Pick the one to use:"
    $lbl.Location = New-Object System.Drawing.Point(15, 15)
    $lbl.Size = New-Object System.Drawing.Size(660, 36)
    $lbl.ForeColor = $ColorWarn
    $dlg.Controls.Add($lbl)

    $list = New-Object System.Windows.Forms.ListBox
    $list.Location = New-Object System.Drawing.Point(15, 55)
    $list.Size = New-Object System.Drawing.Size(660, 230)
    $list.BackColor = $ColorBgInput
    $list.ForeColor = $ColorFg
    $list.Font = $FontMono
    $list.BorderStyle = 'FixedSingle'
    foreach ($f in $Files) { [void]$list.Items.Add($f.FullName) }
    $list.SelectedIndex = 0
    $dlg.Controls.Add($list)

    $okBtn = New-Object System.Windows.Forms.Button
    $okBtn.Text = 'Use selected'
    $okBtn.Location = New-Object System.Drawing.Point(465, 300)
    $okBtn.Size = New-Object System.Drawing.Size(100, 28)
    $okBtn.FlatStyle = 'Flat'
    $okBtn.BackColor = $ColorAccent
    $okBtn.ForeColor = [System.Drawing.Color]::Black
    $okBtn.DialogResult = 'OK'
    $dlg.Controls.Add($okBtn)
    $dlg.AcceptButton = $okBtn

    $cancelBtn = New-Object System.Windows.Forms.Button
    $cancelBtn.Text = 'Cancel'
    $cancelBtn.Location = New-Object System.Drawing.Point(575, 300)
    $cancelBtn.Size = New-Object System.Drawing.Size(100, 28)
    $cancelBtn.FlatStyle = 'Flat'
    $cancelBtn.BackColor = $ColorBgAlt
    $cancelBtn.ForeColor = $ColorFg
    $cancelBtn.FlatAppearance.BorderColor = $ColorBorder
    $cancelBtn.DialogResult = 'Cancel'
    $dlg.Controls.Add($cancelBtn)
    $dlg.CancelButton = $cancelBtn

    if ($dlg.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
        return $Files[$list.SelectedIndex]
    }
    return $null
}

# ---------------------------------------------------------------------------
# Core merge plan
# ---------------------------------------------------------------------------

function Get-MergePlan {
    param(
        [string]$SourceFolder,
        [string]$SourceFolder2,
        [string]$TargetFolder,
        [ValidateSet('Replace', 'AppendMissing')][string]$Mode,
        [string[]]$Source1StyleFolders = @(),
        [string[]]$Source2StyleFolders = @()
    )

    $src1Root = Resolve-ModContentRoot -ExtractedFolder $SourceFolder
    $src2Root = $null
    if (-not [string]::IsNullOrWhiteSpace($SourceFolder2)) {
        $src2Root = Resolve-ModContentRoot -ExtractedFolder $SourceFolder2
    }

    # Scan source folder 1
    Write-Log "Scanning source 1: $SourceFolder" $ColorFgDim
    Set-Status 'Scanning source 1...' $ColorFgDim
    $sourceEntries = New-Object System.Collections.Generic.List[object]
    foreach ($e in @(Get-AppendEntriesForSourceRoot -Root $SourceFolder -SelectedStyleFolders $Source1StyleFolders)) {
        $sourceEntries.Add($e)
    }

    # Scan source folder 2 if provided
    if ($src2Root) {
        Write-Log "Scanning source 2: $SourceFolder2" $ColorFgDim
        Set-Status 'Scanning source 2...' $ColorFgDim
        foreach ($e in @(Get-AppendEntriesForSourceRoot -Root $SourceFolder2 -SelectedStyleFolders $Source2StyleFolders)) {
            $sourceEntries.Add($e)
        }
    }

    # Allowlist: only final .dds texture files are merged. Anything else
    # (preview PNG, .pdn / .psd source, .txt readme, .bak, etc.) is dropped.
    $filtered = New-Object System.Collections.Generic.List[object]
    $nonDdsDrops = 0
    foreach ($e in $sourceEntries) {
        if ($e.File.Name -in $script:ExcludedFileNames) { continue }
        if (-not (Test-IsAllowedForMerge -File $e.File)) { $nonDdsDrops++; continue }
        $filtered.Add($e)
    }
    $excludedCount = $sourceEntries.Count - $filtered.Count
    if ($excludedCount -gt 0) {
        $extPart = if ($nonDdsDrops -gt 0) { " ($nonDdsDrops non-.dds files like .pdn / .psd / .txt skipped — only .dds is copied)" } else { '' }
        Write-Log "Excluded $excludedCount source file(s) by allowlist$extPart." $ColorWarn
    }
    Write-Log "Total source files: $($filtered.Count)" $ColorFg

    if ($filtered.Count -eq 0) {
        Write-Log 'No .dds files found in source yet. Run PNG conversion first, or check folder paths.' $ColorWarn
        return @()
    }

    Write-Log "Scanning destination: $TargetFolder" $ColorFgDim
    Set-Status 'Scanning destination...' $ColorFgDim
    $targetFiles = @(Get-ChildItem -LiteralPath $TargetFolder -File -Recurse)
    Write-Log "Destination files: $($targetFiles.Count)" $ColorFg

    $plan = New-Object System.Collections.Generic.List[object]

    if ($Mode -eq 'Replace') {
        # Replace mode: allowlist final .dds textures only.
        $filtered = New-Object System.Collections.Generic.List[object]
        foreach ($f in @(Get-ChildItem -LiteralPath $SourceFolder -File -Recurse)) {
            if ($f.Name -in $script:ExcludedFileNames) { continue }
            if (-not (Test-IsAllowedForMerge -File $f)) { continue }
            $filtered.Add([pscustomobject]@{ File = $f; Root = $SourceFolder })
        }
        if ($src2Root) {
            foreach ($f in @(Get-ChildItem -LiteralPath $SourceFolder2 -File -Recurse)) {
                if ($f.Name -in $script:ExcludedFileNames) { continue }
                if (-not (Test-IsAllowedForMerge -File $f)) { continue }
                $filtered.Add([pscustomobject]@{ File = $f; Root = $SourceFolder2 })
            }
        }
        # Build name -> chosen entry map. If duplicates across sources, ask which to use.
        $sourceByName = @{}
        $groups = $filtered | Group-Object -Property { $_.File.Name }
        foreach ($g in $groups) {
            if ($g.Count -eq 1) {
                $sourceByName[$g.Name] = $g.Group[0]
            }
            else {
                $files = [System.IO.FileInfo[]]($g.Group | ForEach-Object { $_.File })
                $picked = Select-DuplicateSourceFile -FileName $g.Name -Files $files
                if (-not $picked) {
                    Write-Log "Cancelled at duplicate resolution for '$($g.Name)'." $ColorWarn
                    return $null
                }
                $pickedEntry = $g.Group | Where-Object { $_.File.FullName -eq $picked.FullName } | Select-Object -First 1
                $sourceByName[$g.Name] = $pickedEntry
            }
        }

        foreach ($t in $targetFiles) {
            if ($sourceByName.ContainsKey($t.Name)) {
                $plan.Add([pscustomobject]@{
                    Source      = $sourceByName[$t.Name].File
                    Destination = $t.FullName
                    Action      = 'Replace'
                })
            }
        }
    }
    else {
        $alreadyPlanned = @{}
        Add-AppendEntriesToPlan -PlanList $plan -SourceEntries $filtered -TargetFolder $TargetFolder `
            -TargetFiles $targetFiles -AlreadyPlannedByName $alreadyPlanned
    }

    return $plan
}

function Show-Plan {
    param($Plan, [string]$Mode)

    $items = @($Plan)
    if (-not $items -or $items.Count -eq 0) {
        if ($Mode -eq 'Replace') {
            Write-Log 'No destination files matched source filenames. Nothing to replace.' $ColorWarn
        } else {
            Write-Log 'No source files were missing from the destination. Nothing to append.' $ColorWarn
        }
        return
    }

    Write-Log ''
    if ($Mode -eq 'Replace') {
        Write-Log "Planned replacements ($($Plan.Count)):" $ColorAccent
    } else {
        Write-Log "Planned new files ($($Plan.Count)):" $ColorAccent
    }

    $max = [Math]::Min($items.Count, 200)
    for ($i = 0; $i -lt $max; $i++) {
        $p = $items[$i]
        Write-Log ("  [{0}] {1}" -f $p.Action.ToUpper(), $p.Destination) $ColorFg
        Write-Log ("       from  {0}" -f $p.Source.FullName) $ColorFgDim
    }
    if ($items.Count -gt $max) {
        Write-Log ("  ... and $($items.Count - $max) more (full list omitted for brevity)") $ColorFgDim
    }
}

function Invoke-Plan {
    param($Plan)

    $items = @($Plan)
    if ($items.Count -eq 0) { return }

    $total = $items.Count
    Reset-GlowProgress -Bar $progress -Max $total
    Write-Log ("Copying $total file(s)... (progress updates every 100 files)") $ColorAccent
    Set-Status "Merging 0 / $total..." $ColorFg

    $ok = 0; $fail = 0
    $logEvery = if ($total -gt 500) { 100 } elseif ($total -gt 100) { 50 } else { 10 }
    $uiEvery = if ($total -gt 200) { 25 } else { 5 }

    foreach ($p in $items) {
        try {
            $destFolder = Split-Path -Path $p.Destination -Parent
            if ($destFolder -and -not (Test-Path -LiteralPath $destFolder -PathType Container)) {
                New-Item -ItemType Directory -Path $destFolder -Force | Out-Null
            }
            Copy-Item -LiteralPath $p.Source.FullName -Destination $p.Destination -Force
            $ok++
            if ($ok -eq 1 -or $ok % $logEvery -eq 0 -or $ok -eq $total) {
                Write-Log ("  $ok / $total copied...") $ColorFgDim
                Set-Status "Merging $ok / $total..." $ColorAccent2
            }
        }
        catch {
            $fail++
            Write-Log ("ERR {0}  ({1})" -f $p.Destination, $_.Exception.Message) $ColorErr
        }
        Step-GlowProgress -Bar $progress
        if ($ok % $uiEvery -eq 0) { [System.Windows.Forms.Application]::DoEvents() }
    }

    Write-Log ''
    $doneColor = if ($fail -gt 0) { $ColorWarn } else { $ColorOk }
    Write-Log ("Done. Succeeded: $ok   Failed: $fail") $doneColor
    Set-Status ("Done. $ok ok, $fail failed.") $doneColor
}

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

function Show-InputWarning {
    param([string]$Msg, [string]$Title, [string]$Icon = 'Warning')
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        $color = if ($Icon -eq 'Error') { $ColorErr } else { $ColorWarn }
        Write-Log ("Cannot start: $Msg") $color
    }
    [System.Windows.Forms.MessageBox]::Show($form, $Msg, $Title, 'OK', $Icon) | Out-Null
}

function Test-Inputs {
    if ([string]::IsNullOrWhiteSpace($srcBox.Text)) {
        Show-InputWarning -Msg 'Please fill "2. Add from" — the pack that supplies missing files.' -Title 'Missing "Add from"'
        return $false
    }
    if ([string]::IsNullOrWhiteSpace($dstBox.Text)) {
        Show-InputWarning -Msg 'Please fill "1. Base pack" — your starting pack.' -Title 'Missing base pack'
        return $false
    }
    if (-not (Test-Path -LiteralPath $srcBox.Text -PathType Container)) {
        Show-InputWarning -Msg "'Add from' folder not found:`n$($srcBox.Text)" -Title '"Add from" not found' -Icon 'Error'
        return $false
    }
    if (-not (Test-Path -LiteralPath $dstBox.Text -PathType Container)) {
        Show-InputWarning -Msg "Base pack folder not found:`n$($dstBox.Text)" -Title 'Base pack not found' -Icon 'Error'
        return $false
    }
    $srcResolved = (Resolve-Path -LiteralPath $srcBox.Text).Path
    $dstResolved = (Resolve-Path -LiteralPath $dstBox.Text).Path
    if ([string]::Equals($srcResolved, $dstResolved, [System.StringComparison]::OrdinalIgnoreCase)) {
        Show-InputWarning -Msg '"Base pack" and "Add from" must be different folders.' -Title 'Same folder'
        return $false
    }
    # Output folder is optional. If set it cannot equal "Add from" (source).
    # If output equals base, that is treated as in-place merge.
    if (-not [string]::IsNullOrWhiteSpace($outBox.Text)) {
        $outRaw = $outBox.Text.Trim()
        if (Test-Path -LiteralPath $outRaw -PathType Container) {
            $outResolved = (Resolve-Path -LiteralPath $outRaw).Path
            if ([string]::Equals($outResolved, $srcResolved, [System.StringComparison]::OrdinalIgnoreCase)) {
                Show-InputWarning -Msg 'Output folder must be different from the "Add from" source.' -Title 'Same folder'
                return $false
            }
        }
        else {
            try {
                $parent = Split-Path -Path $outRaw -Parent
                if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
                    Show-InputWarning -Msg "Output folder parent does not exist:`n$parent" -Title 'Output folder' -Icon 'Error'
                    return $false
                }
            } catch {
                Show-InputWarning -Msg "Output folder path is not valid:`n$outRaw" -Title 'Output folder' -Icon 'Error'
                return $false
            }
        }
    }
    return $true
}

# ---------------------------------------------------------------------------
# Button handlers
# ---------------------------------------------------------------------------

function Get-SelectedMode {
    if ($rbReplace.Checked) { return 'Replace' }
    return 'AppendMissing'
}

function Confirm-AppendMergeDirection {
    param(
        [string]$SourceFolder,
        [string]$BasePack,
        [string]$TargetFolder
    )
    $msg = 'Append missing files - confirm folders (Step 2):' + [Environment]::NewLine + [Environment]::NewLine
    $msg += '  1. BASE pack (kept as-is, used as the starting point):' + [Environment]::NewLine + '    ' + $BasePack + [Environment]::NewLine + [Environment]::NewLine
    $msg += '  2. ADD FROM (missing files copied from here):' + [Environment]::NewLine + '    ' + $SourceFolder + [Environment]::NewLine
    $msg += [Environment]::NewLine + '  3. OUTPUT (final merged pack is saved here):' + [Environment]::NewLine + '    ' + $TargetFolder + [Environment]::NewLine
    if ([string]::Equals($BasePack, $TargetFolder, [System.StringComparison]::OrdinalIgnoreCase)) {
        $msg += '    (same as base pack — merging IN PLACE)' + [Environment]::NewLine
    } else {
        $msg += '    (separate folder — base pack is NOT modified)' + [Environment]::NewLine
    }
    $msg += [Environment]::NewLine + 'Only .dds textures are copied. New folders get an -Imported suffix.' + [Environment]::NewLine + [Environment]::NewLine + 'Continue?'
    try { $form.Activate() } catch {}
    $r = [System.Windows.Forms.MessageBox]::Show(
        $form, $msg, 'Append missing files - confirm folders',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question,
        [System.Windows.Forms.MessageBoxDefaultButton]::Button1)
    return ($r -eq [System.Windows.Forms.DialogResult]::Yes)
}

function Test-GameBananaLinksReady {
    if ($gbLinksBox -and [string]::IsNullOrWhiteSpace($gbLinksBox.Text)) {
        $gbLinksBox.Text = Ensure-GameBananaLinksFile -Root (Get-ModMergerAppFolder)
    }
    if ([string]::IsNullOrWhiteSpace($gbLinksBox.Text)) { return $false }
    return (Test-Path -LiteralPath $gbLinksBox.Text -PathType Leaf)
}

function Initialize-OutputFromBase {
    param(
        [string]$BasePack,
        [string]$OutputFolder,
        [bool]$DryRun,
        [scriptblock]$LogFn
    )
    if ([string]::IsNullOrWhiteSpace($OutputFolder)) { return $BasePack }
    if ([string]::Equals($OutputFolder, $BasePack, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $BasePack
    }
    if (-not (Test-Path -LiteralPath $OutputFolder -PathType Container)) {
        if ($DryRun) {
            if ($LogFn) { & $LogFn "Dry run: would create output folder: $OutputFolder" 'warn' }
        } else {
            New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
            if ($LogFn) { & $LogFn "Created output folder: $OutputFolder" 'ok' }
        }
    }
    $alreadyHas = @(Get-ChildItem -LiteralPath $OutputFolder -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($alreadyHas.Count -gt 0) {
        if ($LogFn) { & $LogFn 'Output folder already has files — skipping base-pack copy.' 'dim' }
        return $OutputFolder
    }
    if ($DryRun) {
        if ($LogFn) { & $LogFn "Dry run: would copy base pack -> output folder ($BasePack -> $OutputFolder)" 'warn' }
        return $OutputFolder
    }
    $baseFileCount = @(Get-ChildItem -LiteralPath $BasePack -File -Recurse -ErrorAction SilentlyContinue).Count
    if ($LogFn) {
        & $LogFn "Copying base pack into output folder (~$baseFileCount files — can take several minutes)..." 'warn'
        & $LogFn 'Please wait — the log will update when copy finishes.' 'dim'
    }
    [System.Windows.Forms.Application]::DoEvents()
    try {
        $rcArgs = @($BasePack, $OutputFolder, '/E', '/COPY:DAT', '/R:1', '/W:1', '/NFL', '/NDL', '/NJH', '/NJS', '/nc', '/ns', '/np')
        $null = & robocopy @rcArgs 2>&1
        if ($LASTEXITCODE -lt 8) {
            if ($LogFn) { & $LogFn "Output folder seeded from base pack." 'ok' }
        } else {
            if ($LogFn) { & $LogFn "robocopy returned code $LASTEXITCODE — falling back to Copy-Item." 'warn' }
            Copy-Item -LiteralPath (Join-Path $BasePack '*') -Destination $OutputFolder -Recurse -Force -ErrorAction SilentlyContinue
        }
    } catch {
        if ($LogFn) { & $LogFn "robocopy unavailable — using Copy-Item: $($_.Exception.Message)" 'warn' }
        Copy-Item -LiteralPath (Join-Path $BasePack '*') -Destination $OutputFolder -Recurse -Force -ErrorAction SilentlyContinue
    }
    return $OutputFolder
}

function Invoke-FullMergePipeline {
    param(
        [ValidateSet('Replace', 'AppendMissing')][string]$Mode,
        [string]$SourceFolder,
        [string]$BasePack,
        [string]$OutputFolder,
        [bool]$DryRun,
        [bool]$IncludeGameBanana,
        [bool]$SkipConfirm = $false
    )

    $linksPath = $null
    if ($IncludeGameBanana -and (Test-GameBananaLinksReady)) {
        $linksPath = (Resolve-Path -LiteralPath $gbLinksBox.Text).Path
    }

    # Decide TargetFolder: if Output is set and different from Base, seed it from base then write there.
    $TargetFolder = $BasePack
    if (-not [string]::IsNullOrWhiteSpace($OutputFolder)) {
        $TargetFolder = Initialize-OutputFromBase -BasePack $BasePack -OutputFolder $OutputFolder -DryRun $DryRun -LogFn ({
            param($m, $k)
            $color = switch ($k) { 'err' { $ColorErr } 'warn' { $ColorWarn } 'ok' { $ColorOk } 'accent' { $ColorAccent } default { $ColorFg } }
            Write-Log $m $color
        })
    }

    if ($Mode -eq 'AppendMissing' -and -not $SkipConfirm) {
        if (-not (Confirm-AppendMergeDirection -SourceFolder $SourceFolder -BasePack $BasePack -TargetFolder $TargetFolder)) {
            Write-Log 'Cancelled - append folder direction not confirmed.' $ColorWarn
            Set-Status 'Cancelled.' $ColorWarn
            return
        }
    }

    $logFn = {
        param($msg, $kind)
        $color = switch ($kind) {
            'err'    { $ColorErr }
            'warn'   { $ColorWarn }
            'ok'     { $ColorOk }
            'accent' { $ColorFg }
            'dim'    { $ColorFg }
            default  { $ColorFg }
        }
        Write-Log $msg $color
    }

    $gbDownloads = @()

    if ($DryRun) {
        Write-Log '*** DRY RUN ON — nothing will be written to disk. Uncheck "Dry run only" to merge for real. ***' $ColorWarn
    } else {
        Write-Log 'Live merge — files will be copied to your target folder.' $ColorOk
    }

    $src1StyleFolders = @()

    Write-Log '=== Step 1/3: Convert PNG -> DDS in "Add from" (if needed) ===' $ColorAccent
    Set-Status 'Converting PNG in source...' $ColorFg
    if ($DryRun) {
        Write-Log 'Dry run: would convert PNGs in source folder with texconv.' $ColorWarn
    } elseif (Test-FolderHasTexPng -Folder $SourceFolder) {
        $r1 = Invoke-PngToDdsForFolder -Folder $SourceFolder -LogFn $logFn -ProgressBar $progress -PromptForStyle $true
        $src1StyleFolders = @($r1.SelectedStyleFolders)
    } else {
        Write-Log 'No tex*.png in source — skipping PNG conversion (using existing .dds files).' $ColorFgDim
    }

    Write-Log '=== Step 2/3: Merge "Add from" into target ===' $ColorAccent
    Set-Status 'Building merge plan...' $ColorFg
    $plan = Get-MergePlan -SourceFolder $SourceFolder -SourceFolder2 '' -TargetFolder $TargetFolder -Mode $Mode `
        -Source1StyleFolders $src1StyleFolders -Source2StyleFolders @()
    if ($null -eq $plan) {
        Write-Log 'Folder merge cancelled (duplicate file choice or scan error).' $ColorWarn
        Set-Status 'Merge cancelled.' $ColorWarn
        return
    }
    Show-Plan -Plan @($plan) -Mode $Mode
    if (@($plan).Count -eq 0) {
        Write-Log 'Folder merge: nothing to copy from sources.' $ColorWarn
    } elseif ($DryRun) {
        Write-Log ("Dry run: would merge $($plan.Count) file(s) from source(s) into destination.") $ColorWarn
    } else {
        $doCopy = $true
        if (-not $SkipConfirm) {
            $warn = if ($Mode -eq 'Replace') {
                "Overwrite $($plan.Count) file(s) in destination?`n$TargetFolder"
            } else {
                "Copy $($plan.Count) missing file(s) into destination?`n$TargetFolder"
            }
            try { $form.Activate() } catch {}
            $c = [System.Windows.Forms.MessageBox]::Show(
                $form, $warn, 'Confirm folder merge',
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Warning,
                [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
            $doCopy = ($c -eq [System.Windows.Forms.DialogResult]::Yes)
        }
        if ($doCopy) {
            Set-Status 'Merging folders...' $ColorFg
            Invoke-Plan -Plan @($plan)
        } else {
            Write-Log 'Folder merge cancelled by user.' $ColorWarn
        }
    }

    Write-Log '=== Step 3/3: Convert PNG -> DDS in destination (if needed) ===' $ColorAccent
    Set-Status 'Converting PNG in destination...' $ColorFg
    if ($DryRun) {
        Write-Log 'Dry run: would convert PNGs in destination with texconv.' $ColorWarn
    } elseif (Test-FolderHasTexPng -Folder $TargetFolder) {
        [void](Invoke-PngToDdsForFolder -Folder $TargetFolder -LogFn $logFn -ProgressBar $progress -PromptForStyle $true)
    } else {
        Write-Log 'No tex*.png in destination — skipping PNG conversion.' $ColorFgDim
    }

    if ($linksPath) {
        Write-Log '=== Optional: GameBanana mods ===' $ColorAccent
        Set-Status 'Downloading GameBanana mods...' $ColorAccent2
        if ($DryRun) {
            $n = @(Get-GameBananaLinksFromFile -Path $linksPath).Count
            Write-Log ("Dry run: would download $n mod(s), unzip, and append.") $ColorWarn
        } else {
            $gbDownloads = @(Invoke-GameBananaDownloadToCache -LinksFile $linksPath -DownloadFolder (Get-GameBananaDownloadFolder) -LogFn $logFn -ProgressBar $progress)
            Write-Log 'Unzipping GameBanana mods -> PNG to DDS -> append...' $ColorAccent
            Set-Status 'Extracting and merging GameBanana mods...' $ColorFg
            Invoke-GameBananaExtractAndMerge -TargetFolder $TargetFolder -DownloadFolder (Get-GameBananaDownloadFolder) -LogFn $logFn -ProgressBar $progress -DownloadedFiles $gbDownloads
        }
    } else {
        Write-Log 'GameBanana: skipped (checkbox off or no links file).' $ColorFgDim
    }

    Write-Log ''
    if ($DryRun) {
        Write-Log '*** DRY RUN FINISHED — no files were changed. Uncheck Dry run and click Run again to apply. ***' $ColorWarn
        Set-Status 'Dry run done — no files changed.' $ColorWarn
    } else {
        Write-Log 'Full pipeline finished — files were written.' $ColorOk
        Set-Status 'Merge finished — see log.' $ColorOk
    }
    if (-not $DryRun) {
        if (Open-FolderInExplorer -Path $TargetFolder -DelayMs 400) {
            $label = if ([string]::Equals($TargetFolder, $BasePack, [System.StringComparison]::OrdinalIgnoreCase)) { 'base pack' } else { 'output folder' }
            Write-Log "Opened $label in File Explorer: $TargetFolder" $ColorFgDim
        }
    }
}

$scanBtn.Add_Click((Wrap-SafeUiEvent {
    Write-Log '=== Scan / Preview clicked ===' $ColorAccent
    Set-Status 'Validating inputs...' $ColorFg
    if (-not (Test-Inputs)) {
        Set-Status 'Stopped — fix the input shown in the popup.' $ColorWarn
        return
    }
    if ($script:glassLog) { $script:glassLog.ClearLines() }
    Write-Log '=== Scan / Preview ===' $ColorAccent
    Reset-GlowProgress -Bar $progress -Max 100
    $convertPngBtn.Enabled = $false
    $scanBtn.Enabled = $false; $runBtn.Enabled = $false; $testBarBtn.Enabled = $false; $isoInstallBtn.Enabled = $false; $aboutBtn.Enabled = $false
    try {
        $mode = Get-SelectedMode
        Write-Log ("Mode: $mode") $ColorAccent
        $basePack = (Resolve-Path -LiteralPath $dstBox.Text).Path
        $addFrom = (Resolve-Path -LiteralPath $srcBox.Text).Path
        $target = $basePack
        if (-not [string]::IsNullOrWhiteSpace($outBox.Text)) {
            $outRaw = $outBox.Text.Trim()
            if (Test-Path -LiteralPath $outRaw -PathType Container) {
                $target = (Resolve-Path -LiteralPath $outRaw).Path
            } else {
                $target = $outRaw
            }
            Write-Log ("Output folder: $target (preview — would seed from base pack: $basePack)") $ColorFgDim
        }
        $plan = Get-MergePlan -SourceFolder $addFrom `
                              -SourceFolder2 '' `
                              -TargetFolder $target `
                              -Mode $mode
        if ($null -eq $plan) {
            Set-Status 'Scan cancelled or empty.' $ColorWarn
        }
        else {
            Show-Plan -Plan @($plan) -Mode $mode
            Set-Status ("Scan complete. $($plan.Count) planned operation(s).") $ColorOk
        }
    }
    catch {
        Write-Log ("ERROR: $($_.Exception.Message)") $ColorErr
        if ($_.ScriptStackTrace) { Write-Log $_.ScriptStackTrace $ColorFgDim }
        Set-Status 'Error - see log.' $ColorErr
    }
    finally {
        $convertPngBtn.Enabled = $true
        $scanBtn.Enabled = $true; $runBtn.Enabled = $true; $gbDownloadBtn.Enabled = $true; $testBarBtn.Enabled = $true; $isoInstallBtn.Enabled = $true; $aboutBtn.Enabled = $true
    }
}))

$runBtn.Add_Click({
    Write-RunLogFile "=== Run Full Merge clicked (build $($script:GuiBuildTag)) ==="
    try { $form.Activate() } catch {}
    $runFeedbackLbl.Text = 'Run clicked — checking folders...'
    $runFeedbackLbl.ForeColor = $ColorAccent2
    [System.Windows.Forms.Application]::DoEvents()
    Set-Status 'Validating inputs...' $ColorFg
    if (-not (Test-Inputs)) {
        Write-RunLogFile 'Stopped: input validation failed'
        $runFeedbackLbl.Text = 'Stopped — fix folder paths (see popup or log).'
        $runFeedbackLbl.ForeColor = $ColorWarn
        Set-Status 'Stopped — fix the input shown in the popup.' $ColorWarn
        return
    }
    if ($script:glassLog) { $script:glassLog.ClearLines() }
    Write-Log '=== Run Full Merge ===' $ColorAccent
    Write-Log ("Build $($script:GuiBuildTag)") $ColorFgDim
    Reset-GlowProgress -Bar $progress -Max 100
    $scanBtn.Enabled = $false; $runBtn.Enabled = $false; $testBarBtn.Enabled = $false; $isoInstallBtn.Enabled = $false; $aboutBtn.Enabled = $false
    $gbDownloadBtn.Enabled = $false
    $convertPngBtn.Enabled = $false
    try {
        $mode = Get-SelectedMode
        Write-Log ("Mode: $mode") $ColorAccent
        if ($dryRunBox.Checked) {
            Write-Log 'WARNING: Dry run is ON — no files will change on disk!' $ColorWarn
        }
        Write-Log 'Order: merge folders first, then optional GameBanana.' $ColorFgDim

        $src = (Resolve-Path -LiteralPath $srcBox.Text).Path
        $base = (Resolve-Path -LiteralPath $dstBox.Text).Path
        Write-Log ("Base pack:   $base") $ColorFg
        Write-Log ("Add from:    $src") $ColorFg
        Write-RunLogFile "Base=$base AddFrom=$src"
        $out = ''
        if (-not [string]::IsNullOrWhiteSpace($outBox.Text)) {
            $outRaw = $outBox.Text.Trim()
            if (Test-Path -LiteralPath $outRaw -PathType Container) {
                $out = (Resolve-Path -LiteralPath $outRaw).Path
            } else {
                $out = $outRaw
            }
            Write-Log ("Output:      $out") $ColorFg
            Write-RunLogFile "Output=$out"
        } else {
            Write-Log 'Output:      (in place — base pack will be modified)' $ColorWarn
            Write-RunLogFile 'Output=(in place)'
        }

        $skipConfirms = $false
        try { $skipConfirms = [bool]$skipConfirmBox.Checked } catch {}
        $includeGb = $false
        try { $includeGb = [bool]$includeGbMergeBox.Checked } catch {}
        $runFeedbackLbl.Text = if ($dryRunBox.Checked) { 'Running dry run...' } else { 'Merging — see progress bar and log...' }
        $runFeedbackLbl.ForeColor = $ColorAccent
        Set-Status 'Merge running...' $ColorAccent2
        Write-RunLogFile "Starting pipeline DryRun=$($dryRunBox.Checked) IncludeGB=$includeGb"
        Invoke-FullMergePipeline -Mode $mode -SourceFolder $src -BasePack $base -OutputFolder $out `
            -DryRun $dryRunBox.Checked -IncludeGameBanana $includeGb -SkipConfirm $skipConfirms
        Write-RunLogFile 'Pipeline finished OK'
        if ($dryRunBox.Checked) {
            $runFeedbackLbl.Text = 'Dry run done — no files changed. Uncheck Dry run to merge for real.'
            $runFeedbackLbl.ForeColor = $ColorWarn
        } else {
            $runFeedbackLbl.Text = 'Merge finished — check log and your folder.'
            $runFeedbackLbl.ForeColor = $ColorOk
        }
    }
    catch {
        Write-RunLogFile "ERROR: $($_.Exception.Message)"
        Write-Log ("ERROR: $($_.Exception.Message)") $ColorErr
        if ($_.ScriptStackTrace) { Write-Log $_.ScriptStackTrace $ColorFgDim }
        $runFeedbackLbl.Text = "Error: $($_.Exception.Message)"
        $runFeedbackLbl.ForeColor = $ColorErr
        Set-Status 'Error - see log.' $ColorErr
        [void][System.Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, 'Run Full Merge failed',
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    }
    finally {
        $gbDownloadBtn.Enabled = $true
        $convertPngBtn.Enabled = $true
        $scanBtn.Enabled = $true; $runBtn.Enabled = $true; $testBarBtn.Enabled = $true; $isoInstallBtn.Enabled = $true; $aboutBtn.Enabled = $true
    }
})

Write-Log 'Twilight Texture Pack Merger ready.' $ColorAccent
Write-Log ("App folder (links .txt + mod downloads): $(Get-ModMergerAppFolder)") $ColorFgDim
Write-Log 'Append mode: "Add from" supplies missing files. Set "Output folder" to save the merged pack separately, or leave it empty to merge in place into the base pack.' $ColorFg
Write-Log 'Run Full Merge: GameBanana download -> PNG to DDS -> merge folders -> unzip mods -> append to finished mod.' $ColorFg
Write-Log 'Scan/Preview: plan only. PNG to DDS row: convert any folder manually with texconv.' $ColorFg
Write-Log 'GameBanana button: download+merge mods alone (no folder merge).' $ColorFg
Write-Log 'Drag the title strip to move. Dry run OFF = real merge. GameBanana is optional (checkbox in Step 3).' $ColorFg
Write-Log ("Diagnostic log file: $(Join-Path (Get-ModMergerAppFolder) 'merge-run.log')") $ColorFgDim

try {
    [Console]::TreatControlCAsInput = $false
    $script:CancelKeyHandler = {
        param($sender, $e)
        $e.Cancel = $true
    }
    [Console]::add_CancelKeyPress($script:CancelKeyHandler)
} catch { }

$script:SavedErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    [void]$form.ShowDialog()
}
catch {
    if (-not (Test-IsPipelineStopped $_)) {
        [System.Windows.Forms.MessageBox]::Show(
            "Mod Merger could not start:`n`n$($_.Exception.Message)",
            'Mod Merger - Startup error',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        exit 1
    }
}
finally {
    $ErrorActionPreference = $script:SavedErrorActionPreference
    try {
        [System.Windows.Forms.Application]::remove_ThreadException($script:UiThreadExceptionHandler)
    } catch { }
    try {
        if ($script:CancelKeyHandler) {
            [Console]::remove_CancelKeyPress($script:CancelKeyHandler)
        }
    } catch { }
}
