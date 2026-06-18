#requires -version 5.1

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

$script:WingetPath    = $null
$script:SearchResults = @()
$script:LastOutputDir = $null

function Get-CurrentScriptRoot {
    if ($PSScriptRoot) {
        return $PSScriptRoot
    }

    if ($MyInvocation.MyCommand.Path) {
        return (Split-Path -Parent $MyInvocation.MyCommand.Path)
    }

    return (Get-Location).Path
}

$script:ScriptRoot = Get-CurrentScriptRoot

function Write-GuiLog {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('Info','Success','Warning','Error')][string]$Level = 'Info'
    )

    $time = (Get-Date).ToString('HH:mm:ss')
    $line = "[$time][$Level] $Message"

    if ($script:txtLog -and -not $script:txtLog.IsDisposed) {
        switch ($Level) {
            'Success' { $script:txtLog.SelectionColor = [System.Drawing.Color]::FromArgb(126, 255, 110) }
            'Warning' { $script:txtLog.SelectionColor = [System.Drawing.Color]::FromArgb(255, 214, 102) }
            'Error'   { $script:txtLog.SelectionColor = [System.Drawing.Color]::FromArgb(255, 120, 120) }
            default   { $script:txtLog.SelectionColor = [System.Drawing.Color]::FromArgb(165, 255, 210) }
        }

        $script:txtLog.AppendText("$line`r`n")
        $script:txtLog.SelectionColor = [System.Drawing.Color]::FromArgb(165, 255, 210)
        $script:txtLog.ScrollToCaret()
        $script:txtLog.Refresh()
    } else {
        Write-Host $line
    }
}

function Set-GuiBusy {
    param([bool]$Busy)

    foreach ($control in @($script:btnSearch, $script:btnGenerate, $script:btnBrowse, $script:btnOpenFolder)) {
        if ($control) { $control.Enabled = -not $Busy }
    }

    if ($script:progressBar) {
        if ($Busy) {
            $script:progressBar.Style = 'Marquee'
            $script:progressBar.MarqueeAnimationSpeed = 35
        } else {
            $script:progressBar.Style = 'Blocks'
            $script:progressBar.MarqueeAnimationSpeed = 0
            $script:progressBar.Value = 0
        }
    }

    [System.Windows.Forms.Application]::DoEvents()
}

function Get-LatestWingetPath {
    $winget = $null

    try {
        $appx = Get-AppxPackage -AllUsers -Name Microsoft.DesktopAppInstaller -ErrorAction Stop |
                Sort-Object Version -Descending |
                Select-Object -First 1

        if ($appx -and $appx.InstallLocation) {
            $candidate = Join-Path $appx.InstallLocation 'winget.exe'
            if (Test-Path -LiteralPath $candidate) {
                $winget = $candidate
            }
        }
    } catch {
    }

    if (-not $winget) {
        try {
            $winget = Get-ChildItem -Path 'C:\Program Files\WindowsApps\' -Filter winget.exe -Recurse -ErrorAction SilentlyContinue |
                      Sort-Object LastWriteTime -Descending |
                      Select-Object -First 1 -ExpandProperty FullName
        } catch {
        }
    }

# (\_/)
# ( • .•)
# / > 🥕

    if (-not $winget -or -not (Test-Path -LiteralPath $winget)) {
        throw 'winget.exe was not found. Install App Installer from the Microsoft Store, then try again.'
    }

    return $winget
}

function Search-WingetApps {
    param(
        [Parameter(Mandatory = $true)][string]$SearchTerm,
        [Parameter(Mandatory = $true)][string]$WingetPath
    )

    $SearchTerm = $SearchTerm.Trim()
    if (-not $SearchTerm) {
        throw 'Search term cannot be empty.'
    }

    Write-GuiLog "Searching winget for '$SearchTerm'..." 'Info'

    $rawLines = & $WingetPath search $SearchTerm --accept-source-agreements 2>&1 |
                ForEach-Object { ($_ -as [string]) -replace '\x1B\[[0-9;]*m', '' }

    $headerLine = $rawLines |
                  Where-Object { $_ -match '^Name\s+Id\s+Version' } |
                  Select-Object -First 1

    $results = @()

    if ($headerLine) {
        $colName    = $headerLine.IndexOf('Name')
        $colId      = $headerLine.IndexOf('Id')
        $colVersion = $headerLine.IndexOf('Version')
        $colSource  = $headerLine.LastIndexOf('Source')

        $headerIdx = [array]::IndexOf($rawLines, $headerLine)
        $dataLines = $rawLines | Select-Object -Skip ($headerIdx + 2)

        $results = foreach ($line in $dataLines) {
            if (-not $line) { continue }
            if ($line.Length -lt $colVersion) { continue }

            $name = $line.Substring($colName, $colId - $colName).Trim()
            $id = $line.Substring($colId, $colVersion - $colId).Trim()

            if ($colSource -gt 0) {
                $version = $line.Substring($colVersion, $colSource - $colVersion).Trim()
                $source = if ($line.Length -gt $colSource) { $line.Substring($colSource).Trim() } else { '' }
            } else {
                $version = $line.Substring($colVersion).Trim()
                $source = ''
            }

            if ($id) {
                [PSCustomObject]@{
                    Name    = $name
                    Id      = $id
                    Version = $version
                    Source  = $source
                }
            }
        }
    }

    return @($results)
}

function Get-SafeFolderName {
    param([Parameter(Mandatory = $true)][string]$Name)
    return ($Name -replace '[\\/:*?"<>|]', '_').Trim()
}

