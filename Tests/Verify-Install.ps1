param([string]$SourceRoot = (Split-Path $PSScriptRoot -Parent), [switch]$InChildProcess)
$ErrorActionPreference = 'Stop'
if (-not $InChildProcess) {
    & pwsh -NoLogo -NoProfile -File $PSCommandPath -SourceRoot $SourceRoot -InChildProcess
    if ($LASTEXITCODE -ne 0) { throw 'Installation verification failed in isolated process.' }
    return
}
$root = Join-Path ([IO.Path]::GetTempPath()) ('history-install-test-' + [guid]::NewGuid())
$null = [IO.Directory]::CreateDirectory($root)
$install = Join-Path $root "app with spaces ' `$value ``mark"
$profilePath = Join-Path $root 'profile.ps1'
$original = "# 用户原有配置`nfunction ExistingUserFunction { 'preserved' }`n"
[IO.File]::WriteAllText($profilePath, $original)
function Assert($condition, $message) { if (-not $condition) { throw $message } }
& (Join-Path $SourceRoot 'Install.ps1') -InstallPath $install -ProfilePath $profilePath 6>$null
& (Join-Path $SourceRoot 'Install.ps1') -InstallPath $install -ProfilePath $profilePath 6>$null
$text = [IO.File]::ReadAllText($profilePath)
Assert ([regex]::Matches($text, '# >>> PowerShellHistoryTool >>>').Count -eq 1) 'Duplicate profile block'
Assert ($text.StartsWith($original)) 'Original profile changed'
$tokens = $null; $issues = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($profilePath, [ref]$tokens, [ref]$issues)
Assert ($issues.Count -eq 0) 'Generated profile syntax invalid'
$dot = $ast.Find({ param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.InvocationOperator -eq 'Dot' }, $true)
Assert ($dot.CommandElements[0].Value -eq (Join-Path $install 'RecentCommandHistory.ps1')) 'Path quoting failed'
Import-Module PSReadLine
$native = Join-Path $root 'native.txt'
[IO.File]::WriteAllText($native, '')
Set-PSReadLineOption -HistorySavePath $native
$global:CommandHistoryArchivePath = Join-Path $root 'archive.jsonl'
. (Join-Path $install 'RecentCommandHistory.ps1')
Add-CommandHistoryArchive 'verification-command'
Assert ((Get-CommandHistoryStatus).ToolVersion -eq '1.2.0') 'Installed version incorrect'
$json = & pwsh -NoLogo -NoProfile -File (Join-Path $install 'Commands.ps1') -Action add -Name InstalledAgent -Command 'Get-Date' -RegistryPath $global:CommonCommandRegistryPath -AsJson
Assert ($LASTEXITCODE -eq 0 -and @($json | ConvertFrom-Json)[0].Name -eq 'InstalledAgent') 'Installed agent entry failed'
$extra = "# 安装后新增配置`n"
[IO.File]::AppendAllText($profilePath, $extra)
$sentinel = Join-Path $install 'keep.txt'
[IO.File]::WriteAllText($sentinel, 'keep')
& (Join-Path $install 'Uninstall.ps1') -InstallPath $install 6>$null
Assert ([IO.File]::ReadAllText($profilePath) -eq ($original + $extra)) 'Uninstall changed user settings'
Assert ((Test-Path -LiteralPath $global:CommandHistoryArchivePath) -and (Test-Path -LiteralPath $sentinel)) 'Uninstall deleted data'
Assert (Test-Path -LiteralPath $global:CommonCommandRegistryPath) 'Uninstall deleted common commands'
$blockedProfile = Join-Path $root 'locked.ps1'
$blockedInstall = Join-Path $root 'blocked-install'
[IO.File]::WriteAllText($blockedProfile, $original)
$handle = [IO.File]::Open($blockedProfile, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
try {
    $failed = $false
    try { & (Join-Path $SourceRoot 'Install.ps1') -InstallPath $blockedInstall -ProfilePath $blockedProfile 6>$null } catch { $failed = $true }
    Assert $failed 'Locked profile accepted'
    Assert ([IO.File]::ReadAllText($blockedProfile) -eq $original) 'Failed install damaged profile'
}
finally { $handle.Dispose() }
& (Join-Path $SourceRoot 'Install.ps1') -InstallPath $blockedInstall -ProfilePath $blockedProfile 6>$null
& (Join-Path $SourceRoot 'Uninstall.ps1') -InstallPath $blockedInstall 6>$null
Assert ([IO.File]::ReadAllText($blockedProfile) -eq $original) 'Retry/uninstall changed original profile'
'PASS: install/reinstall, quoted paths, profile preservation, installed version, data-preserving uninstall, atomic failure and retry.'
