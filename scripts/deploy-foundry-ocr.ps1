param([string]$ImageTag = 'gpt41-mini-ocr-20261012')
$ErrorActionPreference = 'Stop'
function Invoke-AzChecked {
    & az @args
    if ($LASTEXITCODE -ne 0) { throw 'Azure CLI operation failed.' }
}

# Existing resources only. Keep unrelated deployments and app settings intact.
Invoke-AzChecked acr build --registry pgai617db570 --image "parkguard-api:$ImageTag" --file backend/Dockerfile backend --no-logs --output none
$foundryKey = & az cognitiveservices account keys list -g guardian-ai-rg -n guardian-ai-openai-617db5 --query key1 -o tsv
if ($LASTEXITCODE -ne 0 -or -not $foundryKey) { throw 'Cannot obtain Foundry credential.' }
try {
    Invoke-AzChecked containerapp secret set -g rg-parkguard-centralindia -n parkguard-api --secrets "gpt41-mini-key=$foundryKey" --output none
} finally {
    $foundryKey = $null
}
Invoke-AzChecked containerapp update -g rg-parkguard-centralindia -n parkguard-api --image "pgai617db570.azurecr.io/parkguard-api:$ImageTag" --set-env-vars 'FOUNDRY_ENDPOINT=https://guardian-ai-openai-617db5.openai.azure.com' 'FOUNDRY_MODEL=guardian-vision' 'FOUNDRY_API_KEY=secretref:gpt41-mini-key' --output none
Write-Output 'ParkGuard GPT-4.1 mini OCR revision deployed.'