function New-IntuneWingetScripts {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$App,
        [Parameter(Mandatory = $true)][string]$OutputDir
    )

    if (-not (Test-Path -LiteralPath $OutputDir -PathType Container)) {
        [System.IO.Directory]::CreateDirectory($OutputDir) | Out-Null
    }

    $appId = $App.Id

    $installTemplate = @'

$AppIds = @(
    "{{APPID}}"
)

$logSource = "Winget App Install"
$logFile = "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\Winget_$($AppIds -join '_')-Install.log"

$logDir = Split-Path $logFile -Parent
try {
    if (Test-Path -LiteralPath $logDir -PathType Leaf) {
        Write-Output "Log path exists as a file and cannot be used as a directory: $logDir"
        exit 1
    }

    if (-not (Test-Path -LiteralPath $logDir -PathType Container)) {
        [System.IO.Directory]::CreateDirectory($logDir) | Out-Null
    }
} catch {
    Write-Output ("Failed to ensure log directory: " + $_)
    exit 1
}

function Log-Event {
    param(
        [string]$Message,
        [string]$Type = "Information",
        [int]$EventId = 3000
    )

    try {
        if (-not [System.Diagnostics.EventLog]::SourceExists($logSource)) {
            New-EventLog -LogName Application -Source $logSource
        }

        Write-EventLog -LogName Application -Source $logSource -EntryType $Type -EventId $EventId -Message $Message
    } catch {
    }

    Add-Content -Path $logFile -Value "[$Type][$EventId][$((Get-Date).ToString('s'))] $Message"
}

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch {
    Log-Event "Failed to set TLS 1.2, proceeding with defaults: $($_)" "Warning" 1010
}

$wingetDir    = "C:\Intune\Winget"
$wingetBundle = Join-Path $wingetDir "Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle"
$vcRedistExe  = Join-Path $wingetDir "vc_redist.x64.exe"

try {
    if (Test-Path -LiteralPath $wingetDir -PathType Leaf) {
        Log-Event "$wingetDir exists as a file; cannot create directory structure." "Error" 1000
        exit 1
    }

    if (-not (Test-Path -LiteralPath $wingetDir -PathType Container)) {
        [System.IO.Directory]::CreateDirectory($wingetDir) | Out-Null
        Log-Event "Created $wingetDir directory." "Information" 1001
    } else {
        Log-Event "$wingetDir already exists." "Information" 1003
    }
} catch {
    Log-Event ("Failed to create directory ${wingetDir}: " + $_) "Error" 1002
    exit 1
}

$MaxDnsAttempts            = 8
$InitialDnsBackoffSec      = 5
$MaxDownloadAttempts       = 6
$InitialDownloadBackoffSec = 5
$BackoffFactor             = 1.7
$JitterPercent             = 0.30

function Get-BackoffDelaySec {
    param(
        [int]$AttemptNumber,
        [int]$InitialSeconds,
        [double]$Factor,
        [double]$JitterFraction
    )

    $base      = [math]::Ceiling($InitialSeconds * [math]::Pow($Factor, ($AttemptNumber - 1)))
    $jitterMax = [math]::Max([int]([math]::Round($base * $JitterFraction)), 1)
    $jitter    = Get-Random -Minimum 0 -Maximum $jitterMax
    return ($base + $jitter)
}

function Resolve-HostWithRetry {
    param([Parameter(Mandatory = $true)][string]$DnsHost)

    for ($i = 1; $i -le $MaxDnsAttempts; $i++) {
        try {
            [void][System.Net.Dns]::GetHostAddresses($DnsHost)
            if ($i -gt 1) {
                Log-Event "DNS resolved $DnsHost on attempt $i." "Information" 1052
            }
            return $true
        } catch {
            $msg = $_.Exception.Message
            Log-Event "DNS resolve failed for $DnsHost (attempt $i/$MaxDnsAttempts): $msg" "Warning" 1051

            if ($i -ge $MaxDnsAttempts) {
                throw
            }

            $delay = Get-BackoffDelaySec -AttemptNumber $i -InitialSeconds $InitialDnsBackoffSec -Factor $BackoffFactor -JitterFraction $JitterPercent
            Log-Event "Retrying DNS for $DnsHost in ${delay}s..." "Information" 1053
            Start-Sleep -Seconds $delay
        }
    }
}

function Ensure-ParentDir {
    param([Parameter(Mandatory = $true)][string]$FilePath)

    $parent = Split-Path -Parent $FilePath
    if (-not $parent) { return }

    if (Test-Path -LiteralPath $parent -PathType Leaf) {
        throw "Path exists as a file and cannot be used as a directory: $parent"
    }

    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        [System.IO.Directory]::CreateDirectory($parent) | Out-Null
        Log-Event "Created download parent dir: $parent" "Information" 1109
    }
}

function Download-FileWithRetry {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $dnsHost = ([uri]$Url).Host
    Resolve-HostWithRetry -DnsHost $dnsHost | Out-Null

    for ($i = 1; $i -le $MaxDownloadAttempts; $i++) {
        try {
            Ensure-ParentDir -FilePath $Destination

            try {
                Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -ErrorAction Stop
            } catch {
                if (Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue) {
                    Start-BitsTransfer -Source $Url -Destination $Destination -DisplayName "Winget dependency download" -ErrorAction Stop
                } else {
                    throw
                }
            }

            if (Test-Path -LiteralPath $Destination) {
                $size = (Get-Item -LiteralPath $Destination).Length
                if ($size -gt 0) {
                    if ($i -gt 1) {
                        Log-Event "Downloaded $Url successfully on attempt $i." "Information" 1112
                    }
                    return $true
                }
            }

            throw "Downloaded file is missing or empty after attempt $i."
        } catch {
            $msg = $_.Exception.Message
            Log-Event "Download failed ($Url) attempt $i/$MaxDownloadAttempts: $msg" "Warning" 1113

            if ($i -ge $MaxDownloadAttempts) {
                throw
            }

            $delay = Get-BackoffDelaySec -AttemptNumber $i -InitialSeconds $InitialDownloadBackoffSec -Factor $BackoffFactor -JitterFraction $JitterPercent
            Log-Event "Retrying download in ${delay}s..." "Information" 1115
            Start-Sleep -Seconds $delay
        }
    }
}

