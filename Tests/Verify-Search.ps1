[CmdletBinding()]
param([string]$RuntimePath = (Join-Path $PSScriptRoot '..\Runtime\RecentCommandHistory.ps1'), [switch]$InChildProcess)
$ErrorActionPreference = 'Stop'
if (-not $InChildProcess) {
    & pwsh -NoLogo -NoProfile -STA -File $PSCommandPath -RuntimePath $RuntimePath -InChildProcess
    if ($LASTEXITCODE -ne 0) { throw 'Search verification failed in isolated process.' }
    return
}
Import-Module PSReadLine
$root = Join-Path ([IO.Path]::GetTempPath()) ('history-search-test-' + [guid]::NewGuid())
$null = [IO.Directory]::CreateDirectory($root)
$global:CommandHistoryArchivePath = Join-Path $root 'archive.jsonl'
[IO.File]::WriteAllText($global:CommandHistoryArchivePath, '')
. $RuntimePath
function Assert($value, $message) { if (-not $value) { throw $message } }
$commands = @('git status', 'git commit -m "status fix"', 'Get-Process', 'get-process -Name pwsh', 'echo git', "Write-Output '中文'`nGet-Date")
$rows = @(for ($i = 0; $i -lt $commands.Count; $i++) { [pscustomobject]@{ '序号' = $i + 1; '命令' = $commands[$i] } })
Assert (@(Find-CommandHistoryMatch $rows -Query 'git').Count -eq 3) 'Contains matching failed'
Assert (@(Find-CommandHistoryMatch $rows -Query 'status git' -Mode Keywords).Count -eq 2) 'AND keyword matching failed'
Assert (@(Find-CommandHistoryMatch $rows -Query 'git' -Mode Prefix).Count -eq 2) 'Prefix matching failed'
Assert (@(Find-CommandHistoryMatch $rows -Query '^git\s+(status|commit)' -Mode Regex).Count -eq 2) 'Regex matching failed'
Assert (@(Find-CommandHistoryMatch $rows -Query 'Get-Process' -CaseSensitive).Count -eq 1) 'Case-sensitive matching failed'
Assert (@(Find-CommandHistoryMatch $rows -Query 'Get-Process').Count -eq 2) 'Case-insensitive matching failed'
Assert (@(Find-CommandHistoryMatch $rows -Query '' -Mode Regex).Count -eq 6) 'Empty query failed'
Assert (@(Find-CommandHistoryMatch $rows -Query '中文').Count -eq 1) 'Unicode query failed'
$failed = $false
try { $null = @(Find-CommandHistoryMatch $rows -Query '(' -Mode Regex) } catch { $failed = $true }
Assert $failed 'Invalid regex was accepted'
$failed = $false
$clock = [Diagnostics.Stopwatch]::StartNew()
try { $null = @(Find-CommandHistoryMatch @([pscustomobject]@{ '命令' = ('a' * 30000) + '!' }) -Query '(a+)+$' -Mode Regex) } catch { $failed = $_.Exception.Message -match '超时' }
Assert ($failed -and $clock.Elapsed.TotalSeconds -lt 3) 'Pathological regex was not bounded'
foreach ($command in $commands) { Add-CommandHistoryArchive $command }
$form = New-CommandHistoryWindow
try {
    $form.Show()
    [Windows.Forms.Application]::DoEvents()
    $form.Tag.Search.Text = 'git'
    Assert ($form.Tag.Filtered.Count -eq 3) 'UI contains mode failed'
    $null = $form.Tag.List.SelectedIndices.Add(2)
    $form.Tag.Search.Text = 'nothing-matches'
    Assert ($form.Tag.List.VirtualListSize -eq 0 -and $form.Tag.List.SelectedIndices.Count -eq 0) 'Filtering selected virtual rows failed'
    $form.Tag.Search.Text = 'git'
    $form.Tag.ModeButtons.Prefix.Checked = $true
    Assert ($form.Tag.Mode -eq 'Prefix' -and $form.Tag.Filtered.Count -eq 2) 'UI prefix button failed'
    $form.Tag.ModeButtons.Keywords.Checked = $true
    $form.Tag.Search.Text = 'status git'
    Assert ($form.Tag.Filtered.Count -eq 2) 'UI keyword button failed'
    $form.Tag.ModeButtons.Regex.Checked = $true
    $form.Tag.Search.Text = '('
    Assert ($form.Tag.Filtered.Count -eq 0 -and $form.Tag.Status.Text -match '无效') 'UI regex error handling failed'
    $form.Tag.Search.Text = '^Get-Process'
    $form.Tag.CaseSensitive.Checked = $true
    Assert ($form.Tag.Filtered.Count -eq 1) 'UI case toggle failed'
    $form.Tag.Search.Text = ''
    $bitmap = [Drawing.Bitmap]::new($form.Width, $form.Height)
    try { $form.DrawToBitmap($bitmap, [Drawing.Rectangle]::new(0,0,$form.Width,$form.Height)); $bitmap.Save((Join-Path $root 'window.png')) }
    finally { $bitmap.Dispose() }
    $form.Width = 650
    [Windows.Forms.Application]::DoEvents()
    Assert ($form.Tag.Search.Width -gt 100) 'Narrow layout failed'
}
finally { $form.Dispose() }
'PASS: four search modes, case toggle, Unicode, invalid/slow regex, UI switching, error recovery, resizable layout.'
"TEST_ROOT=$root"
