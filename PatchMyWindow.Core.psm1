#requires -Version 5.1
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot 'PatchMyWindow.Media.ps1')

function Get-PmwFullPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathRooted($Path)) {
        throw 'Välj en fullständig lokal sökväg.'
    }
    [IO.Path]::GetFullPath($Path).TrimEnd('\')
}

function Assert-PmwLocalPath([string]$Path) {
    $full = Get-PmwFullPath $Path
    if ($full -notmatch '^[A-Za-z]:\\') { throw 'Arbetsmapp och resultat måste ligga på en lokal NTFS-disk.' }
    $drive = New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($full))
    if ($drive.DriveType -ne 'Fixed' -or $drive.DriveFormat -ne 'NTFS') {
        throw 'Arbetsmapp och resultat kräver en lokal, fast NTFS-disk.'
    }
    # Avoid junctions/symlinks redirecting mount or output paths elsewhere.
    $cursor = $full
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            if ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Sökvägen innehåller en länk eller junction: $cursor"
            }
        }
        $parent = [IO.Path]::GetDirectoryName($cursor)
        if ($parent -eq $cursor) { break }
        $cursor = $parent
    }
    $full
}

function Send-PmwEvent($Events, [string]$Kind, $Data) {
    if ($null -ne $Events) { $Events.Enqueue([pscustomobject]@{ Kind = $Kind; Data = $Data }) }
}

function Write-PmwLog($Session, $Events, [string]$Message) {
    $line = '{0:HH:mm:ss}  {1}' -f (Get-Date), $Message
    if ($Session) { Add-Content -LiteralPath $Session.AppLog -Value $line -Encoding UTF8 -ErrorAction Stop }
    Send-PmwEvent $Events 'Log' $line
}

function Save-PmwSession($Session, [string]$Root) {
    $path = Join-Path $Root 'active-session.json'
    $temp = Join-Path $Root 'active-session.tmp'
    $Session | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $temp -Encoding UTF8 -ErrorAction Stop
    if (Test-Path -LiteralPath $path) {
        [IO.File]::Replace($temp, $path, ($path + '.bak'))
    } else { [IO.File]::Move($temp, $path) }
}

function Initialize-PmwWinRe($Session) {
    if (-not $Session.PSObject.Properties['WinRE']) {
        $base = Split-Path $Session.MountPath -Parent
        $Session | Add-Member -NotePropertyName WinRE -NotePropertyValue ([pscustomobject]@{
            ImagePath = (Join-Path $base 'winre.wim')
            MountPath = (Join-Path $base 'WinREMount')
            Phase = 'None'
            Packages = @()
        })
    }
    # Older releases must refuse a journal that can own a second mount.
    if (-not $Session.PSObject.Properties['Finalization']) {
        $Session | Add-Member -NotePropertyName Finalization -NotePropertyValue ([pscustomobject]@{
            CleanupMode = 'Standard'; Optimize = $true
            WindowsCleanup = 'NotRun'; WinRECleanup = 'NotRun'; WinREOptimized = $false
            Warnings = @()
        })
    }
    if (-not $Session.PSObject.Properties['Languages']) {
        $Session | Add-Member -NotePropertyName Languages -NotePropertyValue ([pscustomobject]@{ Packages = @(); RequiresCU = $false })
    }
    if (-not $Session.PSObject.Properties['LXP']) { $Session | Add-Member -NotePropertyName LXP -NotePropertyValue @() }
    if (-not $Session.PSObject.Properties['Apps']) { $Session | Add-Member -NotePropertyName Apps -NotePropertyValue @() }
    if (-not $Session.PSObject.Properties['AppQueue']) { $Session | Add-Member -NotePropertyName AppQueue -NotePropertyValue @() }
    $Session.Schema = 7
}

