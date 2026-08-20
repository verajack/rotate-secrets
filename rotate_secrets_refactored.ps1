[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "High")]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet("Discover", "Rotate")]
    [string]$Mode = "Discover",

    [Parameter(Mandatory = $false)]
    [string]$InputFile = "./customers.csv",

    [Parameter(Mandatory = $false)]
    [int]$ValidityMonths = 24
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ============================================================
# CONFIGURATION
# ============================================================

# Authentication App Registration
$TenantId = "cd57534e-6698-4d73-aeea-b6257e8d0b62"
$AutomationClientId = "cc8d2e70-4e17-47d4-8dbe-4acbb0ead403"

# LAB ONLY.
# Eventually replace this with managed identity / secure injection.
$AutomationClientSecret = $env:AUTOMATION_CLIENT_SECRET
# Output
$Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

$LogDirectory = Join-Path $PSScriptRoot "logs"
$LogFile = Join-Path $LogDirectory "rotation-$Timestamp.csv"

# ============================================================
# INITIAL CHECKS
# ============================================================

if (-not (Test-Path $LogDirectory)) {
    New-Item `
        -Path $LogDirectory `
        -ItemType Directory `
        -Force |
        Out-Null
}

if (-not (Test-Path $InputFile)) {
    throw "Input file '$InputFile' does not exist."
}

if ([string]::IsNullOrWhiteSpace($AutomationClientSecret)) {
    throw "Automation client secret is not configured."
}

if ($ValidityMonths -lt 1 -or $ValidityMonths -gt 24) {
    throw "ValidityMonths must be between 1 and 24."
}

if ($Mode -eq "Rotate" -and -not $WhatIfPreference) {

    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {

        throw @"
Azure CLI ('az') is not available.

This script uses Azure CLI for Key Vault updates.

Azure Cloud Shell includes Azure CLI.

On this machine verify with:

    az --version
"@
    }
}

# ============================================================
# MODULES
# ============================================================

$ModuleDirectory = Join-Path $PSScriptRoot "modules"

Import-Module `
    (Join-Path $ModuleDirectory "Graph.psm1") `
    -Force `
    -ErrorAction Stop

Import-Module `
    (Join-Path $ModuleDirectory "KeyVault.psm1") `
    -Force `
    -ErrorAction Stop

# ============================================================
# LOCAL FUNCTIONS
# ============================================================

function Write-AuditLog {

    param(
        [string]$CustomerName,
        [string]$ApplicationId,
        [string]$KeyVaultName,
        [string]$KeyVaultSecretName,
        [string]$Action,
        [string]$Status,
        [string]$CredentialKeyId,
        [string]$Message
    )

    [PSCustomObject]@{
        TimestampUtc       = (Get-Date).ToUniversalTime().ToString("o")
        CustomerName       = $CustomerName
        ApplicationId      = $ApplicationId
        KeyVaultName       = $KeyVaultName
        KeyVaultSecretName = $KeyVaultSecretName
        Action             = $Action
        Status             = $Status
        CredentialKeyId    = $CredentialKeyId
        Message            = $Message
    } |
        Export-Csv `
            -Path $LogFile `
            -Append `
            -NoTypeInformation
}


