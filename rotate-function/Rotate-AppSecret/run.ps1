param($Timer)

# ------------------------
# Logging helpers (JSONL)
# ------------------------
$runId = [guid]::NewGuid().ToString()
$scriptStart = Get-Date

function Write-Log {
  param(
    [ValidateSet("INFO","WARN","ERROR")][string]$Level,
    [string]$Step,
    [string]$Message,
    [hashtable]$Data = @{}
  )

  $payload = @{
    ts    = (Get-Date).ToString("o")
    level = $Level
    runId = $runId
    step  = $Step
    msg   = $Message
  } + $Data

  $line = $payload | ConvertTo-Json -Compress
  if ($Level -eq "ERROR") { Write-Host ("ERROR: " + $line) }
  elseif ($Level -eq "WARN") { Write-Warning $line }
  else { Write-Host ("INFORMATION: " + $line) }
}

function Step-Time {
  param([string]$StepName, [scriptblock]$Block)

  $t0 = Get-Date
  Write-Log -Level "INFO" -Step $StepName -Message "START"

  try {
    $result = & $Block
    $ms = [int]((Get-Date) - $t0).TotalMilliseconds

    Write-Log -Level "INFO" -Step $StepName -Message "END" -Data @{ durationMs = $ms }

    return $result
  }
  catch {
    $ms = [int]((Get-Date) - $t0).TotalMilliseconds

    Write-Log -Level "ERROR" -Step $StepName -Message "FAILED" -Data @{
      durationMs = $ms
      error      = $_.Exception.Message
    }

    throw
  }
}

# ------------------------
# Resolve wwwroot + Modules root ONCE (scope-safe)
# ------------------------
$wwwroot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

# Prefer "Modules" but fallback to "modules" (Linux case-sensitive)
$modulesRoot = Join-Path $wwwroot "Modules"
if (-not (Test-Path $modulesRoot)) {
  $modulesRootLower = Join-Path $wwwroot "modules"
  if (Test-Path $modulesRootLower) {
    $modulesRoot = $modulesRootLower
  }
}

Write-Log -Level "INFO" -Step "paths" -Message "Resolved runtime paths" -Data @{
  PSScriptRoot = $PSScriptRoot
  wwwroot      = $wwwroot
  modulesRoot  = $modulesRoot
  modulesExist = (Test-Path $modulesRoot)
}

# Optional: lightweight dir listing for future troubleshooting
try {
  $rootItems = (Get-ChildItem -Path $wwwroot -ErrorAction Stop | Select-Object -ExpandProperty Name)
  Write-Log -Level "INFO" -Step "paths" -Message "wwwroot items" -Data @{ items = $rootItems }
} catch {
  Write-Log -Level "WARN" -Step "paths" -Message "Failed listing wwwroot" -Data @{ error = $_.Exception.Message }
}

# ------------------------
# Settings
# ------------------------
$TargetAppId           = $env:TARGET_APPID
$KeyVaultName          = $env:KEYVAULT_NAME
$KvSecretName          = $env:KV_SECRET_NAME
$RotateDaysBefore      = [int]$env:ROTATE_DAYS_BEFORE
$NewSecretLifetimeDays = [int]$env:NEW_SECRET_LIFETIME_DAYS
$AutomationPrefix      = $env:AUTOMATION_PREFIX
$ManagedBy             = $env:MANAGED_BY

$now = Get-Date
$bufferDays = 2
$minGoodEnd = $now.AddDays($RotateDaysBefore + $bufferDays)

Write-Log -Level "INFO" -Step "init" -Message "Rotate started" -Data @{
  targetAppId           = $TargetAppId
  keyVault              = $KeyVaultName
  kvSecretName          = $KvSecretName
  rotateDaysBefore      = $RotateDaysBefore
  newSecretLifetimeDays = $NewSecretLifetimeDays
  bufferDays            = $bufferDays
  minGoodEnd            = $minGoodEnd.ToString("o")
  prefix                = $AutomationPrefix
  managedBy             = $ManagedBy
}

