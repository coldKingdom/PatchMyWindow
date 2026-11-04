#requires -Version 5.1

function Test-PmwPathWithin([string]$Path, [string]$Parent) {
    $Path -eq $Parent -or $Path.StartsWith($Parent.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Invoke-PmwMediaTool([string]$File, [string[]]$Arguments, [string]$Log) {
    # No shell. These arguments contain no embedded quotes or trailing directory slashes.
    foreach ($argument in $Arguments) { if ($argument.Contains('"') -or $argument.EndsWith('\')) { throw 'Ogiltigt argument till mediaverktyget.' } }
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $File
    $start.Arguments = (($Arguments | ForEach-Object { '"' + $_ + '"' }) -join ' ')
    $start.UseShellExecute = $false; $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    try {
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $stdout.Result, $stderr.Result | Out-File -LiteralPath $Log -Append -Encoding UTF8
        if ($process.ExitCode -ne 0) { throw "$([IO.Path]::GetFileName($File)) misslyckades (kod $($process.ExitCode)). Se $Log" }
    } finally { $process.Dispose() }
}

function New-PmwMediaISO($Session, [string]$Root, $Request, $Events) {
    $source = Get-PmwFullPath $Request.MediaSource
    # Get-PmwFullPath strips trailing slashes; restore the slash for a mounted ISO drive root.
    if ($source -match '^[A-Za-z]:$') { $source += '\' }
    $iso = Assert-PmwLocalPath $Request.IsoPath
    $oscdimg = Get-PmwFullPath $Request.Oscdimg
    if ([IO.Path]::GetExtension($iso) -ne '.iso') { throw 'Resultatet måste vara en .iso-fil.' }
    if (Test-Path -LiteralPath $iso) { throw 'ISO-filen finns redan. Välj ett nytt filnamn.' }
    if (-not (Test-Path -LiteralPath (Split-Path $iso -Parent) -PathType Container)) { throw 'Mappen för ISO-resultatet måste finnas.' }
    if (-not (Test-Path -LiteralPath $source -PathType Container)) { throw 'Välj roten på ett monterat ISO-media eller en mediakopia.' }
    if (-not (Test-Path -LiteralPath $oscdimg -PathType Leaf) -or [IO.Path]::GetFileName($oscdimg) -ine 'oscdimg.exe') { throw 'Välj oscdimg.exe från Windows ADK Deployment Tools.' }
    if ((Test-PmwPathWithin $iso $source) -or (Test-PmwPathWithin $Root $source) -or (Test-PmwPathWithin $source $Root)) { throw 'Originalmedia, arbetsmapp och ISO-resultat får inte överlappa.' }
    foreach ($relative in @('setup.exe', 'sources\boot.wim', 'efi\microsoft\boot\efisys.bin')) {
        if (-not (Test-Path -LiteralPath (Join-Path $source $relative) -PathType Leaf)) { throw "Installationsmediet saknar $relative" }
    }
    $du = ''
    if (-not [string]::IsNullOrWhiteSpace([string]$Request.SetupDU)) {
        $du = Get-PmwFullPath $Request.SetupDU
        if ([IO.Path]::GetExtension($du) -ne '.cab' -or -not (Test-Path -LiteralPath $du -PathType Leaf)) { throw 'Setup Dynamic Update måste vara en befintlig CAB-fil.' }
    }
    $image = Get-WindowsImage -ImagePath $Session.Output -Index 1 -ErrorAction Stop
    $boot = Get-WindowsImage -ImagePath (Join-Path $source 'sources\boot.wim') -Index 2 -ErrorAction Stop
    if ([string]$image.Architecture -ne [string]$boot.Architecture -or ([version]$image.Version).Major -ne ([version]$boot.Version).Major -or ([version]$image.Version).Build -ne ([version]$boot.Version).Build) {
        throw 'Windows-image och boot.wim måste ha samma arkitektur och basbuild. Välj matchande originalmedia.'
    }
    $bios = Join-Path $source 'boot\etfsboot.com'
    # DISM Architecture: 9 = amd64, 12 = arm64. ARM64 media uses UEFI only.
    if ([string]$image.Architecture -notin @('9', '12', 'amd64', 'arm64', 'x64')) { throw 'ISO-flödet stöder Windows 11 x64 och ARM64.' }
    $isArm = [string]$image.Architecture -in @('12', 'arm64')
    if (-not $isArm -and -not (Test-Path -LiteralPath $bios -PathType Leaf)) { throw 'x64-mediet saknar boot\etfsboot.com.' }
    # Reject links before traversal; never copy a junction outside the chosen source tree.
    $files = New-Object 'Collections.Generic.List[object]'
    $pending = New-Object 'Collections.Generic.Queue[string]'
    $pending.Enqueue($source)
    while ($pending.Count) {
        $directory = $pending.Dequeue()
        if ((Get-Item -LiteralPath $directory -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Media innehåller en länk: $directory" }
        foreach ($entry in Get-ChildItem -LiteralPath $directory -Force) {
            if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Media innehåller en länk: $($entry.FullName)" }
            if ($entry.PSIsContainer) { $pending.Enqueue($entry.FullName) } else { $files.Add($entry) }
        }
    }
    $size = [long](($files | Measure-Object Length -Sum).Sum) + (Get-Item -LiteralPath $Session.Output).Length + 2GB
    $workDrive = New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($Root))
    $isoDrive = New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($iso))
    if (($workDrive.Name -eq $isoDrive.Name -and $workDrive.AvailableFreeSpace -lt (2 * $size)) -or $workDrive.AvailableFreeSpace -lt $size -or $isoDrive.AvailableFreeSpace -lt $size) { throw 'För lite ledigt utrymme för mediakopia och ISO. Frigör utrymme eller välj en annan disk.' }
    $build = Join-Path (Join-Path $Root 'MediaBuilds') ([guid]::NewGuid().ToString('N'))
    $media = Join-Path $build 'Media'
    $mount = Join-Path $build 'BootMount'
    $nativeLog = Join-Path $build 'tools.log'
    $journal = Join-Path $build 'media.json'
    $partial = Join-Path (Split-Path $iso -Parent) ('.pmw-' + [guid]::NewGuid().ToString('N') + '.partial.iso')
    New-Item -ItemType Directory -Path $media -Force | Out-Null
    $state = [ordered]@{ Source = $source; Image = $Session.Output; Output = $iso; SetupDU = $du; Mount = $mount; PartialISO = $partial; Phase = 'Copying'; Error = '' }
    $state | ConvertTo-Json | Set-Content -LiteralPath $journal -Encoding UTF8
    $mounted = $false
    try {
        Write-PmwLog $Session $Events "Kopierar installationsmedia till $media …"
        foreach ($file in $files) {
            $relative = $file.FullName.Substring($source.TrimEnd('\').Length).TrimStart('\')
            # Keep exactly one install image; never delete or overwrite original media.
            if ($relative -match '^sources\\install(?:\d+)?\.(wim|esd|swm)$') { continue }
            $destination = Join-Path $media $relative
            New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force | Out-Null
            Copy-Item -LiteralPath $file.FullName -Destination $destination -Force
            (Get-Item -LiteralPath $destination -Force).IsReadOnly = $false
        }
        Copy-Item -LiteralPath $Session.Output -Destination (Join-Path $media 'sources\install.wim')
        if ($du) {
            $state.Phase = 'SetupDU'; $state | ConvertTo-Json | Set-Content -LiteralPath $journal -Encoding UTF8
            Write-PmwLog $Session $Events 'Packar upp Setup Dynamic Update till mediakopians sources …'
            # Extract separately so an incorrect servicing CAB cannot become installation media.
            $extracted = Join-Path $build 'SetupDU'
            New-Item -ItemType Directory -Path $extracted | Out-Null
            Invoke-PmwMediaTool "$env:SystemRoot\System32\expand.exe" @($du, '-F:*', $extracted) $nativeLog
            if ((Test-Path -LiteralPath (Join-Path $extracted 'update.mum')) -or -not (Test-Path -LiteralPath (Join-Path $extracted 'setuphost.exe'))) { throw 'CAB-filen känns inte igen som Setup Dynamic Update. Välj Setup DU för mediets version och arkitektur.' }
            Get-ChildItem -LiteralPath $extracted -Force | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $media 'sources') -Recurse -Force }
            New-Item -ItemType Directory -Path $mount | Out-Null
            $state.Phase = 'MountingBootReadOnly'; $state | ConvertTo-Json | Set-Content -LiteralPath $journal -Encoding UTF8
            Mount-WindowsImage -ImagePath (Join-Path $media 'sources\boot.wim') -Index 2 -Path $mount -ReadOnly -LogPath (Join-Path $build 'dism.log') -ErrorAction Stop | Out-Null
            $mounted = $true
            Write-PmwLog $Session $Events 'Synkroniserar setup.exe och setuphost.exe från boot.wim enligt Microsofts mediaflöde …'
            Copy-Item -LiteralPath (Join-Path $mount 'sources\setup.exe') -Destination (Join-Path $media 'sources\setup.exe') -Force
            if ([version]$boot.Version -ge [version]'10.0.26100') {
                Copy-Item -LiteralPath (Join-Path $mount 'sources\setuphost.exe') -Destination (Join-Path $media 'sources\setuphost.exe') -Force
            }
            Dismount-WindowsImage -Path $mount -Discard -ErrorAction Stop | Out-Null
            $mounted = $false
        }
        $state.Phase = 'BuildingISO'; $state | ConvertTo-Json | Set-Content -LiteralPath $journal -Encoding UTF8
        $efi = Join-Path $media 'efi\microsoft\boot\efisys.bin'
        $bootArg = if ($isArm) { '-bootdata:1#pEF,e,b' + $efi } else { '-bootdata:2#p0,e,b' + (Join-Path $media 'boot\etfsboot.com') + '#pEF,e,b' + $efi }
        Write-PmwLog $Session $Events 'Bygger startbar ISO med Oscdimg …'
        Invoke-PmwMediaTool $oscdimg @('-m', '-o', '-h', '-u2', '-udfver102', '-lPATCHMYWINDOW', $bootArg, $media, $partial) $nativeLog
        if (-not (Test-Path -LiteralPath $partial -PathType Leaf) -or (Get-Item -LiteralPath $partial).Length -eq 0) { throw 'Oscdimg skapade ingen ISO-fil.' }
        [IO.File]::Move($partial, $iso)
        $state.Phase = 'Complete'; $state | ConvertTo-Json | Set-Content -LiteralPath $journal -Encoding UTF8
        Write-PmwLog $Session $Events "ISO klar: $iso. Mediakopia och loggar: $build"
        $iso
    } catch {
        $state.Phase = 'Failed'; $state.Error = $_.Exception.Message
        $state | ConvertTo-Json | Set-Content -LiteralPath $journal -Encoding UTF8
        throw
    } finally {
        if ($mounted) {
            try { Dismount-WindowsImage -Path $mount -Discard -ErrorAction Stop | Out-Null }
            catch { Write-PmwLog $Session $Events "Kunde inte avmontera den skrivskyddade boot.wim: $mount. Avmontera denna sökväg med DISM före borttagning av arbetsmappen. $($_.Exception.Message)" }
        }
    }
}
