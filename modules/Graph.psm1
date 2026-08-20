Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-GraphAccessToken {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$TenantId,

        [Parameter(Mandatory)]
        [string]$AutomationClientId,

        [Parameter(Mandatory)]
        [string]$AutomationClientSecret
    )

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

        if ([string]::IsNullOrWhiteSpace($Response.access_token)) {
            throw "Microsoft Graph did not return an access token."
        }

        Write-Host "Microsoft Graph authentication successful."
        Write-Host ""

        return $Response.access_token
    }
    catch {

        if ($_.Exception.Message -eq "Microsoft Graph did not return an access token.") {
            throw
        }

        if ($_.ErrorDetails.Message) {
            throw "Graph authentication failed: $($_.ErrorDetails.Message)"
        }

        throw "Graph authentication failed: $($_.Exception.Message)"
    }
    finally {
        $TokenBody.client_secret = $null
    }
}


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
    Get-GraphAccessToken, `
    Get-GraphHeaders, `
    Get-ApplicationByClientId, `
    Show-AppCredentials, `
    New-AppRegistrationSecret, `
    Remove-AppRegistrationSecret
