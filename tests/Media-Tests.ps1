#requires -Version 5.1
$ErrorActionPreference = 'Stop'
$module = Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'PatchMyWindow.Core.psm1') -Force -PassThru
$testRoot = Join-Path $PSScriptRoot ('media-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    & $module {
        param($TestRoot)
        function Assert($Condition, $Message) { if (-not $Condition) { throw $Message }; "PASS: $Message" }
        # Exercise native argument handling with harmless real files, never DISM or Oscdimg.
        $nativeDir = Join-Path $TestRoot 'native paths with spaces'
        New-Item -ItemType Directory -Path $nativeDir | Out-Null
        $nativeInput = Join-Path $nativeDir 'fixture.txt'
        $nativeCab = Join-Path $nativeDir 'fixture.cab'
        $nativeLog = Join-Path $nativeDir 'native.log'
        Set-Content -LiteralPath $nativeInput -Value 'native fixture'
        Invoke-PmwMediaTool "$env:SystemRoot\System32\makecab.exe" @($nativeInput, $nativeCab) $nativeLog
        $expanded = Join-Path $nativeDir 'expanded'
        New-Item -ItemType Directory -Path $expanded | Out-Null
        Invoke-PmwMediaTool "$env:SystemRoot\System32\expand.exe" @($nativeCab, '-F:*', $expanded) $nativeLog
        # Expand retains the CAB name for a single-file cabinet unless -r is specified.
        $expandedFile = Get-ChildItem -LiteralPath $expanded -File | Select-Object -First 1
        Assert ($null -ne $expandedFile -and (Get-Content -LiteralPath $expandedFile.FullName) -eq 'native fixture') 'Real native CAB expansion handles spaces without a shell'
        $nativeFailed = $false
        try { Invoke-PmwMediaTool "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" @('-NoProfile', '-Command', 'exit 7') $nativeLog } catch { $nativeFailed = $_.Exception.Message -like '*kod 7*' }
        Assert $nativeFailed 'Native nonzero exit code propagates as an error'
        $script:fixture = $TestRoot
        function script:Assert-PmwLocalPath($Path) {
            $full = Get-PmwFullPath $Path
            if (-not (Test-PmwPathWithin $full $script:fixture)) { throw 'Outside fixture' }
            $full
        }
        $script:arch = 9; $script:wrongBuild = $false; $script:failTool = $false; $script:badCab = $false
        $script:mounted = $false; $script:mounts = 0; $script:lastArgs = @()
        $script:missingSetupHost = $false
        function script:Get-WindowsImage {
            param($ImagePath, $Index, $ErrorAction)
            [pscustomobject]@{ Architecture = $script:arch; Version = $(if ($script:wrongBuild -and $ImagePath -like '*boot.wim') { '10.0.22000.1' } else { '10.0.26100.1' }) }
        }
        function script:Mount-WindowsImage {
            param($ImagePath, $Index, $Path, [switch]$ReadOnly, $LogPath, $ErrorAction)
            if (-not $ReadOnly -or $Index -ne 2) { throw 'Expected read-only Setup image' }
            $script:mounted = $true; $script:mounts++
            New-Item -ItemType Directory -Path (Join-Path $Path 'sources') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $Path 'sources\setup.exe') -Value 'boot setup'
            if (-not $script:missingSetupHost) { Set-Content -LiteralPath (Join-Path $Path 'sources\setuphost.exe') -Value 'boot setuphost' }
        }
        function script:Dismount-WindowsImage {
            param($Path, [switch]$Discard, $ErrorAction)
            if (-not $Discard) { throw 'Read-only mount must discard' }; $script:mounted = $false
        }
        function script:Invoke-PmwMediaTool($File, $Arguments, $Log) {
            if ($File -like '*expand.exe') {
                $destination = $Arguments[-1]
                Set-Content -LiteralPath (Join-Path $destination 'setuphost.exe') -Value 'DU host'
                Set-Content -LiteralPath (Join-Path $destination 'compat.dll') -Value 'DU compatibility'
                if ($script:badCab) { Set-Content -LiteralPath (Join-Path $destination 'update.mum') -Value 'servicing' }
            } else {
                $script:lastArgs = $Arguments
                Set-Content -LiteralPath $Arguments[-1] -Value 'fixture ISO'
                if ($script:failTool) { throw 'Simulated Oscdimg failure' }
            }
        }
        $source = Join-Path $TestRoot 'Original media'
        foreach ($path in @('setup.exe', 'sources\boot.wim', 'sources\install.esd', 'sources\install.swm', 'sources\install2.swm', 'efi\microsoft\boot\efisys.bin', 'boot\etfsboot.com', '.hidden')) {
            $full = Join-Path $source $path
            New-Item -ItemType Directory -Path (Split-Path $full -Parent) -Force | Out-Null
            Set-Content -LiteralPath $full -Value 'original'
        }
        $wim = Join-Path $TestRoot 'patched.wim'; Set-Content -LiteralPath $wim -Value 'patched'
        $tool = Join-Path $TestRoot 'oscdimg.exe'; Set-Content -LiteralPath $tool -Value 'fixture only'
        $cab = Join-Path $TestRoot 'setup.cab'; Set-Content -LiteralPath $cab -Value 'fixture'
        $root = Join-Path $TestRoot 'Work'; New-Item -ItemType Directory -Path $root | Out-Null
        $session = [pscustomobject]@{ Output = $wim; AppLog = (Join-Path $root 'activity.log') }
        $events = New-Object 'Collections.Concurrent.ConcurrentQueue[object]'
        $request = @{ MediaSource = $source; IsoPath = (Join-Path $TestRoot 'result.iso'); Oscdimg = $tool; SetupDU = '' }
        $result = New-PmwMediaISO $session $root $request $events
        $media = $script:lastArgs[-2]
        Assert ((Test-Path -LiteralPath $result) -and (Get-Content -LiteralPath (Join-Path $media 'sources\install.wim')) -eq 'patched') 'ISO contains the saved WIM in a separate media copy'
        Assert (-not (Test-Path -LiteralPath (Join-Path $media 'sources\install.esd')) -and -not (Test-Path -LiteralPath (Join-Path $media 'sources\install2.swm'))) 'Conflicting ESD and split images excluded'
        Assert ((Test-Path -LiteralPath (Join-Path $source 'sources\install.esd')) -and $script:mounts -eq 0) 'Original media preserved; no mount without Setup DU'
        Assert ($script:lastArgs[6] -like '-bootdata:2#p0,e,b*#pEF,e,b*') 'x64 ISO uses BIOS and UEFI boot entries, including paths with spaces'
        $caught = $false
        try { New-PmwMediaISO $session $root $request $events } catch { $caught = $true }
        Assert $caught 'Existing ISO cannot be overwritten'
        $request.IsoPath = Join-Path $TestRoot 'du.iso'; $request.SetupDU = $cab
        $result = New-PmwMediaISO $session $root $request $events
        $media = $script:lastArgs[-2]
        Assert ((Get-Content -LiteralPath (Join-Path $media 'sources\compat.dll')) -eq 'DU compatibility' -and (Get-Content -LiteralPath (Join-Path $media 'sources\setuphost.exe')) -eq 'boot setuphost' -and -not $script:mounted) 'Setup DU applied and Setup binaries synchronized from read-only boot.wim'
        $request.IsoPath = Join-Path $TestRoot 'missing-host.iso'; $script:missingSetupHost = $true
        $caught = $false
        try { New-PmwMediaISO $session $root $request $events } catch { $caught = $true }
        Assert ($caught -and -not $script:mounted -and -not (Test-Path -LiteralPath $request.IsoPath)) 'Setup synchronization failure unmounts read-only boot image'
        $script:missingSetupHost = $false
        $request.IsoPath = Join-Path $TestRoot 'failed.iso'; $script:failTool = $true
        $caught = $false
        try { New-PmwMediaISO $session $root $request $events } catch { $caught = $true }
        Assert ($caught -and -not (Test-Path -LiteralPath $request.IsoPath) -and -not $script:mounted) 'Failed ISO build does not publish a partial result'
        $script:failTool = $false; $script:badCab = $true
        $caught = $false
        try { New-PmwMediaISO $session $root $request $events } catch { $caught = $true }
        Assert ($caught -and -not (Test-Path -LiteralPath $request.IsoPath)) 'Servicing CAB rejected as Setup DU'
        $script:badCab = $false; $script:wrongBuild = $true
        $caught = $false
        try { New-PmwMediaISO $session $root $request $events } catch { $caught = $true }
        Assert $caught 'Mismatched Windows base build rejected'
        $script:wrongBuild = $false; $script:arch = 12; $request.SetupDU = ''
        $request.IsoPath = Join-Path $TestRoot 'arm.iso'
        $result = New-PmwMediaISO $session $root $request $events
        Assert ($script:lastArgs[6] -like '-bootdata:1#pEF,e,b*') 'ARM64 ISO uses UEFI only'
        $request.IsoPath = Join-Path $source 'nested.iso'
        $caught = $false
        try { New-PmwMediaISO $session $root $request $events } catch { $caught = $true }
        Assert $caught 'Output inside original media rejected'
    } $testRoot
} finally {
    Remove-Module $module -Force
    $resolved = [IO.Path]::GetFullPath($testRoot)
    if (-not $resolved.StartsWith([IO.Path]::GetFullPath($PSScriptRoot) + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture cleanup path' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
