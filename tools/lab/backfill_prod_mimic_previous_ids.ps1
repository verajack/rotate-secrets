[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "High")]
param(
    [Parameter(Mandatory = $false)]
    [string]$InputFile = "./customers-prod-mimic.csv",

    [Parameter(Mandatory = $false)]
    [string]$LegacyCredentialDisplayName = "legacy-expiry-20260828"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Test-Path $InputFile)) {
    throw "Input file '$InputFile' does not exist."
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI ('az') is not available."
}

$Customers = @(Import-Csv -Path $InputFile)

if ($Customers.Count -eq 0) {
    throw "No customer entries were found in '$InputFile'."
}

$SuccessCount = 0
$FailureCount = 0
$SkippedCount = 0

foreach ($Customer in $Customers) {

    if ("$($Customer.Enabled)" -notmatch "^(?i:true|yes|1)$") {
        continue
    }

    Write-Host ""
    Write-Host "------------------------------------------------"
    Write-Host "Customer: $($Customer.CustomerName)"
    Write-Host "------------------------------------------------"

    try {
        $CredentialsJson =
            az ad app credential list `
                --id $Customer.ApplicationId `
                --output json `
                --only-show-errors

        if ($LASTEXITCODE -ne 0 -or -not $CredentialsJson) {
            throw "Unable to list App Registration credentials."
        }

        $Credentials = @($CredentialsJson | ConvertFrom-Json)

        $LegacyCredentials =
            @(
                $Credentials |
                Where-Object {
                    $_.displayName -eq $LegacyCredentialDisplayName
                }
            )

        if ($LegacyCredentials.Count -eq 0) {
            Write-Host "Legacy credential '$LegacyCredentialDisplayName' is already absent."
            $SkippedCount++
            continue
        }

        if ($LegacyCredentials.Count -ne 1) {
            throw "Expected exactly one '$LegacyCredentialDisplayName' credential, found $($LegacyCredentials.Count)."
        }

        $LegacyCredential = $LegacyCredentials[0]

        $SecretJson =
            az keyvault secret show `
                --vault-name $Customer.KeyVaultName `
                --name $Customer.KeyVaultSecretName `
                --output json `
                --only-show-errors

        if ($LASTEXITCODE -ne 0 -or -not $SecretJson) {
            throw "Unable to read the current Key Vault secret metadata."
        }

        $Secret = $SecretJson | ConvertFrom-Json

        $CurrentCredentialKeyId =
            if ($Secret.tags -and $Secret.tags.CredentialKeyId) {
                "$($Secret.tags.CredentialKeyId)"
            }
            else {
                ""
            }

        if ([string]::IsNullOrWhiteSpace($CurrentCredentialKeyId)) {
            throw "Current Key Vault secret has no CredentialKeyId tag. Refusing backfill."
        }

        if ($CurrentCredentialKeyId -eq "$($LegacyCredential.keyId)") {
            throw "The legacy credential is still the Key Vault current credential. Rotate and validate before backfilling retirement metadata."
        }

        $TagMap = [ordered]@{}

        if ($Secret.tags) {
            foreach ($Property in $Secret.tags.PSObject.Properties) {
                $TagMap[$Property.Name] = "$($Property.Value)"
            }
        }

        $TagMap["PreviousCredentialKeyIds"] = "$($LegacyCredential.keyId)"
        $TagMap["PreviousCredentialSource"] = "ProdMimicBackfill"

        $TagArguments =
            @(
                $TagMap.GetEnumerator() |
                ForEach-Object {
                    "$($_.Key)=$($_.Value)"
                }
            )

        Write-Host "Protected current Key ID: $CurrentCredentialKeyId"
        Write-Host "Legacy Key ID to map:     $($LegacyCredential.keyId)"
        Write-Host ""

        $Target =
            "$($Customer.KeyVaultName)/$($Customer.KeyVaultSecretName)"

        $Action =
            "Backfill exact previous credential Key ID '$($LegacyCredential.keyId)' into Key Vault tags"

        if (-not $PSCmdlet.ShouldProcess($Target, $Action)) {
            $SkippedCount++
            continue
        }

        $Arguments = @(
            "keyvault", "secret", "set-attributes",
            "--vault-name", "$($Customer.KeyVaultName)",
            "--name", "$($Customer.KeyVaultSecretName)",
            "--tags"
        )

        $Arguments += $TagArguments
        $Arguments += @(
            "--output", "none",
            "--only-show-errors"
        )

        & az @Arguments

        if ($LASTEXITCODE -ne 0) {
            throw "Azure CLI failed to update Key Vault secret tags."
        }

        Write-Host "Backfill successful."
        $SuccessCount++
    }
    catch {
        Write-Host "FAILED: $($_.Exception.Message)"
        $FailureCount++
    }
}

Write-Host ""
Write-Host "================================================"
Write-Host " BACKFILL COMPLETE"
Write-Host "================================================"
Write-Host "Successful: $SuccessCount"
Write-Host "Failed:     $FailureCount"
Write-Host "Skipped:    $SkippedCount"
Write-Host ""