function Read-PmwSession([string]$Root) {
    $path = Join-Path $Root 'active-session.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $s = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($s.Schema -notin @(1, 2, 3, 4, 5, 6, 7) -or $s.Id -notmatch '^[a-f0-9]{32}$') { throw 'Sessionsfilen har ett okänt format.' }
    if ($s.Schema -ge 2 -and -not $s.PSObject.Properties['WinRE']) { throw 'Sessionsfilen saknar WinRE-information.' }
    if ($s.Schema -eq 3 -and -not $s.PSObject.Properties['Finalization']) { throw 'Sessionsfilen saknar avslutningsinformation.' }
    $base = Join-Path (Join-Path $Root 'Sessions') $s.Id
    foreach ($pair in @(@('MountPath', 'Mount'), @('ScratchPath', 'Scratch'), @('AppLog', 'activity.log'), @('DismLog', 'dism.log'))) {
        if ((Get-PmwFullPath $s.($pair[0])) -ne (Join-Path $base $pair[1])) { throw 'Sessionsfilens sökvägar är ogiltiga.' }
    }
    if ((Get-PmwFullPath $s.Source) -eq (Get-PmwFullPath $s.Output) -or [IO.Path]::GetExtension($s.Output) -ne '.wim') {
        throw 'Sessionsfilen har en ogiltig resultatfil.'
    }
    Initialize-PmwWinRe $s
    if ($s.Finalization.CleanupMode -notin @('None', 'Standard', 'ResetBase') -or $s.Finalization.Optimize -isnot [bool]) { throw 'Ogiltiga avslutningsinställningar i sessionsfilen.' }
    if ((Get-PmwFullPath $s.WinRE.ImagePath) -ne (Join-Path $base 'winre.wim') -or
        (Get-PmwFullPath $s.WinRE.MountPath) -ne (Join-Path $base 'WinREMount') -or
        $s.WinRE.Phase -notin @('None', 'Copying', 'Ready', 'Mounting', 'Mounted', 'Saving', 'Saved', 'Injecting', 'Integrated', 'Discarded')) {
        throw 'Sessionsfilens WinRE-information är ogiltig.'
    }
    $s
}

function Get-PmwMount($Session, [switch]$WinRE) {
    $mountPath = $Session.MountPath
    $imagePath = $Session.Output
    if ($WinRE) { $mountPath = $Session.WinRE.MountPath; $imagePath = $Session.WinRE.ImagePath }
    $mounts = @(Get-WindowsImage -Mounted -ErrorAction Stop | Where-Object { (Get-PmwFullPath $_.Path) -eq $mountPath })
    if ($mounts.Count -gt 1) { throw 'Flera monteringar matchar arbetsmappen.' }
    if ($mounts.Count -eq 1) {
        if ((Get-PmwFullPath $mounts[0].ImagePath) -ne $imagePath -or $mounts[0].ImageIndex -ne 1) {
            throw 'Monteringen tillhör en annan image. Ingen ändring utförs.'
        }
        return $mounts[0]
    }
    return $null
}

function Get-PmwWinReStatus($Session) {
    if (-not $Session) { return 'None' }
    $m = Get-PmwMount $Session -WinRE
    if ($m) {
        if ([string]$m.MountStatus -eq 'Ok') { return 'Mounted' }
        return 'NeedsRemount'
    }
    switch ($Session.WinRE.Phase) {
        { $_ -in @('None', 'Copying') } { return 'None' }
        { $_ -in @('Ready', 'Mounting') } { return 'Ready' }
        { $_ -in @('Saved', 'Injecting') } { return 'Saved' }
        'Integrated' { return 'Integrated' }
        'Discarded' { return 'None' }
        default { return 'Interrupted' }
    }
}

function Mount-PmwWinRe($Session, [string]$Root, $Events) {
    Assert-PmwMounted $Session
    $state = Get-PmwWinReStatus $Session
    if ($state -eq 'Mounted') { return }
    if ($state -in @('NeedsRemount', 'Interrupted')) { throw 'WinRE behöver återanslutas eller sessionen kastas innan nya paket kan installeras.' }
    if ($state -eq 'None') {
        $embedded = Join-Path $Session.MountPath 'Windows\System32\Recovery\winre.wim'
        if (-not (Test-Path -LiteralPath $embedded -PathType Leaf)) { throw 'Den valda Windows-utgåvan saknar Windows\System32\Recovery\winre.wim. Safe OS kan inte installeras.' }
        $Session.WinRE.Phase = 'Copying'; Save-PmwSession $Session $Root
        Write-PmwLog $Session $Events 'Kopierar WinRE till en separat arbetsfil …'
        Copy-Item -LiteralPath $embedded -Destination $Session.WinRE.ImagePath -Force -ErrorAction Stop
        (Get-Item -LiteralPath $Session.WinRE.ImagePath -Force).IsReadOnly = $false
        $Session.WinRE.Phase = 'Ready'; Save-PmwSession $Session $Root
    }
    # For Saved/Integrated, the working WIM already contains previously committed packages.
    if (-not (Test-Path -LiteralPath $Session.WinRE.ImagePath -PathType Leaf)) { throw 'WinRE-arbetsfilen saknas. Kasta sessionen och börja om.' }
    New-Item -ItemType Directory -Path $Session.WinRE.MountPath -Force | Out-Null
    $Session.WinRE.Phase = 'Mounting'; Save-PmwSession $Session $Root
    Write-PmwLog $Session $Events 'Monterar WinRE, index 1, för Safe OS-paket …'
    Mount-WindowsImage -ImagePath $Session.WinRE.ImagePath -Index 1 -Path $Session.WinRE.MountPath -CheckIntegrity -ScratchDirectory $Session.ScratchPath -LogPath $Session.DismLog -ErrorAction Stop | Out-Null
    $Session.WinRE.Phase = 'Mounted'; Save-PmwSession $Session $Root
}