# ------------------------
# Modules load
# ------------------------
Step-Time "modules.resolve" {
  Write-Log -Level "INFO" -Step "modules.resolve" -Message "ModulesRoot resolved" -Data @{ modulesRoot = $modulesRoot }

  if (-not (Test-Path $modulesRoot)) {
    Write-Log -Level "ERROR" -Step "modules.resolve" -Message "Modules folder missing in deployment" -Data @{ wwwroot = $wwwroot }
    Get-ChildItem $wwwroot | Select-Object Name | ForEach-Object {
      Write-Log -Level "INFO" -Step "modules.resolve" -Message "wwwroot item" -Data @{ name = $_.Name }
    }
    throw "Modules folder missing in deployment."
  }

  $env:PSModulePath = "$modulesRoot;$env:PSModulePath"
  Write-Log -Level "INFO" -Step "modules.resolve" -Message "PSModulePath updated" -Data @{ psModulePath = $env:PSModulePath }

  # Extra: confirm module folders exist (helps when publish misses content)
  $expected = @(
    "Microsoft.Graph.Authentication",
    "Microsoft.Graph.Applications",
    "Az.Accounts",
    "Az.KeyVault"
  )
  foreach ($m in $expected) {
    $p = Join-Path $modulesRoot $m
    Write-Log -Level "INFO" -Step "modules.resolve" -Message "Module folder check" -Data @{
      module = $m
      path   = $p
      exists = (Test-Path $p)
    }
  }
}

Step-Time "modules.import" {
  # NOTE: Keep imports exactly like the known-working approach
  Import-Module "$modulesRoot/Microsoft.Graph.Authentication" -ErrorAction Stop
  Import-Module "$modulesRoot/Microsoft.Graph.Applications"   -ErrorAction Stop
  Import-Module "$modulesRoot/Az.Accounts"                    -ErrorAction Stop
  Import-Module "$modulesRoot/Az.KeyVault"                    -ErrorAction Stop

  Write-Log -Level "INFO" -Step "modules.import" -Message "Modules imported successfully" -Data @{ }
}

