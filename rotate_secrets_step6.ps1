[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "High")]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet("Discover", "Rotate")]
    [string]$Mode = "Discover",

    [Parameter(Mandatory = $false)]
    [string]$InputFile = "./customers.csv",

    [Parameter(Mandatory = $false)]
    [string]$SettingsFile = "./config/settings.psd1",

    [Parameter(Mandatory = $false)]
    [Nullable[int]]$ValidityMonths = $null
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ============================================================
# CONFIGURATION
# ============================================================

# Resolve the settings file relative to the script directory so execution is
# independent of the caller's current working directory.
$ResolvedSettingsFile =
    if ([System.IO.Path]::IsPathRooted($SettingsFile)) {
        $SettingsFile
    }
    else {
        Join-Path $PSScriptRoot $SettingsFile
    }

if (-not (Test-Path $ResolvedSettingsFile)) {
    throw @"
Settings file '$ResolvedSettingsFile' does not exist.

Create it from the example:

    Copy-Item ./config/settings.example.psd1 ./config/settings.psd1

Then set TenantId and the values required by your selected AuthenticationMode. Do not store secret values in the settings file.
"@
}

$Settings = Import-PowerShellDataFile -Path $ResolvedSettingsFile

# Environment variables override file-based identifiers. This makes the same
# code usable across local, CI and hosted execution without editing the script.
$TenantId =
    if (-not [string]::IsNullOrWhiteSpace($env:AZURE_TENANT_ID)) {
        $env:AZURE_TENANT_ID
    }
    elseif ($Settings.ContainsKey("TenantId")) {
        [string]$Settings.TenantId
    }
    else {
        $null
    }

$AutomationClientId =
    if (-not [string]::IsNullOrWhiteSpace($env:AUTOMATION_CLIENT_ID)) {
        $env:AUTOMATION_CLIENT_ID
    }
    elseif ($Settings.ContainsKey("AutomationClientId")) {
        [string]$Settings.AutomationClientId
    }
    else {
        $null
    }

# Authentication mode:
# - ClientSecret: local/lab compatibility using AUTOMATION_CLIENT_SECRET.
# - AzureCli: local/dev or federated CI identity already established in Azure CLI.
# - ManagedIdentity: production Azure-hosted execution. The script explicitly
#   signs Azure CLI in with the system- or user-assigned managed identity.
$AuthenticationMode =
    if (-not [string]::IsNullOrWhiteSpace($env:AUTOMATION_AUTH_MODE)) {
        $env:AUTOMATION_AUTH_MODE
    }
    elseif ($Settings.ContainsKey("AuthenticationMode")) {
        [string]$Settings.AuthenticationMode
    }
    else {
        "ClientSecret"
    }

$ManagedIdentityClientId =
    if (-not [string]::IsNullOrWhiteSpace($env:MANAGED_IDENTITY_CLIENT_ID)) {
        $env:MANAGED_IDENTITY_CLIENT_ID
    }
    elseif ($Settings.ContainsKey("ManagedIdentityClientId")) {
        [string]$Settings.ManagedIdentityClientId
    }
    else {
        $null
    }

$SubscriptionId =
    if (-not [string]::IsNullOrWhiteSpace($env:AZURE_SUBSCRIPTION_ID)) {
        $env:AZURE_SUBSCRIPTION_ID
    }
    elseif ($Settings.ContainsKey("SubscriptionId")) {
        [string]$Settings.SubscriptionId
    }
    else {
        $null
    }

$AutomationClientSecret = $env:AUTOMATION_CLIENT_SECRET

$ConfiguredValidityMonths =
    if ($Settings.ContainsKey("DefaultValidityMonths")) {
        [int]$Settings.DefaultValidityMonths
    }
    else {
        24
    }

$EffectiveValidityMonths =
    if ($null -ne $ValidityMonths) {
        [int]$ValidityMonths
    }
    else {
        $ConfiguredValidityMonths
    }

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

