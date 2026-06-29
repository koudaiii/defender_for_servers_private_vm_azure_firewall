// Log Analytics ワークスペース（Azure Firewall の診断ログ送信先）

@description('Azure リージョン')
param location string

@description('リソース名のプレフィックス')
param namePrefix string

@description('ログ保持日数')
param retentionInDays int = 30

resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${namePrefix}-law'
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: retentionInDays
  }
}

output workspaceId string = law.id
output workspaceName string = law.name
