#Requires -Version 5.1
# PocFunctions.psm1
#
# Herbruikbare functies voor de volledig native Windows-opbouw van de
# PoC-testomgeving. Vereist geen WSL, geen Linux, geen extra downloads:
# alles steunt op onderdelen die standaard in Windows 10/11 aanwezig zijn
# (PowerShell, .NET, IMAPI2FS, OpenSSH-client).

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-Vbox {
    <#
        Roept VBoxManage aan en controleert expliciet de exit code.

        Belangrijk: Windows PowerShell behandelt, bij $ErrorActionPreference =
        'Stop', alle tekst die een native .exe naar stderr schrijft als een
        terminating error -- ook onschuldige statusmeldingen van VBoxManage
        die niets met een echte fout te maken hebben. Deze functie zet de
        preference tijdelijk op 'Continue' zodat zulke meldingen het script
        niet stil laten crashen, en controleert nadien zelf $LASTEXITCODE om
        een ECHTE fout alsnog luid en duidelijk te laten stoppen.
    #>
    param([Parameter(Mandatory)][string]$VBoxManage, [Parameter(ValueFromRemainingArguments)][string[]]$Arguments)

    $prevPref = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $VBoxManage @Arguments 2>&1 | ForEach-Object { Write-Host $_ }
    }
    finally {
        $ErrorActionPreference = $prevPref
    }
    if ($LASTEXITCODE -ne 0) {
        throw "VBoxManage $($Arguments -join ' ') is mislukt (exit code $LASTEXITCODE). Zie de melding hierboven."
    }
}