$downloads = @(
    @{ Path = $wingetBundle; Name = "App Installer (winget) bundle"; Url = "https://aka.ms/getwinget" },
    @{ Path = $vcRedistExe;  Name = "VC++ x64 Redistributable";    Url = "https://aka.ms/vs/17/release/vc_redist.x64.exe" }
)

foreach ($item in $downloads) {
    if (-not (Test-Path -LiteralPath $item.Path)) {
        Log-Event "Downloading $($item.Name) from $($item.Url) to $($item.Path)" "Information" 1111

        try {
            Download-FileWithRetry -Url $item.Url -Destination $item.Path | Out-Null
            Log-Event "Downloaded $($item.Name) to $($item.Path)" "Information" 1116
        } catch {
            Log-Event ("Failed to download $($item.Name) from $($item.Url): " + $_.Exception.Message) "Error" 1117
            exit 1
        }
    } else {
        Log-Event "$($item.Name) already cached at $($item.Path); skipping download." "Information" 1114
    }
}

if (Test-Path -LiteralPath $vcRedistExe) {
    Log-Event "Installing VC++ Redistributable from $vcRedistExe" "Information" 1200

    try {
        $proc = Start-Process -FilePath $vcRedistExe -ArgumentList "/install /quiet /norestart" -Wait -PassThru

        if ($proc.ExitCode -eq 0) {
            Log-Event "VC++ Redistributable installed successfully." "Information" 1201
        } else {
            Log-Event "VC++ Redistributable installer returned ExitCode $($proc.ExitCode)." "Warning" 1202
        }
    } catch {
        Log-Event ("VC++ Redistributable install failed: " + $_) "Error" 1203
    }
} else {
    Log-Event "VC++ installer not found at $vcRedistExe; skipping VC++ installation." "Warning" 1204
}

if (Test-Path -LiteralPath $wingetBundle) {
    Log-Event "Provisioning App Installer from $wingetBundle" "Information" 1210

    try {
        Add-AppxProvisionedPackage -Online -PackagePath $wingetBundle -SkipLicense -ErrorAction Stop | Out-Null
        Log-Event "Provisioned App Installer successfully." "Information" 1211
    } catch {
        Log-Event ("Provisioning failed for App Installer at ${wingetBundle}: " + $_) "Warning" 1212
    }
} else {
    Log-Event "App Installer bundle missing at $wingetBundle; skipping provisioning." "Warning" 1213
}

Log-Event "Waiting 5 seconds for provisioning to settle..." "Information" 1301
Start-Sleep -Seconds 5

$winget = $null

try {
    $appx = Get-AppxPackage -AllUsers -Name Microsoft.DesktopAppInstaller |
            Sort-Object Version -Descending |
            Select-Object -First 1

    if ($appx -and $appx.InstallLocation) {
        $candidate = Join-Path $appx.InstallLocation "winget.exe"
        if (Test-Path -LiteralPath $candidate) {
            $winget = $candidate
        }
    }
} catch {
    Log-Event ("Get-AppxPackage lookup failed: " + $_) "Warning" 1400
}

if (-not $winget) {
    try {
        $winget = Get-ChildItem -Path 'C:\Program Files\WindowsApps\' -Filter winget.exe -Recurse -ErrorAction SilentlyContinue |
                  Sort-Object -Property LastWriteTime -Descending |
                  Select-Object -First 1 -ExpandProperty FullName
    } catch {
        Log-Event ("Error during recursive winget search: " + $_) "Error" 1401
    }
}

if (-not $winget -or -not (Test-Path -LiteralPath $winget)) {
    Log-Event "winget.exe not found; aborting." "Error" 1403
    exit 1
}

Log-Event "Using winget at: $winget" "Information" 1404

try {
    $verInfo = & $winget --version 2>&1
    Log-Event "winget version: $verInfo" "Information" 1410
} catch {
    Log-Event ("Unable to query winget version: " + $_) "Warning" 1411
}

try {
    $srcUpdate = & $winget source update --disable-interactivity 2>&1
    Log-Event "winget source update output:`n$srcUpdate" "Information" 1412
} catch {
    Log-Event ("winget source update failed: " + $_) "Warning" 1413
}

foreach ($AppId in $AppIds) {
    Log-Event "Starting install for AppID: $AppId" "Information" 1501

    try {
        $processInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processInfo.FileName = $winget
        $processInfo.Arguments = "install --id `"$AppId`" --source winget --silent --accept-package-agreements --accept-source-agreements --exact --scope machine --disable-interactivity"
        $processInfo.RedirectStandardOutput = $true
        $processInfo.RedirectStandardError  = $true
        $processInfo.UseShellExecute        = $false

        $proc   = [System.Diagnostics.Process]::Start($processInfo)
        $stdOut = $proc.StandardOutput.ReadToEnd()
        $stdErr = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()
        $exitCode = $proc.ExitCode

        Add-Content -Path $logFile -Value "`n==== Install output for $AppId at $((Get-Date).ToString('s')) ===="
        Add-Content -Path $logFile -Value $stdOut
        Add-Content -Path $logFile -Value "`n==== Install errors for $AppId ===="
        Add-Content -Path $logFile -Value $stdErr

        if ($exitCode -eq 0) {
            Log-Event "Successfully installed $AppId. ExitCode: $exitCode" "Information" 1502
        } elseif ($exitCode -eq -1073741515) {
            Log-Event "Failed to install $AppId. ExitCode: $exitCode (DLL not found - missing dependencies for SYSTEM context)." "Error" 1599
            exit 1
        } else {
            Log-Event "Failed to install $AppId. ExitCode: $exitCode`nStdOut:`n$stdOut`nStdErr:`n$stdErr" "Error" 1503
            exit $exitCode
        }
    } catch {
        Log-Event ("Exception during install of ${AppId}: " + $_) "Error" 1504
        exit 1
    }
}
'@

    $uninstallTemplate = @'
