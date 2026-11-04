#requires -Version 5.1
$ErrorActionPreference = 'Stop'
$project = Split-Path $PSScriptRoot -Parent
$parseErrors = @()
Get-ChildItem -LiteralPath $project -Recurse -File | Where-Object { $_.Extension -in @('.ps1', '.psm1') } | ForEach-Object {
    $tokens = $null; $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors)
    $parseErrors += $errors
}
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
Write-Output 'PASS: All scripts parse in Windows PowerShell 5.1.'

$module = Import-Module (Join-Path $project 'PatchMyWindow.Core.psm1') -Force -PassThru
$testRoot = Join-Path $PSScriptRoot ('temp-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    & $module {
        param($TestRoot)
        $script:fixtureRoot = $TestRoot
        # The repository drive may be ReFS. Production servicing still requires NTFS;
        # these fixture files never reach DISM, so allow only this unique test root.
        function script:Assert-PmwLocalPath([string]$Path) {
            $full = Get-PmwFullPath $Path
            if (-not $full.StartsWith($script:fixtureRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Path outside fixture root' }
            $full
        }
        # Every DISM command is replaced inside the module scope. No image is serviced.
        function script:Import-Module { param($Name, $ErrorAction) }
        $script:mockMount = $null
        $script:mockWinReMount = $null
        $script:mockCalls = New-Object 'Collections.Generic.List[string]'
        $script:packageTargets = New-Object 'Collections.Generic.List[string]'
        $script:failPackage = ''
        $script:failSave = $false
        $script:failWinReSave = $false
        $script:failCopyBack = $false
        $script:failCleanup = ''
        $script:failExport = ''
        $script:pendingPackageTarget = ''
        $script:pendingFeatureTarget = ''
        $script:failPendingQuery = $false
        $script:cancelAfterPackage = $false
        $script:control = [hashtable]::Synchronized(@{ Cancel = $false })
        function script:Get-WindowsImage {
            param($ImagePath, $Index, [switch]$Mounted, $ErrorAction)
            if ($Mounted) { if ($script:mockMount) { $script:mockMount }; if ($script:mockWinReMount) { $script:mockWinReMount }; return }
            [pscustomobject]@{ ImageIndex = 3; ImageName = 'Windows 11 Pro'; ImageSize = 1MB }
        }
        function script:Export-WindowsImage {
            param($SourceImagePath, $SourceIndex, $DestinationImagePath, $CompressionType, [switch]$CheckIntegrity, $ScratchDirectory, $LogPath, $ErrorAction)
            $script:mockCalls.Add('Export:' + $SourceIndex)
            if ($script:failExport -eq $SourceImagePath) {
                Set-Content -LiteralPath $DestinationImagePath -Value 'incomplete export'
                throw 'Simulated export failure'
            }
            [IO.File]::Copy($SourceImagePath, $DestinationImagePath)
        }
        function script:Get-WindowsPackage {
            param($Path, $PackagePath, $LogPath, $ErrorAction)
            if ($PackagePath) { return [pscustomobject]@{ ReleaseType = 'LanguagePack' } }
            if ($script:failPendingQuery) { throw 'Simulated package inspection failure' }
            if ((Split-Path $Path -Leaf) -eq $script:pendingPackageTarget) { [pscustomobject]@{ PackageState = 'InstallPending' } }
        }
        function script:Get-WindowsOptionalFeature {
            param($Path, $LogPath, $ErrorAction)
            if ((Split-Path $Path -Leaf) -eq $script:pendingFeatureTarget) { [pscustomobject]@{ State = 'EnablePending' } }
        }
        function script:Repair-WindowsImage {
            param($Path, [switch]$StartComponentCleanup, [switch]$ResetBase, [switch]$Defer, [switch]$NoRestart, $ScratchDirectory, $LogPath, $ErrorAction)
            if (-not $StartComponentCleanup -or -not $NoRestart -or $Defer) { throw 'Unsafe cleanup flags' }
            $targetName = Split-Path $Path -Leaf
            $script:mockCalls.Add(('Cleanup:{0}:ResetBase={1}' -f $targetName, [bool]$ResetBase))
            if ($script:failCleanup -eq $targetName) { throw 'Simulated cleanup failure' }
        }
        function script:Mount-WindowsImage {
            param($ImagePath, $Index, $Path, [switch]$CheckIntegrity, [switch]$Remount, $ScratchDirectory, $LogPath, $ErrorAction)
            if ((Split-Path $Path -Leaf) -eq 'WinREMount') {
                $script:mockCalls.Add('WinREMount')
                if ($Remount) { $script:mockWinReMount.MountStatus = 'Ok'; return }
                $script:mockWinReMount = [pscustomobject]@{ Path = $Path; ImagePath = $ImagePath; ImageIndex = $Index; MountStatus = 'Ok' }
                return
            }
            $script:mockCalls.Add('Mount')
            if ($Remount) { $script:mockMount.MountStatus = 'Ok'; return }
            $script:mockMount = [pscustomobject]@{ Path = $Path; ImagePath = $ImagePath; ImageIndex = $Index; MountStatus = 'Ok' }
        }
        function script:Add-WindowsPackage {
            param($Path, $PackagePath, [switch]$NoRestart, $ScratchDirectory, $LogPath, $ErrorAction)
            if (-not $NoRestart) { throw 'NoRestart missing' }
            $script:mockCalls.Add('Package:' + [IO.Path]::GetFileName($PackagePath))
            $script:packageTargets.Add($Path)
            if ($PackagePath -eq $script:failPackage) { throw 'Simulated package failure' }
            if ($script:cancelAfterPackage) { $script:control.Cancel = $true }
            [pscustomobject]@{ RestartNeeded = $true }
        }
        function script:Dismount-WindowsImage {
            param($Path, [switch]$Save, [switch]$Discard, [switch]$CheckIntegrity, $ScratchDirectory, $LogPath, $ErrorAction)
            if ((Split-Path $Path -Leaf) -eq 'WinREMount') {
                if ($Save) {
                    $script:mockCalls.Add('WinRESave')
                    if ($script:failWinReSave) { throw 'Simulated WinRE save failure' }
                    Set-Content -LiteralPath $script:mockWinReMount.ImagePath -Value 'serviced winre'
                }
                if ($Discard) { $script:mockCalls.Add('WinREDiscard') }
                $script:mockWinReMount = $null
                return
            }
            if ($Save) { $script:mockCalls.Add('Save'); if ($script:failSave) { throw 'Simulated save failure' } }
            if ($Discard) { $script:mockCalls.Add('Discard') }
            $script:mockMount = $null
        }
        function script:Copy-Item {
            param($LiteralPath, $Destination, [switch]$Force, $ErrorAction)
            if ($Destination -like '*\Recovery\winre.wim') {
                $script:mockCalls.Add('WinRECopyBack')
                if ($script:failCopyBack) { throw 'Simulated WinRE copy-back failure' }
            }
            Microsoft.PowerShell.Management\Copy-Item -LiteralPath $LiteralPath -Destination $Destination -Force:$Force -ErrorAction Stop
        }
        function Assert([bool]$Condition, [string]$Name) {
            if (-not $Condition) { throw ('FAIL: ' + $Name + [Environment]::NewLine + ($r | Format-List * | Out-String)) }
            Write-Output ('PASS: ' + $Name)
        }
        $root = Join-Path $TestRoot 'workspace'
        $source = Join-Path $TestRoot 'source.wim'
        $output = Join-Path $TestRoot 'result.wim'
        $p1 = Join-Path $TestRoot 'checkpoint.msu'
        $p2 = Join-Path $TestRoot 'cumulative.msu'
        $p3 = Join-Path $TestRoot 'netfx.cab'
        foreach ($path in @($source, $p1, $p2, $p3)) { Set-Content -LiteralPath $path -Value 'test fixture' }
        $sourceHash = (Get-FileHash -LiteralPath $source).Hash
        $events = New-Object 'Collections.Concurrent.ConcurrentQueue[object]'
        $r = Invoke-PmwTask @{ Action = 'Inspect'; Root = $root } $events $script:control
        Assert ($r.Success -and $r.Status -eq 'Empty') 'Empty workspace inspection'
        $r = Invoke-PmwTask @{ Action = 'ReadImage'; Root = $root; Source = $source } $events $script:control
        Assert ($r.Success -and $r.Images[0].Index -eq 3) 'Image edition enumeration'
        $r = Invoke-PmwTask @{ Action = 'Prepare'; Root = $root; Source = $source; Output = $source; Index = 3 } $events $script:control
        Assert (-not $r.Success -and $script:mockCalls.Count -eq 0) 'Source overwrite blocked before servicing'
        Set-Content -LiteralPath $output -Value 'existing file'
        $r = Invoke-PmwTask @{ Action = 'Prepare'; Root = $root; Source = $source; Output = $output; Index = 3 } $events $script:control
        Assert (-not $r.Success -and (Get-Content -LiteralPath $output) -eq 'existing file') 'Existing destination preserved'
        Remove-Item -LiteralPath $output
        $r = Invoke-PmwTask @{ Action = 'Prepare'; Root = $root; Source = $source; Output = $output; Index = 3 } $events $script:control
        Assert ($r.Success -and $r.Status -eq 'Mounted' -and $script:mockMount.ImageIndex -eq 1 -and $script:mockCalls[0] -eq 'Export:3') 'Selected edition exported and mounted as index 1'
        Assert ((Get-FileHash -LiteralPath $source).Hash -eq $sourceHash) 'Original image unchanged'
        $r = Invoke-PmwTask @{ Action = 'Apply'; Root = $root; Packages = @($p1, (Join-Path $TestRoot 'missing.cab')) } $events $script:control
        Assert (-not $r.Success -and @($script:mockCalls | Where-Object { $_ -like 'Package:*' }).Count -eq 0) 'Whole queue validated before any installation'
        $script:failPackage = $p2
        $r = Invoke-PmwTask @{ Action = 'Apply'; Root = $root; Packages = @($p1, $p2, $p3) } $events $script:control
        Assert (-not $r.Success -and $r.Status -eq 'Mounted') 'Package failure leaves image mounted'
        Assert (($script:mockCalls -join ',') -match 'Package:checkpoint.msu,Package:cumulative.msu$') 'Queue preserves order and stops at first error'
        Assert ($r.Session.Packages[0].Status -eq 'Klart' -and $r.Session.Packages[1].Status -eq 'Fel') 'Per-package success and failure persisted'
        $r = Invoke-PmwTask @{ Action = 'Inspect'; Root = $root } $events $script:control
        Assert ($r.Success -and $r.Session.Packages.Count -eq 3 -and $r.Session.Packages[2].Status -eq 'Väntar' -and $r.Status -eq 'Mounted') 'Session and unstarted packages can be resumed from journal'
        $script:failPackage = ''
        $script:cancelAfterPackage = $true
        $r = Invoke-PmwTask @{ Action = 'Apply'; Root = $root; Packages = @($p1, $p2, $p3) } $events $script:control
        Assert ($r.Success -and @($r.Session.Packages | Where-Object { $_.Status -eq 'Klart' }).Count -eq 2) 'Cancellation stops between packages and skips completed packages'
        $script:cancelAfterPackage = $false; $script:control.Cancel = $false
        $r = Invoke-PmwTask @{ Action = 'Apply'; Root = $root; Packages = @($p3) } $events $script:control
        Assert ($r.Success -and $r.Session.Packages[2].RestartNeeded) 'Restart-needed result recorded without rebooting host'
        $script:mockMount.ImagePath = $source
        $before = $script:mockCalls.Count
        $r = Invoke-PmwTask @{ Action = 'Save'; Root = $root } $events $script:control
        Assert (-not $r.Success -and $script:mockCalls.Count -eq $before) 'Foreign image mount cannot be saved'
        $script:mockMount.ImagePath = $output
        $script:mockMount.MountStatus = 'NeedsRemount'
        $r = Invoke-PmwTask @{ Action = 'Remount'; Root = $root } $events $script:control
        Assert ($r.Success -and $r.Status -eq 'Mounted') 'Interrupted mount can be reconnected'
        $script:failSave = $true
        $r = Invoke-PmwTask @{ Action = 'Save'; Root = $root } $events $script:control
        Assert (-not $r.Success -and $r.Status -eq 'Mounted' -and $r.Session.Phase -ne 'Saved') 'Failed commit never reported as saved'
        $script:failSave = $false
        $r = Invoke-PmwTask @{ Action = 'Save'; Root = $root } $events $script:control
        Assert ($r.Success -and $r.Status -eq 'Saved' -and -not $script:mockMount) 'Successful commit closes session'
        $output2 = Join-Path $TestRoot 'result2.wim'
        $r = Invoke-PmwTask @{ Action = 'Prepare'; Root = $root; Source = $source; Output = $output2; Index = 3 } $events $script:control
        $r = Invoke-PmwTask @{ Action = 'Discard'; Root = $root } $events $script:control
        Assert ($r.Success -and $r.Status -eq 'Discarded' -and (Test-Path -LiteralPath $output2)) 'Discard keeps original and exported file'
        # Older sessions load with independent WinRE state and upgrade on the next write.
        $legacy = Read-PmwSession $root
        $legacy.PSObject.Properties.Remove('WinRE'); $legacy.Schema = 1
        Save-PmwSession $legacy $root
        $r = Invoke-PmwTask @{ Action = 'Inspect'; Root = $root } $events $script:control
        Assert ($r.Success -and $r.Session.Schema -eq 6 -and $r.WinReStatus -eq 'None') 'Version 1 journals migrate without losing Windows state'

        $safeRoot = Join-Path $TestRoot 'safe-workspace'
        $safeOutput = Join-Path $TestRoot 'safe-result.wim'
        $r = Invoke-PmwTask @{ Action = 'Prepare'; Root = $safeRoot; Source = $source; Output = $safeOutput; Index = 3 } $events $script:control
        $before = $script:mockCalls.Count
        $r = Invoke-PmwTask @{ Action = 'ApplySafeOS'; Root = $safeRoot; Packages = @($p3) } $events $script:control
        Assert (-not $r.Success -and $script:mockCalls.Count -eq $before -and $r.Error -like '*saknar*winre.wim*') 'Missing embedded WinRE stops Safe OS before servicing'
        $embedded = Join-Path $r.Session.MountPath 'Windows\System32\Recovery\winre.wim'
        New-Item -ItemType Directory -Path (Split-Path $embedded -Parent) -Force | Out-Null
        Set-Content -LiteralPath $embedded -Value 'original winre'
        $r = Invoke-PmwTask @{ Action = 'Apply'; Root = $safeRoot; Packages = @($p3) } $events $script:control
        $r = Invoke-PmwTask @{ Action = 'ApplySafeOS'; Root = $safeRoot; Packages = @($p3) } $events $script:control
        Assert ($r.Success -and $r.WinReStatus -eq 'Mounted' -and $script:mockWinReMount.ImageIndex -eq 1) 'Safe OS mounts a separate WinRE copy at index 1'
        Assert ($script:packageTargets[$script:packageTargets.Count - 1] -eq $r.Session.WinRE.MountPath) 'Safe OS packages target WinRE rather than install.wim'
        Assert ($r.Session.Packages.Count -eq 1 -and $r.Session.WinRE.Packages.Count -eq 1) 'Same package path has independent status for each target'
        Assert ((Get-Content -LiteralPath $embedded) -eq 'original winre') 'Embedded WinRE stays unchanged until save'
        $script:failPackage = $p2
        $r = Invoke-PmwTask @{ Action = 'ApplySafeOS'; Root = $safeRoot; Packages = @($p2, $p1) } $events $script:control
        Assert (-not $r.Success -and $r.Status -eq 'Mounted' -and $r.WinReStatus -eq 'Mounted' -and $r.Session.WinRE.Packages[2].Status -eq 'Väntar') 'Safe OS failure preserves both mounts and remaining queue'
        $script:failPackage = ''
        $script:mockWinReMount.MountStatus = 'NeedsRemount'
        $before = $script:mockCalls.Count
        $r = Invoke-PmwTask @{ Action = 'Save'; Root = $safeRoot } $events $script:control
        Assert (-not $r.Success -and $r.WinReStatus -eq 'NeedsRemount' -and $script:mockCalls.Count -eq $before) 'Unhealthy WinRE blocks saving Windows'
        $r = Invoke-PmwTask @{ Action = 'Remount'; Root = $safeRoot } $events $script:control
        Assert ($r.Success -and $r.WinReStatus -eq 'Mounted') 'WinRE can be reconnected independently'
        $heldMount = $script:mockWinReMount; $script:mockWinReMount = $null
        $before = $script:mockCalls.Count
        $r = Invoke-PmwTask @{ Action = 'Save'; Root = $safeRoot } $events $script:control
        Assert (-not $r.Success -and $r.WinReStatus -eq 'Interrupted' -and $script:mockCalls.Count -eq $before) 'Lost WinRE mount cannot silently produce a saved image'
        $script:mockWinReMount = $heldMount
        $script:cancelAfterPackage = $true
        $r = Invoke-PmwTask @{ Action = 'ApplySafeOS'; Root = $safeRoot; Packages = @($p2, $p1) } $events $script:control
        Assert ($r.Success -and $r.Session.WinRE.Packages[1].Status -eq 'Klart' -and $r.Session.WinRE.Packages[2].Status -eq 'Väntar') 'Safe OS queue can stop between packages'
        $script:cancelAfterPackage = $false; $script:control.Cancel = $false
        $r = Invoke-PmwTask @{ Action = 'ApplySafeOS'; Root = $safeRoot; Packages = @($p1) } $events $script:control
        Assert ($r.Success -and $r.Session.WinRE.Packages[2].Status -eq 'Klart') 'Safe OS queue resumes after cancellation'
        $script:failWinReSave = $true
        $r = Invoke-PmwTask @{ Action = 'Save'; Root = $safeRoot } $events $script:control
        Assert (-not $r.Success -and $r.Status -eq 'Mounted' -and $r.WinReStatus -eq 'Mounted' -and $script:mockCalls[$script:mockCalls.Count - 1] -eq 'WinRESave') 'Failed WinRE save prevents parent commit'
        $script:failWinReSave = $false; $script:failCopyBack = $true
        $r = Invoke-PmwTask @{ Action = 'Save'; Root = $safeRoot } $events $script:control
        Assert (-not $r.Success -and $r.Status -eq 'Mounted' -and $r.WinReStatus -eq 'Saved' -and $script:mockCalls[$script:mockCalls.Count - 1] -eq 'WinRECopyBack') 'Failed WinRE integration prevents parent commit and is retryable'
        $script:failCopyBack = $false
        $r = Invoke-PmwTask @{ Action = 'Save'; Root = $safeRoot } $events $script:control
        Assert ($r.Success -and $r.Status -eq 'Saved' -and $r.WinReStatus -eq 'Integrated' -and (Get-Content -LiteralPath $embedded) -eq 'serviced winre') 'Save integrates serviced WinRE before committing Windows'
        Assert (($script:mockCalls -join ',') -match 'WinRECopyBack,Cleanup:Mount:ResetBase=False,Save,Export:1$') 'Parent cleanup and commit follow successful copy-back, then export'

        # Finalization regression scenarios use fresh sessions and real temporary files.
        $cleanRoot = Join-Path $TestRoot 'cleanup-workspace'
        $cleanOutput = Join-Path $TestRoot 'cleanup-result.wim'
        $r = Invoke-PmwTask @{ Action = 'Prepare'; Root = $cleanRoot; Source = $source; Output = $cleanOutput; Index = 3 } $events $script:control
        $script:failPendingQuery = $true
        $before = $script:mockCalls.Count
        $r = Invoke-PmwTask @{ Action = 'Save'; Root = $cleanRoot } $events $script:control
        Assert (-not $r.Success -and $r.Status -eq 'Mounted' -and $script:mockCalls.Count -eq $before) 'Pending-state inspection failure never assumes cleanup is safe'
        $script:failPendingQuery = $false; $script:failCleanup = 'Mount'
        $r = Invoke-PmwTask @{ Action = 'Save'; Root = $cleanRoot } $events $script:control
        Assert (-not $r.Success -and $r.Status -eq 'Mounted' -and $r.Session.Phase -ne 'Saved') 'Cleanup failure leaves Windows mounted and blocks commit'
        $script:failCleanup = ''; $script:failExport = $cleanOutput
        $committedHash = (Get-FileHash -LiteralPath $cleanOutput).Hash
        $r = Invoke-PmwTask @{ Action = 'Save'; Root = $cleanRoot; CleanupMode = 'ResetBase' } $events $script:control
        Assert (-not $r.Success -and $r.Status -eq 'NeedsFinalize' -and $r.Session.Finalization.WindowsCleanup -eq 'ResetBase') 'Explicit ResetBase runs before commit; export failure is resumable'
        Assert ((Get-FileHash -LiteralPath $cleanOutput).Hash -eq $committedHash) 'Failed export never replaces the committed WIM'
        $before = $script:mockCalls.Count
        $r = Invoke-PmwTask @{ Action = 'Discard'; Root = $cleanRoot } $events $script:control
        Assert (-not $r.Success -and $script:mockCalls.Count -eq $before) 'Committed changes cannot be discarded during export recovery'
        $script:failExport = ''
        $r = Invoke-PmwTask @{ Action = 'Save'; Root = $cleanRoot } $events $script:control
        Assert ($r.Success -and $r.Status -eq 'Saved' -and $script:mockCalls.Count -eq ($before + 1) -and $script:mockCalls[$before] -eq 'Export:1') 'Finalization retry exports without repeating cleanup or commit'
        Assert (@(Get-ChildItem -LiteralPath $TestRoot -Filter 'cleanup-result.wim.before-compact-*.bak').Count -eq 1) 'Pre-compaction WIM retained as backup'

        foreach ($kind in @('Package', 'Feature', 'Xml')) {
            $pendingRoot = Join-Path $TestRoot ('pending-' + $kind)
            $pendingOutput = Join-Path $TestRoot ('pending-' + $kind + '.wim')
            $r = Invoke-PmwTask @{ Action = 'Prepare'; Root = $pendingRoot; Source = $source; Output = $pendingOutput; Index = 3 } $events $script:control
            if ($kind -eq 'Package') { $script:pendingPackageTarget = 'Mount' }
            if ($kind -eq 'Feature') { $script:pendingFeatureTarget = 'Mount' }
            if ($kind -eq 'Xml') {
                $xmlPath = Join-Path $r.Session.MountPath 'Windows\WinSxS\pending.xml'
                New-Item -ItemType Directory -Path (Split-Path $xmlPath -Parent) -Force | Out-Null
                Set-Content -LiteralPath $xmlPath -Value '<Pending/>'
            }
            $before = $script:mockCalls.Count
            $r = Invoke-PmwTask @{ Action = 'Save'; Root = $pendingRoot; CleanupMode = 'ResetBase'; Optimize = $false } $events $script:control
            Assert ($r.Success -and $r.Session.Finalization.WindowsCleanup -eq 'SkippedPending' -and $r.Session.Finalization.Warnings.Count -eq 1 -and $script:mockCalls.Count -eq ($before + 1)) ("Pending $kind skips cleanup/ResetBase with a visible warning and still commits")
            $script:pendingPackageTarget = ''; $script:pendingFeatureTarget = ''
        }
        $noneRoot = Join-Path $TestRoot 'no-cleanup'
        $r = Invoke-PmwTask @{ Action = 'Prepare'; Root = $noneRoot; Source = $source; Output = (Join-Path $TestRoot 'no-cleanup.wim'); Index = 3 } $events $script:control
        $before = $script:mockCalls.Count
        $r = Invoke-PmwTask @{ Action = 'Save'; Root = $noneRoot; CleanupMode = 'None'; Optimize = $false } $events $script:control
        Assert ($r.Success -and $script:mockCalls.Count -eq ($before + 1) -and $script:mockCalls[$before] -eq 'Save') 'Explicit no-cleanup/no-export mode only commits'

        $safeOutput2 = Join-Path $TestRoot 'safe-result2.wim'
        $r = Invoke-PmwTask @{ Action = 'Prepare'; Root = $safeRoot; Source = $source; Output = $safeOutput2; Index = 3 } $events $script:control
        $embedded2 = Join-Path $r.Session.MountPath 'Windows\System32\Recovery\winre.wim'
        New-Item -ItemType Directory -Path (Split-Path $embedded2 -Parent) -Force | Out-Null
        Set-Content -LiteralPath $embedded2 -Value 'original winre'
        $r = Invoke-PmwTask @{ Action = 'ApplySafeOS'; Root = $safeRoot; Packages = @($p3) } $events $script:control
        $script:failCleanup = 'WinREMount'
        $r = Invoke-PmwTask @{ Action = 'Save'; Root = $safeRoot } $events $script:control
        Assert (-not $r.Success -and $r.WinReStatus -eq 'Mounted' -and $r.Status -eq 'Mounted') 'WinRE cleanup failure preserves both mounts'
        $script:failCleanup = ''; $script:failExport = $r.Session.WinRE.ImagePath
        $r = Invoke-PmwTask @{ Action = 'Save'; Root = $safeRoot } $events $script:control
        Assert (-not $r.Success -and $r.WinReStatus -eq 'Saved' -and $r.Status -eq 'Mounted' -and (Get-Content -LiteralPath $embedded2) -eq 'original winre') 'WinRE export failure blocks integration and parent commit'
        $script:failExport = ''
        # Reopen saved WinRE to exercise the separate discard path below.
        $r = Invoke-PmwTask @{ Action = 'ApplySafeOS'; Root = $safeRoot; Packages = @($p1) } $events $script:control
        $heldImagePath = $script:mockWinReMount.ImagePath
        $script:mockWinReMount.ImagePath = $source
        $before = $script:mockCalls.Count
        $r = Invoke-PmwTask @{ Action = 'Discard'; Root = $safeRoot } $events $script:control
        Assert (-not $r.Success -and $script:mockCalls.Count -eq $before) 'Foreign WinRE mount blocks all dismounts'
        $script:mockWinReMount.ImagePath = $heldImagePath
        $r = Invoke-PmwTask @{ Action = 'Discard'; Root = $safeRoot } $events $script:control
        Assert ($r.Success -and -not $script:mockWinReMount -and -not $script:mockMount -and ($script:mockCalls -join ',') -match 'WinREDiscard,Discard$') 'Discard closes WinRE before Windows'
        Assert ((Get-Content -LiteralPath $embedded2) -eq 'original winre') 'Discard does not integrate Safe OS changes'
        $tampered = Read-PmwSession $safeRoot
        $tampered.WinRE.ImagePath = $source; Save-PmwSession $tampered $safeRoot
        $r = Invoke-PmwTask @{ Action = 'Inspect'; Root = $safeRoot } $events $script:control
        Assert (-not $r.Success) 'Tampered WinRE working image path rejected'
        $lpRoot = Join-Path $TestRoot 'languages'
        $r = Invoke-PmwTask @{ Action = 'Prepare'; Root = $lpRoot; Source = $source; Output = (Join-Path $TestRoot 'languages.wim'); Index = 3 } $events $script:control
        $r = Invoke-PmwTask @{ Action = 'Apply'; Root = $lpRoot; Packages = @($p2) } $events $script:control
        $r = Invoke-PmwTask @{ Action = 'ApplyLP'; Root = $lpRoot; Packages = @($p3) } $events $script:control
        Assert ($r.Success -and $r.Session.Languages.RequiresCU -and $r.Session.Languages.Packages.Count -eq 1) 'Language installation requires CU reapplication'
        $r = Invoke-PmwTask @{ Action = 'Save'; Root = $lpRoot } $events $script:control
        Assert (-not $r.Success -and $r.Status -eq 'Mounted') 'Language changes block finalization until CU reapplied'
        $script:failPackage = $p2
        $r = Invoke-PmwTask @{ Action = 'ReapplyCU'; Root = $lpRoot; Packages = @($p2) } $events $script:control
        Assert (-not $r.Success -and $r.Session.Languages.RequiresCU) 'Failed CU reapplication preserves language servicing requirement'
        $script:failPackage = ''
        $before = $script:mockCalls.Count
        $r = Invoke-PmwTask @{ Action = 'ReapplyCU'; Root = $lpRoot; Packages = @($p2) } $events $script:control
        Assert ($r.Success -and -not $r.Session.Languages.RequiresCU -and $script:mockCalls.Count -eq ($before + 1)) 'CU is actually reapplied even when already in package history'
        function script:Add-AppxProvisionedPackage {
            param($Path, $PackagePath, $LicensePath, $DependencyPackagePath, $Regions, $LogPath, $ScratchDirectory, $ErrorAction)
            if ($Path -ne $script:mockMount.Path -or $Regions -ne 'all' -or -not $LicensePath) { throw 'Incorrect offline provisioning arguments' }
            $script:lxpDependencies = @($DependencyPackagePath)
            if ($script:failApp) { throw 'Simulated app provisioning failure' }
        }
        $script:failApp = $false
        function script:Get-AppxProvisionedPackage {
            param($Path, $LogPath, $ErrorAction)
            if ($Path -ne $script:mockMount.Path) { throw 'Incorrect inventory target' }
            [pscustomobject]@{ DisplayName = 'Microsoft.Sample'; Version = '2.0.0.0'; Architecture = 'neutral'; PackageName = 'Microsoft.Sample_2.0.0.0_neutral_example' }
        }
        $appx = Join-Path $TestRoot 'language.appx'; $license = Join-Path $TestRoot 'license.xml'; $dependency = Join-Path $TestRoot 'dependency.appx'
        foreach ($file in @($appx, $license, $dependency)) { Set-Content -LiteralPath $file -Value 'fixture' }
        $r = Invoke-PmwTask @{ Action = 'ListApps'; Root = $lpRoot } $events $script:control
        Assert ($r.Success -and $r.Apps.Count -eq 1 -and $r.Apps[0].Version -eq '2.0.0.0') 'Offline app inventory returns versions'
        $r = Invoke-PmwTask @{ Action = 'ProvisionApp'; Root = $lpRoot; PackagePath = $appx; LicensePath = $license; Dependencies = @($dependency) } $events $script:control
        Assert ($r.Success -and $r.Session.Apps[0].Status -eq 'Klart' -and -not $r.Session.Languages.RequiresCU -and $r.Session.LXP.Count -eq 0) 'Inbox app provisioning is separate from LXP and does not require CU'
        $script:failApp = $true
        $r = Invoke-PmwTask @{ Action = 'ProvisionApp'; Root = $lpRoot; PackagePath = $appx; LicensePath = $license; Dependencies = @() } $events $script:control
        Assert (-not $r.Success -and $r.Status -eq 'Mounted' -and $r.Session.Apps[0].Status -eq 'Fel') 'Failed app update remains journaled and mounted'
        $script:failApp = $false
        $r = Invoke-PmwTask @{ Action = 'ProvisionLXP'; Root = $lpRoot; PackagePath = $appx; LicensePath = (Join-Path $TestRoot 'missing.xml'); Dependencies = @() } $events $script:control
        Assert (-not $r.Success -and -not $r.Session.Languages.RequiresCU) 'Missing LXP license rejected before mutation'
        $r = Invoke-PmwTask @{ Action = 'ProvisionLXP'; Root = $lpRoot; PackagePath = $appx; LicensePath = $license; Dependencies = @($dependency) } $events $script:control
        Assert ($r.Success -and $r.Session.Languages.RequiresCU -and $r.Session.LXP[0].Status -eq 'Klart' -and $script:lxpDependencies[0] -eq $dependency) 'LXP provisioned offline with license and dependencies; CU required'
        $r = Invoke-PmwTask @{ Action = 'ProvisionApp'; Root = $lpRoot; PackagePath = $appx; LicensePath = $license; Dependencies = @() } $events $script:control
        Assert ($r.Success -and $r.Session.Languages.RequiresCU) 'App update cannot clear an existing language CU requirement'
        $r = Invoke-PmwTask @{ Action = 'Discard'; Root = $lpRoot } $events $script:control
        $s = Read-PmwSession $root
        $s.MountPath = $TestRoot
        Save-PmwSession $s $root
        $r = Invoke-PmwTask @{ Action = 'Inspect'; Root = $root } $events $script:control
        Assert (-not $r.Success) 'Tampered mount path rejected'
        Assert ((Get-FileHash -LiteralPath $source).Hash -eq $sourceHash) 'Original still unchanged after all operations'
        Assert ($events.Count -gt 0) 'Background operation events available to UI'
    } $testRoot
} finally {
    Remove-Module $module.Name -Force
    # Delete only the unique test directory, after proving it is inside tests/.
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $allowed = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') + '\temp-'
    if ($resolved.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    } else { throw 'Unsafe test cleanup path.' }
}
