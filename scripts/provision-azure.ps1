param(
  [Parameter(Mandatory = $true)] [string] $ResourceGroup,
  [Parameter(Mandatory = $true)] [string] $Location,
  [Parameter(Mandatory = $true)] [string] $StorageAccountName,
  [Parameter(Mandatory = $true)] [string] $RegistryName,
  [Parameter(Mandatory = $true)] [string] $PostgresServerName,
  [Parameter(Mandatory = $true)] [string] $PostgresAdmin,
  [Parameter(Mandatory = $true)] [securestring] $PostgresPassword
)

$ErrorActionPreference = 'Stop'
$plainPassword = [System.Net.NetworkCredential]::new('', $PostgresPassword).Password
az account show --output none
az group create --name $ResourceGroup --location $Location --output none
az storage account create --resource-group $ResourceGroup --name $StorageAccountName --location $Location --sku Standard_LRS --https-only true --allow-blob-public-access false --output none
az storage container create --account-name $StorageAccountName --name violation-evidence --auth-mode login --output none
az acr create --resource-group $ResourceGroup --name $RegistryName --sku Basic --admin-enabled false --output none
az postgres flexible-server create --resource-group $ResourceGroup --name $PostgresServerName --location $Location --admin-user $PostgresAdmin --admin-password $plainPassword --sku-name Standard_B1ms --tier Burstable --storage-size 32 --version 16 --public-access none --output none
az postgres flexible-server db create --resource-group $ResourceGroup --server-name $PostgresServerName --name parkingviolations --output none
az keyvault create --resource-group $ResourceGroup --name "$($RegistryName)kv" --location $Location --enable-rbac-authorization true --output none
Write-Host 'Azure foundation created. Next: deploy the API image, managed identity, private networking, Azure AI Vision, and GPU workers.' -ForegroundColor Green