$ProgramName = "{{APPID}}"
$LogPath = "$env:ProgramData\Microsoft\IntuneManagementExtension\Logs\Winget_$ProgramName-Uninstall.log"

Start-Transcript -Path $LogPath -Force

function Resolve-WingetExe {
    $winget = $null

    try {
        $appx = Get-AppxPackage -AllUsers -Name Microsoft.DesktopAppInstaller |
                Sort-Object Version -Descending |
                Select-Object -First 1

        if ($appx -and $appx.InstallLocation) {
            $candidate = Join-Path $appx.InstallLocation "winget.exe"
            if (Test-Path -LiteralPath $candidate) {
                $winget = $candidate
            }
        }
    } catch {}

    if (-not $winget) {
        $winget = Resolve-Path "C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe" -ErrorAction SilentlyContinue |
                  Sort-Object Path |
                  Select-Object -Last 1 -ExpandProperty Path
    }

    if (-not $winget) {
        throw "Winget not installed."
    }

    return $winget
}

try {
    $winget_exe = Resolve-WingetExe
    & $winget_exe uninstall --exact --id $ProgramName --silent --accept-source-agreements --scope machine --disable-interactivity
    exit $LASTEXITCODE
} catch {
    Write-Error $_
    exit 1
} finally {
    Stop-Transcript
}
'@

    $checkTemplate = @'
$ProgramName = "{{APPID}}"

function Resolve-WingetExe {
    $winget = $null

    try {
        $appx = Get-AppxPackage -AllUsers -Name Microsoft.DesktopAppInstaller |
                Sort-Object Version -Descending |
                Select-Object -First 1

        if ($appx -and $appx.InstallLocation) {
            $candidate = Join-Path $appx.InstallLocation "winget.exe"
            if (Test-Path -LiteralPath $candidate) {
                $winget = $candidate
            }
        }
    } catch {}

    if (-not $winget) {
        $winget = Resolve-Path "C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe" -ErrorAction SilentlyContinue |
                  Sort-Object Path |
                  Select-Object -Last 1 -ExpandProperty Path
    }

    if (-not $winget) {
        throw "Winget not installed."
    }

    return $winget
}

try {
    $winget_exe = Resolve-WingetExe
    $existing = & $winget_exe list --id $ProgramName --exact --accept-source-agreements --disable-interactivity 2>&1

    if ($existing -match [regex]::Escape($ProgramName)) {
        Write-Output "Detected: $ProgramName"
        exit 0
    }

    exit 1
} catch {
    Write-Error $_
    exit 1
}
'@

    $files = @{
        'Install.ps1'   = $installTemplate.Replace('{{APPID}}', $appId)
        'Uninstall.ps1' = $uninstallTemplate.Replace('{{APPID}}', $appId)
        'Check.ps1'     = $checkTemplate.Replace('{{APPID}}', $appId)
    }

    $created = @()

    foreach ($entry in $files.GetEnumerator()) {
        $path = Join-Path $OutputDir $entry.Key
        Set-Content -Path $path -Value $entry.Value -Encoding UTF8
        $created += $path
        Write-GuiLog "Created: $path" 'Success'
    }

    return $created
}

function Get-IntuneWinAppUtil {
    param([Parameter(Mandatory = $true)][string]$ToolPath)

    if (Test-Path -LiteralPath $ToolPath) {
        return $ToolPath
    }

    $url = 'https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool/raw/master/IntuneWinAppUtil.exe'

    try {
        Write-GuiLog "Downloading IntuneWinAppUtil.exe to $ToolPath..." 'Info'
        Invoke-WebRequest -Uri $url -OutFile $ToolPath -UseBasicParsing -ErrorAction Stop
    } catch {
        throw "IntuneWinAppUtil.exe is missing and could not be downloaded. Download it manually and place it here: $ToolPath. Error: $($_.Exception.Message)"
    }

    if (-not (Test-Path -LiteralPath $ToolPath)) {
        throw "IntuneWinAppUtil.exe was not found at: $ToolPath"
    }

    return $ToolPath
}

function New-IntuneWinPackage {
    param(
        [Parameter(Mandatory = $true)][string]$OutputDir,
        [Parameter(Mandatory = $true)][string]$AppId
    )

    $intuneWinUtil = Join-Path $script:ScriptRoot 'IntuneWinAppUtil.exe'
    $intuneWinUtil = Get-IntuneWinAppUtil -ToolPath $intuneWinUtil

    Write-GuiLog "Packaging $AppId to .intunewin..." 'Info'

    $argumentList = "-c `"$OutputDir`" -s `"Install.ps1`" -o `"$OutputDir`" -q"
    $proc = Start-Process -FilePath $intuneWinUtil -ArgumentList $argumentList -Wait -PassThru -NoNewWindow

    if ($proc.ExitCode -ne 0) {
        throw "IntuneWinAppUtil.exe exited with code $($proc.ExitCode)."
    }

    $defaultFile = Join-Path $OutputDir 'Install.intunewin'
    $renamedFile = Join-Path $OutputDir "$AppId.intunewin"

    if (Test-Path -LiteralPath $defaultFile) {
        Rename-Item -LiteralPath $defaultFile -NewName "$AppId.intunewin" -Force
    }

    if (Test-Path -LiteralPath $renamedFile) {
        Write-GuiLog ".intunewin file created: $renamedFile" 'Success'
        return $renamedFile
    }

    Write-GuiLog 'Packaging completed, but the expected .intunewin file was not found.' 'Warning'
    return $null
}