function Clear-StaleVBoxMedium {
    <#
        Zorgt dat VirtualBox geen "spookregistratie" meer heeft voor een
        schijfbestand op het opgegeven pad. VirtualBox houdt zijn eigen
        interne register (los van het bestandssysteem) bij van elke schijf
        die het ooit heeft gezien. Als zo'n .vdi-bestand buiten VirtualBox om
        wordt verwijderd of vervangen (bv. handmatig via de Verkenner, of
        door een eerder afgebroken script), blijft die registratie bestaan
        en levert een latere poging om op datzelfde pad een nieuwe schijf
        aan te maken de fout "hard disk ... already exists" op. Deze functie
        spoort zo'n registratie op en koppelt ze netjes los.
    #>
    param(
        [Parameter(Mandatory)][string]$VBoxManage,
        [Parameter(Mandatory)][string]$MediumPath
    )

    if (-not (Test-Path -LiteralPath $MediumPath -IsValid)) { return }
    $normalizedTarget = [System.IO.Path]::GetFullPath($MediumPath)

    $prevPref = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $listOutput = & $VBoxManage list hdds 2>&1
    $ErrorActionPreference = $prevPref

    $currentUuid = $null
    foreach ($line in $listOutput) {
        if ($line -match '^UUID:\s*(.+)$') {
            $currentUuid = $Matches[1].Trim()
        }
        elseif ($line -match '^Location:\s*(.+)$') {
            $loc = $Matches[1].Trim()
            $normalizedLoc = $null
            try { $normalizedLoc = [System.IO.Path]::GetFullPath($loc) } catch { }
            if ($currentUuid -and $normalizedLoc -and ($normalizedLoc -eq $normalizedTarget)) {
                Write-Host "==> Verweesde VirtualBox-registratie gevonden voor `"$MediumPath`" (UUID $currentUuid), wordt losgekoppeld..."
                $prevPref2 = $ErrorActionPreference
                $ErrorActionPreference = 'Continue'
                & $VBoxManage closemedium disk $currentUuid 2>&1 | Out-Null
                $ErrorActionPreference = $prevPref2
                $currentUuid = $null
            }
        }
    }
}

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
    # BELANGRIJK: pure ISO9660 (waarde 1) staat enkel 8.3-bestandsnamen in
    # hoofdletters toe. Onze bestanden heten letterlijk "user-data" en
    # "meta-data" (kleine letters, met een koppelteken) -- zonder Joliet
    # worden die stilzwijgend herschreven tot iets als "USER-DA.;1", wat
    # cloud-init's NoCloud-detectie (die specifiek zoekt naar bestanden met
    # de EXACTE naam "user-data"/"meta-data") nooit terugvindt. Daardoor
    # werd tot nu toe onze volledige configuratie genegeerd: geen gebruiker,
    # geen wachtwoord-auth, geen SSH-sleutel. Met Joliet erbij (waarde 3)
    # blijven de originele, kleine-letter-bestandsnamen intact.
    $fsi.FileSystemsToCreate = 3   # ISO9660 + Joliet
    $fsi.VolumeName = $VolumeLabel

    $root = $fsi.Root
    Get-ChildItem -LiteralPath $SourceFolder -File | ForEach-Object {
        $root.AddTree($_.FullName, $false)
    }

    $result = $fsi.CreateResultImage()
    [PocIsoWriter.IsoFile]::Write($DestinationIso, $result.ImageStream, $result.BlockSize, $result.TotalBlocks)
}

function Wait-ForCloudInit {
    <#
        Wacht tot cloud-init op de opgegeven VM ECHT volledig is afgerond,
        via het daarvoor bedoelde commando "cloud-init status --wait".

        Dit is een betere graadmeter dan enkel controleren of de SSH-poort
        bereikbaar is: sshd start vaak al binnen enkele seconden, terwijl
        cloud-init zelf (pakketupdates, write_files, runcmd -- inclusief
        het wegschrijven van /etc/poc-ifaces.env) daarna nog several
        minuten kan doorlopen. Zonder deze check kan scenario-select.sh
        lopen vóór cloud-init klaar is, met "No such file or directory"
        voor /etc/poc-ifaces.env tot gevolg.
    #>
    param(
        [Parameter(Mandatory)][string]$Ssh,
        [Parameter(Mandatory)][string]$KeyPath,
        [Parameter(Mandatory)][int]$Port,
        [int]$TimeoutSeconds = 600
    )

    Write-Host "==> Wachten tot cloud-init op poort $Port volledig is afgerond (kan enkele minuten duren)..."
    $prevPref = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & $Ssh -p $Port -i $KeyPath -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL `
        -o ConnectTimeout=10 -o ConnectionAttempts=3 `
        poc@127.0.0.1 "timeout $TimeoutSeconds cloud-init status --wait" 2>&1 | ForEach-Object { Write-Host "   $_" }
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = $prevPref

    if ($exitCode -eq 0) {
        Write-Host "   cloud-init is volledig klaar." -ForegroundColor Green
    } else {
        Write-Host "   Waarschuwing: 'cloud-init status --wait' gaf code $exitCode terug; ga toch verder." -ForegroundColor Yellow
    }
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
        Genereert (indien nog niet aanwezig, of indien de bestaande sleutel
        onbruikbaar blijkt) een apart SSH-sleutelpaar voor de PoC-omgeving,
        zodat alle scripts volledig automatisch (zonder wachtwoord in te
        typen) met de VM's kunnen praten.

        Een lege wachtwoordzin ("-N") rechtstreeks via PowerShell aan een
        native .exe doorgeven (bv. -N '""') is notoir onbetrouwbaar en
        versie-afhankelijk. .NET's ProcessStartInfo.ArgumentList lost dit
        normaal betrouwbaar op, maar is pas beschikbaar vanaf .NET Framework
        4.7.2 -- niet elk Windows-toestel heeft dat. Daarom wordt hier in
        plaats daarvan cmd.exe als tussenpersoon gebruikt: cmd.exe's eigen,
        eenvoudigere manier om een commandoregel te ontleden interpreteert
        "" (twee aanhalingstekens na elkaar) altijd correct als een lege
        argumentwaarde, ongeacht de PowerShell- of .NET-versie.
    #>
    param([Parameter(Mandatory)][string]$KeyPath)

    $keygen = Get-Command 'ssh-keygen.exe' -ErrorAction SilentlyContinue
    if (-not $keygen) {
        $keygen = "$env:WINDIR\System32\OpenSSH\ssh-keygen.exe"
    } else {
        $keygen = $keygen.Source
    }

    if (Test-Path -LiteralPath $KeyPath) {
        # Controleer of de bestaande sleutel effectief zonder wachtwoordzin
        # bruikbaar is. Sleutels aangemaakt vóór deze fix kunnen per ongeluk
        # toch een wachtwoordzin gekregen hebben, wat zich uit als
        # "Permission denied (publickey)". Zo'n kapotte sleutel wordt hier
        # automatisch vervangen in plaats van blindelings hergebruikt.
        $prevPref = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        cmd.exe /c "`"$keygen`" -y -f `"$KeyPath`" -P `"`"" 2>&1 | Out-Null
        $testExitCode = $LASTEXITCODE
        $ErrorActionPreference = $prevPref

        if ($testExitCode -eq 0) {
            return Get-Content -LiteralPath "$KeyPath.pub" -Raw
        }
        Write-Host 'Bestaande SSH-sleutel blijkt een wachtwoordzin te hebben (van vóór een eerdere correctie); wordt vervangen...' -ForegroundColor Yellow
        Remove-Item -LiteralPath $KeyPath, "$KeyPath.pub" -Force -ErrorAction SilentlyContinue
    }

    $dir = Split-Path -Parent $KeyPath
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $prevPref = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    cmd.exe /c "`"$keygen`" -t ed25519 -f `"$KeyPath`" -N `"`" -C poc-scripts -q" 2>&1 | Out-Null
    $genExitCode = $LASTEXITCODE
    $ErrorActionPreference = $prevPref
    if ($genExitCode -ne 0) {
        throw "ssh-keygen is mislukt (exit code $genExitCode)."
    }

    # Beperk de bestandsrechten op de private sleutel tot enkel de huidige
    # gebruiker (Windows-equivalent van chmod 600). Zonder dit kan de
    # OpenSSH-client de sleutel stilzwijgend weigeren als "te toegankelijk
    # voor anderen", wat zich ook uit als "Permission denied (publickey)".
    icacls $KeyPath /inheritance:r | Out-Null
    icacls $KeyPath /grant:r "$($env:USERDOMAIN)\$($env:USERNAME):(R)" | Out-Null

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

        $metaData = "instance-id: $Hostname`nlocal-hostname: $Hostname`n"

        # BELANGRIJK: Set-Content -Encoding utf8 schrijft in Windows
        # PowerShell 5.1 een UTF-8 BOM (byte-order mark) aan het begin van
        # het bestand. cloud-init verwacht dat user-data LETTERLIJK begint
        # met "#cloud-config"; een onzichtbare BOM ervoor kan cloud-init
        # doen besluiten dat het bestand geen geldig cloud-config is, en het
        # dan stilzwijgend negeren -- met als gevolg dat geen enkele
        # instelling (ook niet de SSH-sleutel) ooit toegepast wordt. Daarom
        # wordt hier expliciet BOM-loze UTF-8 weggeschreven via .NET.
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText((Join-Path $tmp 'user-data'), $userData, $utf8NoBom)
        [System.IO.File]::WriteAllText((Join-Path $tmp 'meta-data'), $metaData, $utf8NoBom)

        New-IsoFile -SourceFolder $tmp -DestinationIso $OutIso -VolumeLabel 'cidata'
    }
    finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Remove-StaleVmFolder {
    <#
        Verwijdert een eventueel overgebleven VM-map op VirtualBox's
        standaardlocatie (bv. "C:\Users\<naam>\VirtualBox VMs\<vmnaam>")
        vóórdat een nieuwe VM met diezelfde naam wordt aangemaakt.

        Dit vangt de laatste variant van de "verweesde staat"-problematiek
        op: als een eerdere opruiming de VM enkel losgekoppeld heeft (zonder
        --delete, omdat --delete zelf al mislukte op een ontbrekend
        schijfbestand), blijft de volledige VM-map -- inclusief het
        .vbox-instellingenbestand -- gewoon op schijf staan, ook al is de VM
        zelf niet meer geregistreerd. VirtualBox weigert dan later een
        nieuwe VM met dezelfde naam aan te maken omdat dat instellingen-
        bestand al bestaat.
    #>
    param(
        [Parameter(Mandatory)][string]$VBoxManage,
        [Parameter(Mandatory)][string]$VmName
    )

    $prevPref = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $props = & $VBoxManage list systemproperties 2>&1
    $ErrorActionPreference = $prevPref

    $defaultFolder = $null
    foreach ($line in $props) {
        if ($line -match '^Default machine folder:\s*(.+)$') {
            $defaultFolder = $Matches[1].Trim()
            break
        }
    }
    if (-not $defaultFolder) { return }

    $vmFolder = Join-Path $defaultFolder $VmName
    if (Test-Path -LiteralPath $vmFolder) {
        Write-Host "==> Verweesde VM-map gevonden voor '$VmName' ($vmFolder), wordt verwijderd..."
        Remove-Item -LiteralPath $vmFolder -Recurse -Force -ErrorAction SilentlyContinue
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

    # Verwijder expliciet een eventueel overgebleven schijf/ISO van een
    # vorige (mogelijk mislukte) run. Zonder dit kan clonemedium falen op
    # een reeds bestaand bestand, of erger: stilzwijgend doorwerken op een
    # VERSTE, verouderde schijf -- inclusief een oude cloud-init-ISO zonder
    # de huidige SSH-sleutel, wat zich uit als "Permission denied (publickey)".
    Remove-Item -LiteralPath $vmDisk, $seedIso -Force -ErrorAction SilentlyContinue
    Clear-StaleVBoxMedium -VBoxManage $VBoxManage -MediumPath $vmDisk

    Invoke-Vbox $VBoxManage clonemedium disk $BaseVdi $vmDisk --format VDI
    Invoke-Vbox $VBoxManage modifymedium disk $vmDisk --resize $DiskSizeMb

    $template = Join-Path $CloudInitDir "$Role-user-data.yaml"
    New-PocSeedIso -TemplatePath $template -Hostname $Hostname -SshPublicKey $SshPublicKey -OutIso $seedIso

    Remove-StaleVmFolder -VBoxManage $VBoxManage -VmName $VmName
    Invoke-Vbox $VBoxManage createvm --name $VmName --ostype Ubuntu_64 --register
    Invoke-Vbox $VBoxManage modifyvm $VmName `
        --memory $MemoryMb --cpus $Cpus `
        --nic1 nat --natpf1 "ssh,tcp,127.0.0.1,$MgmtSshHostPort,,22" `
        --nic2 intnet --intnet2 $LinkANet --nicpromisc2 allow-all `
        --audio none --usb off

    if ($LinkBNet) {
        # Cruciaal voor de link-emulator: zonder "allow-all" op de interne-
        # netwerkadapters filtert VirtualBox elk frame weg dat niet voor het
        # MAC-adres van deze specifieke VM bedoeld is. Een brug moet echter
        # net frames doorsturen die voor de MAC-adressen van de server en de
        # client bestemd zijn -- zonder promiscuous mode komt dat verkeer
        # nooit binnen, ook al is de Linux-brug zelf perfect geconfigureerd.
        Invoke-Vbox $VBoxManage modifyvm $VmName --nic3 intnet --intnet3 $LinkBNet --nicpromisc3 allow-all
    }

    Invoke-Vbox $VBoxManage storagectl $VmName --name SATA --add sata --controller IntelAHCI
    Invoke-Vbox $VBoxManage storageattach $VmName --storagectl SATA --port 0 --device 0 --type hdd --medium $vmDisk
    Invoke-Vbox $VBoxManage storageattach $VmName --storagectl SATA --port 1 --device 0 --type dvddrive --medium $seedIso

    Invoke-Vbox $VBoxManage startvm $VmName --type headless

    Write-Host "==> [$VmName] opgestart, cloud-init installeert nu automatisch (rol: $Role)" -ForegroundColor Cyan
}

Export-ModuleMember -Function *
