[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 3650)]
    [int]$ExpiresWithinDays = 30,

    [Parameter(Mandatory = $false)]
    [string]$ExpiresOnOrBefore = "",

    [Parameter(Mandatory = $false)]
    [string]$OutputFile = "./customers-generated.csv",

    [Parameter(Mandatory = $false)]
    [switch]$IncludeExpired,

    [Parameter(Mandatory = $false)]
    [switch]$SkipKeyVaultScan
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ============================================================
# CONFIGURATION
# ============================================================

$TenantId = "cd57534e-6698-4d73-aeea-b6257e8d0b62"
$AutomationClientId = "cc8d2e70-4e17-47d4-8dbe-4acbb0ead403"

# Prefer secure injection if supplied.
$AutomationClientSecret = $env:AUTOMATION_CLIENT_SECRET

# On macOS, fall back to the login Keychain.
if ([string]::IsNullOrWhiteSpace($AutomationClientSecret) -and $IsMacOS) {

    $KeychainSecret = & /usr/bin/security find-generic-password `
        -a $env:USER `
        -s "azure-secret-rotation-automation" `
        -w 2>$null

    if (
        $LASTEXITCODE -eq 0 -and
        -not [string]::IsNullOrWhiteSpace($KeychainSecret)
    ) {
        $AutomationClientSecret = $KeychainSecret
    }
}

if ([string]::IsNullOrWhiteSpace($AutomationClientSecret)) {
    throw "Automation client secret is not configured."
}

# ============================================================
# FUNCTIONS
# ============================================================

function Get-GraphAccessToken {

    Write-Host "Authenticating to Microsoft Graph..."

    $TokenUri =
        "https://login.microsoftonline.com/${TenantId}/oauth2/v2.0/token"

    $TokenBody = @{
        client_id     = $AutomationClientId
        client_secret = $AutomationClientSecret
        scope         = "https://graph.microsoft.com/.default"
        grant_type    = "client_credentials"
    }

    try {
        $Response =
            Invoke-RestMethod `
                -Method POST `
                -Uri $TokenUri `
                -Body $TokenBody `
                -ContentType "application/x-www-form-urlencoded"
    }
    catch {
        if ($_.ErrorDetails.Message) {
            throw "Graph authentication failed: $($_.ErrorDetails.Message)"
        }

        throw "Graph authentication failed: $($_.Exception.Message)"
    }

    if ([string]::IsNullOrWhiteSpace($Response.access_token)) {
        throw "Microsoft Graph did not return an access token."
    }

    Write-Host "Microsoft Graph authentication successful."
    Write-Host ""

    return $Response.access_token
}


function Get-AllApplications {

    param(
        [Parameter(Mandatory)]
        [hashtable]$Headers
    )

    $Applications = [System.Collections.Generic.List[object]]::new()

    $Uri =
        "https://graph.microsoft.com/v1.0/applications?`$select=id,appId,displayName,passwordCredentials&`$top=999"

    do {

        $Response =
            Invoke-RestMethod `
                -Method GET `
                -Uri $Uri `
                -Headers $Headers

        foreach ($Application in @($Response.value)) {
            $Applications.Add($Application) | Out-Null
        }

        $NextLink =
            if ($Response.PSObject.Properties.Name -contains "@odata.nextLink") {
                $Response.'@odata.nextLink'
            }
            else {
                $null
            }

        $Uri = $NextLink

    } while (-not [string]::IsNullOrWhiteSpace($Uri))

    return @($Applications)
}


function Test-AzureCliLogin {

    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        return $false
    }

    try {

        $AccountJson =
            az account show `
                --output json `
                --only-show-errors 2>$null

        if ($LASTEXITCODE -ne 0 -or -not $AccountJson) {
            return $false
        }

        $Account = $AccountJson | ConvertFrom-Json

        if (-not $Account.id) {
            return $false
        }

        Write-Host "Azure CLI context:"
        Write-Host "Subscription: $($Account.name)"
        Write-Host "Tenant:       $($Account.tenantId)"
        Write-Host ""

        return $true
    }
    catch {
        return $false
    }
}


