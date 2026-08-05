#Requires -Version 5.1
# PocFunctions.psm1
#
# Herbruikbare functies voor de volledig native Windows-opbouw van de
# PoC-testomgeving. Vereist geen WSL, geen Linux, geen extra downloads:
# alles steunt op onderdelen die standaard in Windows 10/11 aanwezig zijn
# (PowerShell, .NET, IMAPI2FS, OpenSSH-client).

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-VBoxManagePath {
    <#
        Zoekt VBoxManage.exe op: eerst in PATH, anders op de twee
        gebruikelijke installatielocaties. Geeft een duidelijke Nederlandse
        foutmelding als VirtualBox niet gevonden wordt.
    #>
    $cmd = Get-Command 'VBoxManage.exe' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $candidates = @(
        "$env:ProgramFiles\Oracle\VirtualBox\VBoxManage.exe",
        "${env:ProgramFiles(x86)}\Oracle\VirtualBox\VBoxManage.exe"
    )
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) { return $c }
    }

    Write-Host ''
    Write-Host 'VirtualBox werd niet gevonden op dit toestel.' -ForegroundColor Red
    Write-Host 'Installeer VirtualBox eerst via https://www.virtualbox.org/wiki/Downloads' -ForegroundColor Yellow
    Write-Host 'en voer dit script daarna opnieuw uit.' -ForegroundColor Yellow
    Write-Host ''
    $answer = Read-Host 'Wil je de downloadpagina nu openen? (j/n)'
    if ($answer -match '^[jJ]') {
        Start-Process 'https://www.virtualbox.org/wiki/Downloads'
    }
    throw 'VirtualBox (VBoxManage.exe) niet gevonden.'
}

function New-IsoFile {
    <#
        Bouwt een ISO9660-bestand (cloud-init "NoCloud" seed) uit alle
        bestanden in $SourceFolder, met het opgegeven volumelabel.
        Gebruikt uitsluitend ingebouwde Windows-componenten (IMAPI2FS,
        onderdeel van Windows sinds Vista) -- geen extra software nodig.
    #>
    param(
        [Parameter(Mandatory)][string]$SourceFolder,
        [Parameter(Mandatory)][string]$DestinationIso,
        [string]$VolumeLabel = 'cidata'
    )

    if (Test-Path -LiteralPath $DestinationIso) {
        Remove-Item -LiteralPath $DestinationIso -Force
    }

    # Kleine C#-helper om de COM IStream van IMAPI2FS naar een bestand te
    # schrijven. Dit is de standaardaanpak om vanuit PowerShell, zonder
    # externe tools, een ISO-bestand weg te schrijven. Het effectief aantal
    # gelezen bytes per blok wordt bijgehouden (via een unsafe pointer),
    # zodat het laatste blok nooit met te veel bytes wordt weggeschreven.
    if (-not ('PocIsoWriter.IsoFile' -as [type])) {
        $compilerParams = New-Object System.CodeDom.Compiler.CompilerParameters
        $compilerParams.CompilerOptions = '/unsafe'
        Add-Type -CompilerParameters $compilerParams -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices.ComTypes;
namespace PocIsoWriter {
    public static class IsoFile {
        public unsafe static void Write(string path, object stream, int blockSize, long totalBlocks) {
            int bytesRead = 0;
            IntPtr pBytesRead = (IntPtr)(&bytesRead);
            var iStream = (IStream)stream;
            var outFile = File.OpenWrite(path);
            var buffer = new byte[blockSize];
            while (totalBlocks-- > 0) {
                iStream.Read(buffer, blockSize, pBytesRead);
                outFile.Write(buffer, 0, bytesRead);
            }
            outFile.Flush();
            outFile.Close();
        }
    }
}
'@
    }

    $fsi = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
    $fsi.FileSystemsToCreate = 1   # ISO9660 -- meest compatibel, alles wat cloud-init nodig heeft
    $fsi.VolumeName = $VolumeLabel

    $root = $fsi.Root
    Get-ChildItem -LiteralPath $SourceFolder -File | ForEach-Object {
        $root.AddTree($_.FullName, $false)
    }

    $result = $fsi.CreateResultImage()
    [PocIsoWriter.IsoFile]::Write($DestinationIso, $result.ImageStream, $result.BlockSize, $result.TotalBlocks)
}

