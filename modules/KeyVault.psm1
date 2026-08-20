Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Test-KeyVaultExists {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$VaultName
    )

    try {

        az keyvault show `
            --name $VaultName `
            --output none `
            --only-show-errors 2>$null

        if ($LASTEXITCODE -ne 0) {
            return $false
        }

        return $true
    }
    catch {
        return $false
    }
}


function Set-CustomerKeyVaultSecret {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$VaultName,

        [Parameter(Mandatory)]
        [string]$SecretName,

        [Parameter(Mandatory)]
        [string]$SecretValue
    )

    # The secret remains in memory and is passed directly to Azure CLI.
    # It is never written to console output or audit logs by this function.

    $Result =
        az keyvault secret set `
            --vault-name $VaultName `
            --name $SecretName `
            --value $SecretValue `
            --output json `
            --only-show-errors

    $AzExitCode = $LASTEXITCODE

    if ($AzExitCode -ne 0) {
        throw "Azure CLI Key Vault secret update failed with exit code $AzExitCode."
    }

    if (-not $Result) {
        throw "Azure CLI returned no result from Key Vault secret update."
    }

    return ($Result | ConvertFrom-Json)
}


function Get-KeyVaultSecretMetadata {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$VaultName,

        [Parameter(Mandatory)]
        [string]$SecretName
    )

    $Result =
        az keyvault secret show `
            --vault-name $VaultName `
            --name $SecretName `
            --query "{id:id,name:name,enabled:attributes.enabled,updated:attributes.updated}" `
            --output json `
            --only-show-errors

    $AzExitCode = $LASTEXITCODE

    if ($AzExitCode -ne 0) {
        throw "Azure CLI failed to retrieve Key Vault secret metadata with exit code $AzExitCode."
    }

    if (-not $Result) {
        throw "Unable to retrieve Key Vault secret metadata."
    }

    return ($Result | ConvertFrom-Json)
}

Export-ModuleMember -Function `
    Test-KeyVaultExists, `
    Set-CustomerKeyVaultSecret, `
    Get-KeyVaultSecretMetadata