function Get-SelectedGridApp {
    if (-not $script:gridResults.CurrentRow) {
        return $null
    }

    $item = $script:gridResults.CurrentRow.DataBoundItem
    if (-not $item) {
        return $null
    }

    return [PSCustomObject]@{
        Name    = $item.Name
        Id      = $item.Id
        Version = $item.Version
        Source  = $item.Source
    }
}

$script:Theme = [PSCustomObject]@{
    Window      = [System.Drawing.Color]::FromArgb(7, 18, 28)
    Panel       = [System.Drawing.Color]::FromArgb(10, 24, 38)
    PanelAlt    = [System.Drawing.Color]::FromArgb(12, 29, 45)
    Control     = [System.Drawing.Color]::FromArgb(14, 34, 52)
    ControlAlt  = [System.Drawing.Color]::FromArgb(18, 41, 61)
    Header      = [System.Drawing.Color]::FromArgb(8, 20, 32)
    Accent      = [System.Drawing.Color]::FromArgb(44, 182, 125)
    AccentDark  = [System.Drawing.Color]::FromArgb(24, 128, 86)
    Text        = [System.Drawing.Color]::FromArgb(210, 255, 235)
    MutedText   = [System.Drawing.Color]::FromArgb(120, 182, 164)
    Border      = [System.Drawing.Color]::FromArgb(22, 73, 84)
    Success     = [System.Drawing.Color]::FromArgb(61, 214, 111)
}

function Set-DarkControlTheme {
    param([Parameter(Mandatory = $true)][System.Windows.Forms.Control]$Control)

    if ($Control -is [System.Windows.Forms.Form]) {
        $Control.BackColor = $script:Theme.Window
        $Control.ForeColor = $script:Theme.Text
    }
    elseif ($Control -is [System.Windows.Forms.GroupBox]) {
        $Control.BackColor = $script:Theme.Panel
        $Control.ForeColor = $script:Theme.Text
    }
    elseif ($Control -is [System.Windows.Forms.Panel]) {
        $Control.BackColor = $script:Theme.Panel
        $Control.ForeColor = $script:Theme.Text
    }
    elseif ($Control -is [System.Windows.Forms.Label]) {
        $Control.BackColor = [System.Drawing.Color]::Transparent
        $Control.ForeColor = $script:Theme.Text
    }
    elseif ($Control -is [System.Windows.Forms.TextBox]) {
        $Control.BackColor = $script:Theme.Control
        $Control.ForeColor = $script:Theme.Text
        $Control.BorderStyle = 'FixedSingle'
    }
    elseif ($Control -is [System.Windows.Forms.RichTextBox]) {
        $Control.BackColor = [System.Drawing.Color]::FromArgb(4, 14, 22)
        $Control.ForeColor = $script:Theme.Text
        $Control.BorderStyle = 'FixedSingle'
    }
    elseif ($Control -is [System.Windows.Forms.Button]) {
        $Control.BackColor = $script:Theme.Accent
        $Control.ForeColor = [System.Drawing.Color]::FromArgb(3, 18, 22)
        $Control.FlatStyle = 'Flat'
        $Control.FlatAppearance.BorderSize = 0
        $Control.FlatAppearance.MouseOverBackColor = $script:Theme.AccentDark
        $Control.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(14, 92, 60)
        $Control.UseVisualStyleBackColor = $false
    }
    elseif ($Control -is [System.Windows.Forms.CheckBox]) {
        $Control.BackColor = $script:Theme.Panel
        $Control.ForeColor = $script:Theme.Text
        $Control.FlatStyle = 'Flat'
        $Control.FlatAppearance.BorderSize = 1
        $Control.FlatAppearance.BorderColor = $script:Theme.Border
        $Control.FlatAppearance.CheckedBackColor = [System.Drawing.Color]::FromArgb(14, 58, 46)
        $Control.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(14, 44, 56)
        $Control.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(18, 60, 75)
    }
    elseif ($Control -is [System.Windows.Forms.DataGridView]) {
        $Control.BackgroundColor = $script:Theme.PanelAlt
        $Control.GridColor = $script:Theme.Border
        $Control.BorderStyle = 'FixedSingle'
        $Control.EnableHeadersVisualStyles = $false
        $Control.ColumnHeadersBorderStyle = 'Single'
        $Control.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(7, 34, 42)
        $Control.ColumnHeadersDefaultCellStyle.ForeColor = [System.Drawing.Color]::FromArgb(118, 255, 176)
        $Control.ColumnHeadersDefaultCellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(7, 34, 42)
        $Control.ColumnHeadersDefaultCellStyle.Font = New-Object System.Drawing.Font('Cascadia Mono SemiBold', 10)
        $Control.DefaultCellStyle.BackColor = $script:Theme.Control
        $Control.DefaultCellStyle.ForeColor = $script:Theme.Text
        $Control.DefaultCellStyle.SelectionBackColor = $script:Theme.Accent
        $Control.DefaultCellStyle.SelectionForeColor = [System.Drawing.Color]::FromArgb(3, 18, 22)
        $Control.AlternatingRowsDefaultCellStyle.BackColor = $script:Theme.ControlAlt
        $Control.RowTemplate.Height = 30
        $Control.Font = New-Object System.Drawing.Font('Consolas', 10)
    }

    foreach ($child in $Control.Controls) {
        Set-DarkControlTheme -Control $child
    }
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Intune Winget Package Creator'
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object System.Drawing.Size(1280, 900)
$form.MinimumSize = New-Object System.Drawing.Size(1120, 760)
$form.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$form.BackColor = $script:Theme.Window

$headerPanel = New-Object System.Windows.Forms.Panel
$headerPanel.Dock = 'Top'
$headerPanel.Height = 108
$headerPanel.BackColor = $script:Theme.Header
$form.Controls.Add($headerPanel)

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Text = 'Intune Winget Package Creator'
$titleLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 21)
$titleLabel.ForeColor = [System.Drawing.Color]::FromArgb(118, 255, 176)
$titleLabel.AutoSize = $true
$titleLabel.Location = New-Object System.Drawing.Point(20, 14)
$headerPanel.Controls.Add($titleLabel)

