// デフォルトルート（0.0.0.0/0 -> Azure Firewall Private IP）を Route Table に追加する。
// Firewall 作成後に呼び出すことで、動的に払い出される Firewall Private IP を参照できる。

@description('既存 Route Table のリソース名')
param routeTableName string

@description('Azure Firewall の Private IP アドレス')
param firewallPrivateIp string

resource routeTable 'Microsoft.Network/routeTables@2023-11-01' existing = {
  name: routeTableName
}

resource defaultRoute 'Microsoft.Network/routeTables/routes@2023-11-01' = {
  parent: routeTable
  name: 'to-internet-via-firewall'
  properties: {
    addressPrefix: '0.0.0.0/0'
    nextHopType: 'VirtualAppliance'
    nextHopIpAddress: firewallPrivateIp
  }
}
