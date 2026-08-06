#Requires -Version 5.1
<#
    Run-DistanceTrials.ps1

    Voert een reeks onafhankelijke trials uit voor één afstandscategorie
    (0-15 | 15-30 | 30+). Bij elke trial krijgt de link-emulator een verse,
    willekeurige weers- en DFS-realisatie (via poc-run-trial.sh), waarna de
    client gedurende het meetvenster het effectieve packet loss meet. Na
    alle trials wordt de statistische verdeling (gemiddelde, standaard-
    afwijking, min/max, aandeel boven REQ-03) berekend en weggeschreven naar
    een CSV-bestand voor verdere analyse in Hoofdstuk Resultaten en Evaluatie.
#>

param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('0-15', '15-30', '30+')]
    [string]$Distance,

    [int]$Count = 100,
    [int]$SshPortLinkEmu = 2223,
    [int]$SshPortClient = 2224,
    [string]$OutputCsv
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

if (-not $OutputCsv) {
    $safeDistance = $Distance -replace '\+', 'plus'
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $OutputCsv = Join-Path $ScriptDir "work\results\trials-$safeDistance-$stamp.csv"
}
New-Item -ItemType Directory -Path (Split-Path -Parent $OutputCsv) -Force | Out-Null

function Invoke-OnLinkEmulator {
    param([Parameter(Mandatory)][string]$Command)
    & $ssh -p $SshPortLinkEmu -i $SshKeyPath `
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL -o ConnectTimeout=10 `
        poc@127.0.0.1 $Command
}

function Invoke-OnClient {
    param([Parameter(Mandatory)][string]$Command)
    & $ssh -p $SshPortClient -i $SshKeyPath `
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL -o ConnectTimeout=10 `
        poc@127.0.0.1 $Command
}

$results = New-Object System.Collections.Generic.List[object]

Write-Host "Start van $Count trials voor afstandscategorie '$Distance'." -ForegroundColor Cyan
Write-Host "Elke trial duurt ongeveer 30s (meetvenster) -- totaal ca. $([math]::Round($Count * 30 / 60, 1)) minuten." -ForegroundColor Cyan
Write-Host ''

for ($i = 1; $i -le $Count; $i++) {
    Write-Host -NoNewline "Trial $i/$Count... "

    # Nieuwe, willekeurige weers-/DFS-realisatie voor deze trial (Sectie
    # sim-trials). De aanroep zelf is vrijwel onmiddellijk; een eventuele
    # DFS-onderbreking wordt op de link-emulator zelf op de achtergrond
    # ingepland en overleeft de SSH-sessie (disown).
    $trialInfo = Invoke-OnLinkEmulator "sudo /usr/local/bin/poc-run-trial.sh $Distance"
    $dfsThisTrial = ($trialInfo -join ' ') -match 'dfs=ja'

    # Meetvenster van 30s (ping, 1/s) dekt ruimschoots een eventuele
    # DFS-onderbreking (start binnen 0-8s na de trial, duurt 10s: uiterlijk
    # op t=18s afgerond).
    $pingOutput = Invoke-OnClient 'ping -c 30 10.0.0.1'
    $lossMatch = $pingOutput | Select-String -Pattern '([\d.]+)%\s*packet loss'
    $lossPct = if ($lossMatch) { [double]$lossMatch.Matches[0].Groups[1].Value } else { $null }

    $results.Add([PSCustomObject]@{
        Trial         = $i
        Distance      = $Distance
        PacketLossPct = $lossPct
        DfsEvent      = $dfsThisTrial
        Timestamp     = Get-Date -Format 'o'
    })

    $dfsLabel = if ($dfsThisTrial) { ' (DFS-gebeurtenis)' } else { '' }
    Write-Host "verlies: $lossPct%$dfsLabel"
}

$results | Export-Csv -LiteralPath $OutputCsv -NoTypeInformation -Encoding UTF8

$lossValues = $results | Where-Object { $null -ne $_.PacketLossPct } | ForEach-Object { $_.PacketLossPct }
if ($lossValues.Count -eq 0) {
    Write-Host 'Geen enkele geldige meting -- controleer de connectiviteit.' -ForegroundColor Red
    exit 1
}

$mean = ($lossValues | Measure-Object -Average).Average
$maxLoss = ($lossValues | Measure-Object -Maximum).Maximum
$minLoss = ($lossValues | Measure-Object -Minimum).Minimum
$variance = (($lossValues | ForEach-Object { [math]::Pow($_ - $mean, 2) }) | Measure-Object -Sum).Sum / $lossValues.Count
$stddev = [math]::Sqrt($variance)
$exceedingReq03 = ($results | Where-Object { $null -ne $_.PacketLossPct -and $_.PacketLossPct -gt 2 }).Count
$dfsCount = ($results | Where-Object { $_.DfsEvent }).Count

Write-Host ''
Write-Host "=== Samenvatting: afstandscategorie '$Distance' ($Count trials) ===" -ForegroundColor Green
Write-Host ("Gemiddeld packet loss:      {0:N2}%" -f $mean)
Write-Host ("Standaardafwijking:         {0:N2}%" -f $stddev)
Write-Host ("Min / Max:                  {0:N2}% / {1:N2}%" -f $minLoss, $maxLoss)
Write-Host ("Trials met DFS-gebeurtenis: $dfsCount / $Count")
Write-Host ("Trials boven REQ-03 (2%):   $exceedingReq03 / $Count")
Write-Host ''
Write-Host "Resultaten opgeslagen in: $OutputCsv" -ForegroundColor Cyan
