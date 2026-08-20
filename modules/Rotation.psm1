Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Explicit module dependencies. Rotation owns the transaction, while the
# Graph and Key Vault modules own provider-specific operations.
Import-Module (Join-Path $PSScriptRoot "Graph.psm1") -Scope Local -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot "KeyVault.psm1") -Scope Local -ErrorAction Stop

function Invoke-SecretRotationTransaction {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Application,

        [Parameter(Mandatory)]
        [string]$CustomerName,

        [Parameter(Mandatory)]
        [string]$KeyVaultName,

        [Parameter(Mandatory)]
        [string]$KeyVaultSecretName,

        [Parameter(Mandatory)]
        [hashtable]$GraphHeaders,

        [Parameter(Mandatory)]
        [ValidateRange(1, 24)]
        [int]$ValidityMonths
    )

    $NewCredential = $null
    $KeyVaultWriteSucceeded = $false
    $RollbackStatus = "NotRequired"

    try {

        # ----------------------------------------------------
        # VERIFY KEY VAULT BEFORE CREATING NEW CREDENTIAL
        # ----------------------------------------------------

        Write-Host ""
        Write-Host "Checking Key Vault '$KeyVaultName'..."

        if (-not (
            Test-KeyVaultExists `
                -VaultName $KeyVaultName
        )) {
            throw "Key Vault '$KeyVaultName' is not accessible."
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
                -CustomerName $CustomerName

        Write-Host "Created successfully:"
        Write-Host "Display name: $($NewCredential.displayName)"
        Write-Host "Key ID:       $($NewCredential.keyId)"
        Write-Host "Expiry:       $($NewCredential.endDateTime)"
        Write-Host ""

        # NEVER WRITE secretText TO CONSOLE OR LOG.

        # ----------------------------------------------------
        # APPLY TO KEY VAULT
        # ----------------------------------------------------

        Write-Host "Updating Key Vault secret..."

        $null =
            Set-CustomerKeyVaultSecret `
                -VaultName $KeyVaultName `
                -SecretName $KeyVaultSecretName `
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
                -VaultName $KeyVaultName `
                -SecretName $KeyVaultSecretName

        Write-Host ""
        Write-Host "Key Vault secret verified:"
        Write-Host "Name:    $($Metadata.name)"
        Write-Host "Enabled: $($Metadata.enabled)"
        Write-Host "Updated: $($Metadata.updated)"
        Write-Host ""

        return [PSCustomObject]@{
            Success                 = $true
            CredentialKeyId         = $NewCredential.keyId
            CredentialDisplayName   = $NewCredential.displayName
            KeyVaultWriteSucceeded  = $true
            RollbackStatus          = "NotRequired"
            Message                 = "New App Registration credential created and new Key Vault secret version applied."
            Metadata                = $Metadata
        }
    }
    catch {

        $ErrorMessage = $_.Exception.Message
        $CredentialKeyId = ""
        $CredentialDisplayName = ""

        if ($NewCredential) {
            $CredentialKeyId = $NewCredential.keyId
            $CredentialDisplayName = $NewCredential.displayName
        }

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

                    $RollbackStatus = "Succeeded"
                    Write-Warning "Automatic rollback completed successfully."

                    $ErrorMessage =
                        "$ErrorMessage Automatic rollback removed credential $($NewCredential.keyId)."
                }
                catch {

                    $RollbackError = $_.Exception.Message
                    $RollbackStatus = "Failed"

                    Write-Host ""
                    Write-Error "CRITICAL: Automatic rollback failed for credential $($NewCredential.keyId). Manual cleanup is required. $RollbackError"

                    $ErrorMessage =
                        "$ErrorMessage Automatic rollback FAILED for credential $($NewCredential.keyId): $RollbackError"
                }
            }
            else {

                $RollbackStatus = "CredentialRetained"

                Write-Host ""
                Write-Warning "The Key Vault write completed before the later failure."
                Write-Warning "The new credential has been retained intentionally."
                Write-Warning "Do NOT delete credential $($NewCredential.keyId) until the Key Vault version has been verified."
            }
        }

        return [PSCustomObject]@{
            Success                 = $false
            CredentialKeyId         = $CredentialKeyId
            CredentialDisplayName   = $CredentialDisplayName
            KeyVaultWriteSucceeded  = $KeyVaultWriteSucceeded
            RollbackStatus          = $RollbackStatus
            Message                 = $ErrorMessage
            Metadata                = $null
        }
    }
    finally {

        if ($NewCredential) {
            $NewCredential.secretText = $null
        }

        $NewCredential = $null
    }
}

Export-ModuleMember -Function Invoke-SecretRotationTransaction
