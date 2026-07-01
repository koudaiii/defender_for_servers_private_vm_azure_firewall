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
// 参考（Learn）:
//   - MDE streamlined 接続 URL / Service Tag（両タグ必要な根拠）:
//       https://learn.microsoft.com/defender-endpoint/streamlined-device-connectivity-urls-commercial
//   - Azure Monitor Agent のネットワーク要件（AzureMonitor / AzureResourceManager タグ）:
//       https://learn.microsoft.com/azure/azure-monitor/agents/azure-monitor-agent-network-configuration
//   - Azure サービスタグ一覧（各タグが表す宛先の定義元）:
//       https://learn.microsoft.com/azure/virtual-network/service-tags-overview
//   - Defender for Servers のプラン別サポート/要件:
//       https://learn.microsoft.com/azure/defender-for-cloud/support-matrix-defender-for-servers
//   補足:
//   - OneDsCollector（EDR Cyber data）は MicrosoftDefenderForEndpoint タグに含まれないため両方必要。
//   - config.edge.skype.com は Linux で Required（"skype" はレガシーな名残で Skype とは無関係）。
//
//   従来方式の宛先（下記）
//     - MDE コア:      winatp-gw-<region>.microsoft.com（C&C）, 検体 blob（ussus*/wsus*…blob.core.windows.net）,
//                      AutoIR（automatedirstrprd*.blob.core.windows.net）, events.data.microsoft.com
//     - EDR Cyber data: <region>.vortex-win.data.microsoft.com, <region>-v20.events.data.microsoft.com
//     - MAPS(AV):       *.wdcp.microsoft.com / *.wd.microsoft.com / *.wdcpalt.microsoft.com
//     - 定義/製品更新:  go.microsoft.com / definitionupdates.microsoft.com / *.update.microsoft.com ほか
//     - 証明書検証(CRL): crl.microsoft.com / ctldl.windowsupdate.com / www.microsoft.com/pki*（port 80 も必要）
//   Learn（従来方式の URL 一覧）: https://learn.microsoft.com/defender-endpoint/standard-device-connectivity-urls-commercial

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
              // AMA: global/<region>.handler.control.monitor.azure.com（DCR 取得）,
              //      <workspaceId>.ods.opinsights.azure.com（ログ取込）, ※メトリック送信時のみ <region>.monitoring.azure.com
              // Learn: https://learn.microsoft.com/azure/azure-monitor/agents/azure-monitor-agent-network-configuration
              'AzureMonitor'
              // ARM 制御プレーン: management.azure.com（AMA も必須）
              // Learn: https://learn.microsoft.com/azure/azure-monitor/agents/azure-monitor-agent-network-configuration
              'AzureResourceManager'
              // Entra ID 認証: login.microsoftonline.com
              // Learn: https://learn.microsoft.com/azure/virtual-network/service-tags-overview
              'AzureActiveDirectory'
              // MDE コア（streamlined 集約 URL: *.endpoint.security.microsoft.com。MAPS / 検体 / C&C / native config）
              // Learn: https://learn.microsoft.com/defender-endpoint/streamlined-device-connectivity-urls-commercial
              'MicrosoftDefenderForEndpoint'
              // MDE EDR Cyber data（OneDsCollector。MicrosoftDefenderForEndpoint タグには含まれないため別途必須）
              // Learn: https://learn.microsoft.com/defender-endpoint/streamlined-device-connectivity-urls-commercial
              'OneDsCollector'
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
              // MDE for Linux 内部構成（ECS）。実際のパスは https://config.edge.skype.com/config/v1。
              // Service Tag に無いため FQDN 許可。"skype" は Skype とは無関係のレガシー名。
              // Learn: https://learn.microsoft.com/defender-endpoint/streamlined-device-connectivity-urls-commercial
              'config.edge.skype.com'
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