$subTitleLabel = New-Object System.Windows.Forms.Label
$subTitleLabel.Text = 'Search winget, generate Intune scripts, and build .intunewin package'
$subTitleLabel.Font = New-Object System.Drawing.Font('Segoe UI', 11)
$subTitleLabel.ForeColor = [System.Drawing.Color]::FromArgb(120, 182, 164)
$subTitleLabel.AutoSize = $true
$subTitleLabel.Location = New-Object System.Drawing.Point(23, 60)
$headerPanel.Controls.Add($subTitleLabel)

$headerAccent = New-Object System.Windows.Forms.Panel
$headerAccent.Dock = 'Bottom'
$headerAccent.Height = 2
$headerAccent.BackColor = [System.Drawing.Color]::FromArgb(44, 182, 125)
$headerPanel.Controls.Add($headerAccent)

$mainPanel = New-Object System.Windows.Forms.Panel
$mainPanel.Dock = 'None'
$mainPanel.Location = New-Object System.Drawing.Point(0, 108)
$mainPanel.Size = New-Object System.Drawing.Size($form.ClientSize.Width, ($form.ClientSize.Height - 108))
$mainPanel.Anchor = 'Top,Bottom,Left,Right'
$mainPanel.Padding = New-Object System.Windows.Forms.Padding(16)
$form.Controls.Add($mainPanel)

$lblSearch = New-Object System.Windows.Forms.Label
$lblSearch.Text = 'App name to search'
$lblSearch.AutoSize = $true
$lblSearch.Location = New-Object System.Drawing.Point(18, 18)
$mainPanel.Controls.Add($lblSearch)

$script:txtSearch = New-Object System.Windows.Forms.TextBox
$script:txtSearch.Location = New-Object System.Drawing.Point(18, 42)
$script:txtSearch.Size = New-Object System.Drawing.Size(790, 30)
$script:txtSearch.Anchor = 'Top,Left,Right'
try { $script:txtSearch.PlaceholderText = 'Example: Adobe Acrobat, 7zip, Notepad++' } catch { }
$mainPanel.Controls.Add($script:txtSearch)

$script:btnSearch = New-Object System.Windows.Forms.Button
$script:btnSearch.Text = 'Search'
$script:btnSearch.Location = New-Object System.Drawing.Point(820, 40)
$script:btnSearch.Size = New-Object System.Drawing.Size(130, 32)
$script:btnSearch.Anchor = 'Top,Right'
$mainPanel.Controls.Add($script:btnSearch)

$script:btnGenerate = New-Object System.Windows.Forms.Button
$script:btnGenerate.Text = 'Generate Package'
$script:btnGenerate.Location = New-Object System.Drawing.Point(960, 40)
$script:btnGenerate.Size = New-Object System.Drawing.Size(170, 32)
$script:btnGenerate.Anchor = 'Top,Right'
$mainPanel.Controls.Add($script:btnGenerate)

$script:btnOpenFolder = New-Object System.Windows.Forms.Button
$script:btnOpenFolder.Text = 'Open Folder'
$script:btnOpenFolder.Location = New-Object System.Drawing.Point(1140, 40)
$script:btnOpenFolder.Size = New-Object System.Drawing.Size(120, 32)
$script:btnOpenFolder.Anchor = 'Top,Right'
$mainPanel.Controls.Add($script:btnOpenFolder)

$groupOptions = New-Object System.Windows.Forms.GroupBox
$groupOptions.Text = 'Options'
$groupOptions.Location = New-Object System.Drawing.Point(18, 84)
$groupOptions.Size = New-Object System.Drawing.Size(1210, 96)
$groupOptions.Anchor = 'Top,Left,Right'
$mainPanel.Controls.Add($groupOptions)

$lblOutput = New-Object System.Windows.Forms.Label
$lblOutput.Text = 'Output root folder'
$lblOutput.AutoSize = $true
$lblOutput.Location = New-Object System.Drawing.Point(14, 28)
$groupOptions.Controls.Add($lblOutput)

$script:txtOutput = New-Object System.Windows.Forms.TextBox
$script:txtOutput.Location = New-Object System.Drawing.Point(120, 24)
$script:txtOutput.Size = New-Object System.Drawing.Size(860, 28)
$script:txtOutput.Anchor = 'Top,Left,Right'
$script:txtOutput.Text = $script:ScriptRoot
$groupOptions.Controls.Add($script:txtOutput)