# ------------------------
# Auth
# ------------------------
Step-Time "auth.graph" {
  Disconnect-MgGraph -ErrorAction SilentlyContinue
  Connect-MgGraph -Identity | Out-Null

  $ctx = Get-MgContext
  Write-Log -Level "INFO" -Step "auth.graph" -Message "Graph context" -Data @{
    tenantId = $ctx.TenantId
    clientId = $ctx.ClientId
    authType = $ctx.AuthType
  }

  Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/applications?`$top=1" | Out-Null
  Write-Log -Level "INFO" -Step "auth.graph" -Message "Graph test OK: can read applications" -Data @{ }
}

Step-Time "auth.azure" {
  Connect-AzAccount -Identity | Out-Null
  Write-Log -Level "INFO" -Step "auth.azure" -Message "Connected to Azure with Managed Identity" -Data @{ }
}

# ------------------------
# Get target app (return-safe)
# ------------------------
$app = Step-Time "graph.getApp" {

  Write-Log -Level "INFO" -Step "graph.getApp" -Message "Looking up application by appId" -Data @{ targetAppId = $TargetAppId }

  $result = Get-MgApplication -Filter "appId eq '$TargetAppId'" -ConsistencyLevel eventual -CountVariable c | Select-Object -First 1

  if (-not $result) {
    Write-Log -Level "ERROR" -Step "graph.getApp" -Message "Application not found" -Data @{ targetAppId = $TargetAppId }
    throw "Application with appId '$TargetAppId' not found."
  }

  Write-Log -Level "INFO" -Step "graph.getApp" -Message "Application found" -Data @{
    appObjectId = $result.Id
    appId       = $result.AppId
    displayName = $result.DisplayName
  }

  return $result
}

if (-not $app -or -not $app.Id) {
  Write-Log -Level "ERROR" -Step "graph.getApp" -Message "Application object not available after lookup" -Data @{ }
  throw "Application object not available."
}

# ------------------------
# Key Vault: read active keyId (RETURN-SAFE)
# ------------------------
$activeKeyId = Step-Time "kv.readActive" {
  try {
    $kvCurrent = Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name $KvSecretName -ErrorAction Stop
    $tags = $kvCurrent.Tags
    $kid = $null

    if ($tags -and $tags.ContainsKey("keyId")) {
      $kid = $tags["keyId"]
    }

    Write-Log -Level "INFO" -Step "kv.readActive" -Message "Key Vault secret read" -Data @{
      kvSecretName = $KvSecretName
      activeKeyId  = $kid
      hasTags      = [bool]$tags
      tagsKeys     = @($tags.Keys)
    }

    return $kid
  }
  catch {
    Write-Log -Level "WARN" -Step "kv.readActive" -Message "Key Vault secret not found (bootstrap scenario)" -Data @{
      kvSecretName = $KvSecretName
      error        = $_.Exception.Message
    }
    return $null
  }
}

# ------------------------
# Read Graph credentials (RETURN-SAFE)
# ------------------------
$creds = Step-Time "graph.readCreds" {
  $localCreds = $app.PasswordCredentials
  $count = if ($localCreds) { $localCreds.Count } else { 0 }

  $soonest = $null
  if ($count -gt 0) { $soonest = $localCreds | Sort-Object EndDateTime | Select-Object -First 1 }

  Write-Log -Level "INFO" -Step "graph.readCreds" -Message "Read passwordCredentials" -Data @{
    credsCount    = $count
    soonestKeyId  = if ($soonest) { "$($soonest.KeyId)" } else { $null }
    soonestEnd    = if ($soonest) { "$($soonest.EndDateTime)" } else { $null }
  }

  return $localCreds
}

if (-not $creds) { $creds = @() }

# Extra diagnostic (helps when logs show count but decision sees empty)
Write-Log -Level "INFO" -Step "diag.state" -Message "State after reads" -Data @{
  activeKeyId = $activeKeyId
  credsCount  = $creds.Count
}

# ------------------------
# Helper: Create new secret + store in KV
# ------------------------
function New-AppSecretAndStoreInKV {
  param(
    [string]$ApplicationObjectId,
    [string]$KeyVaultName,
    [string]$KvSecretName,
    [datetime]$EndDate,
    [string]$DisplayName,
    [string]$ManagedBy
  )

  if ([string]::IsNullOrWhiteSpace($ApplicationObjectId)) {
    Write-Log -Level "ERROR" -Step "rotate.createSecret" -Message "ApplicationObjectId is empty - refusing to continue" -Data @{ }
    throw "ApplicationObjectId is empty."
  }

  Write-Log -Level "INFO" -Step "rotate.createSecret" -Message "Creating new app secret" -Data @{
    displayName = $DisplayName
    endDateTime = $EndDate.ToString("o")
  }

  $body = @{
    passwordCredential = @{
      displayName = $DisplayName
      endDateTime = $EndDate.ToString("o")
    }
  }

  $newSecret = Add-MgApplicationPassword -ApplicationId $ApplicationObjectId -BodyParameter $body

  if (-not $newSecret.SecretText) {
    Write-Log -Level "ERROR" -Step "rotate.createSecret" -Message "SecretText not returned by Graph" -Data @{
      newKeyId = "$($newSecret.KeyId)"
    }
    throw "SecretText not returned; cannot store in Key Vault."
  }

  Write-Log -Level "INFO" -Step "rotate.createSecret" -Message "Secret created" -Data @{
    newKeyId = "$($newSecret.KeyId)"
  }

  $tags = @{
    keyId       = "$($newSecret.KeyId)"
    endDateTime = "$($EndDate.ToString('o'))"
    managedBy   = $ManagedBy
    purpose     = "clientSecret"
  }

  Write-Log -Level "INFO" -Step "kv.write" -Message "Writing new secret version to Key Vault" -Data @{
    kvSecretName = $KvSecretName
    tags         = $tags
  }

  Set-AzKeyVaultSecret -VaultName $KeyVaultName -Name $KvSecretName `
    -SecretValue (ConvertTo-SecureString $newSecret.SecretText -AsPlainText -Force) `
    -Tag $tags | Out-Null

  Write-Log -Level "INFO" -Step "kv.write" -Message "Key Vault updated" -Data @{
    kvSecretName = $KvSecretName
    activeKeyId  = "$($newSecret.KeyId)"
    endDateTime  = "$($EndDate.ToString('o'))"
  }
}

# ------------------------
# Decision tree (FIXED)
# ------------------------

# 1) If Graph has no creds at all => bootstrap
if ($creds.Count -eq 0) {
  Write-Log -Level "WARN" -Step "rotate.decision" -Message "No passwordCredentials found in Graph; bootstrapping first secret" -Data @{ }

  $newEnd = $now.AddDays($NewSecretLifetimeDays)
  $name = "$AutomationPrefix bootstrap $($now.ToString('yyyy-MM-dd'))"

  Step-Time "rotate.bootstrap" {
    New-AppSecretAndStoreInKV -ApplicationObjectId $app.Id -KeyVaultName $KeyVaultName -KvSecretName $KvSecretName `
      -EndDate $newEnd -DisplayName $name -ManagedBy $ManagedBy
  }

  Write-Log -Level "INFO" -Step "rotate.end" -Message "Rotate finished (bootstrap)" -Data @{
    totalMs = [int]((Get-Date) - $scriptStart).TotalMilliseconds
  }
  return
}

