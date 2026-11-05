#Requires -Version 7.4
[CmdletBinding()]
param(
    [string]$InstallPath = (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Programs\PowerShellHistoryTool')
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'SetupHelpers.ps1')
$InstallPath = [IO.Path]::GetFullPath($InstallPath)
$infoPath = Join-Path $InstallPath 'install-info.json'
if (-not (Test-Path -LiteralPath $infoPath -PathType Leaf)) { throw '未找到安装记录，请检查 InstallPath 参数。' }
$info = Get-Content -LiteralPath $infoPath -Raw | ConvertFrom-Json
if ($info.Tool -ne 'PowerShellHistoryTool' -or -not $info.ProfilePath) { throw '安装记录无效，已停止卸载。' }
$profilePath = [IO.Path]::GetFullPath([string]$info.ProfilePath)
if (Test-Path -LiteralPath $profilePath -PathType Leaf) {
    $original = Read-HistoryToolProfile $profilePath
    $start = '# >>> PowerShellHistoryTool >>>'
    $end = '# <<< PowerShellHistoryTool <<<'
    $pattern = '(?ms)^' + [regex]::Escape($start) + '\r?\n.*?^' + [regex]::Escape($end) + '(?:\r?\n|$)'
    $matches = [regex]::Matches($original, $pattern)
    if (([regex]::Matches($original, [regex]::Escape($start)).Count -ne $matches.Count) -or
        ([regex]::Matches($original, [regex]::Escape($end)).Count -ne $matches.Count)) {
        throw '配置标记不完整，已停止卸载，未删除任何工具文件。'
    }
    if ($matches.Count -gt 0) {
        $backup = "$profilePath.before-history-tool-uninstall-$([guid]::NewGuid().ToString('N')).bak"
        Copy-Item -LiteralPath $profilePath -Destination $backup
        $clean = [regex]::Replace($original, $pattern, '')
        Write-HistoryToolFile -Path $profilePath -Content $clean
    }
}
# Delete only known application files. Keep archives, backups, and unrelated files.
foreach ($name in @('RecentCommandHistory.ps1', 'Uninstall.ps1', 'SetupHelpers.ps1', 'install-info.json')) {
    $target = Join-Path $InstallPath $name
    if (Test-Path -LiteralPath $target -PathType Leaf) { Remove-Item -LiteralPath $target -Force }
}
if (@(Get-ChildItem -LiteralPath $InstallPath -Force).Count -eq 0) { [IO.Directory]::Delete($InstallPath) }
Write-Host '卸载完成。历史归档和配置备份已保留。请重新打开 PowerShell 标签页。'
