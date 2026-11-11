#Requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][string]$TaskKey,[Parameter(Mandatory)][string]$Owner,[switch]$Apply,[switch]$ConfirmRemoval)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Dansheng.Workspace.psm1') -Force
Close-DsTask @PSBoundParameters | ConvertTo-Json -Depth 12
$global:LASTEXITCODE=0
