#Requires -Version 5.1
<#
    Select-Scenario.ps1 <0-15|15-30|30+>

    Schakelt op afstand (via SSH, met de automatisch gegenereerde sleutel) de
    link-emulator naar de VASTE basistoestand van één van de drie
    afstandscategorieën. Voor de statistische batchtests met willekeurige
    weers- en DFS-variatie, zie Run-DistanceTrials.ps1.
#>

param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('0-15', '15-30', '30+')]
    [string]$Distance,

    [int]$SshPortLinkEmu = 2223
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $ScriptDir 'Modules\PocFunctions.psm1') -Force

$SshKeyPath = Join-Path $ScriptDir 'work\ssh\poc_ed25519'
if (-not (Test-Path -LiteralPath $SshKeyPath)) {
    throw 'Geen SSH-sleutel gevonden. Voer eerst .\Build-PoC.ps1 (of 1-Build.bat) uit.'
}

$ssh = Get-SshCommand

& $ssh -p $SshPortLinkEmu -i $SshKeyPath `
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL -o ConnectTimeout=10 `
    poc@127.0.0.1 "sudo /usr/local/bin/poc-set-scenario.sh $Distance"
