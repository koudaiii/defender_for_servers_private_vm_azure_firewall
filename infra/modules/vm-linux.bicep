// 検証用 Linux VM（Ubuntu 24.04 LTS / Private IP のみ / Trusted Launch / AMA）
//   - Defender for Servers 対応 OS（MDE for Linux supported versions に Ubuntu 24.04 を含む）
//   - MDE は Defender for Servers プランの自動プロビジョニングで導入されるため拡張機能は配置しない

@description('Azure リージョン')
param location string

@description('リソース名のプレフィックス')
param namePrefix string

@description('VM を配置するワークロード Subnet のリソース ID')
param workloadSubnetId string

@description('管理者ユーザー名')
param adminUsername string = 'azureuser'

@description('SSH 公開鍵（パスワード認証は無効）')
@secure()
param sshPublicKey string

@description('VM サイズ')
param vmSize string = 'Standard_D2s_v3'

@description('AMA 拡張機能を導入するか')
param deployAzureMonitorAgent bool = true

var nicName = '${namePrefix}-linux-nic'
var vmName = '${namePrefix}-linux'

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
      computerName: vmName
      adminUsername: adminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: sshPublicKey
            }
          ]
        }
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: 'ubuntu-24_04-lts'
        sku: 'server' // Gen2
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
  name: 'AzureMonitorLinuxAgent'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.Monitor'
    type: 'AzureMonitorLinuxAgent'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
    enableAutomaticUpgrade: true
  }
}

output vmId string = vm.id
output vmName string = vm.name
output vmPrincipalId string = vm.identity.principalId
