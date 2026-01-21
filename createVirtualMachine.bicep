param location string

@description('The name of existing Virtual Network')
param virtualNetworkName string

@description('The name of the existing subnet in the VNET')
param subnetName string

@description('The name of the existing NSG')
param NSGName string

@description('Optional: Name of existing availability set for the VM')
param adAvailabilitySetName string = ''

@description('The computer name for the new VM.')
param vmName string

@description('20:00: The time the VM should shutdown.')
param vmShutdownTime string = '20:00'

@description('UTC: The time zone of the vmShutdownTime.')
param vmShutdownTimeTimeZoneId string = 'UTC'

@description('Optional: The email address the shutdown notification should go to.')
param vmShutdownEmailRecipient string = ''

@description('The IP address for the new VM')
param vmIpAddress string

@description('The name of the admin account for the VM')
param adminUsername string

@description('The name of the admin FQDN for the VM')
param adminFullUsername string

@description('The password for the Administrator account of the new VM')
@secure()
param adminPassword string

@description('The size of the VM Created')
param vmSize string = 'Standard_B2as_v2'

@description('Windows Server Version')
param imageReference object

@description('Windows Server Version')
param imagePlan object

@description('The Storage type of the data Disks.')
@allowed([
  'StandardSSD_LRS'
  'Standard_LRS'
  'Premium_LRS'
])
param diskType string = 'StandardSSD_LRS'

@description('Should the Azure VM guest service wait for the DNS service to start')
param waitOnDNS bool = false

@description('By default, the VM is not assigned a PIP')
param addPublicIp bool = false

var isWindows = startsWith(imageReference.Publisher, 'MicrosoftWindows')
var adSubnetRef = resourceId('Microsoft.Network/virtualNetworks/subnets/', virtualNetworkName, subnetName)
var vmPublicIPName = '${vmName}PublicIP'
var vmNicName = '${vmName}Nic'
var vmDataDisk = '${vmName}-managed-DataDisk1'
var vmOSDisk = '${vmName}-managed-OSDisk'
var vmDataDiskSize = 10

// Cloud-init is stored in repo and embedded at compile time
var cloudInit = base64(loadTextContent('./cloud-init.yml'))


resource vmPublicIP 'Microsoft.Network/publicIPAddresses@2023-04-01' = if (addPublicIp) {
  name: vmPublicIPName
  location: location
  properties: {
    publicIPAllocationMethod: 'Dynamic'
    dnsSettings: {
      domainNameLabel: '${toLower(vmName)}-${uniqueString(resourceGroup().id)}'
    }
  }
}

resource vmNic 'Microsoft.Network/networkInterfaces@2023-04-01' = {
  name: vmNicName
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Static'
          privateIPAddress: vmIpAddress
          subnet: {
            id: adSubnetRef
          }
          publicIPAddress: addPublicIp
            ? {
                id: vmPublicIP.id
              }
            : null
        }
      }
    ]
    networkSecurityGroup: {
      id: resourceId('Microsoft.Network/networkSecurityGroups', NSGName)
    }
  }
}

resource virtualMachine 'Microsoft.Compute/virtualMachines@2023-03-01' = {
  name: vmName
  location: location
  plan: (!empty(imagePlan))
    ? {
        name: imagePlan.name
        publisher: imagePlan.publisher
        product: imagePlan.product
      }
    : null
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    availabilitySet: (!empty(adAvailabilitySetName))
      ? {
          id: resourceId('Microsoft.Compute/availabilitySets', adAvailabilitySetName)
        }
      : null
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      adminPassword: adminPassword
      customData: cloudInit
      windowsConfiguration: (isWindows)
        ? {
            timeZone: vmShutdownTimeTimeZoneId
          }
        : null
    }
    storageProfile: {
      imageReference: imageReference
      osDisk: {
        name: vmOSDisk
        caching: 'ReadWrite'
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: diskType
        }
      }
      dataDisks: [
        {
          name: vmDataDisk
          caching: 'None'
          lun: 0
          diskSizeGB: vmDataDiskSize
          createOption: 'Empty'
          managedDisk: {
            storageAccountType: diskType
          }
        }
      ]
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: vmNic.id
        }
      ]
    }
  }
  tags: {
    '${adminFullUsername}': adminPassword
  }
}

resource autoShutdownConfig 'Microsoft.DevTestLab/schedules@2018-09-15' = {
  name: 'shutdown-computevm-${vmName}'
  location: location
  properties: {
    status: 'Enabled'
    notificationSettings: (vmShutdownEmailRecipient != '')
      ? {
          status: 'Enabled'
          timeInMinutes: 15
          notificationLocale: 'en'
          emailRecipient: vmShutdownEmailRecipient
        }
      : null
    dailyRecurrence: {
      time: vmShutdownTime
    }
    timeZoneId: vmShutdownTimeTimeZoneId
    taskType: 'ComputeVmShutdownTask'
    targetResourceId: virtualMachine.id
  }
}

// https://stackoverflow.com/questions/61985840/arm-template-with-dsc-extension-fails-with-security-error-after-reboot-during-cr
resource setWindowsAzureGuestAgent 'Microsoft.Compute/virtualMachines/runCommands@2023-03-01' = if (waitOnDNS) {
  name: 'setWindowsAzureGuestAgent'
  location: location
  parent: virtualMachine
  properties: {
    asyncExecution: false
    source: {
      script: 'Set-ItemProperty -Path "HKLM:\\SYSTEM\\CurrentControlSet\\Services\\WindowsAzureGuestAgent" -Name DependOnService -Type MultiString -Value DNS'
    }
    timeoutInSeconds: 30
  }
}

resource ApplyConfigPackage 'Microsoft.Compute/virtualMachines/extensions@2021-04-01' = if (isWindows) {
  parent: virtualMachine
  name: 'ApplyConfigPackage'
  location: location
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'CustomScriptExtension'
    typeHandlerVersion: '1.7'
    autoUpgradeMinorVersion: true
    settings: {
      commandToExecute: 'powershell.exe -Command "Set-DnsClientServerAddress \'Ether*\' -ServerAddresses (\'168.63.129.16\'); Clear-DnsClientCache; if (!(Test-Path -PathType Container -Path c:\\tools\\labsetup)) { New-Item -Path C:\\Tools\\labsetup -ItemType Directory }; Get-DnsClientServerAddress | Out-File c:\\Tools\\labsetup\\setup.log -encoding default; [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -UseBasicParsing -Uri https://aka.ms/SecPracASDefendLab -OutFile c:\\tools\\labsetup\\setup.zip; if (Test-Path -PathType Leaf -Path c:\\tools\\labsetup\\setup.zip) { Expand-Archive -Path C:\\Tools\\labsetup\\setup.zip -DestinationPath C:\\Tools\\labsetup -Force; if (Test-Path -PathType Leaf -Path c:\\tools\\labsetup\\invoke-setup.ps1) { & c:\\tools\\labsetup\\invoke-setup.ps1 } } else { exit 1 }"'
    }
  }
}
