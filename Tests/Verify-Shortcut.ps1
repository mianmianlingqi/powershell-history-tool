param([string]$RuntimePath = (Join-Path $PSScriptRoot '..\Runtime\RecentCommandHistory.ps1'), [switch]$InChildProcess)
$ErrorActionPreference = 'Stop'
if (-not $InChildProcess) {
    & pwsh -NoLogo -NoProfile -File $PSCommandPath -RuntimePath $RuntimePath -InChildProcess
    if ($LASTEXITCODE -ne 0) { throw 'Shortcut verification failed in isolated process.' }
    return
}
Import-Module PSReadLine
$global:CommandHistoryArchivePath = Join-Path ([IO.Path]::GetTempPath()) ('history-shortcut-test-' + [guid]::NewGuid() + '.jsonl')
[IO.File]::WriteAllText($global:CommandHistoryArchivePath, '')
. $RuntimePath
Set-PSReadLineOption -EditMode Windows
if ((Get-PSReadLineKeyHandler -Chord Ctrl+h).Function -eq 'CommandHistoryArchive') { Set-PSReadLineKeyHandler -Chord Ctrl+h -Function BackwardDeleteChar }
if (-not (Get-Command Enable-CommandHistoryShortcut -ErrorAction SilentlyContinue)) { throw 'REGRESSION: Ctrl+H was reset and no recovery path is installed.' }
# Replace only the final blocking console reader; exercise the real shell entry point.
function global:Invoke-CommandHistoryReadLine { param([bool]$LastRunStatus) $global:ShortcutTestLastStatus = $LastRunStatus; 'TEST_READLINE' }
$result = PSConsoleHostReadLine
if ((Get-PSReadLineKeyHandler -Chord Ctrl+h).Function -ne 'CommandHistoryArchive') { throw 'REGRESSION: Ctrl+H remains lost when the next input line starts.' }
if ($result -ne 'TEST_READLINE') { throw 'Shell reader result changed' }
Write-Error 'Deliberately failed test command' -ErrorAction SilentlyContinue
$null = PSConsoleHostReadLine
if ($global:ShortcutTestLastStatus -ne $false) { throw 'Last-command failure status was not preserved' }
Set-StrictMode -Version Latest
Remove-PSReadLineKeyHandler -Chord Ctrl+h
Enable-CommandHistoryShortcut
if ((Get-PSReadLineKeyHandler -Chord Ctrl+h).Function -ne 'CommandHistoryArchive') { throw 'Unbound shortcut failed under strict mode' }
Set-StrictMode -Off
. $RuntimePath
Set-PSReadLineOption -EditMode Emacs
function global:Invoke-CommandHistoryReadLine { param([bool]$LastRunStatus) $global:ShortcutTestLastStatus = $LastRunStatus; 'TEST_READLINE' }
$null = PSConsoleHostReadLine
if ((Get-PSReadLineKeyHandler -Chord Ctrl+h).Function -ne 'CommandHistoryArchive') { throw 'Reload/Emacs recovery failed' }
Set-PSReadLineKeyHandler -Chord Ctrl+h -BriefDescription UserCustomCtrlH -ScriptBlock {}
$null = PSConsoleHostReadLine
if ((Get-PSReadLineKeyHandler -Chord Ctrl+h).Function -ne 'UserCustomCtrlH') { throw 'User custom shortcut overwritten' }
Enable-CommandHistoryShortcut -Force
function global:Enable-CommandHistoryShortcut { throw 'fixture-rebind-failure' }
if ((PSConsoleHostReadLine) -ne 'TEST_READLINE') { throw 'Shortcut recovery failure blocked the input reader' }
if ($global:CommandHistoryShortcutError -ne 'fixture-rebind-failure') { throw 'Recovery failure was not recorded' }
$blocker = Join-Path ([IO.Path]::GetTempPath()) ('history-unavailable-' + [guid]::NewGuid())
[IO.File]::WriteAllText($blocker, 'file, not directory')
$global:CommandHistoryArchivePath = Join-Path $blocker 'archive.jsonl'
Set-PSReadLineOption -EditMode Windows
. $RuntimePath
if ((Get-PSReadLineKeyHandler -Chord Ctrl+h).Function -ne 'CommandHistoryArchive') { throw 'Archive startup error prevented shortcut registration' }
function global:PSConsoleHostReadLine { 'CUSTOM_READER' }
. $RuntimePath
if ((PSConsoleHostReadLine) -ne 'CUSTOM_READER') { throw 'Existing custom input reader was overwritten' }
if ((Get-CommandHistoryStatus).InputHook -ne 'NotActive') { throw 'Stale input hook status' }
'PASS: Windows/Emacs reset recovery, last-command status, reload, archive errors, custom shortcuts/readers, repair failure isolation, and live hook status.'
