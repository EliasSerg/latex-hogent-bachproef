#Requires -Version 5.1
<#
    Analyze-Trials.ps1 <pad-naar-csv>

    Leest een CSV-bestand in dat door Run-DistanceTrials.ps1 werd
    weggeschreven, en berekent de statistische verdeling van het packet
    loss apart voor trials MET en ZONDER DFS-gebeurtenis. Dit geeft een
    zuiverder antwoord op twee afzonderlijke vragen:

      - REQ-03 (packet loss bij normale, courante kanaalwerking):
        enkel de trials zonder DFS-gebeurtenis zijn hiervoor relevant.
      - FR-06 (herstelvermogen na een DFS-onderbreking):
        enkel de trials MET een DFS-gebeurtenis tonen dit.

    Kan achteraf op elk reeds opgeslagen CSV-bestand toegepast worden --
    er moet niets opnieuw gemeten worden.
#>

param(
    [Parameter(Mandatory, Position = 0)]
    [string]$CsvPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $CsvPath)) {
    throw "Bestand niet gevonden: $CsvPath"
}

$rows = Import-Csv -LiteralPath $CsvPath
if ($rows.Count -eq 0) {
    throw 'Het CSV-bestand bevat geen rijen.'
}

# Import-Csv leest alles als tekst in; PacketLossPct en DfsEvent worden
# hier expliciet naar de juiste types omgezet.
$parsed = $rows | ForEach-Object {
    [PSCustomObject]@{
        Trial         = [int]$_.Trial
        Distance      = $_.Distance
        PacketLossPct = if ($_.PacketLossPct) { [double]$_.PacketLossPct } else { $null }
        DfsEvent      = [bool]::Parse($_.DfsEvent)
    }
}

function Get-LossStats {
    param([Parameter(Mandatory)][array]$Group, [Parameter(Mandatory)][string]$Label)

    $values = $Group | Where-Object { $null -ne $_.PacketLossPct } | ForEach-Object { $_.PacketLossPct }
    if ($values.Count -eq 0) {
        Write-Host "$Label -- geen geldige metingen." -ForegroundColor Yellow
        return
    }

    $mean = ($values | Measure-Object -Average).Average
    $min = ($values | Measure-Object -Minimum).Minimum
    $max = ($values | Measure-Object -Maximum).Maximum
    $variance = (($values | ForEach-Object { [math]::Pow($_ - $mean, 2) }) | Measure-Object -Sum).Sum / $values.Count
    $stddev = [math]::Sqrt($variance)
    $exceeding = ($Group | Where-Object { $null -ne $_.PacketLossPct -and $_.PacketLossPct -gt 2 }).Count

    Write-Host "$Label ($($Group.Count) trials)" -ForegroundColor Cyan
    Write-Host ("  Gemiddeld packet loss:    {0:N2}%" -f $mean)
    Write-Host ("  Standaardafwijking:       {0:N2}%" -f $stddev)
    Write-Host ("  Min / Max:                {0:N2}% / {1:N2}%" -f $min, $max)
    Write-Host ("  Trials boven REQ-03 (2%): $exceeding / $($Group.Count)")
    Write-Host ''
}

$distance = $parsed[0].Distance
Write-Host "=== Analyse van $CsvPath (afstandscategorie '$distance') ===" -ForegroundColor Green
Write-Host ''

$zonderDfs = $parsed | Where-Object { -not $_.DfsEvent }
$metDfs = $parsed | Where-Object { $_.DfsEvent }

Get-LossStats -Group $parsed -Label 'ALLE trials (ruw gemiddelde, zoals oorspronkelijk gerapporteerd)'
Get-LossStats -Group $zonderDfs -Label 'ZONDER DFS-gebeurtenis (relevant voor REQ-03: normale kanaalwerking)'
Get-LossStats -Group $metDfs -Label 'MET DFS-gebeurtenis (relevant voor FR-06: herstel na onderbreking)'