function Add-PmwWarning($Session, $Events, [string]$Message) {
    if ($Message -notin $Session.Finalization.Warnings) { $Session.Finalization.Warnings = @($Session.Finalization.Warnings) + $Message }
    Write-PmwLog $Session $Events ('OBS: ' + $Message)
}

function Test-PmwCleanupRequired($Session, [string]$Target) {
    $mode = $Session.Finalization.CleanupMode
    $previous = $Session.Finalization.($Target + 'Cleanup')
    return $mode -ne 'None' -and $previous -notin @($mode, 'ResetBase', 'SkippedPending')
}

function Invoke-PmwCleanup($Session, [string]$Root, $Events, [string]$Target) {
    $field = $Target + 'Cleanup'
    $mode = $Session.Finalization.CleanupMode
    if ($mode -eq 'None') { Write-PmwLog $Session $Events ("$Target · Cleanup är avstängd."); return }
    if ($Session.Finalization.$field -eq 'SkippedPending') {
        Add-PmwWarning $Session $Events ("$Target · Cleanup/ResetBase hoppades över på grund av väntande åtgärder. Dessa måste slutföras när imagen startas.")
        return
    }
    if (-not (Test-PmwCleanupRequired $Session $Target)) { return }
    $Session.Finalization.Warnings = @($Session.Finalization.Warnings | Where-Object { -not $_.StartsWith($Target + ' · ') })
    $mountPath = $Session.MountPath
    if ($Target -eq 'WinRE') { $mountPath = $Session.WinRE.MountPath }
    Write-PmwLog $Session $Events ("$Target · Kontrollerar väntande åtgärder före cleanup …")
    $pendingPackages = @(Get-WindowsPackage -Path $mountPath -LogPath $Session.DismLog -ErrorAction Stop | Where-Object { [string]$_.PackageState -match 'Pending' })
    $pendingFeatures = @(Get-WindowsOptionalFeature -Path $mountPath -LogPath $Session.DismLog -ErrorAction Stop | Where-Object { [string]$_.State -match 'Pending' })
    if ($pendingPackages.Count -gt 0 -or $pendingFeatures.Count -gt 0 -or (Test-Path -LiteralPath (Join-Path $mountPath 'Windows\WinSxS\pending.xml'))) {
        $Session.Finalization.$field = 'SkippedPending'
        Add-PmwWarning $Session $Events ("$Target · Cleanup/ResetBase hoppades över på grund av väntande åtgärder. Dessa måste slutföras när imagen startas.")
        Save-PmwSession $Session $Root
        return
    }
    Write-PmwLog $Session $Events ("$Target · StartComponentCleanup ($mode) …")
    $parameters = @{
        Path = $mountPath; StartComponentCleanup = $true; NoRestart = $true
        ScratchDirectory = $Session.ScratchPath; LogPath = $Session.DismLog; ErrorAction = 'Stop'
    }
    if ($mode -eq 'ResetBase') { $parameters.ResetBase = $true }
    # Defer is intended for specific factory workflows; cleanup is completed here.
    Repair-WindowsImage @parameters | Out-Null
    $Session.Finalization.$field = $mode
    Save-PmwSession $Session $Root
    Write-PmwLog $Session $Events ("$Target · Cleanup klar.")
}

function Optimize-PmwImage($Session, $Events, [string]$ImagePath) {
    if (@(Get-WindowsImage -Mounted -ErrorAction Stop | Where-Object { (Get-PmwFullPath $_.ImagePath) -eq $ImagePath }).Count -gt 0) { throw 'En monterad WIM får inte ersättas vid kompaktering.' }
    # Export to a unique sibling: the committed image is untouched until export succeeds.
    $token = [guid]::NewGuid().ToString('N')
    $temp = $ImagePath + '.compact-' + $token + '.wim'
    $backup = $ImagePath + '.before-compact-' + $token + '.bak'
    Write-PmwLog $Session $Events ("Kompakterar till ny WIM: $temp")
    Export-WindowsImage -SourceImagePath $ImagePath -SourceIndex 1 -DestinationImagePath $temp -CompressionType Max -CheckIntegrity -ScratchDirectory $Session.ScratchPath -LogPath $Session.DismLog -ErrorAction Stop | Out-Null
    Get-WindowsImage -ImagePath $temp -Index 1 -ErrorAction Stop | Out-Null
    [IO.File]::Replace($temp, $ImagePath, $backup)
    Write-PmwLog $Session $Events ("Kompaktering klar. Föregående sparade WIM behålls som: $backup")
}