function Test-AzureCliLogin {

    try {

        $AccountJson =
            az account show `
                --output json `
                --only-show-errors 2>$null

        $AzExitCode = $LASTEXITCODE

        if ($AzExitCode -ne 0 -or -not $AccountJson) {
            return $false
        }

        $Account =
            $AccountJson |
            ConvertFrom-Json

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

# ============================================================
# LOAD INPUT
# ============================================================

$Customers =
    @(Import-Csv -Path $InputFile)

if ($Customers.Count -eq 0) {
    throw "No customer entries were found in '$InputFile'."
}

$EnabledCustomers =
    @(
        $Customers |
        Where-Object {
            $_.Enabled -match "^(true|yes|1)$"
        }
    )

Write-Host ""
Write-Host "================================================"
Write-Host " CompanyA App Registration Secret Rotation"
Write-Host "================================================"
Write-Host ""

Write-Host "Mode:              $Mode"
Write-Host "Input file:        $InputFile"
Write-Host "Total entries:     $($Customers.Count)"
Write-Host "Enabled entries:   $($EnabledCustomers.Count)"
Write-Host "Secret lifetime:   $ValidityMonths months"
Write-Host ""

# ============================================================
# GRAPH AUTHENTICATION
# ============================================================

$AccessToken =
    Get-GraphAccessToken `
        -TenantId $TenantId `
        -AutomationClientId $AutomationClientId `
        -AutomationClientSecret $AutomationClientSecret

$GraphHeaders =
    Get-GraphHeaders `
        -AccessToken $AccessToken

# ============================================================
# AZURE CLI CHECK
# ============================================================

if ($Mode -eq "Rotate" -and -not $WhatIfPreference) {

    Write-Host "Checking Azure CLI authentication..."

    if (-not (Test-AzureCliLogin)) {

        throw @"
Azure CLI is not authenticated.

For a manual lab test run:

    az login

Azure Cloud Shell should already have an authenticated Azure context.
"@
    }
}

# ============================================================
# PROCESS CUSTOMERS
# ============================================================

$SuccessCount = 0
$FailureCount = 0
$SkippedCount = 0

foreach ($Customer in $EnabledCustomers) {

    Write-Host ""
    Write-Host "------------------------------------------------"
    Write-Host "Customer: $($Customer.CustomerName)"
    Write-Host "------------------------------------------------"

    $NewCredential = $null
    $KeyVaultWriteSucceeded = $false

    try {

        # ----------------------------------------------------
        # VALIDATE CSV ENTRY
        # ----------------------------------------------------

        if ([string]::IsNullOrWhiteSpace($Customer.ApplicationId)) {
            throw "ApplicationId is missing."
        }

        if ($Customer.ApplicationId -eq $AutomationClientId) {
            throw "Refusing to rotate the automation App Registration itself ('$AutomationClientId'). Use a separate target App Registration for rotation testing."
        }

        # ----------------------------------------------------
        # FIND EXACT APP BY CLIENT ID
        # ----------------------------------------------------

        $Application =
            Get-ApplicationByClientId `
                -ApplicationId $Customer.ApplicationId `
                -Headers $GraphHeaders

        Write-Host "App Registration found:"
        Write-Host "Name:      $($Application.displayName)"
        Write-Host "Client ID: $($Application.appId)"
        Write-Host "Object ID: $($Application.id)"
        Write-Host ""

        Write-Host "Existing credentials:"
        Write-Host ""

        Show-AppCredentials `
            -Application $Application

        # ----------------------------------------------------
        # DISCOVER ONLY
        # ----------------------------------------------------

        if ($Mode -eq "Discover") {

            Write-AuditLog `
                -CustomerName $Customer.CustomerName `
                -ApplicationId $Customer.ApplicationId `
                -KeyVaultName $Customer.KeyVaultName `
                -KeyVaultSecretName $Customer.KeyVaultSecretName `
                -Action "Discover" `
                -Status "Success" `
                -CredentialKeyId "" `
                -Message "Application located and credentials listed."

            $SuccessCount++

            continue
        }

        # ----------------------------------------------------
        # VALIDATE ROTATION INPUT
        # ----------------------------------------------------

        if ([string]::IsNullOrWhiteSpace($Customer.KeyVaultName)) {
            throw "KeyVaultName is missing."
        }

        if ([string]::IsNullOrWhiteSpace($Customer.KeyVaultSecretName)) {
            throw "KeyVaultSecretName is missing."
        }

        # ----------------------------------------------------
        # WHATIF / SHOULDPROCESS
        # ----------------------------------------------------

        $Target =
            "$($Customer.CustomerName): $($Customer.ApplicationId) -> $($Customer.KeyVaultName)/$($Customer.KeyVaultSecretName)"

        $Action =
            "Create a new App Registration client secret and apply it to Key Vault"

        if (-not $PSCmdlet.ShouldProcess($Target, $Action)) {

            Write-AuditLog `
                -CustomerName $Customer.CustomerName `
                -ApplicationId $Customer.ApplicationId `
                -KeyVaultName $Customer.KeyVaultName `
                -KeyVaultSecretName $Customer.KeyVaultSecretName `
                -Action "Rotate" `
                -Status "WhatIf" `
                -CredentialKeyId "" `
                -Message "No changes made."

            $SkippedCount++

            continue
        }

        # ----------------------------------------------------
        # VERIFY KEY VAULT BEFORE CREATING NEW CREDENTIAL
        # ----------------------------------------------------

        Write-Host ""
        Write-Host "Checking Key Vault '$($Customer.KeyVaultName)'..."

        if (-not (
            Test-KeyVaultExists `
                -VaultName $Customer.KeyVaultName
        )) {

            throw "Key Vault '$($Customer.KeyVaultName)' is not accessible."
        }

        Write-Host "Key Vault accessible."

        # ----------------------------------------------------
        # CREATE NEW APP REGISTRATION SECRET
        # ----------------------------------------------------

        Write-Host ""
        Write-Host "Creating new App Registration secret..."

        $NewCredential =
            New-AppRegistrationSecret `
                -ObjectId $Application.id `
                -Headers $GraphHeaders `
                -ValidityMonths $ValidityMonths `
                -CustomerName $Customer.CustomerName

        Write-Host "Created successfully:"
        Write-Host "Display name: $($NewCredential.displayName)"
        Write-Host "Key ID:       $($NewCredential.keyId)"
        Write-Host "Expiry:       $($NewCredential.endDateTime)"
        Write-Host ""

        #
        # NEVER WRITE secretText TO CONSOLE OR LOG
        #

        # ----------------------------------------------------
        # APPLY TO KEY VAULT
        # ----------------------------------------------------

        Write-Host "Updating Key Vault secret..."

        $KeyVaultResult =
            Set-CustomerKeyVaultSecret `
                -VaultName $Customer.KeyVaultName `
                -SecretName $Customer.KeyVaultSecretName `
                -SecretValue $NewCredential.secretText

        $KeyVaultWriteSucceeded = $true

        Write-Host "Key Vault update returned successfully."

        # ----------------------------------------------------
        # REMOVE PLAINTEXT REFERENCE ASAP
        # ----------------------------------------------------

        $NewCredential.secretText = $null

        # ----------------------------------------------------
        # VERIFY METADATA
        # ----------------------------------------------------

        $Metadata =
            Get-KeyVaultSecretMetadata `
                -VaultName $Customer.KeyVaultName `
                -SecretName $Customer.KeyVaultSecretName

        Write-Host ""
        Write-Host "Key Vault secret verified:"
        Write-Host "Name:    $($Metadata.name)"
        Write-Host "Enabled: $($Metadata.enabled)"
        Write-Host "Updated: $($Metadata.updated)"
        Write-Host ""

        # ----------------------------------------------------
        # SUCCESS LOG
        # ----------------------------------------------------

        Write-AuditLog `
            -CustomerName $Customer.CustomerName `
            -ApplicationId $Customer.ApplicationId `
            -KeyVaultName $Customer.KeyVaultName `
            -KeyVaultSecretName $Customer.KeyVaultSecretName `
            -Action "Rotate" `
            -Status "CreatedAndApplied" `
            -CredentialKeyId $NewCredential.keyId `
            -Message "New App Registration credential created and new Key Vault secret version applied."

        $SuccessCount++

        Write-Host "SUCCESS"
        Write-Host ""
        Write-Host "IMPORTANT:"
        Write-Host "Old App Registration credentials have NOT been deleted."
        Write-Host "Application validation is still required."

    }
    catch {

        $FailureCount++

        $ErrorMessage =
            $_.Exception.Message

        Write-Host ""
        Write-Host "FAILED: $ErrorMessage"

        if ($NewCredential -and $NewCredential.keyId) {

            if (-not $KeyVaultWriteSucceeded) {

                Write-Host ""
                Write-Warning "A new App Registration credential was created, but the Key Vault write did not complete."
                Write-Warning "Attempting automatic rollback of credential $($NewCredential.keyId)..."

                try {

                    Remove-AppRegistrationSecret `
                        -ObjectId $Application.id `
                        -KeyId $NewCredential.keyId `
                        -Headers $GraphHeaders

                    Write-Warning "Automatic rollback completed successfully."

                    $ErrorMessage =
                        "$ErrorMessage Automatic rollback removed credential $($NewCredential.keyId)."
                }
                catch {

                    $RollbackError =
                        $_.Exception.Message

                    Write-Host ""
                    Write-Error "CRITICAL: Automatic rollback failed for credential $($NewCredential.keyId). Manual cleanup is required. $RollbackError"

                    $ErrorMessage =
                        "$ErrorMessage Automatic rollback FAILED for credential $($NewCredential.keyId): $RollbackError"
                }
            }
            else {

                Write-Host ""
                Write-Warning "The Key Vault write completed before the later failure."
                Write-Warning "The new credential has been retained intentionally."
                Write-Warning "Do NOT delete credential $($NewCredential.keyId) until the Key Vault version has been verified."
            }
        }

        Write-AuditLog `
            -CustomerName $Customer.CustomerName `
            -ApplicationId $Customer.ApplicationId `
            -KeyVaultName $Customer.KeyVaultName `
            -KeyVaultSecretName $Customer.KeyVaultSecretName `
            -Action $Mode `
            -Status "Failed" `
            -CredentialKeyId $(if ($NewCredential) { $NewCredential.keyId } else { "" }) `
            -Message $ErrorMessage
    }

    finally {

        if ($NewCredential) {
            $NewCredential.secretText = $null
        }

        $NewCredential = $null
    }
}

# ============================================================
# SUMMARY
# ============================================================

Write-Host ""
Write-Host "================================================"
Write-Host " COMPLETE"
Write-Host "================================================"
Write-Host ""

Write-Host "Successful: $SuccessCount"
Write-Host "Failed:     $FailureCount"
Write-Host "Skipped:    $SkippedCount"
Write-Host ""
Write-Host "Audit log:"
Write-Host $LogFile
Write-Host ""

if ($Mode -eq "Rotate") {

    Write-Host "No old App Registration credentials were removed."
    Write-Host "Validation and retirement remain separate stages."
    Write-Host ""
}

