$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$main = Join-Path $root 'Texturepack-Merge-GUI.ps1'
$errFile = Join-Path $root '_err.txt'

if (-not (Test-Path -LiteralPath $main)) {
    [System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms') | Out-Null
    [System.Windows.Forms.MessageBox]::Show("Main script not found:`n$main", 'Mod Merger') | Out-Null
    exit 1
}

$parseErrors = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile($main, [ref]$null, [ref]$parseErrors)
if ($parseErrors) {
    $msg = ($parseErrors | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
    Set-Content -LiteralPath $errFile -Value $msg -Encoding UTF8
    [System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms') | Out-Null
    [System.Windows.Forms.MessageBox]::Show(
        "Script has syntax errors. See _err.txt in the mod folder.`n`nFirst error:`n$($parseErrors[0])",
        'Mod Merger - Cannot start') | Out-Null
    exit 1
}

try {
    Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
    & $main
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
catch {
    $msg = $_.Exception.Message
    if ($_.ScriptStackTrace) { $msg += [Environment]::NewLine + $_.ScriptStackTrace }
    Set-Content -LiteralPath $errFile -Value $msg -Encoding UTF8
    [System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms') | Out-Null
    [System.Windows.Forms.MessageBox]::Show(
        ($msg + [Environment]::NewLine + [Environment]::NewLine + 'Details saved to:' + [Environment]::NewLine + $errFile),
        'Mod Merger - Startup error') | Out-Null
    exit 1
}
