#Requires -Version 7.4
[CmdletBinding()]
param(
    [ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version = '1.1.0',
    [string]$DestinationPath = (Split-Path $PSScriptRoot -Parent)
)
$ErrorActionPreference = 'Stop'
$payload = @('Install.ps1', 'Uninstall.ps1', 'SetupHelpers.ps1', 'Runtime\RecentCommandHistory.ps1', 'README.md')
$buildRoot = Join-Path ([IO.Path]::GetTempPath()) ('history-build-' + [guid]::NewGuid())
$packageName = "PowerShellHistoryTool-$Version"
$stage = Join-Path $buildRoot $packageName
$null = [IO.Directory]::CreateDirectory((Join-Path $stage 'Runtime'))
$hashes = foreach ($relative in $payload) {
    $source = Join-Path $PSScriptRoot $relative
    $target = Join-Path $stage $relative
    if ($source.EndsWith('.ps1')) {
        $tokens = $null; $issues = $null
        $null = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$issues)
        if ($issues.Count) { throw ($issues | Out-String) }
    }
    Copy-Item -LiteralPath $source -Destination $target
    (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant() + '  ' + $relative.Replace('\', '/')
}
[IO.File]::WriteAllLines((Join-Path $stage 'SHA256SUMS.txt'), $hashes, [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllLines((Join-Path $PSScriptRoot 'SHA256SUMS.txt'), $hashes, [Text.UTF8Encoding]::new($false))
$null = [IO.Directory]::CreateDirectory([IO.Path]::GetFullPath($DestinationPath))
$zip = Join-Path $DestinationPath "$packageName.zip"
Compress-Archive -LiteralPath $stage -DestinationPath $zip -CompressionLevel Optimal -Force
$verification = Join-Path $buildRoot 'verify'
Expand-Archive -LiteralPath $zip -DestinationPath $verification
foreach ($line in $hashes) {
    $hash, $relative = $line -split '  ', 2
    $actual = (Get-FileHash -LiteralPath (Join-Path (Join-Path $verification $packageName) $relative) -Algorithm SHA256).Hash
    if ($actual -ne $hash) { throw "ZIP 校验失败：$relative" }
}
$archive = [IO.Compression.ZipFile]::OpenRead($zip)
try {
    $files = @($archive.Entries | Where-Object { -not $_.FullName.EndsWith('/') })
    if ($files.Count -ne 6) { throw 'ZIP 文件列表与预期不一致。' }
}
finally { $archive.Dispose() }
$zipHash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText("$zip.sha256", "$zipHash  $packageName.zip`n")
[pscustomobject]@{ Path = $zip; Bytes = (Get-Item -LiteralPath $zip).Length; SHA256 = $zipHash; Verified = $true }
