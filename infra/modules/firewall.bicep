// Azure Firewall + Firewall Policy + ルールコレクション
//   - Network Rule（Service Tag に統一）:
//       AzureMonitor / AzureResourceManager / AzureActiveDirectory（AMA / ARM / Entra ID）
//       MicrosoftDefenderForEndpoint / OneDsCollector（MDE コア + EDR Cyber data）
//   - Application Rule（Linux のみ・条件付き）:
//       config.edge.skype.com（MDE for Linux の内部構成取得 ECS。Service Tag に無いため FQDN 許可）
//   それ以外の通信は Azure Firewall の既定動作で拒否される（明示的な Deny ルールは不要）。
//
// ★前提: MDE を Service Tag / streamlined 宛先で疎通させるには、Defender ポータル
//   （security.microsoft.com）の詳細設定で「Apply streamlined connectivity settings to
//   devices managed by Intune and Defender for Cloud」を ON にする必要がある。
//
// 参考: https://learn.microsoft.com/defender-endpoint/streamlined-device-connectivity-urls-commercial
//   - OneDsCollector（EDR Cyber data）は MicrosoftDefenderForEndpoint タグに含まれないため両方必要。
//   - config.edge.skype.com は Linux で Required（"skype" はレガシーな名残で Skype とは無関係）。

@description('Azure リージョン')
param location string

@description('リソース名のプレフィックス')
param namePrefix string

@description('AzureFirewallSubnet のリソース ID')
param firewallSubnetId string

@description('ルールの送信元に指定するワークロード Subnet のアドレス範囲')
param workloadSubnetPrefix string

@description('Azure Firewall SKU tier（Standard で Service Tag ベースの Network Rule を利用）')
@allowed([
  'Standard'
  'Premium'
])
param firewallTier string = 'Standard'

@description('Linux VM を含むか（true の場合のみ MDE for Linux 用 Application Rule を追加）')
param deployLinuxVm bool = true

@description('Firewall 診断ログの送信先 Log Analytics ワークスペース ID（空なら診断設定を作らない）')
param logAnalyticsWorkspaceId string = ''

var fwName = '${namePrefix}-afw'
var fwPipName = '${namePrefix}-afw-pip'
var fwPolicyName = '${namePrefix}-afwpolicy'

resource pip 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: fwPipName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource fwPolicy 'Microsoft.Network/firewallPolicies@2023-11-01' = {
  name: fwPolicyName
  location: location
  properties: {
    sku: {
      tier: firewallTier
    }
    threatIntelMode: 'Alert'
  }
}

// Network Rule（コア通信を Service Tag に統一 = FQDN 追従ゼロ）
resource networkRules 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2023-11-01' = {
  parent: fwPolicy
  name: 'DefenderForServers-Network'
  properties: {
    priority: 200
    ruleCollections: [
      {
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'Allow-DefenderForServers-ServiceTags'
        priority: 100
        action: {
          type: 'Allow'
        }
        rules: [
          {
            ruleType: 'NetworkRule'
            name: 'Allow-AzureServiceTags-443'
            ipProtocols: [
              'TCP'
            ]
            sourceAddresses: [
              workloadSubnetPrefix
            ]
            destinationAddresses: [
              'AzureMonitor' // AMA: *.ods.opinsights.azure.com / *.monitor.azure.com
              'AzureResourceManager' // management.azure.com
              'AzureActiveDirectory' // login.microsoftonline.com
              'MicrosoftDefenderForEndpoint' // MDE コア（MAPS / 検体 / C&C / native config）
              'OneDsCollector' // MDE EDR Cyber data（MicrosoftDefenderForEndpoint には含まれない）
            ]
            destinationPorts: [
              '443'
            ]
          }
        ]
      }
    ]
  }
}

// Application Rule（Linux のみ）: MDE for Linux が内部構成を取得する ECS エンドポイント。
// Service Tag に含まれないため FQDN で許可する。Firewall Policy 内の RCG は逐次デプロイ。
resource applicationRules 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2023-11-01' = if (deployLinuxVm) {
  parent: fwPolicy
  name: 'DefenderForServers-Application'
  dependsOn: [
    networkRules
  ]
  properties: {
    priority: 300
    ruleCollections: [
      {
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'Allow-MDE-Linux-Config'
        priority: 110
        action: {
          type: 'Allow'
        }
        rules: [
          {
            ruleType: 'ApplicationRule'
            name: 'Allow-MDE-Linux-ECS-Config'
            protocols: [
              {
                protocolType: 'Https'
                port: 443
              }
            ]
            sourceAddresses: [
              workloadSubnetPrefix
            ]
            targetFqdns: [
              'config.edge.skype.com' // MDE for Linux 内部構成（ECS）。Skype とは無関係のレガシー名
            ]
          }
        ]
      }
    ]
  }
}

resource firewall 'Microsoft.Network/azureFirewalls@2023-11-01' = {
  name: fwName
  location: location
  dependsOn: [
    networkRules
    applicationRules
  ]
  properties: {
    sku: {
      name: 'AZFW_VNet'
      tier: firewallTier
    }
    firewallPolicy: {
      id: fwPolicy.id
    }
    ipConfigurations: [
      {
        name: 'fw-ipconfig'
        properties: {
          subnet: {
            id: firewallSubnetId
          }
          publicIPAddress: {
            id: pip.id
          }
        }
      }
    ]
  }
}

// 診断ログ（構造化 = resource-specific テーブル: AZFWNetworkRule / AZFWApplicationRule 等）。
// logAnalyticsDestinationType: 'Dedicated' で専用テーブルに出力する。
resource firewallDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (!empty(logAnalyticsWorkspaceId)) {
  scope: firewall
  name: 'fw-diagnostics'
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logAnalyticsDestinationType: 'Dedicated'
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

output firewallPrivateIp string = firewall.properties.ipConfigurations[0].properties.privateIPAddress
output firewallName string = firewall.name
