#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CoreRepo,
    [Parameter(Mandatory)][string]$AppRepo,
    [Parameter(Mandatory)][string]$WorkspaceRoot,
    [string]$WorktreeRoot,
    [Parameter(Mandatory)][string]$TaskId,
    [Parameter(Mandatory)][string]$Slug,
    [Parameter(Mandatory)][string]$Owner,
    [ValidateSet('feat','fix','refactor','chore')][string]$Kind='feat',
    [ValidateSet('Core','App','Both')][string]$Scope='Both',
    [string]$BaseRef='main',
    [switch]$Apply
)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Dansheng.Workspace.psm1') -Force
New-DsTask @PSBoundParameters | ConvertTo-Json -Depth 12
$global:LASTEXITCODE=0
