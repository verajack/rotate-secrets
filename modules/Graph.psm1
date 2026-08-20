Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-GraphHeaders {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$AccessToken
    )

    return @{
        Authorization  = "Bearer $AccessToken"
        "Content-Type" = "application/json"
    }
}


function Get-ApplicationByClientId {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ApplicationId,

        [Parameter(Mandatory)]
        [hashtable]$Headers
    )

    $Uri =
        "https://graph.microsoft.com/v1.0/applications?`$filter=appId eq '$ApplicationId'&`$select=id,appId,displayName,passwordCredentials"

    $Response =
        Invoke-RestMethod `
            -Method GET `
            -Uri $Uri `
            -Headers $Headers

    $Applications = @($Response.value)

    if ($Applications.Count -eq 0) {
        throw "No App Registration found with Client ID '$ApplicationId'."
    }

    if ($Applications.Count -gt 1) {
        throw "More than one App Registration returned for Client ID '$ApplicationId'."
    }

    return $Applications[0]
}


function Show-AppCredentials {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Application
    )

    $Credentials =
        @($Application.passwordCredentials)

    if ($Credentials.Count -eq 0) {

        Write-Host "No client secrets found."
        return
    }

    $Credentials |
        Sort-Object endDateTime |
        Select-Object `
            displayName,
            keyId,
            startDateTime,
            endDateTime |
        Format-Table -AutoSize
}


function New-AppRegistrationSecret {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ObjectId,

        [Parameter(Mandatory)]
        [hashtable]$Headers,

        [Parameter(Mandatory)]
        [ValidateRange(1, 24)]
        [int]$ValidityMonths,

        [Parameter(Mandatory)]
        [string]$CustomerName
    )

    $StartDate =
        (Get-Date).ToUniversalTime()

    $EndDate =
        $StartDate.AddMonths($ValidityMonths)

    $RotationName =
        "rotation-$($StartDate.ToString('yyyyMMdd-HHmmss'))"

    $Body = @{
        passwordCredential = @{
            displayName   = $RotationName
            startDateTime = $StartDate.ToString("yyyy-MM-ddTHH:mm:ssZ")
            endDateTime   = $EndDate.ToString("yyyy-MM-ddTHH:mm:ssZ")
        }
    } |
        ConvertTo-Json -Depth 4

    $Uri =
        "https://graph.microsoft.com/v1.0/applications/${ObjectId}/addPassword"

    $Result =
        Invoke-RestMethod `
            -Method POST `
            -Uri $Uri `
            -Headers $Headers `
            -Body $Body

    if ([string]::IsNullOrWhiteSpace($Result.secretText)) {
        throw "Graph created the credential but did not return secretText."
    }

    return $Result
}


function Remove-AppRegistrationSecret {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ObjectId,

        [Parameter(Mandatory)]
        [string]$KeyId,

        [Parameter(Mandatory)]
        [hashtable]$Headers
    )

    $Uri =
        "https://graph.microsoft.com/v1.0/applications/${ObjectId}/removePassword"

    $Body = @{
        keyId = $KeyId
    } |
        ConvertTo-Json

    Invoke-RestMethod `
        -Method POST `
        -Uri $Uri `
        -Headers $Headers `
        -Body $Body

    Write-Host "Rollback successfully removed credential $KeyId"
}

Export-ModuleMember -Function `
    Get-GraphHeaders, `
    Get-ApplicationByClientId, `
    Show-AppCredentials, `
    New-AppRegistrationSecret, `
    Remove-AppRegistrationSecret
