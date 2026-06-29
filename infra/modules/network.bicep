// ネットワーク基盤: VNet / Subnet / NSG / Route Table（空）
// Route Table は空で作成し、Firewall 作成後に route モジュールでデフォルトルートを追加する
// （Firewall の Private IP に依存させるための順序制御）

@description('Azure リージョン')
param location string

@description('リソース名のプレフィックス')
param namePrefix string

@description('VNet アドレス空間')
param vnetAddressPrefix string = '192.168.130.0/25'

@description('AzureFirewallSubnet のアドレス範囲（最小 /26、名前は固定）')
param firewallSubnetPrefix string = '192.168.130.0/26'

@description('ワークロード（VM）Subnet のアドレス範囲')
param workloadSubnetPrefix string = '192.168.130.64/26'

var vnetName = '${namePrefix}-vnet'
var routeTableName = '${namePrefix}-rt'
var nsgName = '${namePrefix}-workload-nsg'

// ワークロード Subnet 用 NSG（インターネットからの受信を明示的に拒否）
resource nsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: nsgName
  location: location
  properties: {
    securityRules: [
      {
        name: 'Deny-Internet-Inbound'
        properties: {
          priority: 4096
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

// デフォルトルート（0.0.0.0/0 -> Firewall）は route モジュールで後付けする
resource routeTable 'Microsoft.Network/routeTables@2023-11-01' = {
  name: routeTableName
  location: location
  properties: {
    disableBgpRoutePropagation: true
    routes: []
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    subnets: [
      {
        // 名前は 'AzureFirewallSubnet' 固定（Azure Firewall の要件）
        name: 'AzureFirewallSubnet'
        properties: {
          addressPrefix: firewallSubnetPrefix
        }
      }
      {
        name: 'workload'
        properties: {
          addressPrefix: workloadSubnetPrefix
          routeTable: {
            id: routeTable.id
          }
          networkSecurityGroup: {
            id: nsg.id
          }
          // 既定の送信アクセスを無効化し、すべての egress を Firewall 経由に強制
          defaultOutboundAccess: false
        }
      }
    ]
  }
}

output vnetId string = vnet.id
output firewallSubnetId string = vnet.properties.subnets[0].id
output workloadSubnetId string = vnet.properties.subnets[1].id
output routeTableName string = routeTable.name
