Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Invoke-AzureCliCommand {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw "Azure CLI ('az') is not available."
    }

    $Output =
        & az @Arguments 2>&1

    $ExitCode = $LASTEXITCODE

    [PSCustomObject]@{
        ExitCode = $ExitCode
        Output   = @($Output)
    }
}


function Get-AzureCliContext {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$ExpectedTenantId
    )

    $Result =
        Invoke-AzureCliCommand `
            -Arguments @(
                "account", "show",
                "--output", "json",
                "--only-show-errors"
            )

    if ($Result.ExitCode -ne 0 -or $Result.Output.Count -eq 0) {
        throw "Azure CLI is not authenticated. Establish an Azure CLI identity before running the script."
    }

    try {
        $Account =
            ($Result.Output -join [Environment]::NewLine) |
            ConvertFrom-Json
    }
    catch {
        throw "Azure CLI returned invalid account context JSON: $($_.Exception.Message)"
    }

    if (-not $Account.id) {
        throw "Azure CLI account context does not contain a subscription ID."
    }

    if (
        -not [string]::IsNullOrWhiteSpace($ExpectedTenantId) -and
        $Account.tenantId -ne $ExpectedTenantId
    ) {
        throw "Azure CLI tenant '$($Account.tenantId)' does not match configured tenant '$ExpectedTenantId'."
    }

    return $Account
}


function Get-AutomationGraphAccessToken {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet("ClientSecret", "AzureCli")]
        [string]$AuthenticationMode,

        [Parameter(Mandatory)]
        [string]$TenantId,

        [Parameter(Mandatory)]
        [string]$AutomationClientId,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$AutomationClientSecret
    )

    Write-Host "Authenticating to Microsoft Graph using $AuthenticationMode..."

    if ($AuthenticationMode -eq "AzureCli") {

        $Result =
            Invoke-AzureCliCommand `
                -Arguments @(
                    "account", "get-access-token",
                    "--resource-type", "ms-graph",
                    "--query", "accessToken",
                    "--output", "tsv",
                    "--only-show-errors"
                )

        if ($Result.ExitCode -ne 0) {
            throw "Azure CLI failed to acquire a Microsoft Graph access token: $($Result.Output -join ' ')"
        }

        $AccessToken =
            ($Result.Output -join "").Trim()

        if ([string]::IsNullOrWhiteSpace($AccessToken)) {
            throw "Azure CLI did not return a Microsoft Graph access token."
        }

        Write-Host "Microsoft Graph authentication successful."
        Write-Host ""

        return $AccessToken
    }

    if ([string]::IsNullOrWhiteSpace($AutomationClientSecret)) {
        throw "ClientSecret authentication requires AUTOMATION_CLIENT_SECRET."
    }

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

Export-ModuleMember -Function `
    Get-AzureCliContext, `
    Get-AutomationGraphAccessToken