# 2) If KV has activeKeyId, validate it in Graph and enforce no-op if healthy
if ($activeKeyId) {

  $activeCred = $creds | Where-Object { "$($_.KeyId)" -eq "$activeKeyId" } | Select-Object -First 1

  if ($activeCred) {
    $activeEnd = [datetime]$activeCred.EndDateTime
    $daysLeft = [int](($activeEnd - $now).TotalDays)

    Write-Log -Level "INFO" -Step "rotate.decision" -Message "KV activeKeyId found in Graph" -Data @{
      activeKeyId = $activeKeyId
      activeEnd   = "$($activeCred.EndDateTime)"
      daysLeft    = $daysLeft
      minGoodEnd  = $minGoodEnd.ToString("o")
    }

    # ✅ Your requirement: if active secret is valid beyond threshold => NO-OP
    if ($activeEnd -gt $minGoodEnd) {
      Write-Log -Level "INFO" -Step "rotate.decision" -Message "Active secret valid beyond threshold; no rotation needed" -Data @{ }
      Write-Log -Level "INFO" -Step "rotate.end" -Message "Rotate finished (no-op)" -Data @{
        totalMs = [int]((Get-Date) - $scriptStart).TotalMilliseconds
      }
      return
    }

    Write-Log -Level "WARN" -Step "rotate.decision" -Message "Active secret nearing expiry; rotation will proceed" -Data @{
      daysLeft         = $daysLeft
      rotateDaysBefore = $RotateDaysBefore
    }
  }
  else {
    Write-Log -Level "WARN" -Step "rotate.decision" -Message "KV activeKeyId not found in Graph; rotation will proceed" -Data @{
      activeKeyId = $activeKeyId
    }
  }
}
else {
  # 3) KV is missing activeKeyId. If a healthy auto-rotated exists, do NO-OP (avoid churn).
  $bestAuto = $creds | Where-Object {
    $_.DisplayName -like "$AutomationPrefix*" -and ([datetime]$_.EndDateTime) -gt $minGoodEnd
  } | Sort-Object EndDateTime -Descending | Select-Object -First 1

  if ($bestAuto) {
    Write-Log -Level "WARN" -Step "rotate.decision" -Message "KV missing activeKeyId but healthy auto-rotated secret exists; no rotation" -Data @{
      bestAutoKeyId = "$($bestAuto.KeyId)"
      bestAutoEnd   = "$($bestAuto.EndDateTime)"
      minGoodEnd    = $minGoodEnd.ToString("o")
    }

    Write-Log -Level "INFO" -Step "rotate.end" -Message "Rotate finished (no-op)" -Data @{
      totalMs = [int]((Get-Date) - $scriptStart).TotalMilliseconds
    }
    return
  }

  Write-Log -Level "WARN" -Step "rotate.decision" -Message "KV missing activeKeyId and no healthy auto secret exists; rotation will proceed" -Data @{ }
}

# 4) Rotation path: create a new secret + store in KV
$newEnd = $now.AddDays($NewSecretLifetimeDays)
$name = "$AutomationPrefix $($now.ToString('yyyy-MM-dd'))"

Step-Time "rotate.execute" {
  New-AppSecretAndStoreInKV -ApplicationObjectId $app.Id -KeyVaultName $KeyVaultName -KvSecretName $KvSecretName `
    -EndDate $newEnd -DisplayName $name -ManagedBy $ManagedBy
}

Write-Log -Level "INFO" -Step "rotate.end" -Message "Rotation complete" -Data @{
  totalMs = [int]((Get-Date) - $scriptStart).TotalMilliseconds
}