function Save-PmwWinRe($Session, [string]$Root, $Events) {
    $state = Get-PmwWinReStatus $Session
    if ($state -eq 'None' -and $Session.WinRE.Phase -eq 'None') { return }
    if ($state -in @('Saved', 'Integrated') -and (Test-PmwCleanupRequired $Session 'WinRE')) {
        Mount-PmwWinRe $Session $Root $Events
        $state = 'Mounted'
        $Session.Finalization.WinREOptimized = $false
    }
    if ($state -eq 'Integrated') {
        Invoke-PmwCleanup $Session $Root $Events 'WinRE'
        if (-not $Session.Finalization.Optimize -or $Session.Finalization.WinREOptimized) { return }
        $state = 'Saved'
    }
    if ($state -notin @('Mounted', 'Saved')) { throw 'WinRE är inte redo att sparas. Återanslut eller slutför Safe OS-körningen innan Windows-imagen sparas.' }
    if ($state -eq 'Mounted') {
        Invoke-PmwCleanup $Session $Root $Events 'WinRE'
        $Session.WinRE.Phase = 'Saving'; Save-PmwSession $Session $Root
        Write-PmwLog $Session $Events 'Sparar och avmonterar WinRE före Windows-imagen …'
        Dismount-WindowsImage -Path $Session.WinRE.MountPath -Save -CheckIntegrity -ScratchDirectory $Session.ScratchPath -LogPath $Session.DismLog -ErrorAction Stop | Out-Null
        $Session.WinRE.Phase = 'Saved'; Save-PmwSession $Session $Root
    }
    if ($Session.Finalization.Optimize -and -not $Session.Finalization.WinREOptimized) {
        # Persist Saved before export so a failed export can be retried without mounting.
        $Session.WinRE.Phase = 'Saved'; Save-PmwSession $Session $Root
        Optimize-PmwImage $Session $Events $Session.WinRE.ImagePath
        $Session.Finalization.WinREOptimized = $true; Save-PmwSession $Session $Root
    }
    $embedded = Join-Path $Session.MountPath 'Windows\System32\Recovery\winre.wim'
    $Session.WinRE.Phase = 'Injecting'; Save-PmwSession $Session $Root
    Write-PmwLog $Session $Events 'Kopierar uppdaterad WinRE tillbaka till Windows-imagen …'
    Copy-Item -LiteralPath $Session.WinRE.ImagePath -Destination $embedded -Force -ErrorAction Stop
    $Session.WinRE.Phase = 'Integrated'; Save-PmwSession $Session $Root
}

function Get-PmwStatus($Session) {
    if (-not $Session) { return 'Empty' }
    if ($Session.Phase -in @('Saved', 'Discarded')) { return $Session.Phase }
    $m = Get-PmwMount $Session
    if (-not $m -and $Session.Phase -in @('Committed', 'Optimizing')) { return 'NeedsFinalize' }
    if ($m) {
        if ([string]$m.MountStatus -eq 'Ok') { return 'Mounted' }
        return 'NeedsRemount'
    }
    return 'Interrupted'
}

function Assert-PmwMounted($Session) {
    if ((Get-PmwStatus $Session) -ne 'Mounted') { throw 'Imagen är inte korrekt monterad. Kontrollera eller återanslut sessionen.' }
}

