[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "High")]
param(
    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 150)]
    [int]$CustomerCount = 100,

    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName = "",

    [Parameter(Mandatory = $false)]
    [string]$Location = "uksouth",

    [Parameter(Mandatory = $false)]
    [string]$LegacyExpiryUtc = "2026-08-28T17:00:00Z",

    [Parameter(Mandatory = $false)]
    [string]$OutputCsv = "./customers-prod-mimic.csv",

    [Parameter(Mandatory = $false)]
    [string]$ManifestFile = "./prod-mimic-manifest.json"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Invoke-AzJson {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $Result = & az @Arguments --output json --only-show-errors
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI command failed: az $($Arguments -join ' ')"
    }
    if (-not $Result) {
        throw "Azure CLI returned no JSON result: az $($Arguments -join ' ')"
    }
    return ($Result | ConvertFrom-Json)
}

function Invoke-AzNone {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    & az @Arguments --output none --only-show-errors
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI command failed: az $($Arguments -join ' ')"
    }
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI ('az') is not installed or not on PATH."
}

$Account = Invoke-AzJson -Arguments @("account", "show")
$TenantId = "$($Account.tenantId)"
$SubscriptionId = "$($Account.id)"
$SubscriptionName = "$($Account.name)"

$LegacyExpiry = [DateTimeOffset]::Parse($LegacyExpiryUtc).ToUniversalTime()
if ($LegacyExpiry -le [DateTimeOffset]::UtcNow) {
    throw "LegacyExpiryUtc must be in the future. Current value: $LegacyExpiryUtc"
}

$LegacyExpiryString = $LegacyExpiry.ToString("yyyy-MM-ddTHH:mm:ssZ")
if ($LegacyExpiry.DayOfWeek -ne [System.DayOfWeek]::Friday) {
    Write-Warning "Legacy expiry is $($LegacyExpiry.DayOfWeek), not Friday."
}

$Suffix = ([Guid]::NewGuid().ToString("N").Substring(0, 8))
if ([string]::IsNullOrWhiteSpace($ResourceGroupName)) {
    $ResourceGroupName = "secret-rotation-prod-mimic-$Suffix"
}

$OutputCsv = [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $OutputCsv))
$ManifestFile = [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $ManifestFile))

if (Test-Path $OutputCsv) {
    throw "Output CSV already exists: $OutputCsv. Move/delete it first so an existing customer list is not overwritten."
}
if (Test-Path $ManifestFile) {
    throw "Manifest already exists: $ManifestFile. Move/delete it first so cleanup data is not overwritten."
}

Write-Host ""
Write-Host "================================================"
Write-Host " PROD-MIMIC SECRET ROTATION LAB"
Write-Host "================================================"
Write-Host ""
Write-Host "Customers:        $CustomerCount"
Write-Host "Subscription:     $SubscriptionName"
Write-Host "Subscription ID:  $SubscriptionId"
Write-Host "Tenant:           $TenantId"
Write-Host "Region:           $Location"
Write-Host "Resource group:   $ResourceGroupName"
Write-Host "Legacy expiry:    $LegacyExpiryString ($($LegacyExpiry.DayOfWeek))"
Write-Host "Output CSV:       $OutputCsv"
Write-Host "Manifest:         $ManifestFile"
Write-Host ""
Write-Host "This will create $CustomerCount App Registrations and $CustomerCount Key Vaults."
Write-Host "Each App Registration will start with one client secret expiring on the legacy date."
Write-Host "The same value will be stored in that customer's Key Vault secret."
Write-Host ""

$Target = "$CustomerCount App Registrations + $CustomerCount Key Vaults in $ResourceGroupName"
if (-not $PSCmdlet.ShouldProcess($Target, "Create prod-mimic secret rotation lab")) {
    return
}

Write-Host "Creating resource group..."
Invoke-AzNone -Arguments @(
    "group", "create",
    "--name", $ResourceGroupName,
    "--location", $Location
)

$Rows = [System.Collections.Generic.List[object]]::new()
$Created = [System.Collections.Generic.List[object]]::new()
$Failures = [System.Collections.Generic.List[object]]::new()

