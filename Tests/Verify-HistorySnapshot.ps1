param([string]$RuntimePath = (Join-Path $PSScriptRoot '..\Runtime\RecentCommandHistory.ps1'), [switch]$InChildProcess)
$ErrorActionPreference = 'Stop'
if (-not $InChildProcess) {
    & pwsh -NoLogo -NoProfile -File $PSCommandPath -RuntimePath $RuntimePath -InChildProcess
    if ($LASTEXITCODE -ne 0) { throw 'History snapshot verification failed in isolated process.' }
    return
}
$global:CommandHistoryArchivePath = Join-Path ([IO.Path]::GetTempPath()) ('history-snapshot-' + [guid]::NewGuid() + '.jsonl')
$lines = @(1..100 | ForEach-Object { ConvertTo-Json -InputObject "snapshot-$_" -Compress })
[IO.File]::WriteAllLines($global:CommandHistoryArchivePath, $lines)
. $RuntimePath -NoConsoleIntegration
$script:WriterProbed = $false
function ConvertFrom-Json {
    [CmdletBinding()]
    param([string]$InputObject)
    if (-not $script:WriterProbed) {
        $script:WriterProbed = $true
        $job = Start-Job -ScriptBlock {
            param($runtime, $archive)
            $ErrorActionPreference = 'Stop'
            $global:CommandHistoryArchivePath = $archive
            . $runtime -NoConsoleIntegration
            Add-CommandHistoryArchive 'snapshot-appended'
            'WRITE_SUCCESS'
        } -ArgumentList $RuntimePath, $global:CommandHistoryArchivePath
        try {
            $null = Wait-Job $job -Timeout 4
            if ($job.State -ne 'Completed' -or (Receive-Job $job -ErrorAction Stop) -ne 'WRITE_SUCCESS') { throw 'History parsing held the writer lock.' }
        }
        finally { Stop-Job $job; Remove-Job $job }
    }
    Microsoft.PowerShell.Utility\ConvertFrom-Json -InputObject $InputObject
}
$rows = @(Get-RecentPSReadLineCommand -Count 0)
if ($rows.Count -ne 100 -or -not $script:WriterProbed) { throw 'Reader did not use a stable snapshot.' }
if (@(Get-RecentPSReadLineCommand -Count 0).Count -ne 101) { throw 'Concurrent archive append was lost.' }
'PASS: a second process can append while the snapshot is parsed; current read stays stable and next read sees the append.'