if ([string]::IsNullOrWhiteSpace($TenantId)) {
    throw "TenantId is not configured. Set it in '$ResolvedSettingsFile' or AZURE_TENANT_ID."
}

if (
    $AuthenticationMode -eq "ClientSecret" -and
    [string]::IsNullOrWhiteSpace($AutomationClientId)
) {
    throw "AutomationClientId is required for ClientSecret authentication. Set it in '$ResolvedSettingsFile' or AUTOMATION_CLIENT_ID."
}

$ParsedTenantId = [guid]::Empty
if (-not [guid]::TryParse($TenantId, [ref]$ParsedTenantId)) {
    throw "TenantId '$TenantId' is not a valid GUID."
}

if (-not [string]::IsNullOrWhiteSpace($AutomationClientId)) {
    $ParsedAutomationClientId = [guid]::Empty
    if (-not [guid]::TryParse($AutomationClientId, [ref]$ParsedAutomationClientId)) {
        throw "AutomationClientId '$AutomationClientId' is not a valid GUID."
    }
}

if (-not [string]::IsNullOrWhiteSpace($ManagedIdentityClientId)) {
    $ParsedManagedIdentityClientId = [guid]::Empty
    if (-not [guid]::TryParse($ManagedIdentityClientId, [ref]$ParsedManagedIdentityClientId)) {
        throw "ManagedIdentityClientId '$ManagedIdentityClientId' is not a valid GUID."
    }
}

if (-not [string]::IsNullOrWhiteSpace($SubscriptionId)) {
    $ParsedSubscriptionId = [guid]::Empty
    if (-not [guid]::TryParse($SubscriptionId, [ref]$ParsedSubscriptionId)) {
        throw "SubscriptionId '$SubscriptionId' is not a valid GUID."
    }
}

if ($AuthenticationMode -notin @("ClientSecret", "AzureCli", "ManagedIdentity")) {
    throw "AuthenticationMode '$AuthenticationMode' is invalid. Use ClientSecret, AzureCli or ManagedIdentity."
}

if ($AuthenticationMode -eq "ClientSecret" -and [string]::IsNullOrWhiteSpace($AutomationClientSecret)) {
    throw "Automation client secret is not configured in AUTOMATION_CLIENT_SECRET."
}

if (
    $AuthenticationMode -in @("AzureCli", "ManagedIdentity") -and
    -not (Get-Command az -ErrorAction SilentlyContinue)
) {
    throw "AuthenticationMode $AuthenticationMode requires Azure CLI ('az')."
}

