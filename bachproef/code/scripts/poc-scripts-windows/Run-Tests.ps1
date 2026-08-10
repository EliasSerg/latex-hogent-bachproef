#Requires -Version 5.1
<#
    Run-Tests.ps1

    Voert, via SSH (met de automatisch gegenereerde sleutel) naar de
    client-VM, de standaard teststeekproef uit: REQ-01 doorvoersnelheid,
    REQ-02 latency, en een reÃ«le SFTP-overdracht voor FR-01/FR-02, tegen de
    server op het geÃ«muleerde linksegment (10.0.0.1).
#>

param(
    [int]$SshPortClient = 2224
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
$ServerIp = '10.0.0.1'

function Invoke-OnClient {
    param([Parameter(Mandatory)][string]$Command)
    & $ssh -p $SshPortClient -i $SshKeyPath `
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL -o ConnectTimeout=10 `
        poc@127.0.0.1 $Command
}

Write-Host '== REQ-01: doorvoersnelheid (iperf3) ==' -ForegroundColor Cyan
# "</dev/null" vermijdt een gekende eigenaardigheid van iperf3 die kan
# optreden bij niet-interactieve uitvoering via SSH met een ongebruikelijke
# stdin-toestand -- dit uit zich als "unable to send control message: Bad
# file descriptor". Dit wordt bewust NIET toegepast op de sftp-aanroep
# verderop, die zijn eigen stdin al beheert via een heredoc.
Invoke-OnClient "iperf3 -c $ServerIp -t 10 </dev/null"

Write-Host ''
Write-Host '== REQ-02: latency/jitter (mtr) ==' -ForegroundColor Cyan
Invoke-OnClient "mtr -r -c 20 $ServerIp"

Write-Host ''
Write-Host '== FR-01/FR-02: reele SFTP-bestandsoverdracht (20 MB testbestand) ==' -ForegroundColor Cyan
Invoke-OnClient 'dd if=/dev/urandom of=/tmp/testfile.bin bs=1M count=20 status=none'
Invoke-OnClient "sshpass -p sftp sftp -o StrictHostKeyChecking=no sftpuser@$ServerIp <<< `$'put /tmp/testfile.bin /upload/testfile.bin\nbye'"

Write-Host ''
Write-Host 'Teststeekproef afgerond.' -ForegroundColor Green