function Wait-ForPort {
    <#
        Wacht tot een TCP-poort op 127.0.0.1 bereikbaar is (signaal dat
        cloud-init de eerste boot van een VM heeft afgerond).
    #>
    param(
        [Parameter(Mandatory)][int]$Port,
        [int]$TimeoutSeconds = 300
    )
    $elapsed = 0
    Write-Host -NoNewline "==> Wachten tot poort $Port (SSH) bereikbaar is "
    while ($true) {
        $test = Test-NetConnection -ComputerName '127.0.0.1' -Port $Port -WarningAction SilentlyContinue
        if ($test.TcpTestSucceeded) {
            Write-Host ' OK' -ForegroundColor Green
            return
        }
        Start-Sleep -Seconds 5
        $elapsed += 5
        Write-Host -NoNewline '.'
        if ($elapsed -ge $TimeoutSeconds) {
            Write-Host ' TIMEOUT' -ForegroundColor Red
            throw "Poort $Port werd niet bereikbaar binnen $TimeoutSeconds seconden."
        }
    }
}

function Get-SshCommand {
    <#
        Geeft het pad naar ssh.exe terug. Windows 10 (1809+) en Windows 11
        hebben de OpenSSH-client standaard geïnstalleerd. Als dat niet zo is,
        wordt geprobeerd hem automatisch te activeren (vereist geen
        beheerdersrechten op de meeste Windows 11-installaties omdat de
        component vaak al aanwezig, maar niet in PATH, staat).
    #>
    $cmd = Get-Command 'ssh.exe' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $fallback = "$env:WINDIR\System32\OpenSSH\ssh.exe"
    if (Test-Path -LiteralPath $fallback) { return $fallback }

    Write-Host 'De OpenSSH-client werd niet gevonden.' -ForegroundColor Yellow
    Write-Host 'Ga naar Instellingen > Systeem > Optionele onderdelen > Onderdeel toevoegen' -ForegroundColor Yellow
    Write-Host 'en installeer "OpenSSH-client", of voer uit (als beheerder):' -ForegroundColor Yellow
    Write-Host '  Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0' -ForegroundColor Yellow
    throw 'ssh.exe niet gevonden.'
}

function Initialize-PocSshKey {
    <#
        Genereert (indien nog niet aanwezig) een apart SSH-sleutelpaar voor
        de PoC-omgeving, zodat alle scripts volledig automatisch (zonder
        wachtwoord in te typen) met de VM's kunnen praten.
    #>
    param([Parameter(Mandatory)][string]$KeyPath)

    if (Test-Path -LiteralPath $KeyPath) {
        return Get-Content -LiteralPath "$KeyPath.pub" -Raw
    }

    $dir = Split-Path -Parent $KeyPath
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $keygen = Get-Command 'ssh-keygen.exe' -ErrorAction SilentlyContinue
    if (-not $keygen) {
        $keygen = "$env:WINDIR\System32\OpenSSH\ssh-keygen.exe"
    } else {
        $keygen = $keygen.Source
    }

    & $keygen -t ed25519 -N '""' -C 'poc-scripts' -f $KeyPath | Out-Null
    return Get-Content -LiteralPath "$KeyPath.pub" -Raw
}