if ($EffectiveValidityMonths -lt 1 -or $EffectiveValidityMonths -gt 24) {
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
    (Join-Path $ModuleDirectory "Authentication.psm1") `
    -Force `
    -ErrorAction Stop

Import-Module `
    (Join-Path $ModuleDirectory "Graph.psm1") `
    -Force `
    -ErrorAction Stop

Import-Module `
    (Join-Path $ModuleDirectory "KeyVault.psm1") `
    -Force `
    -ErrorAction Stop

Import-Module `
    (Join-Path $ModuleDirectory "Rotation.psm1") `
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
Write-Host "Settings file:     $ResolvedSettingsFile"
Write-Host "Authentication:    $AuthenticationMode"
Write-Host "Total entries:     $($Customers.Count)"
Write-Host "Enabled entries:   $($EnabledCustomers.Count)"
Write-Host "Secret lifetime:   $EffectiveValidityMonths months"
Write-Host ""

# ============================================================
# AUTHENTICATION / AZURE CLI CONTEXT
# ============================================================

$AzureContext = $null

# AzureCli authentication reuses an existing CLI identity. ManagedIdentity
# deliberately establishes a fresh managed-identity CLI session so production
# cannot silently fall back to a human login. Real Rotate runs also need Azure
# CLI for Key Vault operations.
if ($AuthenticationMode -eq "ManagedIdentity") {

    Write-Host "Signing Azure CLI in with Managed Identity..."

    $AzureContext =
        Connect-ManagedIdentityAzureCli `
            -ExpectedTenantId $TenantId `
            -ManagedIdentityClientId $ManagedIdentityClientId `
            -SubscriptionId $SubscriptionId
}
elseif (
    $AuthenticationMode -eq "AzureCli" -or
    ($Mode -eq "Rotate" -and -not $WhatIfPreference)
) {

    Write-Host "Checking Azure CLI authentication..."

    $AzureContext =
        Get-AzureCliContext `
            -ExpectedTenantId $TenantId
}

if ($null -ne $AzureContext) {
    Write-Host "Azure CLI context:"
    Write-Host "Subscription: $($AzureContext.name)"
    Write-Host "Tenant:       $($AzureContext.tenantId)"
    Write-Host "Identity:     $($AzureContext.user.type)"
    Write-Host ""
}

# ============================================================
# GRAPH AUTHENTICATION
# ============================================================

$AccessToken =
    Get-AutomationGraphAccessToken `
        -AuthenticationMode $AuthenticationMode `
        -TenantId $TenantId `
        -AutomationClientId $AutomationClientId `
        -AutomationClientSecret $AutomationClientSecret

# Drop the script-local plaintext reference as soon as authentication completes.
$AutomationClientSecret = $null

$GraphHeaders =
    Get-GraphHeaders `
        -AccessToken $AccessToken

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

    try {

        # ----------------------------------------------------
        # VALIDATE CSV ENTRY
        # ----------------------------------------------------

        if ([string]::IsNullOrWhiteSpace($Customer.ApplicationId)) {
            throw "ApplicationId is missing."
        }

        if (
            -not [string]::IsNullOrWhiteSpace($AutomationClientId) -and
            $Customer.ApplicationId -eq $AutomationClientId
        ) {
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
        # ROTATION TRANSACTION
        # ----------------------------------------------------

        $RotationResult =
            Invoke-SecretRotationTransaction `
                -Application $Application `
                -CustomerName $Customer.CustomerName `
                -KeyVaultName $Customer.KeyVaultName `
                -KeyVaultSecretName $Customer.KeyVaultSecretName `
                -GraphHeaders $GraphHeaders `
                -ValidityMonths $EffectiveValidityMonths

        if (-not $RotationResult.Success) {

            $FailureCount++

            Write-Host ""
            Write-Host "FAILED: $($RotationResult.Message)"

            Write-AuditLog `
                -CustomerName $Customer.CustomerName `
                -ApplicationId $Customer.ApplicationId `
                -KeyVaultName $Customer.KeyVaultName `
                -KeyVaultSecretName $Customer.KeyVaultSecretName `
                -Action $Mode `
                -Status "Failed" `
                -CredentialKeyId $RotationResult.CredentialKeyId `
                -Message $RotationResult.Message

            continue
        }

        Write-AuditLog `
            -CustomerName $Customer.CustomerName `
            -ApplicationId $Customer.ApplicationId `
            -KeyVaultName $Customer.KeyVaultName `
            -KeyVaultSecretName $Customer.KeyVaultSecretName `
            -Action "Rotate" `
            -Status "CreatedAndApplied" `
            -CredentialKeyId $RotationResult.CredentialKeyId `
            -Message $RotationResult.Message

        $SuccessCount++

        Write-Host "SUCCESS"
        Write-Host ""
        Write-Host "IMPORTANT:"
        Write-Host "Old App Registration credentials have NOT been deleted."
        Write-Host "Application validation is still required."
    }
    catch {

        $FailureCount++
        $ErrorMessage = $_.Exception.Message

        Write-Host ""
        Write-Host "FAILED: $ErrorMessage"

        Write-AuditLog `
            -CustomerName $Customer.CustomerName `
            -ApplicationId $Customer.ApplicationId `
            -KeyVaultName $Customer.KeyVaultName `
            -KeyVaultSecretName $Customer.KeyVaultSecretName `
            -Action $Mode `
            -Status "Failed" `
            -CredentialKeyId "" `
            -Message $ErrorMessage
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

