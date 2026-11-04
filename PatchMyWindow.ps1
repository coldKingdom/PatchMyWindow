#requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$Preview,
    [switch]$SmokeTest,
    [string]$ScreenshotPath
)

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSEdition -ne 'Desktop' -or -not [Environment]::Is64BitProcess) {
    throw 'Starta med 64-bitars Windows PowerShell 5.1 via Start-PatchMyWindow.cmd.'
}
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Starta PowerShell med -STA.' }

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal $identity
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $Preview -and -not $SmokeTest) {
    try {
        $arguments = '-NoProfile -STA -ExecutionPolicy Bypass -File "{0}"' -f $PSCommandPath
        Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden | Out-Null
    } catch {
        [Windows.MessageBox]::Show('Administratörsbehörighet behövs för DISM. Starta igen och godkänn Windows UAC-dialog.', 'PatchMyWindow', 'OK', 'Information') | Out-Null
    }
    return
}

$script:mutex = New-Object Threading.Mutex($false, 'Local\PatchMyWindow.ImageServicing')
$script:ownsMutex = $false
try { $script:ownsMutex = $script:mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $script:ownsMutex = $true }
if (-not $script:ownsMutex) {
    [Windows.MessageBox]::Show('PatchMyWindow körs redan. Använd det öppna fönstret.', 'PatchMyWindow') | Out-Null
    $script:mutex.Dispose()
    return
}

