param([string]$SourceRoot = (Split-Path $PSScriptRoot -Parent), [switch]$InChildProcess)
$ErrorActionPreference = 'Stop'
if (-not $InChildProcess) {
    & pwsh -NoLogo -NoProfile -STA -File $PSCommandPath -SourceRoot $SourceRoot -InChildProcess
    if ($LASTEXITCODE -ne 0) { throw 'Common command verification failed in isolated process.' }
    return
}
function Assert($condition, $message) { if (-not $condition) { throw $message } }
$root = Join-Path ([IO.Path]::GetTempPath()) ('common-command-test-' + [guid]::NewGuid())
$null = [IO.Directory]::CreateDirectory($root)
$global:CommandHistoryArchivePath = Join-Path $root 'history.jsonl'
$global:CommonCommandRegistryPath = Join-Path $root 'common-commands.json'
$runtime = Join-Path $SourceRoot 'Runtime\RecentCommandHistory.ps1'
. $runtime -NoConsoleIntegration
Assert (@(Get-CommonCommand).Count -eq 0) 'Empty registry failed'
Assert (-not (Test-Path -LiteralPath $global:CommonCommandRegistryPath)) 'Listing created a registry'
Assert ($null -eq (Get-Module PSReadLine)) 'CLI-only load imported PSReadLine'
$marker = Join-Path $root 'MUST-NOT-EXECUTE.txt'
$payload = "[IO.File]::WriteAllText('$marker', 'executed')"
$null = hcmd add -Name Deploy -Command $payload -Description '部署说明'
$created = (Get-CommonCommand -Name DEPLOY).CreatedAtUtc
$failed = $false
try { $null = hcmd add -Name deploy -Command 'duplicate' } catch { $failed = $true }
Assert $failed 'Duplicate name accepted'
$null = hcmd add -Name Deploy -Command $payload -Description '部署说明更新' -Force
Assert ((Get-CommonCommand -Name deploy).CreatedAtUtc -eq $created) 'Update lost creation date'
Assert (-not (Test-Path -LiteralPath $marker)) 'Registration executed a command'
$null = Register-CommonCommand -Name MultiLine -Command "Write-Output '中文'`nGet-Date" -Description '多行说明'
Assert (@(Get-CommonCommand -Name Deploy).Count -eq 1) 'Named lookup returned other records'
Unregister-CommonCommand -Name Deploy -WhatIf
Assert (@(Get-CommonCommand -Name Deploy).Count -eq 1) 'WhatIf removed a record'
$commandsEntry = Join-Path $SourceRoot 'Commands.ps1'
$json = & pwsh -NoLogo -NoProfile -File $commandsEntry -Action add -Name AgentEntry -Command 'git status' -Description 'agent 手动注册' -RegistryPath $global:CommonCommandRegistryPath -AsJson
Assert ($LASTEXITCODE -eq 0 -and @($json | ConvertFrom-Json)[0].Name -eq 'AgentEntry') 'Noninteractive CLI registration failed'
$json = & pwsh -NoLogo -NoProfile -File $commandsEntry -Action list -Name AgentEntry -RegistryPath $global:CommonCommandRegistryPath -AsJson
Assert ($LASTEXITCODE -eq 0 -and @($json | ConvertFrom-Json).Count -eq 1) 'Cross-process named lookup failed'
$json = & pwsh -NoLogo -NoProfile -File $commandsEntry -Action remove -Name AgentEntry -RegistryPath $global:CommonCommandRegistryPath -AsJson
Assert ($LASTEXITCODE -eq 0 -and @($json | ConvertFrom-Json).Count -eq 0 -and @(Get-CommonCommand -Name AgentEntry).Count -eq 0) 'Noninteractive CLI removal failed'
$mainRegistry = $global:CommonCommandRegistryPath
$global:CommonCommandRegistryPath = Join-Path $root 'single.json'
$null = Register-CommonCommand -Name OnlyEntry -Command 'Get-Date'
Unregister-CommonCommand -Name OnlyEntry
Assert (@(Get-CommonCommand).Count -eq 0) 'Last-record removal broke the registry'
$global:CommonCommandRegistryPath = $mainRegistry
$global:CommonCommandRegistryPath = Join-Path $root 'minimal.json'
[IO.File]::WriteAllText($global:CommonCommandRegistryPath, '{"SchemaVersion":1,"Commands":[{"Name":"Minimal","Command":"Get-Date"}]}')
Assert ((Get-CommonCommand -Name Minimal).Description -eq '') 'Optional description was rejected'
$null = Register-CommonCommand -Name Minimal -Command 'Get-Location' -Force
Assert ((Get-CommonCommand -Name Minimal).Command -eq 'Get-Location') 'Minimal entry could not be updated'
$global:CommonCommandRegistryPath = $mainRegistry
$before = @(Get-CommonCommand).Count
$jobs = @(foreach ($worker in 1..4) {
    Start-Job -ScriptBlock {
        param($runtime, $registry, $worker)
        $ErrorActionPreference = 'Stop'
        $global:CommonCommandRegistryPath = $registry
        . $runtime -NoConsoleIntegration
        foreach ($i in 1..20) { $null = Register-CommonCommand -Name "worker-$worker-$i" -Command "Write-Output $i" }
    } -ArgumentList $runtime, $global:CommonCommandRegistryPath, $worker
})
try {
    $null = $jobs | Wait-Job -Timeout 30
    foreach ($job in $jobs) { Assert ($job.State -eq 'Completed') 'Concurrent writer failed'; $null = Receive-Job $job -ErrorAction Stop }
}
finally { $jobs | Stop-Job; $jobs | Remove-Job }
Assert (@(Get-CommonCommand).Count -eq ($before + 80)) 'Concurrent registrations lost records'
Import-Module PSReadLine
[IO.File]::WriteAllText($global:CommandHistoryArchivePath, '')
. $runtime
$form = New-CommandHistoryWindow
try {
    $form.Show(); [Windows.Forms.Application]::DoEvents()
    $form.Tag.CommonViewButton.PerformClick()
    Assert ($form.Tag.View -eq 'Common' -and $form.Tag.AddCommonButton.Visible) 'View button failed'
    $form.Tag.Search.Text = 'Deploy'
    Assert ($form.Tag.Filtered.Count -eq 1) 'Searching by registered name failed'
    $form.Tag.ModeButtons.Keywords.Checked = $true
    $form.Tag.Search.Text = 'Deploy 部署说明更新'
    Assert ($form.Tag.Filtered.Count -eq 1) 'Cross-field keyword matching failed'
    $form.Tag.Search.Text = ''
    $null = Register-CommonCommand -Name ExternalRefresh -Command 'Get-Date'
    $form.Tag.RefreshCommonButton.PerformClick()
    Assert ($form.Tag.CommonRows.Count -eq ($before + 81)) 'Refresh missed external registration'
    $bitmap = [Drawing.Bitmap]::new($form.Width, $form.Height)
    try { $form.DrawToBitmap($bitmap, [Drawing.Rectangle]::new(0,0,$form.Width,$form.Height)); $bitmap.Save((Join-Path $root 'common-window.png')) } finally { $bitmap.Dispose() }
    $form.Tag.HistoryViewButton.PerformClick()
    Assert ($form.Tag.View -eq 'History' -and -not $form.Tag.AddCommonButton.Visible) 'Returning to history failed'
    $form.Tag.CommonViewButton.PerformClick()
    $form.Tag.Search.Text = 'Deploy'
    $null = $form.Tag.List.SelectedIndices.Add(0)
    Assert $form.Tag.EditCommonButton.Enabled 'Selection did not enable management'
    $form.AcceptButton.PerformClick()
    Assert ($form.Tag.Selected -eq $payload) 'Registered command was not returned intact'
    Assert (-not (Test-Path -LiteralPath $marker)) 'Selecting a registered command executed it'
}
finally { $form.Dispose() }
$editor = New-CommonCommandEditor
try {
    $editor.Show(); [Windows.Forms.Application]::DoEvents()
    $editor.Tag.NameBox.Text = 'UIEntry'
    $editor.Tag.CommandBox.Text = "Write-Output '界面'`nGet-Date"
    $editor.Tag.DescriptionBox.Text = '从面板注册'
    $editor.Tag.SaveButton.PerformClick()
    Assert ($editor.DialogResult -eq 'OK' -and @(Get-CommonCommand -Name UIEntry).Count -eq 1) 'Editor save failed'
}
finally { $editor.Dispose() }
$editor = New-CommonCommandEditor
try {
    $editor.Show(); [Windows.Forms.Application]::DoEvents()
    $editor.Tag.NameBox.Text = 'UIEntry'; $editor.Tag.CommandBox.Text = 'duplicate'
    $editor.Tag.SaveButton.PerformClick()
    Assert ($editor.Visible -and $editor.Tag.ErrorLabel.Text -match '已存在') 'Duplicate editor did not retain input'
    $editor.CancelButton.PerformClick()
}
finally { $editor.Dispose() }
$editor = New-CommonCommandEditor -Entry (Get-CommonCommand -Name UIEntry)
try {
    $editor.Show(); [Windows.Forms.Application]::DoEvents()
    Assert $editor.Tag.NameBox.ReadOnly 'Edit identity should remain stable'
    $editor.Tag.CommandBox.Text = 'Get-Location'
    $editor.Tag.SaveButton.PerformClick()
    Assert ((Get-CommonCommand -Name UIEntry).Command -eq 'Get-Location') 'Editor update failed'
}
finally { $editor.Dispose() }
$snapshot = Get-CommonCommand -Name UIEntry
$editor = New-CommonCommandEditor -Entry $snapshot
try {
    $editor.Show(); [Windows.Forms.Application]::DoEvents()
    $null = Register-CommonCommand -Name UIEntry -Command 'Get-Date' -Force
    $editor.Tag.CommandBox.Text = 'stale edit'
    $editor.Tag.SaveButton.PerformClick()
    Assert ($editor.Visible -and $editor.Tag.ErrorLabel.Text -match '已被') 'Stale GUI edit overwrote concurrent change'
    Assert ((Get-CommonCommand -Name UIEntry).Command -eq 'Get-Date') 'Concurrent value was lost'
    $editor.CancelButton.PerformClick()
}
finally { $editor.Dispose() }
$snapshot = Get-CommonCommand -Name UIEntry
Unregister-CommonCommand -Name UIEntry
Assert (@(Get-CommonCommand -Name UIEntry).Count -eq 0) 'Unregister failed'
$failed = $false
try { $null = Register-CommonCommand -Name UIEntry -Command 'must not resurrect' -Force -ExpectedRevision $snapshot.Revision } catch { $failed = $true }
Assert ($failed -and @(Get-CommonCommand -Name UIEntry).Count -eq 0) 'Stale editor resurrected deleted entry'
[IO.File]::WriteAllText($global:CommandHistoryArchivePath, '{broken-history')
$form = New-CommandHistoryWindow
try {
    $form.Show(); [Windows.Forms.Application]::DoEvents()
    Assert ($form.Tag.Status.Text -match '历史读取失败') 'Broken history was not reported'
    $form.Tag.CommonViewButton.PerformClick()
    Assert ($form.Tag.View -eq 'Common' -and $form.Tag.CommonRows.Count -gt 0) 'Broken history blocked common commands'
}
finally { $form.Dispose() }
$broken = '{broken-json'
[IO.File]::WriteAllText($global:CommonCommandRegistryPath, $broken)
$failed = $false
try { $null = Register-CommonCommand -Name MustNotOverwrite -Command 'Get-Date' } catch { $failed = $true }
Assert ($failed -and [IO.File]::ReadAllText($global:CommonCommandRegistryPath) -eq $broken) 'Invalid store was overwritten'
'PASS: CLI/agent registration, exact lookup, duplicate protection, force update, multiline data, concurrent writers, metadata search, view switching, selection without execution, editor CRUD, and invalid-store preservation.'
"TEST_ROOT=$root"