function Invoke-PmwTask {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Request, $Events, $Control)
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    $s = $null
    $root = $null
    $result = [ordered]@{ Success = $false; Error = ''; Session = $null; Status = 'Empty'; WinReStatus = 'None'; Images = @(); Action = $Request.Action }
    try {
        Import-Module Dism -ErrorAction Stop
        $root = Assert-PmwLocalPath $Request.Root
        $s = Read-PmwSession $root
        switch ($Request.Action) {
            'BuildISO' {
                if (-not $s -or (Get-PmwStatus $s) -ne 'Saved') { throw 'Spara och avsluta Windows-imagen innan ISO skapas.' }
                $result.ISO = New-PmwMediaISO $s $root $Request $Events
            }
            'Inspect' { }
            'ReadImage' {
                $source = Get-PmwFullPath $Request.Source
                if ([IO.Path]::GetExtension($source) -notin @('.wim', '.esd') -or -not (Test-Path -LiteralPath $source -PathType Leaf)) {
                    throw 'Välj en befintlig WIM- eller ESD-fil.'
                }
                Write-PmwLog $null $Events 'Läser Windows-utgåvor …'
                $result.Images = @(Get-WindowsImage -ImagePath $source -ErrorAction Stop | ForEach-Object {
                    [pscustomobject]@{ Index = [int]$_.ImageIndex; Name = $_.ImageName; Size = [long]$_.ImageSize; Display = ('{0}  ·  {1}  ·  {2:N1} GB' -f $_.ImageIndex, $_.ImageName, ($_.ImageSize / 1GB)) }
                })
            }
            'Prepare' {
                if ($s -and $s.Phase -notin @('Saved', 'Discarded')) { throw 'Avsluta den befintliga sessionen först.' }
                $source = Get-PmwFullPath $Request.Source
                $output = Assert-PmwLocalPath $Request.Output
                if ($source -eq $output) { throw 'Resultatfilen får inte vara originalfilen.' }
                if ([IO.Path]::GetExtension($source) -notin @('.wim', '.esd') -or -not (Test-Path -LiteralPath $source -PathType Leaf)) { throw 'Källfilen måste vara en befintlig WIM eller ESD.' }
                if ([IO.Path]::GetExtension($output) -ne '.wim') { throw 'Resultatfilen måste sluta med .wim.' }
                if (Test-Path -LiteralPath $output) { throw 'Resultatfilen finns redan. Välj ett nytt filnamn.' }
                if (-not (Test-Path -LiteralPath (Split-Path $output -Parent) -PathType Container)) { throw 'Resultatmappen finns inte.' }
                if ($output.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Spara resultatet utanför arbetsmappen.' }
                $info = Get-WindowsImage -ImagePath $source -Index $Request.Index -ErrorAction Stop
                $required = [long]$info.ImageSize + 10GB
                $workDrive = New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($root))
                $outDrive = New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($output))
                if ($workDrive.Name -eq $outDrive.Name) {
                    if ($workDrive.AvailableFreeSpace -lt (2 * $required)) { throw ('För lite diskutrymme. Ha minst {0:N0} GB ledigt på arbetsdisken.' -f (2 * $required / 1GB)) }
                } elseif ($workDrive.AvailableFreeSpace -lt $required -or $outDrive.AvailableFreeSpace -lt $required) {
                    throw ('Ha minst {0:N0} GB ledigt på både arbets- och resultatdisken.' -f ($required / 1GB))
                }
                $id = [guid]::NewGuid().ToString('N')
                $base = Join-Path (Join-Path $root 'Sessions') $id
                $s = [pscustomobject]@{ Schema = 1; Id = $id; Source = $source; SourceIndex = [int]$Request.Index; Name = $info.ImageName; Output = $output; MountPath = (Join-Path $base 'Mount'); ScratchPath = (Join-Path $base 'Scratch'); AppLog = (Join-Path $base 'activity.log'); DismLog = (Join-Path $base 'dism.log'); Phase = 'Exporting'; Packages = @(); Created = (Get-Date).ToString('o'); LastError = '' }
                Initialize-PmwWinRe $s
                New-Item -ItemType Directory -Path $s.MountPath, $s.ScratchPath -Force | Out-Null
                Save-PmwSession $s $root
                Write-PmwLog $s $Events ('Exporterar {0} till {1}. Originalet bevaras.' -f $s.Name, $output)
                Export-WindowsImage -SourceImagePath $source -SourceIndex $Request.Index -DestinationImagePath $output -CompressionType Max -CheckIntegrity -ScratchDirectory $s.ScratchPath -LogPath $s.DismLog -ErrorAction Stop | Out-Null
                $s.Phase = 'Mounting'; Save-PmwSession $s $root
                Write-PmwLog $s $Events 'Monterar arbetskopian med integritetskontroll …'
                Mount-WindowsImage -ImagePath $output -Index 1 -Path $s.MountPath -CheckIntegrity -ScratchDirectory $s.ScratchPath -LogPath $s.DismLog -ErrorAction Stop | Out-Null
                $s.Phase = 'Mounted'; Save-PmwSession $s $root
                Write-PmwLog $s $Events 'Arbetskopian är monterad. Lägg till uppdateringar i paketkön.'
            }
            { $_ -in @('Apply', 'ApplySafeOS', 'ApplyLP', 'ReapplyCU') } {
                Assert-PmwMounted $s
                $safeOS = $Request.Action -eq 'ApplySafeOS'
                $target = 'Windows'
                $owner = $s
                if ($safeOS) { $target = 'WinRE'; $owner = $s.WinRE }
                if ($Request.Action -eq 'ApplyLP') { $target = 'Languages'; $owner = $s.Languages }
                $paths = @($Request.Packages)
                if ($paths.Count -eq 0) { throw 'Paketkön är tom.' }
                # Validate the complete queue before making any changes.
                foreach ($path in $paths) {
                    if ([IO.Path]::GetExtension($path) -notin @('.msu', '.cab') -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Ogiltigt eller saknat paket: $path" }
                    if ($Request.Action -eq 'ApplyLP') {
                        if ([IO.Path]::GetExtension($path) -ne '.cab') { throw 'LP/LIP för offline-installation måste vara CAB-filer.' }
                        $metadata = Get-WindowsPackage -Path $s.MountPath -PackagePath $path -ErrorAction Stop
                        if ([string]$metadata.ReleaseType -ne 'LanguagePack') { throw "Paketet är inte ett språkpaket enligt DISM: $path" }
                    }
                }
                if ($safeOS) { Mount-PmwWinRe $s $root $Events }
                $cleanupTarget = if ($safeOS) { 'WinRECleanup' } else { 'WindowsCleanup' }
                $s.Finalization.$cleanupTarget = 'NotRun'
                if ($safeOS) { $s.Finalization.WinREOptimized = $false }
                # Journal the entire requested order, including packages not yet started.
                $planned = @()
                foreach ($path in $paths) {
                    $full = Get-PmwFullPath $path
                    if (@($planned | Where-Object { $_.Path -eq $full }).Count -gt 0) { continue }
                    $existing = $owner.Packages | Where-Object { $_.Path -eq $full } | Select-Object -First 1
                    if ($existing) { $planned += $existing } else {
                        $planned += [pscustomobject]@{ Path = $full; Status = 'Väntar'; RestartNeeded = $false }
                    }
                }
                $owner.Packages = @($owner.Packages | Where-Object { $_.Path -notin @($planned | ForEach-Object { $_.Path }) }) + $planned
                Save-PmwSession $s $root
                for ($i = 0; $i -lt $paths.Count; $i++) {
                    if ($Control -and $Control.Cancel) { Write-PmwLog $s $Events 'Kön stoppades mellan två paket. Imagen är fortfarande monterad.'; break }
                    $path = Get-PmwFullPath $paths[$i]
                    if ($Request.Action -ne 'ReapplyCU' -and @($owner.Packages | Where-Object { $_.Path -eq $path -and $_.Status -eq 'Klart' }).Count -gt 0) { continue }
                    $entry = $owner.Packages | Where-Object { $_.Path -eq $path } | Select-Object -First 1
                    $entry.Status = 'Installerar'
                    Save-PmwSession $s $root
                    Send-PmwEvent $Events 'Package' @{ Path = $path; Status = 'Installerar'; Target = $target }
                    Write-PmwLog $s $Events ('{0} · Paket {1}/{2}: {3}' -f $target, ($i + 1), $paths.Count, [IO.Path]::GetFileName($path))
                    try {
                        if ($Request.Action -eq 'ApplyLP') {
                            $s.Languages.RequiresCU = $true
                            Save-PmwSession $s $root
                        }
                        $installPath = $s.MountPath
                        if ($safeOS) { $installPath = $s.WinRE.MountPath }
                        $added = Add-WindowsPackage -Path $installPath -PackagePath $path -NoRestart -ScratchDirectory $s.ScratchPath -LogPath $s.DismLog -ErrorAction Stop
                        $entry.RestartNeeded = [bool]$added.RestartNeeded
                        $entry.Status = 'Klart'
                        if ($entry.RestartNeeded) { Write-PmwLog $s $Events 'Paketet rapporterar väntande åtgärder. Dessa kan slutföras när imagen startas.' }
                    } catch {
                        $entry.Status = 'Fel'
                        throw
                    } finally {
                        Save-PmwSession $s $root
                        Send-PmwEvent $Events 'Package' @{ Path = $path; Status = $entry.Status; Target = $target }
                    }
                }
                if ($Request.Action -eq 'ReapplyCU' -and -not ($Control -and $Control.Cancel)) {
                    $s.Languages.RequiresCU = $false
                    Save-PmwSession $s $root
                    Write-PmwLog $s $Events 'Vald CU-kö har återapplicerats efter språkändringarna.'
                }
                Write-PmwLog $s $Events 'Paketkörningen är avslutad. Granska loggen och spara sedan imagen.'
            }
            'ProvisionAppBatch' {
                Assert-PmwMounted $s
                if (@($Request.Items).Count -eq 0) { throw 'Appkön är tom.' }
                $previousQueue = @($s.AppQueue)
                $s.AppQueue = @($Request.Items | ForEach-Object {
                    $item = $_
                    $old = $previousQueue | Where-Object { $_.Path -eq $item.Path -and $_.Status -eq 'Klart' -and $_.LicensePath -eq $item.LicensePath -and $_.SkipLicense -eq $item.SkipLicense -and ($_.Dependencies -join '|') -eq ($item.Dependencies -join '|') } | Select-Object -First 1
                    [pscustomobject]@{ Path = $item.Path; LicensePath = $item.LicensePath; SkipLicense = [bool]$item.SkipLicense; Dependencies = @($item.Dependencies); Status = $(if ($old) { 'Klart' } else { 'Väntar' }) }
                })
                Save-PmwSession $s $root
                for ($i = 0; $i -lt $s.AppQueue.Count; $i++) {
                    if ($Control -and $Control.Cancel) { Write-PmwLog $s $Events 'Appkön stoppades mellan två appar.'; break }
                    $item = $s.AppQueue[$i]
                    if ($item.Status -eq 'Klart') { continue }
                    $item.Status = 'Installerar'; Save-PmwSession $s $root
                    Write-PmwLog $s $Events ('App {0}/{1}: {2}' -f ($i + 1), $s.AppQueue.Count, $item.Path)
                    $child = Invoke-PmwTask @{ Action = 'ProvisionApp'; Root = $root; PackagePath = $item.Path; LicensePath = $item.LicensePath; SkipLicense = $item.SkipLicense; Dependencies = @($item.Dependencies) } $Events $Control
                    $s = $child.Session
                    $s.AppQueue[$i].Status = if ($child.Success) { 'Klart' } else { 'Fel' }
                    Save-PmwSession $s $root
                    if (-not $child.Success) { throw $child.Error }
                }
            }
            'ListApps' {
                Assert-PmwMounted $s
                $result.Apps = @(Get-AppxProvisionedPackage -Path $s.MountPath -LogPath $s.DismLog -ErrorAction Stop | Select-Object DisplayName, Version, Architecture, PackageName)
                Write-PmwLog $s $Events ('Hittade {0} provisionerade appar.' -f $result.Apps.Count)
            }
            { $_ -in @('ProvisionLXP', 'ProvisionApp') } {
                Assert-PmwMounted $s
                $isLanguage = $Request.Action -eq 'ProvisionLXP'
                $collection = if ($isLanguage) { 'LXP' } else { 'Apps' }
                $package = Get-PmwFullPath $Request.PackagePath
                $skipLicense = $Request.ContainsKey('SkipLicense') -and $Request.SkipLicense -eq $true
                $license = ''
                if ($skipLicense) {
                    if (-not [string]::IsNullOrWhiteSpace([string]$Request.LicensePath)) { throw 'Välj antingen XML-licens eller SkipLicense, inte båda.' }
                    $edition = Get-WindowsEdition -Path $s.MountPath -ErrorAction Stop
                    if ([string]$edition.Edition -notmatch 'Enterprise|Server') { throw 'SkipLicense stöds här endast för licensfria paket på Enterprise-/Server-imager enligt Microsofts dokumentation.' }
                } else { $license = Get-PmwFullPath $Request.LicensePath }
                $dependencies = @($Request.Dependencies)
                foreach ($file in @($package) + $dependencies) {
                    if ([IO.Path]::GetExtension($file) -notin @('.appx', '.appxbundle', '.msix', '.msixbundle') -or -not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Ogiltigt eller saknat APPX/MSIX-paket: $file" }
                }
                if (-not $skipLicense -and ([IO.Path]::GetExtension($license) -ne '.xml' -or -not (Test-Path -LiteralPath $license -PathType Leaf))) { throw 'Välj paketets befintliga XML-licensfil.' }
                $entry = [pscustomobject]@{ Path = $package; LicensePath = $license; SkipLicense = $skipLicense; Dependencies = $dependencies; Status = 'Installerar' }
                $s.$collection = @($s.$collection | Where-Object { $_.Path -ne $package }) + @($entry)
                if ($isLanguage) { $s.Languages.RequiresCU = $true }
                $s.Finalization.WindowsCleanup = 'NotRun'
                Save-PmwSession $s $root
                Write-PmwLog $s $Events ("Provisionerar $collection i Windows-imagen: $package")
                Write-PmwLog $s $Events ("Licensval: SkipLicense=$skipLicense; LicensePath=$license")
                try {
                    $parameters = @{ Path = $s.MountPath; PackagePath = $package; Regions = 'all'; LogPath = $s.DismLog; ScratchDirectory = $s.ScratchPath; ErrorAction = 'Stop' }
                    if ($skipLicense) { $parameters.SkipLicense = $true } else { $parameters.LicensePath = $license }
                    if ($dependencies.Count -gt 0) { $parameters.DependencyPackagePath = $dependencies }
                    Add-AppxProvisionedPackage @parameters | Out-Null
                    $entry.Status = 'Klart'
                    if ($isLanguage) { Write-PmwLog $s $Events 'LXP-provisionering klar. Återapplicera CU innan sparning.' }
                    else { Write-PmwLog $s $Events 'App-provisionering klar. Uppdatera applistan för att granska versionerna.' }
                } catch { $entry.Status = 'Fel'; throw }
                finally { Save-PmwSession $s $root }
            }
            'Save' {
                if (-not $s) { throw 'Ingen session att spara.' }
                if ($s.Languages.RequiresCU) { throw 'Språk har ändrats. Välj rätt senaste CU med nödvändiga checkpoints och kör Återapplicera CU innan sparning/cleanup.' }
                $state = Get-PmwStatus $s
                if ($state -notin @('Mounted', 'NeedsFinalize')) { throw 'Imagen är inte redo att sparas.' }
                $mode = $s.Finalization.CleanupMode
                if ($Request.ContainsKey('CleanupMode')) { $mode = [string]$Request.CleanupMode }
                if ($mode -notin @('None', 'Standard', 'ResetBase')) { throw 'Ogiltigt cleanup-läge.' }
                if ($state -eq 'NeedsFinalize' -and $mode -ne $s.Finalization.CleanupMode) { throw 'Imagen är redan avmonterad. Endast kompakteringen kan ändras nu.' }
                $s.Finalization.CleanupMode = $mode
                if ($Request.ContainsKey('Optimize')) { $s.Finalization.Optimize = [bool]$Request.Optimize }
                Save-PmwSession $s $root
                if ($state -eq 'Mounted') {
                    Save-PmwWinRe $s $root $Events
                    Invoke-PmwCleanup $s $root $Events 'Windows'
                    $s.Phase = 'Saving'; Save-PmwSession $s $root
                    Write-PmwLog $s $Events 'Sparar ändringar och avmonterar. Vänta tills operationen är klar …'
                    Dismount-WindowsImage -Path $s.MountPath -Save -CheckIntegrity -LogPath $s.DismLog -ScratchDirectory $s.ScratchPath -ErrorAction Stop | Out-Null
                    $s.Phase = 'Committed'; Save-PmwSession $s $root
                }
                if ($s.Finalization.Optimize) {
                    $s.Phase = 'Optimizing'; Save-PmwSession $s $root
                    Optimize-PmwImage $s $Events $s.Output
                }
                $s.Phase = 'Saved'; Save-PmwSession $s $root
                Write-PmwLog $s $Events ('Klart! Uppdaterad WIM: {0}' -f $s.Output)
                foreach ($warning in $s.Finalization.Warnings) { Write-PmwLog $s $Events ('OBS: ' + $warning) }
            }
            'Discard' {
                if (-not $s -or $s.Phase -in @('Saved', 'Discarded')) { throw 'Ingen aktiv session att avsluta.' }
                if ((Get-PmwStatus $s) -eq 'NeedsFinalize') { throw 'Imagen är redan sparad. Slutför avslutningen; sparade ändringar kan inte kastas.' }
                # Verify both mount identities before dismounting either one.
                $mainMount = Get-PmwMount $s
                $reMount = Get-PmwMount $s -WinRE
                if ($reMount) {
                    Write-PmwLog $s $Events 'Kastar ändringar och avmonterar WinRE först …'
                    Dismount-WindowsImage -Path $s.WinRE.MountPath -Discard -LogPath $s.DismLog -ErrorAction Stop | Out-Null
                }
                $s.WinRE.Phase = 'Discarded'; Save-PmwSession $s $root
                if ($mainMount) {
                    Write-PmwLog $s $Events 'Avmonterar och kastar osparade ändringar …'
                    Dismount-WindowsImage -Path $s.MountPath -Discard -LogPath $s.DismLog -ErrorAction Stop | Out-Null
                }
                $s.Phase = 'Discarded'; Save-PmwSession $s $root
                Write-PmwLog $s $Events 'Sessionen är avslutad. Exportfilen har behållits; den är inte ett verifierat patchresultat.'
            }
            'Remount' {
                if (-not $s) { throw 'Ingen session att återansluta.' }
                $mainState = Get-PmwStatus $s
                $reState = Get-PmwWinReStatus $s
                if ($mainState -ne 'NeedsRemount' -and $reState -ne 'NeedsRemount') { throw 'Ingen montering behöver återanslutas.' }
                if ($mainState -eq 'NeedsRemount') { Mount-WindowsImage -Path $s.MountPath -Remount -LogPath $s.DismLog -ErrorAction Stop | Out-Null }
                Assert-PmwMounted $s
                if ($reState -eq 'NeedsRemount') {
                    Mount-WindowsImage -Path $s.WinRE.MountPath -Remount -LogPath $s.DismLog -ErrorAction Stop | Out-Null
                    $s.WinRE.Phase = 'Mounted'
                }
                $s.Phase = 'Mounted'; Save-PmwSession $s $root
                Write-PmwLog $s $Events 'Sessionen har återanslutits.'
            }
            default { throw 'Okänd åtgärd.' }
        }
        $result.Success = $true
    } catch {
        $result.Error = $_.Exception.Message
        if ($s -and $root -and $Request.Action -notin @('ReadImage', 'Inspect')) {
            try { $s.LastError = $result.Error; Save-PmwSession $s $root } catch { }
        }
        try { Write-PmwLog $s $Events ('FEL: ' + $result.Error) } catch { Send-PmwEvent $Events 'Log' $result.Error }
    } finally {
        $result.Session = $s
        try { $result.Status = Get-PmwStatus $s; $result.WinReStatus = Get-PmwWinReStatus $s } catch { $result.Success = $false; $result.Status = 'Unknown'; $result.WinReStatus = 'Unknown'; $result.Error += ' ' + $_.Exception.Message }
    }
    [pscustomobject]$result
}

Export-ModuleMember -Function Invoke-PmwTask
