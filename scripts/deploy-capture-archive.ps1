param([string]$ImageTag = 'motion-archive-20261012-v2', [switch]$SkipBuild)
$ErrorActionPreference = 'Stop'
$azureCliPython = Join-Path (Split-Path (Get-Command az).Source -Parent) '..\python.exe'
if (-not (Test-Path -LiteralPath $azureCliPython)) { throw 'Azure CLI Python runtime not found.' }
function Invoke-AzChecked {
    # Bypass az.cmd: its %* re-parses SAS ampersands as shell separators.
    & $azureCliPython -IBm azure.cli @args
    if ($LASTEXITCODE -ne 0) { throw 'Azure CLI operation failed.' }
}

if (-not $SkipBuild) {
    Invoke-AzChecked acr build --registry pgai617db570 --image "parkguard-api:$ImageTag" --file backend/Dockerfile backend --no-logs --output none
}
$archiveKey = & $azureCliPython -IBm azure.cli storage account keys list -g rg-parkguard-centralindia -n pgai617db570 --query '[0].value' -o tsv
if ($LASTEXITCODE -ne 0 -or -not $archiveKey) { throw 'Cannot obtain storage credential.' }
try {
    Invoke-AzChecked storage container create --account-name pgai617db570 --account-key $archiveKey --name plate-snapshots --public-access off --output none
    $archiveExpiry = [DateTime]::UtcNow.AddDays(90).ToString('yyyy-MM-ddTHH:mmZ')
    # Read/create only, scoped to this private container; no overwrite/delete/list.
    $archiveSas = & $azureCliPython -IBm azure.cli storage container generate-sas --account-name pgai617db570 --account-key $archiveKey --name plate-snapshots --permissions rc --https-only --expiry $archiveExpiry -o tsv
    if ($LASTEXITCODE -ne 0 -or -not $archiveSas) { throw 'Cannot create scoped storage credential.' }
    Invoke-AzChecked containerapp secret set -g rg-parkguard-centralindia -n parkguard-api --secrets "capture-storage-sas=$archiveSas" --output none
} finally {
    $archiveKey = $null
    $archiveSas = $null
}
Invoke-AzChecked containerapp update -g rg-parkguard-centralindia -n parkguard-api --image "pgai617db570.azurecr.io/parkguard-api:$ImageTag" --set-env-vars 'CAPTURE_STORAGE_URL=https://pgai617db570.blob.core.windows.net' 'CAPTURE_STORAGE_SAS=secretref:capture-storage-sas' --output none
Write-Output "Private capture archive deployed. Renew scoped credential before $archiveExpiry by rerunning this script."
