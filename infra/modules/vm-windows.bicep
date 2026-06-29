// 検証用 Windows VM（Windows Server 2025 Azure Edition / Private IP のみ / Trusted Launch / AMA）
//   - Defender for Servers 対応 OS（Windows Server 2025）
//   - MDE は Defender for Servers プランの自動プロビジョニングで導入されるため拡張機能は配置しない

@description('Azure リージョン')
param location string

@description('リソース名のプレフィックス')
param namePrefix string

@description('VM を配置するワークロード Subnet のリソース ID')
param workloadSubnetId string

@description('管理者ユーザー名')
param adminUsername string = 'azureuser'

@description('管理者パスワード（12〜123 文字・複雑性要件あり）')
@secure()
param adminPassword string

@description('VM サイズ')
param vmSize string = 'Standard_D2s_v3'

@description('AMA 拡張機能を導入するか')
param deployAzureMonitorAgent bool = true

var nicName = '${namePrefix}-win-nic'
var vmName = '${namePrefix}-win'
// Windows の computerName は 15 文字以内
var computerName = take(replace('${namePrefix}win', '-', ''), 15)

resource nic 'Microsoft.Network/networkInterfaces@2023-11-01' = {
  name: nicName
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: workloadSubnetId
          }
          privateIPAllocationMethod: 'Dynamic'
          // Public IP は割り当てない（Private IP のみ）
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: vmName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: computerName
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        provisionVMAgent: true
        enableAutomaticUpdates: true
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2025-datacenter-azure-edition' // Gen2 / Azure Edition
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
      }
    }
    // Trusted Launch（Gen2 + Secure Boot + vTPM）
    securityProfile: {
      securityType: 'TrustedLaunch'
      uefiSettings: {
        secureBootEnabled: true
        vTpmEnabled: true
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
        }
      ]
    }
  }
}

resource ama 'Microsoft.Compute/virtualMachines/extensions@2023-09-01' = if (deployAzureMonitorAgent) {
  parent: vm
  name: 'AzureMonitorWindowsAgent'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.Monitor'
    type: 'AzureMonitorWindowsAgent'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
    enableAutomaticUpgrade: true
  }
}

output vmId string = vm.id
output vmName string = vm.name
output vmPrincipalId string = vm.identity.principalId