try {
    [xml]$markup = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'MainWindow.xaml') -Raw -Encoding UTF8
    $reader = New-Object Xml.XmlNodeReader $markup
    $script:window = [Windows.Markup.XamlReader]::Load($reader)
    $reader.Close()
    $script:ui = @{}
    $ns = New-Object Xml.XmlNamespaceManager $markup.NameTable
    $ns.AddNamespace('x', 'http://schemas.microsoft.com/winfx/2006/xaml')
    foreach ($node in $markup.SelectNodes('//*[@x:Name]', $ns)) {
        $name = $node.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml')
        $script:ui[$name] = $window.FindName($name)
    }

    $script:queues = @{
        Windows = (New-Object 'Collections.ObjectModel.ObservableCollection[object]')
        WinRE = (New-Object 'Collections.ObjectModel.ObservableCollection[object]')
        Languages = (New-Object 'Collections.ObjectModel.ObservableCollection[object]')
    }
    $script:target = 'Windows'
    $script:appQueue = New-Object 'Collections.ObjectModel.ObservableCollection[object]'
    $ui.AppQueueGrid.ItemsSource = $appQueue
    $script:queue = $queues.Windows
    $ui.PackageGrid.ItemsSource = $queue
    $script:session = $null
    $script:status = 'Empty'
    $script:winReStatus = 'None'
    $script:busy = $false
    $script:job = $null
    $script:source = ''
    $script:output = ''
    $script:root = Join-Path $env:LOCALAPPDATA 'PatchMyWindow'
    $script:settingsPath = Join-Path $env:LOCALAPPDATA 'PatchMyWindow\settings.json'
    $script:modulePath = Join-Path $PSScriptRoot 'PatchMyWindow.Core.psm1'
    $script:readOnly = [bool]($Preview -or $SmokeTest)
    $script:events = New-Object 'Collections.Concurrent.ConcurrentQueue[object]'
    $script:control = [hashtable]::Synchronized(@{ Cancel = $false })
    if (Test-Path -LiteralPath $settingsPath) {
        try { $saved = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json; if ($saved.WorkRoot) { $script:root = $saved.WorkRoot } } catch { }
    }
    $ui.WorkPath.Text = $root
    $ui.WorkPath.ToolTip = $root
    if ($readOnly) { $ui.AdminText.Text = 'Förhandsvisning · skrivskyddad'; $ui.AdminText.Foreground = '#F5C67D' }

    function Add-Log([string]$Text) {
        $ui.Log.AppendText($Text + [Environment]::NewLine)
        # Keep the interface bounded; the session log retains the full history.
        if ($ui.Log.Text.Length -gt 100000) { $ui.Log.Text = $ui.Log.Text.Substring($ui.Log.Text.Length - 70000) }
        $ui.Log.ScrollToEnd()
    }
    function Show-Error([string]$Message) {
        Add-Log ('FEL: ' + $Message)
        $ui.StatusText.Text = 'Åtgärden kunde inte slutföras. Se loggen.'
        [Windows.MessageBox]::Show($window, $Message, 'PatchMyWindow', 'OK', 'Error') | Out-Null
    }
    function Confirm-Action([string]$Message) {
        return [Windows.MessageBox]::Show($window, $Message, 'PatchMyWindow', 'YesNo', 'Warning', 'No') -eq 'Yes'
    }
    function Update-Ui {
        $idle = -not $script:busy
        $editable = $idle -and -not $readOnly
        $active = $script:status -notin @('Empty', 'Saved', 'Discarded')
        $mounted = $script:status -eq 'Mounted'
        $ui.BrowseSource.IsEnabled = $editable -and -not $active
        $ui.BrowseOutput.IsEnabled = $editable -and -not $active
        $ui.BrowseWork.IsEnabled = $editable -and -not $active
        $ui.Edition.IsEnabled = $editable -and -not $active
        $ui.Prepare.IsEnabled = $editable -and -not $active -and $null -ne $ui.Edition.SelectedItem -and $script:output.Length -gt 0
        $ui.AddPackages.IsEnabled = $editable
        $ui.ReapplyCU.IsEnabled = $editable -and $mounted
        $ui.ProvisionLXP.IsEnabled = $editable -and $mounted
        $ui.AppLicenseMode.IsEnabled = $editable
        $ui.ProvisionApp.IsEnabled = $editable -and $mounted
        $ui.RunAppQueue.IsEnabled = $editable -and $mounted -and @($appQueue | Where-Object { $_.Status -ne 'Klart' }).Count -gt 0
        $ui.RemoveQueuedApp.IsEnabled = $editable -and $appQueue.Count -gt 0
        $ui.ListApps.IsEnabled = $editable -and $mounted
        $ui.PackageTarget.IsEnabled = $idle
        $selected = $ui.PackageGrid.SelectedIndex
        $ui.MoveUp.IsEnabled = $editable -and $selected -gt 0
        $ui.MoveDown.IsEnabled = $editable -and $selected -ge 0 -and $selected -lt ($queue.Count - 1)
        $ui.RemovePackage.IsEnabled = $editable -and $selected -ge 0
        $pending = @($queue | Where-Object { $_.Status -ne 'Klart' }).Count
        $reCanApply = $script:winReStatus -notin @('NeedsRemount', 'Interrupted', 'Unknown')
        $reCanSave = $script:winReStatus -in @('None', 'Mounted', 'Saved', 'Integrated')
        if ($script:session -and $script:winReStatus -eq 'None' -and $script:session.WinRE.Phase -ne 'None') { $reCanSave = $false }
        $ui.Apply.IsEnabled = $editable -and $mounted -and $pending -gt 0 -and ($script:target -eq 'Windows' -or $reCanApply)
        $ui.Apply.Content = if ($script:target -eq 'WinRE') { 'Installera i WinRE' } else { 'Installera paket' }
        if ($script:target -eq 'Languages') { $ui.Apply.Content = 'Installera språkpaket' }
        $ui.TargetHint.Text = if ($script:target -eq 'WinRE') {
            'Separat kö för Safe OS Dynamic Update och dess WinRE-förkrav. Välj paket för rätt Windows-version och arkitektur. WinRE sparas före Windows-imagen.'
        } else { 'Lägg checkpoint- och förkravspaket före uppdateringen som behöver dem. Ordningen nedan används vid installation.' }
        $ui.Save.IsEnabled = $editable -and (($mounted -and $reCanSave) -or $script:status -eq 'NeedsFinalize')
        if ($script:session -and $script:session.Languages.RequiresCU) { $ui.Save.IsEnabled = $false }
        $ui.Save.Content = if ($script:status -eq 'NeedsFinalize') { 'Slutför avslutningen' } else { 'Spara och avmontera' }
        $ui.Discard.IsEnabled = $editable -and $active -and $script:status -notin @('Unknown', 'NeedsFinalize')
        $ui.CleanupMode.IsEnabled = $editable -and $script:status -ne 'NeedsFinalize'
        $ui.OptimizeWim.IsEnabled = $editable
        $ui.CleanupHint.Text = if ($ui.CleanupMode.SelectedIndex -eq 2) {
            'ResetBase: redan installerade uppdateringar kan därefter inte avinstalleras. Vid väntande åtgärder hoppas cleanup över och redovisas i loggen.'
        } else { 'Cleanup körs före avmontering. Vid väntande åtgärder hoppas den över och redovisas i loggen.' }
        $ui.CleanupHint.Foreground = if ($ui.CleanupMode.SelectedIndex -eq 2) { '#A33C49' } else { '#66788F' }
        $ui.Remount.Visibility = if ($script:status -eq 'NeedsRemount' -or $script:winReStatus -eq 'NeedsRemount') { 'Visible' } else { 'Collapsed' }
        $ui.Remount.IsEnabled = $editable
        $ui.OpenLogs.IsEnabled = $null -ne $script:session
        $ui.QueueCount.Text = '{0} paket · {1} klara' -f $queue.Count, @($queue | Where-Object { $_.Status -eq 'Klart' }).Count
        $ui.WinReStateText.Text = 'WinRE · ' + $(switch ($script:winReStatus) {
            'Mounted' { 'Monterad · osparade ändringar' }
            'NeedsRemount' { 'Behöver återanslutas' }
            'Interrupted' { 'Montering saknas · kasta sessionen' }
            'Ready' { 'Fortsätt via Installera i WinRE' }
            'Saved' { 'Sparad arbetsfil · återstår att integrera' }
            'Integrated' { 'Integrerad i Windows-imagen' }
            'Unknown' { 'Okänd status · se loggen' }
            default { 'Inte påbörjad' }
        })
        $ui.EmptyQueue.Visibility = if ($queue.Count -eq 0) { 'Visible' } else { 'Collapsed' }
        $ui.Progress.IsIndeterminate = $script:busy
        $ui.Progress.Value = if ($script:status -eq 'Saved') { 100 } else { 0 }
        $ui.Step1.Foreground = if ($mounted -or $script:status -eq 'Saved') { '#76D5BA' } else { 'White' }
        $ui.Step2.Foreground = if ($mounted) { 'White' } else { '#8EA4C2' }
        $ui.Step3.Foreground = if ($script:status -eq 'Saved') { '#76D5BA' } else { '#8EA4C2' }
        $ui.PackageGrid.Items.Refresh()
    }
    function Sync-Session($Result) {
        $script:session = $Result.Session
        $script:status = $Result.Status
        $script:winReStatus = $Result.WinReStatus
        if ($script:session) {
            if ($Result.Action -in @('Inspect', 'Prepare', 'ProvisionAppBatch')) {
                $appQueue.Clear()
                foreach ($row in @($script:session.AppQueue)) { $appQueue.Add($row) }
            }
            if ($Result.Action -in @('Inspect', 'Prepare', 'Save')) {
                $ui.CleanupMode.SelectedIndex = [array]::IndexOf(@('None', 'Standard', 'ResetBase'), $script:session.Finalization.CleanupMode)
                $ui.OptimizeWim.IsChecked = $script:session.Finalization.Optimize
            }
            $cleanupLabels = @{ NotRun = 'ej körd'; Standard = 'klar'; ResetBase = 'klar med ResetBase'; SkippedPending = 'överhoppad, väntande åtgärder' }
            $windowsCleanup = $cleanupLabels[$script:session.Finalization.WindowsCleanup]
            $winreCleanup = $cleanupLabels[$script:session.Finalization.WinRECleanup]
            $ui.FinalizationSummary.Text = "Cleanup: Windows $windowsCleanup · WinRE $winreCleanup"
            $ui.ResultText.Text = 'Resultat: ' + $script:session.Output
            $ui.ResultText.ToolTip = $script:session.Output
            if ($script:status -notin @('Empty', 'Saved', 'Discarded')) {
                $script:source = $script:session.Source
                $script:output = $script:session.Output
                $ui.SourcePath.Text = $script:source
                $ui.SourcePath.ToolTip = $script:source
                $ui.OutputPath.Text = $script:output
                $ui.OutputPath.ToolTip = $script:output
                $ui.Edition.ItemsSource = @([pscustomobject]@{ Index = $script:session.SourceIndex; Display = ('{0}  ·  {1}' -f $script:session.SourceIndex, $script:session.Name) })
                $ui.Edition.SelectedIndex = 0
            }
            foreach ($targetName in @('Windows', 'WinRE', 'Languages')) {
                $items = $queues[$targetName]
                $entries = @($script:session.Packages)
                if ($targetName -eq 'WinRE') { $entries = @($script:session.WinRE.Packages) }
                if ($targetName -eq 'Languages') { $entries = @($script:session.Languages.Packages) }
                foreach ($entry in $entries) {
                    $item = $items | Where-Object { $_.Path -eq $entry.Path } | Select-Object -First 1
                    $state = if ($entry.Status -eq 'Installerar') { 'Kontrollera' } else { $entry.Status }
                    if ($item) { $item.Status = $state } else {
                        $items.Add([pscustomobject]@{ Path = $entry.Path; Name = [IO.Path]::GetFileName($entry.Path); Size = '—'; Status = $state })
                    }
                }
            }
        }
        $ui.StatusText.Text = switch ($script:status) {
            'Mounted' { 'Monterad · Installera paket eller spara imagen' }
            'Saved' { 'Klart · Din uppdaterade WIM är sparad och avmonterad' }
            'NeedsFinalize' { 'Imagen är sparad och avmonterad · Kompakteringen återstår. Välj Slutför avslutningen.' }
            'Discarded' { 'Session avslutad · Osparade ändringar har kastats' }
            'NeedsRemount' { 'Monteringen behöver återanslutas · Klicka på Återanslut montering' }
            'Interrupted' { 'Avbruten session · Ingen montering hittades. Avsluta med Kasta ändringar och använd ett nytt resultatnamn.' }
            'Unknown' { 'Monteringsstatus kunde inte fastställas · Se loggen innan du fortsätter' }
            default { 'Redo · Välj en Windows-image för att börja' }
        }
        if ($script:status -eq 'Saved' -and $script:session.Finalization.Warnings.Count -gt 0) { $ui.StatusText.Text = 'Sparad och avmonterad med anmärkning · Cleanup hoppades över för väntande åtgärder. Se loggen.' }
        if ($script:session -and $script:session.Languages.RequiresCU) { $ui.StatusText.Text = 'Språkändringar väntar på CU · Återapplicera senaste CU innan sparning och cleanup.' }
    }
    function Start-Task([string]$Action, [hashtable]$Extra = @{}) {
        if ($script:busy -or $readOnly) { return }
        $request = @{ Action = $Action; Root = $script:root }
        foreach ($key in $Extra.Keys) { $request[$key] = $Extra[$key] }
        $script:control.Cancel = $false
        $ps = [PowerShell]::Create()
        $code = 'param($ModulePath, $Request, $Events, $Control) Import-Module $ModulePath -Force -ErrorAction Stop; Invoke-PmwTask -Request $Request -Events $Events -Control $Control'
        [void]$ps.AddScript($code).AddArgument($script:modulePath).AddArgument($request).AddArgument($script:events).AddArgument($script:control)
        try {
            $handle = $ps.BeginInvoke()
            $script:job = @{ PowerShell = $ps; Handle = $handle; Action = $Action }
            $script:busy = $true
            $ui.StatusText.Text = switch ($Action) {
                'ReadImage' { 'Läser utgåvor i Windows-imagen …' }
                'Prepare' { 'Skapar och monterar arbetskopia · Detta kan ta flera minuter …' }
                'Apply' { 'Installerar paket · Vänta medan DISM arbetar …' }
                'ApplySafeOS' { 'Installerar Safe OS-paket i WinRE · Vänta medan DISM arbetar …' }
                'Save' { 'Sparar och avmonterar · Stäng inte av datorn …' }
                'Discard' { 'Avslutar sessionen …' }
                default { 'Kontrollerar sessionen …' }
            }
            $ui.StopQueue.Visibility = if ($Action -in @('Apply', 'ApplySafeOS', 'ApplyLP', 'ReapplyCU', 'ProvisionAppBatch')) { 'Visible' } else { 'Collapsed' }
            $ui.StopQueue.IsEnabled = $true
            Update-Ui
        } catch { $ps.Dispose(); Show-Error $_.Exception.Message }
    }

    $script:timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(200)
    $timer.Add_Tick({
        $eventItem = $null
        while ($script:events.TryDequeue([ref]$eventItem)) {
            if ($eventItem.Kind -eq 'Log') { Add-Log $eventItem.Data }
            if ($eventItem.Kind -eq 'Package') {
                foreach ($item in $queues[$eventItem.Data.Target]) { if ($item.Path -eq $eventItem.Data.Path) { $item.Status = $eventItem.Data.Status } }
                $ui.PackageGrid.Items.Refresh()
            }
        }
        if ($script:job -and $script:job.Handle.IsCompleted) {
            $finished = $script:job
            $script:job = $null
            try {
                $results = $finished.PowerShell.EndInvoke($finished.Handle)
                if ($results.Count -eq 0) { throw ('Bakgrundskörningen gav inget resultat. ' + ($finished.PowerShell.Streams.Error | Out-String)) }
                $result = $results[$results.Count - 1]
                if ($finished.Action -eq 'Prepare' -and $result.Success) { foreach ($item in @($queues.Windows) + @($queues.WinRE) + @($queues.Languages)) { $item.Status = 'Väntar' } }
                Sync-Session $result
                if ($finished.Action -eq 'ListApps' -and $result.Success) {
                    $ui.AppsGrid.ItemsSource = @($result.Apps)
                    $ui.AppsHint.Text = '{0} provisionerade paket · läst {1:HH:mm:ss}' -f $result.Apps.Count, (Get-Date)
                }
                if ($finished.Action -in @('Prepare', 'ProvisionApp', 'ProvisionAppBatch', 'ProvisionLXP', 'Discard')) {
                    $ui.AppsGrid.ItemsSource = $null
                    $ui.AppsHint.Text = 'Läs appar och versioner för aktuell status.'
                }
                if ($finished.Action -eq 'ReadImage' -and $result.Success) {
                    $ui.Edition.ItemsSource = @($result.Images)
                    if ($result.Images.Count -gt 0) { $ui.Edition.SelectedIndex = 0 }
                    Add-Log ('Hittade {0} Windows-utgåvor.' -f $result.Images.Count)
                }
                if (-not $result.Success) { Show-Error $result.Error }
            } catch { $script:status = 'Unknown'; Show-Error $_.Exception.Message }
            finally {
                $finished.PowerShell.Dispose()
                $script:busy = $false
                $ui.StopQueue.Visibility = 'Collapsed'
                Update-Ui
            }
        }
    })

    $ui.BrowseSource.Add_Click({
        try {
            $dialog = New-Object Microsoft.Win32.OpenFileDialog
            $dialog.Filter = 'Windows-image (*.wim;*.esd)|*.wim;*.esd'
            if ($dialog.ShowDialog($window)) {
                $script:source = $dialog.FileName
                $ui.SourcePath.Text = $script:source
                $ui.SourcePath.ToolTip = $script:source
                $ui.Edition.ItemsSource = $null
                Start-Task 'ReadImage' @{ Source = $script:source }
            }
        } catch { Show-Error $_.Exception.Message }
    })
    $ui.BrowseOutput.Add_Click({
        $dialog = New-Object Microsoft.Win32.SaveFileDialog
        $dialog.Filter = 'Windows-image (*.wim)|*.wim'
        $dialog.FileName = 'install-patched.wim'
        $dialog.OverwritePrompt = $true
        if ($dialog.ShowDialog($window)) {
            if (Test-Path -LiteralPath $dialog.FileName) { Show-Error 'Välj ett nytt filnamn. Befintliga filer skrivs inte över.'; return }
            $script:output = $dialog.FileName; $ui.OutputPath.Text = $script:output; $ui.OutputPath.ToolTip = $script:output; Update-Ui
        }
    })
    $ui.BrowseWork.Add_Click({
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.Description = 'Välj en arbetsmapp på en lokal NTFS-disk med gott om ledigt utrymme.'
        if ($dialog.ShowDialog() -eq 'OK') {
            $script:root = $dialog.SelectedPath; $ui.WorkPath.Text = $script:root; $ui.WorkPath.ToolTip = $script:root
            try {
                New-Item -ItemType Directory -Path (Split-Path $settingsPath -Parent) -Force | Out-Null
                @{ WorkRoot = $script:root } | ConvertTo-Json | Set-Content -LiteralPath $settingsPath -Encoding UTF8
                $queues.Windows.Clear(); $queues.WinRE.Clear(); $queues.Languages.Clear()
                $appQueue.Clear()
                $ui.AppsGrid.ItemsSource = $null
                $ui.AppsHint.Text = 'Applistan har inte lästs för den valda arbetsmappen.'
                Start-Task 'Inspect'
            } catch { Show-Error $_.Exception.Message }
        }
        $dialog.Dispose()
    })
    $ui.Prepare.Add_Click({ Start-Task 'Prepare' @{ Source = $script:source; Output = $script:output; Index = [int]$ui.Edition.SelectedItem.Index } })
    $ui.Edition.Add_SelectionChanged({ Update-Ui })
    $ui.CleanupMode.Add_SelectionChanged({ Update-Ui })
    $ui.PackageGrid.Add_SelectionChanged({ Update-Ui })
    $ui.PackageTarget.Add_SelectionChanged({
        $script:target = @('Windows', 'WinRE', 'Languages')[$ui.PackageTarget.SelectedIndex]
        $script:queue = $queues[$script:target]
        $ui.PackageGrid.ItemsSource = $script:queue
        Update-Ui
    })
    $ui.AddPackages.Add_Click({
        $dialog = New-Object Microsoft.Win32.OpenFileDialog
        $dialog.Filter = if ($script:target -eq 'WinRE') { 'Safe OS / WinRE-paket (*.cab;*.msu)|*.cab;*.msu' } else { 'Uppdateringspaket (*.msu;*.cab)|*.msu;*.cab' }
        $dialog.Title = if ($script:target -eq 'WinRE') { 'Välj Safe OS Dynamic Update eller WinRE-förkrav' } else { 'Välj Windows-uppdateringar' }
        $dialog.Multiselect = $true
        if ($script:target -eq 'Languages') { $dialog.Filter = 'Språkpaket LP/LIP (*.cab)|*.cab'; $dialog.Title = 'Välj LP/LIP för rätt Windows-version och arkitektur' }
        if ($dialog.ShowDialog($window)) {
            foreach ($path in $dialog.FileNames) {
                if (@($queue | Where-Object { $_.Path -eq $path }).Count -eq 0) {
                    $file = Get-Item -LiteralPath $path
                    $queue.Add([pscustomobject]@{ Path = $path; Name = $file.Name; Size = ('{0:N1} MB' -f ($file.Length / 1MB)); Status = 'Väntar' })
                }
            }
            Update-Ui
        }
    })
    $ui.MoveUp.Add_Click({ $i = $ui.PackageGrid.SelectedIndex; if ($i -gt 0) { $queue.Move($i, $i - 1); $ui.PackageGrid.SelectedIndex = $i - 1 }; Update-Ui })
    $ui.MoveDown.Add_Click({ $i = $ui.PackageGrid.SelectedIndex; if ($i -ge 0 -and $i -lt ($queue.Count - 1)) { $queue.Move($i, $i + 1); $ui.PackageGrid.SelectedIndex = $i + 1 }; Update-Ui })
    $ui.RemovePackage.Add_Click({ $i = $ui.PackageGrid.SelectedIndex; if ($i -ge 0) { $queue.RemoveAt($i) }; Update-Ui })
    $ui.Apply.Add_Click({
        $action = if ($script:target -eq 'WinRE') { 'ApplySafeOS' } else { 'Apply' }
        if ($script:target -eq 'Languages') { $action = 'ApplyLP' }
        Start-Task $action @{ Packages = @($queue | Where-Object { $_.Status -ne 'Klart' } | ForEach-Object { $_.Path }) }
    })
    $ui.StopQueue.Add_Click({ $script:control.Cancel = $true; $ui.StopQueue.IsEnabled = $false; $ui.StatusText.Text = 'Stoppar kön när pågående paket är klart …' })
    $ui.ReapplyCU.Add_Click({
        $dialog = New-Object Microsoft.Win32.OpenFileDialog
        $dialog.Filter = 'Kumulativ uppdatering (*.msu;*.cab)|*.msu;*.cab'
        $dialog.Title = 'Välj senaste CU. Lägg nödvändiga checkpoints i samma mapp.'
        if ($dialog.ShowDialog($window)) {
            if (Confirm-Action "Återapplicera denna CU efter språkändringarna? Välj rätt Windows-version och arkitektur. Filtypen ensam verifierar inte att paketet är en CU.`n`n$($dialog.FileName)") {
                Start-Task 'ReapplyCU' @{ Packages = @($dialog.FileName) }
            }
        }
    })
    function Show-ProvisionDialog([bool]$IsLanguage) {
        $label = if ($IsLanguage) { 'LXP' } else { 'app' }
        $packageDialog = New-Object Microsoft.Win32.OpenFileDialog
        $packageDialog.Title = "Välj kompatibelt $label-paket"
        $packageDialog.Filter = 'APPX/MSIX-paket|*.appx;*.appxbundle;*.msix;*.msixbundle'
        $packageDialog.Multiselect = -not $IsLanguage
        if (-not $packageDialog.ShowDialog($window)) { return }
        $skipLicense = $ui.AppLicenseMode.SelectedIndex -eq 1
        foreach ($packageFile in $packageDialog.FileNames) {
        $licenseDialog = New-Object Microsoft.Win32.OpenFileDialog
        $licenseDialog.Title = "Välj XML-licensen för $([IO.Path]::GetFileName($packageFile))"
        $licenseDialog.Filter = 'XML-licens|*.xml'
        if (-not $skipLicense -and -not $licenseDialog.ShowDialog($window)) { return }
        $dependencyDialog = New-Object Microsoft.Win32.OpenFileDialog
        $dependencyDialog.Title = "Beroenden för $([IO.Path]::GetFileName($packageFile)) — Avbryt om inga behövs"
        $dependencyDialog.Filter = $packageDialog.Filter
        $dependencyDialog.Multiselect = $true
        $dependencies = @()
        if ($dependencyDialog.ShowDialog($window)) { $dependencies = @($dependencyDialog.FileNames) }
        if (-not $IsLanguage) {
            $existing = @($appQueue | Where-Object { $_.Path -eq $packageFile })
            foreach ($row in $existing) { [void]$appQueue.Remove($row) }
            $appQueue.Add([pscustomobject]@{ Path = $packageFile; LicensePath = $licenseDialog.FileName; SkipLicense = $skipLicense; Dependencies = $dependencies; Status = 'Väntar' })
            Update-Ui
            continue
        }
        $message = "Provisionera $label i den monterade Windows-imagen?`n`nPaket: $($packageDialog.FileName)`nLicens: $($licenseDialog.FileName)`nBeroenden: $($dependencies -join ', ')`n`nPaketet måste stödja målversionen."
        if ($IsLanguage) { $message += ' CU behöver återappliceras efteråt.' }
        if ($skipLicense) { $message += "`n`nSkipLicense är valt: paketet ska inte kräva någon licens. Endast Enterprise/Server stöds för detta val." }
        $action = if ($IsLanguage) { 'ProvisionLXP' } else { 'ProvisionApp' }
        if (Confirm-Action $message) {
            Start-Task $action @{ PackagePath = $packageDialog.FileName; LicensePath = $licenseDialog.FileName; SkipLicense = $skipLicense; Dependencies = $dependencies }
            $ui.AppLicenseMode.SelectedIndex = 0
        }
        }
        $ui.AppLicenseMode.SelectedIndex = 0
    }
    $ui.ProvisionLXP.Add_Click({ Show-ProvisionDialog $true })
    $ui.ProvisionApp.Add_Click({ Show-ProvisionDialog $false })
    $ui.ListApps.Add_Click({ Start-Task 'ListApps' })
    $ui.RemoveQueuedApp.Add_Click({ if ($ui.AppQueueGrid.SelectedItem) { [void]$appQueue.Remove($ui.AppQueueGrid.SelectedItem) }; Update-Ui })
    $ui.RunAppQueue.Add_Click({
        if (Confirm-Action "Provisionera appkön i visad ordning?`n`n$($appQueue.Count) rader. Klara appar hoppas över. Kön stannar vid första fel. Granska licensval och beroenden innan körning.") {
            Start-Task 'ProvisionAppBatch' @{ Items = @($appQueue) }
        }
    })
    $ui.Save.Add_Click({
        $pending = @(@($queues.Windows) + @($queues.WinRE) + @($queues.Languages) | Where-Object { $_.Status -ne 'Klart' }).Count
        $pending += @($appQueue | Where-Object { $_.Status -ne 'Klart' }).Count
        $message = "Spara ändringarna och avmontera imagen?`n`n$($script:session.Output)"
        $mode = @('None', 'Standard', 'ResetBase')[$ui.CleanupMode.SelectedIndex]
        if ($script:status -eq 'NeedsFinalize') { $message = "Slutföra den redan sparade imagen?`n`n$($script:session.Output)" }
        $message += "`n`nCleanup: $($ui.CleanupMode.SelectedItem.Content)`nKompaktering: $([bool]$ui.OptimizeWim.IsChecked)"
        if ($mode -eq 'ResetBase' -and $script:status -ne 'NeedsFinalize') { $message += "`n`nResetBase gör att redan installerade uppdateringar inte längre kan avinstalleras i resultatet." }
        if ($script:session.WinRE.Phase -ne 'None') { $message += "`n`nWinRE sparas och integreras före Windows-imagen." }
        if ($pending -gt 0 -or $script:session.LastError) { $message += "`n`nDet finns paket som inte är klara eller ett tidigare fel. Kontrollera loggen innan du sparar ett partiellt resultat." }
        if (Confirm-Action $message) { Start-Task 'Save' @{ CleanupMode = $mode; Optimize = [bool]$ui.OptimizeWim.IsChecked } }
    })
    $ui.Discard.Add_Click({
        if (Confirm-Action "Kasta alla osparade ändringar i Windows och WinRE och avsluta sessionen?`n`nOriginalet och arbetsfilerna behålls. Exportfilen ska inte användas som verifierat patchresultat.") { Start-Task 'Discard' }
    })
    $ui.Remount.Add_Click({ Start-Task 'Remount' })
    $ui.OpenLogs.Add_Click({
        if ($script:session) {
            $path = Split-Path $script:session.AppLog -Parent
            if (Test-Path -LiteralPath $path) { Start-Process explorer.exe -ArgumentList ('"{0}"' -f $path) }
        }
    })
    $window.Add_Closing({
        param($sender, $eventArgs)
        if ($script:busy) {
            $eventArgs.Cancel = $true
            [Windows.MessageBox]::Show($window, 'En operation pågår. Vänta tills DISM är klart. Paketkön kan stoppas mellan två paket.', 'PatchMyWindow', 'OK', 'Information') | Out-Null
        } elseif ($script:status -notin @('Empty', 'Saved', 'Discarded')) {
            if (-not (Confirm-Action "Imagen eller sessionen är fortfarande aktiv. Stänga fönstret och lämna sessionen för återupptagning?`n`nÖppna samma arbetsmapp nästa gång för att fortsätta.")) { $eventArgs.Cancel = $true }
        }
    })

    Add-Log 'Välkommen till PatchMyWindow. Originalet bevaras; vald utgåva exporteras till en ny WIM.'
    Add-Log 'Använd paket för rätt Windows-version och arkitektur. Förkrav installeras före beroende paket.'
    Update-Ui
    if ($SmokeTest) {
        # Exercise layout and enablement without elevation or DISM/image changes.
        $required = @('SourcePath','Edition','Prepare','Apply','Save','Discard','Log','Progress','StopQueue')
        foreach ($name in $required) { if (-not $ui[$name]) { throw "Saknad kontroll: $name" } }
        if ($ui.Prepare.IsEnabled -or $ui.Apply.IsEnabled -or $ui.Save.IsEnabled) { throw 'En ändringsåtgärd är aktiv i skrivskyddad förhandsvisning.' }
        if ($ui.CleanupMode.SelectedIndex -ne 1 -or -not $ui.OptimizeWim.IsChecked -or $ui.CleanupMode.IsEnabled) { throw 'Fel standardinställningar för avslutning.' }
        $script:readOnly = $false
        $script:status = 'Mounted'
        $appQueue.Add([pscustomobject]@{ Path = 'fixture.appx'; LicensePath = 'license.xml'; SkipLicense = $false; Dependencies = @(); Status = 'Väntar' })
        $queue.Add([pscustomobject]@{ Path = 'fixture.msu'; Name = 'fixture.msu'; Size = '1 MB'; Status = 'Väntar' })
        Update-Ui
        if (-not $ui.RunAppQueue.IsEnabled -or -not $ui.RemoveQueuedApp.IsEnabled) { throw 'Appkön kan inte köras eller redigeras för monterad image.' }
        if (-not $ui.Apply.IsEnabled -or -not $ui.Save.IsEnabled -or $ui.BrowseSource.IsEnabled) { throw 'Felaktiga åtgärder för monterad image.' }
        $script:busy = $true; Update-Ui
        if ($ui.RunAppQueue.IsEnabled -or $ui.RemoveQueuedApp.IsEnabled -or $ui.ProvisionApp.IsEnabled) { throw 'Appkön kan ändras under körning.' }
        if ($ui.Apply.IsEnabled -or $ui.Save.IsEnabled -or $ui.Discard.IsEnabled -or $ui.AddPackages.IsEnabled) { throw 'Ändringar tillåts under pågående körning.' }
        if ($ui.PackageTarget.IsEnabled) { throw 'Målbyte tillåts under pågående körning.' }
        if ($ui.CleanupMode.IsEnabled -or $ui.OptimizeWim.IsEnabled) { throw 'Avslutningsinställningar kan ändras under körning.' }
        $script:busy = $false
        $ui.PackageTarget.SelectedIndex = 1
        if ($queue.Count -ne 0 -or $ui.Apply.IsEnabled -or $script:target -ne 'WinRE') { throw 'Safe OS-kön är inte separat från Windows-kön.' }
        $queue.Add([pscustomobject]@{ Path = 'safeos.cab'; Name = 'safeos.cab'; Size = '1 MB'; Status = 'Väntar' })
        Update-Ui
        if (-not $ui.Apply.IsEnabled -or $ui.Apply.Content -ne 'Installera i WinRE') { throw 'Safe OS-åtgärden saknas.' }
        $script:winReStatus = 'NeedsRemount'; Update-Ui
        if ($ui.Apply.IsEnabled -or $ui.Save.IsEnabled -or $ui.Remount.Visibility -ne 'Visible') { throw 'En trasig WinRE-montering tillåter ändringar.' }
        $script:winReStatus = 'Interrupted'; Update-Ui
        if ($ui.Save.IsEnabled) { throw 'Windows kan sparas trots saknad WinRE-montering.' }
        $script:winReStatus = 'None'
        $ui.PackageTarget.SelectedIndex = 0
        if ($queue.Count -ne 1 -or $queue[0].Path -ne 'fixture.msu') { throw 'Windows-kön förlorades vid målbyte.' }
        $ui.CleanupMode.SelectedIndex = 2
        if ($ui.CleanupHint.Text -notlike '*inte avinstalleras*') { throw 'ResetBase saknar konsekvensbeskrivning.' }
        $script:status = 'NeedsFinalize'; Update-Ui
        if (-not $ui.Save.IsEnabled -or $ui.Discard.IsEnabled -or $ui.CleanupMode.IsEnabled -or -not $ui.OptimizeWim.IsEnabled) { throw 'Felaktiga åtgärder vid avbruten kompaktering.' }
        $ui.CleanupMode.SelectedIndex = 1
        $appQueue.Clear()
        $script:status = 'Empty'; $script:readOnly = $true; $queues.Windows.Clear(); $queues.WinRE.Clear(); Update-Ui
        $window.Show()
        $window.UpdateLayout()
        $window.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::ApplicationIdle)
        if ($ScreenshotPath) {
            $bitmap = New-Object Windows.Media.Imaging.RenderTargetBitmap ([int]$window.Content.ActualWidth), ([int]$window.Content.ActualHeight), 96, 96, ([Windows.Media.PixelFormats]::Pbgra32)
            $bitmap.Render($window.Content)
            $encoder = New-Object Windows.Media.Imaging.PngBitmapEncoder
            $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
            $stream = [IO.File]::Create($ScreenshotPath)
            try { $encoder.Save($stream) } finally { $stream.Dispose() }
        }
        $window.Close()
        Write-Output ('PASS: WPF layout, {0} named controls, isolated target queues, busy/read-only/WinRE recovery guards. PowerShell {1}' -f $ui.Count, $PSVersionTable.PSVersion)
    } else {
        $timer.Start()
        $window.Add_ContentRendered({ if (-not $readOnly) { Start-Task 'Inspect' } })
        [void]$window.ShowDialog()
    }
} finally {
    if (Get-Variable timer -Scope Script -ErrorAction SilentlyContinue) { $script:timer.Stop() }
    if ($script:ownsMutex) { $script:mutex.ReleaseMutex() }
    $script:mutex.Dispose()
}