$script:btnBrowse = New-Object System.Windows.Forms.Button
$script:btnBrowse.Text = 'Browse...'
$script:btnBrowse.Location = New-Object System.Drawing.Point(995, 22)
$script:btnBrowse.Size = New-Object System.Drawing.Size(90, 30)
$script:btnBrowse.Anchor = 'Top,Right'
$groupOptions.Controls.Add($script:btnBrowse)

$script:chkPackage = New-Object System.Windows.Forms.CheckBox
$script:chkPackage.Text = 'Create .intunewin'
$script:chkPackage.Checked = $true
$script:chkPackage.AutoSize = $true
$script:chkPackage.Location = New-Object System.Drawing.Point(120, 58)
$groupOptions.Controls.Add($script:chkPackage)

$script:chkOpenWhenDone = New-Object System.Windows.Forms.CheckBox
$script:chkOpenWhenDone.Text = 'Open folder when done'
$script:chkOpenWhenDone.Checked = $true
$script:chkOpenWhenDone.AutoSize = $true
$script:chkOpenWhenDone.Location = New-Object System.Drawing.Point(270, 58)
$groupOptions.Controls.Add($script:chkOpenWhenDone)

$script:lblSelected = New-Object System.Windows.Forms.Label
$script:lblSelected.Text = 'Selected app: none'
$script:lblSelected.AutoSize = $true
$script:lblSelected.Location = New-Object System.Drawing.Point(18, 190)
$script:lblSelected.Font = New-Object System.Drawing.Font('Consolas', 10, [System.Drawing.FontStyle]::Bold)
$mainPanel.Controls.Add($script:lblSelected)

$script:gridResults = New-Object System.Windows.Forms.DataGridView
$script:gridResults.Location = New-Object System.Drawing.Point(18, 220)
$script:gridResults.Size = New-Object System.Drawing.Size(1210, 300)
$script:gridResults.Anchor = 'Top,Bottom,Left,Right'
$script:gridResults.ReadOnly = $true
$script:gridResults.AllowUserToAddRows = $false
$script:gridResults.AllowUserToDeleteRows = $false
$script:gridResults.MultiSelect = $false
$script:gridResults.SelectionMode = 'FullRowSelect'
$script:gridResults.AutoSizeColumnsMode = 'Fill'
$script:gridResults.BackgroundColor = $script:Theme.PanelAlt
$script:gridResults.BorderStyle = 'Fixed3D'
$script:gridResults.RowHeadersVisible = $false
$mainPanel.Controls.Add($script:gridResults)

$script:progressBar = New-Object System.Windows.Forms.ProgressBar
$script:progressBar.Location = New-Object System.Drawing.Point(18, 535)
$script:progressBar.Size = New-Object System.Drawing.Size(1210, 16)
$script:progressBar.Anchor = 'Bottom,Left,Right'
$mainPanel.Controls.Add($script:progressBar)

$lblLog = New-Object System.Windows.Forms.Label
$lblLog.Text = 'Live log'
$lblLog.AutoSize = $true
$lblLog.Location = New-Object System.Drawing.Point(18, 562)
$lblLog.Anchor = 'Bottom,Left'
$mainPanel.Controls.Add($lblLog)

$script:txtLog = New-Object System.Windows.Forms.RichTextBox
$script:txtLog.Location = New-Object System.Drawing.Point(18, 590)
$script:txtLog.Size = New-Object System.Drawing.Size(1210, 160)
$script:txtLog.Anchor = 'Bottom,Left,Right'
$script:txtLog.ReadOnly = $true
$script:txtLog.BackColor = [System.Drawing.Color]::FromArgb(4, 14, 22)
$script:txtLog.Font = New-Object System.Drawing.Font('Cascadia Code', 10)
$mainPanel.Controls.Add($script:txtLog)

Set-DarkControlTheme -Control $form
$headerPanel.BackColor = $script:Theme.Header
$titleLabel.ForeColor = [System.Drawing.Color]::FromArgb(118, 255, 176)
$subTitleLabel.ForeColor = $script:Theme.MutedText
$script:btnGenerate.BackColor = $script:Theme.Success
$script:btnGenerate.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(88, 234, 135)
$script:btnOpenFolder.BackColor = [System.Drawing.Color]::FromArgb(19, 76, 92)
$script:btnOpenFolder.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(29, 104, 122)
$script:btnBrowse.BackColor = [System.Drawing.Color]::FromArgb(19, 76, 92)
$script:btnBrowse.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(29, 104, 122)
$script:btnSearch.BackColor = [System.Drawing.Color]::FromArgb(34, 145, 170)
$script:btnSearch.ForeColor = [System.Drawing.Color]::FromArgb(230, 255, 250)
$script:btnSearch.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(42, 170, 198)
$script:btnSearch.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(22, 110, 130)
$script:btnOpenFolder.ForeColor = [System.Drawing.Color]::FromArgb(220, 255, 246)
$script:btnBrowse.ForeColor = [System.Drawing.Color]::FromArgb(220, 255, 246)
$script:btnGenerate.ForeColor = [System.Drawing.Color]::FromArgb(4, 18, 12)
$script:btnSearch.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
$script:btnGenerate.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
$script:btnOpenFolder.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
$script:btnBrowse.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
$script:chkPackage.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$script:chkOpenWhenDone.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$script:chkPackage.UseVisualStyleBackColor = $false
$script:chkOpenWhenDone.UseVisualStyleBackColor = $false
$script:gridResults.DefaultCellStyle.Font = New-Object System.Drawing.Font('Consolas', 10)
$script:gridResults.ColumnHeadersDefaultCellStyle.Font = New-Object System.Drawing.Font('Consolas', 10, [System.Drawing.FontStyle]::Bold)

$script:btnBrowse.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = 'Select output root folder'
    $dialog.SelectedPath = $script:txtOutput.Text

    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $script:txtOutput.Text = $dialog.SelectedPath
    }
})

