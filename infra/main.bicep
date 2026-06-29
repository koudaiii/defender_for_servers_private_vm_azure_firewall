// Defender for Servers 導入（Private VM + Azure Firewall）一式
//
// デプロイ範囲:
//   - リソースグループ
//   - ネットワーク（VNet / Subnet / NSG / Route Table、既定送信インターネット禁止）
//   - Azure Firewall（Service Tag 主経路 + MDE 用 FQDN）
//   - デフォルトルート（0.0.0.0/0 -> Firewall）
//   - 検証用 VM（Private IP のみ / Trusted Launch / AMA）
//       * Ubuntu 24.04 LTS
//       * Windows Server 2025 Azure Edition
//   - Defender for Servers Plan 2 の有効化（★サブスクリプション全体・課金対象。Portal 設定でも可）
//
// スコープはサブスクリプション（Defender プランがサブスクリプション単位のため）

targetScope = 'subscription'

@description('Azure リージョン')
param location string = 'japaneast'

@description('リソース名のプレフィックス')
param namePrefix string = 'dfs-priv'

@description('作成するリソースグループ名')
param resourceGroupName string = 'rg-defender-priv-vm'

@description('VM 管理者ユーザー名')
param adminUsername string = 'azureuser'

@description('Linux VM の SSH 公開鍵（パスワード認証は無効）')
@secure()
param sshPublicKey string

@description('Windows VM の管理者パスワード（deployWindowsVm=true のとき必須）')
@secure()
param adminPassword string = ''

@description('VM サイズ')
param vmSize string = 'Standard_D2s_v3'

@description('VNet アドレス空間')
param vnetAddressPrefix string = '192.168.130.0/25'

@description('AzureFirewallSubnet のアドレス範囲（最小 /26）')
param firewallSubnetPrefix string = '192.168.130.0/26'

@description('ワークロード Subnet のアドレス範囲')
param workloadSubnetPrefix string = '192.168.130.64/26'

@description('Azure Firewall SKU tier')
@allowed([
  'Standard'
  'Premium'
])
param firewallTier string = 'Standard'

@description('★Defender for Servers Plan 2 をサブスクリプション全体で有効化（課金対象）。Portal で設定する場合は false。')
param enableDefenderForServersPlan bool = true

@description('Ubuntu 24.04 LTS 検証用 VM をデプロイ')
param deployLinuxVm bool = true

@description('Windows Server 2025 Azure Edition 検証用 VM をデプロイ')
param deployWindowsVm bool = true

@description('Firewall 診断ログ（Log Analytics ワークスペース）を有効化')
param enableFirewallDiagnostics bool = true

resource rg 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: resourceGroupName
  location: location
}

module network 'modules/network.bicep' = {
  name: 'network'
  scope: rg
  params: {
    location: location
    namePrefix: namePrefix
    vnetAddressPrefix: vnetAddressPrefix
    firewallSubnetPrefix: firewallSubnetPrefix
    workloadSubnetPrefix: workloadSubnetPrefix
  }
}

// Firewall 診断ログ用の Log Analytics ワークスペース
module monitoring 'modules/monitoring.bicep' = if (enableFirewallDiagnostics) {
  name: 'monitoring'
  scope: rg
  params: {
    location: location
    namePrefix: namePrefix
  }
}

module firewall 'modules/firewall.bicep' = {
  name: 'firewall'
  scope: rg
  params: {
    location: location
    namePrefix: namePrefix
    firewallSubnetId: network.outputs.firewallSubnetId
    workloadSubnetPrefix: workloadSubnetPrefix
    firewallTier: firewallTier
    deployLinuxVm: deployLinuxVm
    logAnalyticsWorkspaceId: enableFirewallDiagnostics ? monitoring!.outputs.workspaceId : ''
  }
}

// Firewall 作成後にデフォルトルートを追加（Firewall Private IP を参照）
module route 'modules/route.bicep' = {
  name: 'route'
  scope: rg
  params: {
    routeTableName: network.outputs.routeTableName
    firewallPrivateIp: firewall.outputs.firewallPrivateIp
  }
}

// VM はルート確定後に作成し、拡張機能インストール時に egress（Firewall 経由）を確保
module vmLinux 'modules/vm-linux.bicep' = if (deployLinuxVm) {
  name: 'vm-linux'
  scope: rg
  dependsOn: [
    route
  ]
  params: {
    location: location
    namePrefix: namePrefix
    workloadSubnetId: network.outputs.workloadSubnetId
    adminUsername: adminUsername
    sshPublicKey: sshPublicKey
    vmSize: vmSize
  }
}

module vmWindows 'modules/vm-windows.bicep' = if (deployWindowsVm) {
  name: 'vm-windows'
  scope: rg
  dependsOn: [
    route
  ]
  params: {
    location: location
    namePrefix: namePrefix
    workloadSubnetId: network.outputs.workloadSubnetId
    adminUsername: adminUsername
    adminPassword: adminPassword
    vmSize: vmSize
  }
}

// --- Defender for Servers Plan 2 の有効化（サブスクリプション単位）---
resource defenderForServers 'Microsoft.Security/pricings@2024-01-01' = if (enableDefenderForServersPlan) {
  name: 'VirtualMachines'
  properties: {
    pricingTier: 'Standard'
    subPlan: 'P2'
  }
}

// --- MDE（Defender for Endpoint）統合の有効化 ---
resource mdeIntegration 'Microsoft.Security/settings@2022-05-01' = if (enableDefenderForServersPlan) {
  name: 'WDATP'
  kind: 'DataExportSettings'
  properties: {
    enabled: true
  }
}

output resourceGroupId string = rg.id
output firewallPrivateIp string = firewall.outputs.firewallPrivateIp
output logAnalyticsWorkspaceName string = enableFirewallDiagnostics ? monitoring!.outputs.workspaceName : ''
output linuxVmName string = deployLinuxVm ? vmLinux!.outputs.vmName : ''
output windowsVmName string = deployWindowsVm ? vmWindows!.outputs.vmName : ''