function New-PocSeedIso {
    <#
        Bouwt de cloud-init seed-ISO voor één rol: leest het YAML-sjabloon,
        vult hostnaam en publieke SSH-sleutel in, en verpakt het resultaat.
    #>
    param(
        [Parameter(Mandatory)][string]$TemplatePath,
        [Parameter(Mandatory)][string]$Hostname,
        [Parameter(Mandatory)][string]$SshPublicKey,
        [Parameter(Mandatory)][string]$OutIso
    )

    $tmp = Join-Path $env:TEMP ("pocseed-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        $userData = Get-Content -LiteralPath $TemplatePath -Raw
        $userData = $userData -replace '__SSH_PUBLIC_KEY__', $SshPublicKey.Trim()
        Set-Content -LiteralPath (Join-Path $tmp 'user-data') -Value $userData -NoNewline -Encoding utf8

        $metaData = "instance-id: $Hostname`nlocal-hostname: $Hostname`n"
        Set-Content -LiteralPath (Join-Path $tmp 'meta-data') -Value $metaData -NoNewline -Encoding utf8

        New-IsoFile -SourceFolder $tmp -DestinationIso $OutIso -VolumeLabel 'cidata'
    }
    finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function New-PocVm {
    <#
        Maakt en start één VirtualBox-VM aan: kloont de basisschijf, bouwt de
        cloud-init-ISO op maat van de rol, koppelt de netwerkadapters volgens
        de dumbbell-topologie, en start de VM op.
    #>
    param(
        [Parameter(Mandatory)][string]$VBoxManage,
        [Parameter(Mandatory)][string]$VmName,
        [Parameter(Mandatory)][string]$Role,
        [Parameter(Mandatory)][string]$Hostname,
        [Parameter(Mandatory)][string]$BaseVdi,
        [Parameter(Mandatory)][string]$WorkDir,
        [Parameter(Mandatory)][string]$CloudInitDir,
        [Parameter(Mandatory)][string]$SshPublicKey,
        [Parameter(Mandatory)][int]$MgmtSshHostPort,
        [Parameter(Mandatory)][string]$LinkANet,
        [string]$LinkBNet = '',
        [int]$MemoryMb = 1024,
        [int]$Cpus = 1,
        [int]$DiskSizeMb = 8192
    )

    Write-Host "==> [$VmName] VM aanmaken (rol: $Role)" -ForegroundColor Cyan

    $disksDir = Join-Path $WorkDir 'disks'
    $seedsDir = Join-Path $WorkDir 'seeds'
    New-Item -ItemType Directory -Path $disksDir, $seedsDir -Force | Out-Null

    $vmDisk = Join-Path $disksDir "$VmName.vdi"
    $seedIso = Join-Path $seedsDir "$VmName-seed.iso"

    & $VBoxManage clonemedium disk $BaseVdi $vmDisk --format VDI
    & $VBoxManage modifymedium disk $vmDisk --resize $DiskSizeMb

    $template = Join-Path $CloudInitDir "$Role-user-data.yaml"
    New-PocSeedIso -TemplatePath $template -Hostname $Hostname -SshPublicKey $SshPublicKey -OutIso $seedIso

    & $VBoxManage createvm --name $VmName --ostype Ubuntu_64 --register
    & $VBoxManage modifyvm $VmName `
        --memory $MemoryMb --cpus $Cpus `
        --nic1 nat --natpf1 "ssh,tcp,127.0.0.1,$MgmtSshHostPort,,22" `
        --nic2 intnet --intnet2 $LinkANet `
        --audio none --usb off

    if ($LinkBNet) {
        & $VBoxManage modifyvm $VmName --nic3 intnet --intnet3 $LinkBNet
    }

    & $VBoxManage storagectl $VmName --name SATA --add sata --controller IntelAHCI
    & $VBoxManage storageattach $VmName --storagectl SATA --port 0 --device 0 --type hdd --medium $vmDisk
    & $VBoxManage storageattach $VmName --storagectl SATA --port 1 --device 0 --type dvddrive --medium $seedIso

    & $VBoxManage startvm $VmName --type headless

    Write-Host "==> [$VmName] opgestart, cloud-init installeert nu automatisch (rol: $Role)" -ForegroundColor Cyan
}

Export-ModuleMember -Function *