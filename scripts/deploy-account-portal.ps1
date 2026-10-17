param(
    [Parameter(Mandatory=$true)][string]$AdminEmail,
    [Parameter(Mandatory=$true)][SecureString]$AdminPassword,
    [Parameter(Mandatory=$true)][string]$FcmCredentialFile,
    [string]$ImageTag='accounts-20261017-v2',
    [switch]$SkipBuild
)
$ErrorActionPreference='Stop'
$azurePython=Join-Path (Split-Path (Get-Command az).Source -Parent) '..\python.exe'
$backendPython=Join-Path $PSScriptRoot '..\backend\.venv\Scripts\python.exe'
function Invoke-AzChecked {
    & $azurePython -IBm azure.cli @args
    if($LASTEXITCODE -ne 0){throw 'Azure operation failed'}
}
if(-not $SkipBuild){
    Invoke-AzChecked acr build --registry pgai617db570 --image "parkguard-api:$ImageTag" --file backend/Dockerfile backend --no-logs --output none
}
$handle=[IntPtr]::Zero
try {
    $handle=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($AdminPassword)
    $plain=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($handle)
    $hash=$plain | & $backendPython -c "import sys; sys.path.insert(0,'backend'); from account_portal import hash_password; print(hash_password(sys.stdin.read().rstrip(chr(10)+chr(13))))"
    if($LASTEXITCODE -ne 0){throw 'Could not hash administrator password'}
    $fcm=Get-Content -LiteralPath $FcmCredentialFile -Raw | ConvertFrom-Json
    if($fcm.project_id -ne 'guardian-ai-617db5'){throw 'Unexpected Firebase project'}
    $fcmJson=$fcm | ConvertTo-Json -Compress -Depth 10
    $fcmEncoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($fcmJson))
    Invoke-AzChecked containerapp secret set -g rg-parkguard-centralindia -n parkguard-api --secrets "portal-admin-hash=$hash" "portal-fcm-account=$fcmEncoded" --output none
    Invoke-AzChecked containerapp update -g rg-parkguard-centralindia -n parkguard-api --image "pgai617db570.azurecr.io/parkguard-api:$ImageTag" --min-replicas 1 --set-env-vars "BOOTSTRAP_ADMIN_EMAIL=$AdminEmail" 'BOOTSTRAP_ADMIN_HASH=secretref:portal-admin-hash' 'FCM_SERVICE_ACCOUNT_BASE64=secretref:portal-fcm-account' --remove-env-vars FCM_SERVICE_ACCOUNT_JSON --output none
    Write-Output 'Account portal deployed; administrator bootstrap and FCM are configured.'
} finally {
    $plain=$null; $hash=$null; $fcm=$null; $fcmJson=$null; $fcmEncoded=$null
    if($handle -ne [IntPtr]::Zero){[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($handle)}
}
