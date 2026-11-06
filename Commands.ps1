#Requires -Version 7.4
[CmdletBinding()]
param(
    [ValidateSet('list', 'add', 'remove')][string]$Action = 'list',
    [string]$Name,
    [string]$Command,
    [string]$Description = '',
    [switch]$Force,
    [switch]$AsJson,
    [string]$RegistryPath
)
$ErrorActionPreference = 'Stop'
$passedParameters = @{} + $PSBoundParameters
if ($RegistryPath) { $global:CommonCommandRegistryPath = [IO.Path]::GetFullPath($RegistryPath) }
$runtime = Join-Path $PSScriptRoot 'RecentCommandHistory.ps1'
if (-not [IO.File]::Exists($runtime)) { $runtime = Join-Path $PSScriptRoot 'Runtime\RecentCommandHistory.ps1' }
. $runtime -NoConsoleIntegration
$arguments = @{ Action = $Action; Force = $Force }
if ($passedParameters.ContainsKey('Name')) { $arguments.Name = $Name }
if ($passedParameters.ContainsKey('Command')) { $arguments.Command = $Command }
if ($passedParameters.ContainsKey('Description')) { $arguments.Description = $Description }
$result = @(hcmd @arguments)
if ($AsJson) { ConvertTo-Json -InputObject $result -Depth 6 } else { $result }
