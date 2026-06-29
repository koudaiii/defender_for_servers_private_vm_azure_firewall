using './main.bicep'

// 認証情報は環境変数から読み込む（setup スクリプトが自動設定）
//   export SSH_PUBLIC_KEY="$(cat ~/.ssh/dfs_priv_vm.pub)"
//   export WIN_ADMIN_PASSWORD="<複雑性要件を満たすパスワード>"
param sshPublicKey = readEnvironmentVariable('SSH_PUBLIC_KEY', '')
param adminPassword = readEnvironmentVariable('WIN_ADMIN_PASSWORD', '')

param location = 'japaneast'
param namePrefix = 'dfs-priv'
param resourceGroupName = 'rg-defender-priv-vm'
param adminUsername = 'azureuser'
param vmSize = 'Standard_D2s_v3'

param vnetAddressPrefix = '192.168.130.0/25'
param firewallSubnetPrefix = '192.168.130.0/26'
param workloadSubnetPrefix = '192.168.130.64/26'

param firewallTier = 'Standard'

// ★サブスクリプション全体に適用・課金対象。Portal で設定する場合は false。
param enableDefenderForServersPlan = true

// 検証用 VM（Defender for Servers 対応 OS）
param deployLinuxVm = true   // Ubuntu 24.04 LTS
param deployWindowsVm = true // Windows Server 2025 Azure Edition

// Firewall 診断ログ（Log Analytics）
param enableFirewallDiagnostics = true
