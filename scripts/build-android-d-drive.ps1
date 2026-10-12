param(
    [string]$BuildCache = 'D:\parkguard-build-cache',
    [ValidateSet('debug', 'release')]
    [string]$Mode = 'debug',
    [string]$ApiBaseUrl = ''
)

$ErrorActionPreference = 'Stop'
$resolvedCache = [System.IO.Path]::GetFullPath($BuildCache)
if (-not $resolvedCache.StartsWith('D:\', [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "BuildCache must be on D:. Received: $resolvedCache"
}

$gradleCache = Join-Path $resolvedCache 'gradle'
$tempCache = Join-Path $resolvedCache 'temp'
$pubCache = Join-Path (Split-Path $resolvedCache -Parent) 'parkguard-pub-cache'
New-Item -ItemType Directory -Force -Path $gradleCache, $tempCache, $pubCache | Out-Null

$env:GRADLE_USER_HOME = $gradleCache
$env:TEMP = $tempCache
$env:TMP = $tempCache
$env:PUB_CACHE = $pubCache
$javaTemp = $tempCache.Replace('\', '/')
$env:JAVA_TOOL_OPTIONS = "-Djava.io.tmpdir=$javaTemp"

$buildArgs = @('build', 'apk', "--$Mode", '--no-pub')
if ($ApiBaseUrl) { $buildArgs += "--dart-define=API_BASE_URL=$ApiBaseUrl" }
flutter @buildArgs
if ($LASTEXITCODE -ne 0) { throw 'Flutter build failed.' }
