function CreateAuditOutput($MyText) {
	$MyOutputText = (get-date -UFormat "%Y.%m.%d.%H.%M.%S") + " " + $MyText
	Out-File -filepath 'c:\tools\labsetup\setup.log' -Encoding default -Append -inputObject $MyOutputText
} #CreateAuditOutput


if (!(Test-Path -PathType Container -Path c:\tools\labsetup)) {
    New-Item -Path C:\Tools\labsetup -ItemType Directory
}

CreateAuditOutput ("Setup is continuing in " + $MyInvocation.MyCommand.Name)

CreateAuditOutput ("Checking current role")
$CurrentRole = (Get-CimInstance -ClassName Win32_OperatingSystem).ProductType
CreateAuditOutput ("Current role is $CurrentRole")

$Computers = @()
$Computers += 'SVR16-ADFS'
$Computers += 'SVR19-PKI'
$Computers += 'SVR22-SYNC'
$Computers += 'WIN10-ADM'
$Computers += 'WIN10-CEO'

if ($CurrentRole -eq '2') {
    CreateAuditOutput ("Waiting for ADDS services")
    Start-Service -Name 'NTDS'
    Start-Service -Name 'DNS'
    Start-Service -Name 'Kdc'
    Start-Service -Name 'ADWS'
    Start-Sleep -Seconds 30
    CreateAuditOutput ("ADDS services are running")
    $foundDC = $false
    do {
        CreateAuditOutput ("Waiting for DC computer account to become available")
        $DC = Get-ADComputer -LDAPFilter "(&(objectClass=computer)(cn=SVR19-DC1))"
        if ($null -eq $DC) {
            Start-Sleep -Seconds 10
        } else {
            $foundDC = $true
        }
    } while (!($foundDC))

    CreateAuditOutput ("Checking for computer accounts")
    ForEach ($Computer in $Computers) {
        CreateAuditOutput ("Checking for $Computer")
        $CPUAccount = Get-ADComputer -LDAPFilter "(&(objectClass=computer)(cn=$Computer))"
        if ($null -eq $CPUAccount) {
            CreateAuditOutput ("Did not find $Computer")
            CreateAuditOutput ("Creating $Computer")
            New-ADComputer -Name $Computer -AccountPassword (ConvertTo-SecureString -String 'TempJoinPA$$' -AsPlainText -Force)
        } else {
            CreateAuditOutput ("Found $Computer")
        }
    }

    CreateAuditOutput ("Checking for KDS Root Key")
    $KDS = Get-KdsRootKey
    if ($null -eq $KDS) {
        try {
            Add-KdsRootKey -EffectiveTime ((Get-Date).AddHours(-10))
        } catch {
            CreateAuditOutput ("" + ($Error[0] | Out-String))
        }
    } else {
        CreateAuditOutput ("Found KDS Root Key " + $KDS.KeyId)
    }
	
    $Task = Get-ScheduledTask -TaskName 'ATTACKSIMLABSETUP' -ErrorAction SilentlyContinue
    if ($null -ne $Task) {
        CreateAuditOutput ("Deleting setup task")
        Unregister-ScheduledTask -TaskName 'ATTACKSIMLABSETUP' -Confirm:$false
    }
} else {
    CreateAuditOutput ("Checking for startup task")
    $Task = Get-ScheduledTask -TaskName 'ATTACKSIMLABSETUP' -ErrorAction SilentlyContinue
    if ($null -eq $Task) {
        CreateAuditOutput ("Startup task was not found")
        CreateAuditOutput ("Creating startup task")
        $taskTrigger = New-ScheduledTaskTrigger -AtStartup
        $taskAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File C:\Tools\labsetup\invoke-setup.ps1" -WorkingDirectory 'c:\tools\labsetup'
        $taskPrincipal = New-ScheduledTaskPrincipal -UserID "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest
        $Task = Register-ScheduledTask 'ATTACKSIMLABSETUP' -Action $taskAction -Trigger $taskTrigger -Principal $taskPrincipal
    }
    CreateAuditOutput ("Checking for AD-Domain-Services feature")
    if (!(Get-WindowsFeature -Name AD-Domain-Services).Installed) {
        CreateAuditOutput ("AD-Domain-Services feature is not installed")
        CreateAuditOutput ("Installing AD-Domain-Services feature")
        try {
            Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools
        } catch {
            CreateAuditOutput ("" + ($Error[0] | Out-String))
            exit 1
        }
    }
    
    CreateAuditOutput ("Checking for Caldera Agent")
    if (Test-Path -Path "C:\Users\Public\splunkd.exe" -PathType Leaf) {
        CreateAuditOutput ("Found Caldera Agent")
    } else {
        CreateAuditOutput ("Scheduling Caldera Agent installer script")
        $childScript = "C:\Tools\labsetup\Install-CalderaAgent.ps1"
        $arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $childScript + '" -CreateSchedule'
        Start-Process -FilePath "powershell.exe" -ArgumentList $arguments -WindowStyle Hidden
    }

    CreateAuditOutput ("Starting promotion to DC in new forest")
    try {
        Install-ADDSForest -DomainName 'contoso.local' -SafeModeAdministratorPassword (Convertto-SecureString -AsPlainText "P@ssw0rd123!" -Force) -Force
    } catch {
        CreateAuditOutput ("" + ($Error[0] | Out-String))
        exit 1
    }
}

CreateAuditOutput ("Setup has ended in " + $MyInvocation.MyCommand.Name)