function Add-KeyVaultMapping {

    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$Mappings,

        [Parameter(Mandatory)]
        [string]$VaultName,

        [Parameter(Mandatory)]
        [string]$SecretName,

        [Parameter(Mandatory = $false)]
        [string]$ApplicationIdTag = "",

        [Parameter(Mandatory = $false)]
        [string]$CredentialKeyIdTag = "",

        [Parameter(Mandatory = $false)]
        [string]$CustomerNameTag = ""
    )

    $Mappings.Add(
        [PSCustomObject]@{
            KeyVaultName        = $VaultName
            KeyVaultSecretName  = $SecretName
            ApplicationIdTag    = $ApplicationIdTag
            CredentialKeyIdTag  = $CredentialKeyIdTag
            CustomerNameTag     = $CustomerNameTag
        }
    ) | Out-Null
}


function Get-KeyVaultMappings {

    Write-Host "Scanning accessible Key Vault secret metadata..."
    Write-Host "Secret VALUES are not read."
    Write-Host ""

    $Mappings = [System.Collections.Generic.List[object]]::new()

    $VaultOutput =
        az keyvault list `
            --query "[].name" `
            --output tsv `
            --only-show-errors

    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI failed while listing Key Vaults."
    }

    $VaultNames =
        @(
            $VaultOutput |
            ForEach-Object { "$_".Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )

    $VaultNumber = 0

    foreach ($VaultName in $VaultNames) {

        $VaultNumber++

        Write-Host "[$VaultNumber/$($VaultNames.Count)] $VaultName"

        $SecretJson =
            az keyvault secret list `
                --vault-name $VaultName `
                --query "[].{name:name,tags:tags}" `
                --output json `
                --only-show-errors 2>$null

        if ($LASTEXITCODE -ne 0 -or -not $SecretJson) {
            Write-Warning "Could not list secret metadata for Key Vault '$VaultName'. Skipping it."
            continue
        }

        $Secrets = @($SecretJson | ConvertFrom-Json)

        foreach ($Secret in $Secrets) {

            if ([string]::IsNullOrWhiteSpace("$($Secret.name)")) {
                continue
            }

            $ApplicationIdTag = ""
            $CredentialKeyIdTag = ""
            $CustomerNameTag = ""

            if ($null -ne $Secret.tags) {

                if ($Secret.tags.PSObject.Properties.Name -contains "ApplicationId") {
                    $ApplicationIdTag = "$($Secret.tags.ApplicationId)".Trim()
                }

                if ($Secret.tags.PSObject.Properties.Name -contains "CredentialKeyId") {
                    $CredentialKeyIdTag = "$($Secret.tags.CredentialKeyId)".Trim()
                }

                if ($Secret.tags.PSObject.Properties.Name -contains "CustomerName") {
                    $CustomerNameTag = "$($Secret.tags.CustomerName)".Trim()
                }
            }

            # Only keep metadata that gives us a safe way to map the
            # Key Vault secret back to an App Registration.
            if (
                [string]::IsNullOrWhiteSpace($ApplicationIdTag) -and
                [string]::IsNullOrWhiteSpace($CredentialKeyIdTag)
            ) {
                continue
            }

            Add-KeyVaultMapping `
                -Mappings $Mappings `
                -VaultName $VaultName `
                -SecretName "$($Secret.name)" `
                -ApplicationIdTag $ApplicationIdTag `
                -CredentialKeyIdTag $CredentialKeyIdTag `
                -CustomerNameTag $CustomerNameTag
        }
    }

    Write-Host ""
    Write-Host "Mapped Key Vault secret metadata entries: $($Mappings.Count)"
    Write-Host ""

    return @($Mappings)
}


function Get-CutoffUtc {

    if (-not [string]::IsNullOrWhiteSpace($ExpiresOnOrBefore)) {

        $Parsed = [DateTimeOffset]::MinValue

        if (-not [DateTimeOffset]::TryParse($ExpiresOnOrBefore, [ref]$Parsed)) {
            throw "ExpiresOnOrBefore '$ExpiresOnOrBefore' is not a valid date/time."
        }

        # If the operator supplied only a date, make the cutoff the end
        # of that UTC day. If a time/offset was supplied, preserve it.
        if ($ExpiresOnOrBefore -notmatch "[T ]\d{1,2}:") {
            return [DateTimeOffset]::new(
                $Parsed.Year,
                $Parsed.Month,
                $Parsed.Day,
                23,
                59,
                59,
                [TimeSpan]::Zero
            )
        }

        return $Parsed.ToUniversalTime()
    }

    return [DateTimeOffset]::UtcNow.AddDays($ExpiresWithinDays)
}

# ============================================================
# BUILD INVENTORY
# ============================================================

$NowUtc = [DateTimeOffset]::UtcNow
$CutoffUtc = Get-CutoffUtc

Write-Host ""
Write-Host "================================================"
Write-Host " App Registration Rotation Input Builder"
Write-Host "================================================"
Write-Host ""
Write-Host "Current UTC:        $($NowUtc.ToString('yyyy-MM-dd HH:mm:ss'))"
Write-Host "Expiry cutoff UTC:  $($CutoffUtc.ToString('yyyy-MM-dd HH:mm:ss'))"
Write-Host "Include expired:    $($IncludeExpired.IsPresent)"
Write-Host "Output file:        $OutputFile"
Write-Host ""

$AccessToken = Get-GraphAccessToken

$GraphHeaders = @{
    Authorization = "Bearer $AccessToken"
}

Write-Host "Reading App Registrations from Microsoft Graph..."

$Applications =
    Get-AllApplications `
        -Headers $GraphHeaders

Write-Host "App Registrations read: $($Applications.Count)"
Write-Host ""

$Candidates = [System.Collections.Generic.List[object]]::new()

foreach ($Application in $Applications) {

    if ("$($Application.appId)" -eq $AutomationClientId) {
        continue
    }

    $Credentials = @($Application.passwordCredentials)

    if ($Credentials.Count -eq 0) {
        continue
    }

    $ExpiringCredentials =
        @(
            $Credentials |
            Where-Object {

                if ([string]::IsNullOrWhiteSpace("$($_.endDateTime)")) {
                    return $false
                }

                $End =
                    [DateTimeOffset]$_.endDateTime

                if ($End -gt $CutoffUtc) {
                    return $false
                }

                if (-not $IncludeExpired.IsPresent -and $End -lt $NowUtc) {
                    return $false
                }

                return $true
            } |
            Sort-Object { [DateTimeOffset]$_.endDateTime }
        )

    if ($ExpiringCredentials.Count -eq 0) {
        continue
    }

    $Earliest = $ExpiringCredentials[0]

    $AllCredentialKeyIds =
        @(
            $Credentials |
            ForEach-Object { "$($_.keyId)".Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )

    $Candidates.Add(
        [PSCustomObject]@{
            CustomerName             = "$($Application.displayName)"
            ApplicationId            = "$($Application.appId)"
            CredentialExpiryUtc      = ([DateTimeOffset]$Earliest.endDateTime).UtcDateTime.ToString("yyyy-MM-ddTHH:mm:ssZ")
            ExpiringCredentialName   = "$($Earliest.displayName)"
            ExpiringCredentialKeyId  = "$($Earliest.keyId)"
            ExpiringCredentialCount  = $ExpiringCredentials.Count
            AllCredentialKeyIds      = $AllCredentialKeyIds
        }
    ) | Out-Null
}

$Candidates =
    @(
        $Candidates |
        Sort-Object CredentialExpiryUtc, CustomerName
    )

Write-Host "Applications with credentials in scope: $($Candidates.Count)"
Write-Host ""

# ============================================================
# MAP APPS TO KEY VAULT SECRETS
# ============================================================

$KeyVaultMappings = @()

if (-not $SkipKeyVaultScan.IsPresent) {

    Write-Host "Checking Azure CLI authentication..."

    if (-not (Test-AzureCliLogin)) {
        throw "Azure CLI is not authenticated. Run 'az login' or use -SkipKeyVaultScan."
    }

    $KeyVaultMappings = @(Get-KeyVaultMappings)
}
else {
    Write-Warning "Key Vault scan skipped. Generated rows will be disabled until Key Vault mappings are supplied."
    Write-Host ""
}

$Rows = [System.Collections.Generic.List[object]]::new()

foreach ($Candidate in $Candidates) {

    $Matches = @()
    $MappingSource = ""
    $MappingStatus = "NotFound"

    if ($KeyVaultMappings.Count -gt 0) {

        # Preferred mapping: explicit ApplicationId tag.
        $Matches =
            @(
                $KeyVaultMappings |
                Where-Object {
                    -not [string]::IsNullOrWhiteSpace($_.ApplicationIdTag) -and
                    $_.ApplicationIdTag -eq $Candidate.ApplicationId
                }
            )

        if ($Matches.Count -gt 0) {
            $MappingSource = "ApplicationIdTag"
        }
        else {

            # Backward-compatible mapping for secrets created by v4:
            # match the Key Vault CredentialKeyId tag to any credential
            # currently belonging to the App Registration.
            $CredentialKeySet = @{}
            foreach ($KeyId in @($Candidate.AllCredentialKeyIds)) {
                $CredentialKeySet[$KeyId.ToLowerInvariant()] = $true
            }

            $Matches =
                @(
                    $KeyVaultMappings |
                    Where-Object {
                        -not [string]::IsNullOrWhiteSpace($_.CredentialKeyIdTag) -and
                        $CredentialKeySet.ContainsKey($_.CredentialKeyIdTag.ToLowerInvariant())
                    }
                )

            if ($Matches.Count -gt 0) {
                $MappingSource = "CredentialKeyIdTag"
            }
        }
    }

    $KeyVaultName = ""
    $KeyVaultSecretName = ""
    $Enabled = "false"

    if ($Matches.Count -eq 1) {
        $KeyVaultName = "$($Matches[0].KeyVaultName)"
        $KeyVaultSecretName = "$($Matches[0].KeyVaultSecretName)"
        $MappingStatus = "Mapped"
        $Enabled = "true"
    }
    elseif ($Matches.Count -gt 1) {
        $MappingStatus = "Ambiguous"
        $Enabled = "false"
    }

    $Rows.Add(
        [PSCustomObject]@{
            CustomerName            = $Candidate.CustomerName
            ApplicationId           = $Candidate.ApplicationId
            KeyVaultName            = $KeyVaultName
            KeyVaultSecretName      = $KeyVaultSecretName
            Enabled                 = $Enabled
            CredentialExpiryUtc     = $Candidate.CredentialExpiryUtc
            ExpiringCredentialName  = $Candidate.ExpiringCredentialName
            ExpiringCredentialKeyId = $Candidate.ExpiringCredentialKeyId
            ExpiringCredentialCount = $Candidate.ExpiringCredentialCount
            MappingStatus           = $MappingStatus
            MappingSource           = $MappingSource
        }
    ) | Out-Null
}

$OutputDirectory =
    Split-Path -Parent $OutputFile

if (
    -not [string]::IsNullOrWhiteSpace($OutputDirectory) -and
    -not (Test-Path $OutputDirectory)
) {
    New-Item `
        -Path $OutputDirectory `
        -ItemType Directory `
        -Force |
        Out-Null
}

$Rows |
    Export-Csv `
        -Path $OutputFile `
        -NoTypeInformation

# ============================================================
# SUMMARY
# ============================================================

$MappedCount = @($Rows | Where-Object { $_.MappingStatus -eq "Mapped" }).Count
$AmbiguousCount = @($Rows | Where-Object { $_.MappingStatus -eq "Ambiguous" }).Count
$UnmappedCount = @($Rows | Where-Object { $_.MappingStatus -eq "NotFound" }).Count

Write-Host "================================================"
Write-Host " INPUT BUILD COMPLETE"
Write-Host "================================================"
Write-Host ""
Write-Host "Expiring applications: $($Rows.Count)"
Write-Host "Mapped automatically:  $MappedCount"
Write-Host "Ambiguous mappings:    $AmbiguousCount"
Write-Host "Unmapped:              $UnmappedCount"
Write-Host ""

if ($Rows.Count -gt 0) {

    Write-Host "Preview:"
    Write-Host ""

    $Rows |
        Select-Object `
            CustomerName,
            CredentialExpiryUtc,
            KeyVaultName,
            KeyVaultSecretName,
            Enabled,
            MappingStatus |
        Format-Table -AutoSize

    Write-Host ""
}

Write-Host "Generated:"
Write-Host $OutputFile
Write-Host ""

if ($AmbiguousCount -gt 0 -or $UnmappedCount -gt 0) {
    Write-Warning "Rows without one exact Key Vault mapping were generated with Enabled=false."
    Write-Warning "Supply/review their KeyVaultName and KeyVaultSecretName before enabling them."
}
else {
    Write-Host "All rows were mapped automatically and enabled."
}

Write-Host ""
Write-Host "No Key Vault secret VALUES were read by this script."

# Clear sensitive authentication references.
$AccessToken = $null
$AutomationClientSecret = $null
$KeychainSecret = $null
