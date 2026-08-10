#Requires -Version 5.1
<#
    Build-PoC.ps1

    Bouwt de volledige virtuele PoC-testomgeving met Ã©Ã©n script, volledig
    native op Windows -- geen WSL, geen Linux, geen extra installaties
    buiten VirtualBox zelf. Iedereen met een Windows 10/11-toestel kan dit
    uitvoeren door simpelweg 1-Build.bat te dubbelklikken.

    Wat dit script doet:
      1. Controleert of VirtualBox aanwezig is.
      2. Genereert (eenmalig) een apart SSH-sleutelpaar voor de PoC.
      3. Downloadt de Ubuntu Server cloud-image (eenmalig).
      4. Zet die om naar een VirtualBox VDI-basisschijf (eenmalig).
      5. Ruimt een eventuele vorige testopstelling op.
      6. Maakt de drie VM's aan (server, link-emulator, client) volgens de
         dumbbell-topologie, en start ze op.
      7. Wacht tot elke VM klaar is met zijn automatische installatie.
#>

param(
    [int]$SshPortServer = 2222,
    [int]$SshPortLinkEmu = 2223,
    [int]$SshPortClient = 2224
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $ScriptDir 'Modules\PocFunctions.psm1') -Force

$WorkDir = Join-Path $ScriptDir 'work'
$CloudInitDir = Join-Path $ScriptDir 'cloud-init'
$SshKeyPath = Join-Path $WorkDir 'ssh\poc_ed25519'

$ImgUrl = 'https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img'
$BaseImg = Join-Path $WorkDir 'base\jammy-server-cloudimg-amd64.img'
$BaseVdi = Join-Path $WorkDir 'base\jammy-server-cloudimg-amd64.vdi'

$NetLinkA = 'poc-link-a'
$NetLinkB = 'poc-link-b'

Write-Host '############################################################'
Write-Host '# Stap 0/6: controles vooraf'
Write-Host '############################################################'
$VBoxManage = Get-VBoxManagePath
Write-Host "VirtualBox gevonden: $VBoxManage" -ForegroundColor Green
Get-SshCommand | Out-Null
Write-Host 'OpenSSH-client gevonden.' -ForegroundColor Green

Write-Host ''
Write-Host '############################################################'
Write-Host '# Stap 1/6: SSH-sleutel voorbereiden'
Write-Host '############################################################'
$sshPublicKey = Initialize-PocSshKey -KeyPath $SshKeyPath
Write-Host 'SSH-sleutel klaar (poc-scripts logt hiermee automatisch in, geen wachtwoord nodig).' -ForegroundColor Green

Write-Host ''
Write-Host '############################################################'
Write-Host '# Stap 2/6: basisimage ophalen'
Write-Host '############################################################'
New-Item -ItemType Directory -Path (Split-Path -Parent $BaseImg) -Force | Out-Null
if (-not (Test-Path -LiteralPath $BaseImg)) {
    Write-Host 'Downloaden van de Ubuntu Server cloud-image (eenmalig, kan enkele minuten duren)...'
    Invoke-WebRequest -Uri $ImgUrl -OutFile $BaseImg
} else {
    Write-Host 'Basisimage al aanwezig, download overgeslagen.'
}

if (-not (Test-Path -LiteralPath $BaseVdi)) {
    Write-Host '==> Converteren naar VDI-formaat (eenmalig)'
    & $VBoxManage clonemedium disk $BaseImg $BaseVdi --format VDI
}

Write-Host ''
Write-Host '############################################################'
Write-Host '# Stap 3/6: bestaande PoC-VMs opruimen (indien aanwezig)'
Write-Host '############################################################'
$existingVms = & $VBoxManage list vms
foreach ($vm in @('poc-server', 'poc-link-emulator', 'poc-client')) {
    if ($existingVms -match [regex]::Escape("`"$vm`"")) {
        Write-Host "==> Bestaande VM '$vm' gevonden, wordt verwijderd."

        # Voer poweroff uit via cmd om NativeCommandError in PowerShell te voorkomen
        cmd.exe /c "`"$VBoxManage`" controlvm $vm poweroff >nul 2>&1"
        Start-Sleep -Seconds 2

        # Verwijder de VM via cmd
        cmd.exe /c "`"$VBoxManage`" unregistervm $vm --delete >nul 2>&1"
    }
}

Write-Host ''
Write-Host '############################################################'
Write-Host '# Stap 4/6: drie VMs aanmaken volgens de dumbbell-topologie'
Write-Host '############################################################'
$commonArgs = @{
    VBoxManage    = $VBoxManage
    BaseVdi       = $BaseVdi
    WorkDir       = $WorkDir
    CloudInitDir  = $CloudInitDir
    SshPublicKey  = $sshPublicKey
}

New-PocVm @commonArgs -VmName 'poc-server' -Role 'server' -Hostname 'poc-server' `
    -MgmtSshHostPort $SshPortServer -LinkANet $NetLinkA

New-PocVm @commonArgs -VmName 'poc-link-emulator' -Role 'link-emulator' -Hostname 'poc-link-emulator' `
    -MgmtSshHostPort $SshPortLinkEmu -LinkANet $NetLinkA -LinkBNet $NetLinkB

New-PocVm @commonArgs -VmName 'poc-client' -Role 'client' -Hostname 'poc-client' `
    -MgmtSshHostPort $SshPortClient -LinkANet $NetLinkB

Write-Host ''
Write-Host '############################################################'
Write-Host '# Stap 5/6: wachten tot cloud-init de eerste boot afrondt'
Write-Host '############################################################'
Wait-ForPort -Port $SshPortServer
Wait-ForPort -Port $SshPortLinkEmu
Wait-ForPort -Port $SshPortClient

Write-Host ''
Write-Host '############################################################'
Write-Host '# Stap 6/6: klaar'
Write-Host '############################################################'
Write-Host ''
Write-Host 'De volledige testopstelling is opgebouwd en actief:' -ForegroundColor Green
Write-Host "  poc-server         (SFTP-server)   ssh -p $SshPortServer -i `"$SshKeyPath`" poc@127.0.0.1"
Write-Host "  poc-link-emulator  (netem-bridge)  ssh -p $SshPortLinkEmu -i `"$SshKeyPath`" poc@127.0.0.1"
Write-Host "  poc-client         (SFTP-client)   ssh -p $SshPortClient -i `"$SshKeyPath`" poc@127.0.0.1"
Write-Host ''
Write-Host 'Kies een kanaalscenario met:'
Write-Host '  .\Select-Scenario.ps1 ideaal|marginaal|dfs'
Write-Host ''
Write-Host 'Voer de teststeekproef uit met:'
Write-Host '  .\Run-Tests.ps1'
Write-Host ''