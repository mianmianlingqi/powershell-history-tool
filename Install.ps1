#Requires -Version 7.4
[CmdletBinding()]
param(
    [string]$InstallPath = (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Programs\PowerShellHistoryTool'),
    [string]$ProfilePath = $PROFILE.CurrentUserCurrentHost
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'SetupHelpers.ps1')
if (-not $IsWindows) { throw '此工具需要 Windows 和 PowerShell 7.4 或更高版本。' }
Import-Module PSReadLine -MinimumVersion 2.4.5 -ErrorAction Stop
$InstallPath = [IO.Path]::GetFullPath($InstallPath)
$ProfilePath = [IO.Path]::GetFullPath($ProfilePath)
$source = Join-Path $PSScriptRoot 'Runtime\RecentCommandHistory.ps1'
if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw '安装包不完整：缺少 Runtime\RecentCommandHistory.ps1。' }
foreach ($required in @('Uninstall.ps1', 'SetupHelpers.ps1')) {
    if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $required) -PathType Leaf)) { throw "安装包不完整：缺少 $required。" }
}
if ($InstallPath.TrimEnd('\') -eq $PSScriptRoot.TrimEnd('\')) { throw '安装目录不能与解压目录相同。' }
$infoPath = Join-Path $InstallPath 'install-info.json'
if ((Test-Path -LiteralPath $InstallPath) -and -not (Test-Path -LiteralPath $infoPath)) {
    if (@(Get-ChildItem -LiteralPath $InstallPath -Force).Count -gt 0) {
        throw '目标目录已有其他文件，请选择一个新的空目录。'
    }
}
$start = '# >>> PowerShellHistoryTool >>>'
$end = '# <<< PowerShellHistoryTool <<<'
$pattern = '(?ms)^' + [regex]::Escape($start) + '\r?\n.*?^' + [regex]::Escape($end) + '(?:\r?\n|$)'
$original = if (Test-Path -LiteralPath $ProfilePath) { Read-HistoryToolProfile $ProfilePath } else { '' }
$matches = [regex]::Matches($original, $pattern)
if (([regex]::Matches($original, [regex]::Escape($start)).Count -ne $matches.Count) -or
    ([regex]::Matches($original, [regex]::Escape($end)).Count -ne $matches.Count)) {
    throw '配置文件中的工具标记不完整，请先修复标记后再安装。'
}
if (Test-Path -LiteralPath $infoPath) {
    $oldInfo = Get-Content -LiteralPath $infoPath -Raw | ConvertFrom-Json
    if ($oldInfo.Tool -ne 'PowerShellHistoryTool' -or $oldInfo.ProfilePath -ne $ProfilePath) {
        throw '此安装目录已关联其他配置文件，请使用其他安装目录。'
    }
}
$null = [IO.Directory]::CreateDirectory($InstallPath)
$null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($ProfilePath))
$backup = $null
if (Test-Path -LiteralPath $ProfilePath) {
    $backup = "$ProfilePath.before-history-tool-$([DateTime]::Now.ToString('yyyyMMdd-HHmmss-fff'))-$([guid]::NewGuid().ToString('N').Substring(0,8)).bak"
    Copy-Item -LiteralPath $ProfilePath -Destination $backup
    Write-Host "配置备份：$backup"
}
# Record ownership first so any later interrupted install can be retried or uninstalled.
$info = [ordered]@{ Tool = 'PowerShellHistoryTool'; Version = '1.1.0'; ProfilePath = $ProfilePath; ProfileBackup = $backup; InstalledAt = [DateTime]::Now.ToString('o') }
Write-HistoryToolFile -Path $infoPath -Content ($info | ConvertTo-Json)
$runtimePath = Join-Path $InstallPath 'RecentCommandHistory.ps1'
Copy-Item -LiteralPath $source -Destination $runtimePath -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Uninstall.ps1') -Destination (Join-Path $InstallPath 'Uninstall.ps1') -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'SetupHelpers.ps1') -Destination (Join-Path $InstallPath 'SetupHelpers.ps1') -Force
$escapedRuntime = $runtimePath.Replace("'", "''")
$block = @'
# >>> PowerShellHistoryTool >>>
if ($Host.Name -eq 'ConsoleHost' -and -not [Console]::IsOutputRedirected) {
    try {
        Import-Module PSReadLine -MinimumVersion 2.4.5 -ErrorAction Stop
        . '__RUNTIME_PATH__'
    }
    catch { Write-Warning "历史命令工具加载失败：$($_.Exception.Message)" }
}
# <<< PowerShellHistoryTool <<<
'@
$block = $block.Replace('__RUNTIME_PATH__', $escapedRuntime)
$clean = [regex]::Replace($original, $pattern, '')
if ($clean.Length -gt 0 -and -not $clean.EndsWith("`n")) { $clean += [Environment]::NewLine }
Write-HistoryToolFile -Path $ProfilePath -Content ($clean + $block + [Environment]::NewLine)
Write-Host '安装完成。新开 PowerShell 标签页，按 Ctrl+H 打开历史命令窗口。'
Write-Host "安装目录：$InstallPath"
Write-Host "配置文件：$ProfilePath"