$script:btnOpenFolder.Add_Click({
    $folderToOpen = $script:LastOutputDir

    if (-not $folderToOpen -or -not (Test-Path -LiteralPath $folderToOpen)) {
        $folderToOpen = $script:txtOutput.Text
    }

    if (Test-Path -LiteralPath $folderToOpen) {
        Start-Process explorer.exe $folderToOpen
    } else {
        [System.Windows.Forms.MessageBox]::Show('No valid output folder found yet.', 'Open Folder', 'OK', 'Information') | Out-Null
    }
})

$script:gridResults.Add_SelectionChanged({
    $selected = Get-SelectedGridApp

    if ($selected) {
        $script:lblSelected.Text = "Selected app: $($selected.Name) | ID: $($selected.Id) | Version: $($selected.Version)"
    } else {
        $script:lblSelected.Text = 'Selected app: none'
    }
})

$script:btnSearch.Add_Click({
    try {
        Set-GuiBusy $true

        $term = $script:txtSearch.Text.Trim()
        if (-not $term) {
            [System.Windows.Forms.MessageBox]::Show('Enter an application name first.', 'Search', 'OK', 'Warning') | Out-Null
            return
        }

        if (-not $script:WingetPath) {
            $script:WingetPath = Get-LatestWingetPath
            Write-GuiLog "Using winget: $script:WingetPath" 'Success'
        }

        $results = Search-WingetApps -SearchTerm $term -WingetPath $script:WingetPath

        $script:gridResults.DataSource = $null
        $script:SearchResults = @($results)

        if (-not $script:SearchResults -or $script:SearchResults.Count -eq 0) {
            Write-GuiLog "No result found for '$term'." 'Warning'
            [System.Windows.Forms.MessageBox]::Show("No result found for '$term'. Try another search term.", 'Search', 'OK', 'Information') | Out-Null
            return
        }

        $gridList = New-Object System.Collections.ArrayList
        foreach ($result in $script:SearchResults) { [void]$gridList.Add($result) }
        $script:gridResults.DataSource = $gridList
        $script:gridResults.ClearSelection()

        Write-GuiLog "Found $($script:SearchResults.Count) result(s). Select one row, then click Generate Package." 'Success'
    } catch {
        Write-GuiLog $_.Exception.Message 'Error'
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Error', 'OK', 'Error') | Out-Null
    } finally {
        Set-GuiBusy $false
    }
})

$script:txtSearch.Add_KeyDown({
    if ($_.KeyCode -eq 'Enter') {
        $script:btnSearch.PerformClick()
        $_.SuppressKeyPress = $true
    }
})

$script:btnGenerate.Add_Click({
    try {
        Set-GuiBusy $true

        $selected = Get-SelectedGridApp
        if (-not $selected) {
            [System.Windows.Forms.MessageBox]::Show('Select one application from the results grid first.', 'Generate Package', 'OK', 'Warning') | Out-Null
            return
        }

        $outputRoot = $script:txtOutput.Text.Trim()
        if (-not $outputRoot) {
            throw 'Output root folder cannot be empty.'
        }

        if (Test-Path -LiteralPath $outputRoot -PathType Leaf) {
            throw "Output root exists as a file and cannot be used as a folder: $outputRoot"
        }

        if (-not (Test-Path -LiteralPath $outputRoot -PathType Container)) {
            [System.IO.Directory]::CreateDirectory($outputRoot) | Out-Null
            Write-GuiLog "Created output root folder: $outputRoot" 'Success'
        }

        $safeAppId = Get-SafeFolderName -Name $selected.Id
        $outputDir = Join-Path $outputRoot $safeAppId
        $script:LastOutputDir = $outputDir

        if (-not (Test-Path -LiteralPath $outputDir -PathType Container)) {
            [System.IO.Directory]::CreateDirectory($outputDir) | Out-Null
            Write-GuiLog "Created app output folder: $outputDir" 'Success'
        }

        Write-GuiLog "Generating Intune package files for $($selected.Name) ($($selected.Id))..." 'Info'

        New-IntuneWingetScripts -App $selected -OutputDir $outputDir | Out-Null

        if ($script:chkPackage.Checked) {
            New-IntuneWinPackage -OutputDir $outputDir -AppId $safeAppId | Out-Null
        }

        Write-GuiLog 'Intune command lines:' 'Info'
        Write-GuiLog 'Install: %SystemRoot%\sysnative\WindowsPowerShell\v1.0\powershell.exe -windowstyle hidden -executionpolicy bypass -command .\Install.ps1' 'Info'
        Write-GuiLog 'Uninstall: %SystemRoot%\sysnative\WindowsPowerShell\v1.0\powershell.exe -windowstyle hidden -executionpolicy bypass -command .\Uninstall.ps1' 'Info'
        Write-GuiLog "Detection script: $(Join-Path $outputDir 'Check.ps1')" 'Info'
        Write-GuiLog "Done. Output folder: $outputDir" 'Success'

        if ($script:chkOpenWhenDone.Checked) {
            Start-Process explorer.exe $outputDir
        }

        [System.Windows.Forms.MessageBox]::Show("Package files created successfully:`r`n$outputDir", 'Done', 'OK', 'Information') | Out-Null
    } catch {
        Write-GuiLog $_.Exception.Message 'Error'
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Error', 'OK', 'Error') | Out-Null
    } finally {
        Set-GuiBusy $false
    }
})

$form.Add_Shown({
    Write-GuiLog 'Ready. Search for an application, select it, then generate the Intune package.' 'Info'
    $script:txtSearch.Focus()
})

[void]$form.ShowDialog()
