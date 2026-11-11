#Requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][string]$TaskKey)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Dansheng.Workspace.psm1') -Force
Get-DsTaskStatus @PSBoundParameters | ConvertTo-Json -Depth 12
$global:LASTEXITCODE=0