for ($i = 1; $i -le $CustomerCount; $i++) {
    $Index = $i.ToString("000")
    $CustomerName = "ProdMimicCustomer$Index"
    $AppName = "prod-mimic-customer-$Index"
    # Key Vault names must be globally unique and 3-24 characters.
    $KeyVaultName = "srpm-$Suffix-$Index".ToLowerInvariant()
    $KeyVaultSecretName = "Customer$Index-ClientSecret"
    $LegacyCredentialName = "legacy-expiry-20260828"

    Write-Progress `
        -Activity "Creating prod-mimic customer estate" `
        -Status "$CustomerName ($i of $CustomerCount)" `
        -PercentComplete (($i / $CustomerCount) * 100)

    $AppId = $null
    $AppObjectId = $null
    $SecretValue = $null
    $VaultCreated = $false

    try {
        Write-Host "[$Index/$($CustomerCount.ToString('000'))] Creating $CustomerName ..."

        $App = Invoke-AzJson -Arguments @(
            "ad", "app", "create",
            "--display-name", $AppName,
            "--sign-in-audience", "AzureADMyOrg"
        )

        $AppId = "$($App.appId)"
        $AppObjectId = "$($App.id)"

        # --append is deliberate: it guarantees we add the legacy credential
        # rather than invoking the reset command's default clear-and-replace behaviour.
        $SecretValue = & az ad app credential reset `
            --id $AppId `
            --append `
            --display-name $LegacyCredentialName `
            --end-date $LegacyExpiryString `
            --query password `
            --output tsv `
            --only-show-errors

        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($SecretValue)) {
            throw "Failed to create the legacy client secret."
        }

        Invoke-AzNone -Arguments @(
            "keyvault", "create",
            "--name", $KeyVaultName,
            "--resource-group", $ResourceGroupName,
            "--location", $Location,
            "--enable-rbac-authorization", "false"
        )
        $VaultCreated = $true

        Invoke-AzNone -Arguments @(
            "keyvault", "secret", "set",
            "--vault-name", $KeyVaultName,
            "--name", $KeyVaultSecretName,
            "--value", $SecretValue,
            "--expires", $LegacyExpiryString,
            "--tags",
                "Lab=ProdMimic",
                "LegacyExpiry=$LegacyExpiryString",
                "ApplicationId=$AppId"
        )

        # Never persist the plaintext client secret in CSV, manifest or console output.
        $SecretValue = $null

        $Rows.Add([PSCustomObject]@{
            CustomerName       = $CustomerName
            ApplicationId      = $AppId
            KeyVaultName       = $KeyVaultName
            KeyVaultSecretName = $KeyVaultSecretName
            Enabled            = "true"
        }) | Out-Null

        $Created.Add([PSCustomObject]@{
            CustomerName       = $CustomerName
            ApplicationId      = $AppId
            ApplicationObjectId = $AppObjectId
            AppDisplayName     = $AppName
            KeyVaultName       = $KeyVaultName
            KeyVaultSecretName = $KeyVaultSecretName
            LegacyExpiryUtc    = $LegacyExpiryString
        }) | Out-Null
    }
    catch {
        $SecretValue = $null
        $Message = $_.Exception.Message
        Write-Warning "$CustomerName failed: $Message"

        $Failures.Add([PSCustomObject]@{
            CustomerName  = $CustomerName
            ApplicationId = $AppId
            KeyVaultName  = $KeyVaultName
            Error         = $Message
        }) | Out-Null

        # Best-effort rollback of this partially-created customer.
        if ($AppId) {
            & az ad app delete --id $AppId --only-show-errors 2>$null
        }
        if ($VaultCreated) {
            & az keyvault delete --name $KeyVaultName --only-show-errors 2>$null
        }
    }
}

Write-Progress -Activity "Creating prod-mimic customer estate" -Completed

if ($Rows.Count -gt 0) {
    $Rows | Export-Csv -Path $OutputCsv -NoTypeInformation
}

$Manifest = [PSCustomObject]@{
    CreatedUtc        = (Get-Date).ToUniversalTime().ToString("o")
    SubscriptionId    = $SubscriptionId
    SubscriptionName  = $SubscriptionName
    TenantId          = $TenantId
    ResourceGroupName = $ResourceGroupName
    Location          = $Location
    LegacyExpiryUtc   = $LegacyExpiryString
    RequestedCount    = $CustomerCount
    SuccessfulCount   = $Created.Count
    FailedCount       = $Failures.Count
    Customers         = @($Created)
    Failures          = @($Failures)
}
$Manifest | ConvertTo-Json -Depth 6 | Set-Content -Path $ManifestFile

Write-Host ""
Write-Host "================================================"
Write-Host " PROD-MIMIC LAB COMPLETE"
Write-Host "================================================"
Write-Host ""
Write-Host "Requested:  $CustomerCount"
Write-Host "Created:    $($Created.Count)"
Write-Host "Failed:     $($Failures.Count)"
Write-Host ""
Write-Host "Customer CSV: $OutputCsv"
Write-Host "Manifest:     $ManifestFile"
Write-Host ""

if ($Failures.Count -gt 0) {
    Write-Host "FAILED CUSTOMERS"
    $Failures | Format-Table CustomerName, KeyVaultName, Error -AutoSize
    Write-Warning "The lab is usable with the successfully-created rows, but it contains fewer than $CustomerCount customers."
}

Write-Host "Next safe test:"
Write-Host "  ./rotate_secrets.ps1 -Mode Discover -InputFile '$OutputCsv'"
Write-Host ""
Write-Host "Then:"
Write-Host "  ./rotate_secrets.ps1 -Mode Rotate -InputFile '$OutputCsv' -WhatIf"
Write-Host ""
