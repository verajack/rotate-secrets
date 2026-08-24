[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "High")]
param(
    [Parameter(Mandatory = $false)]
    [string]$ManifestFile = "./prod-mimic-manifest.json",

    [Parameter(Mandatory = $false)]
    [switch]$RemoveLocalFiles,

    [Parameter(Mandatory = $false)]
    [switch]$PurgeDeletedVaults
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI ('az') is not installed or not on PATH."
}

if (-not (Test-Path $ManifestFile)) {
    throw "Manifest file not found: $ManifestFile"
}

$Manifest = Get-Content $ManifestFile -Raw | ConvertFrom-Json
$Customers = @($Manifest.Customers)
$ResourceGroupName = "$($Manifest.ResourceGroupName)"
$Location = "$($Manifest.Location)"

$CurrentAccount = az account show --output json --only-show-errors | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) {
    throw "Azure CLI is not authenticated."
}

if ("$($CurrentAccount.id)" -ne "$($Manifest.SubscriptionId)") {
    throw "Current Azure subscription '$($CurrentAccount.id)' does not match manifest subscription '$($Manifest.SubscriptionId)'."
}
if ("$($CurrentAccount.tenantId)" -ne "$($Manifest.TenantId)") {
    throw "Current Azure tenant '$($CurrentAccount.tenantId)' does not match manifest tenant '$($Manifest.TenantId)'."
}

Write-Host ""
Write-Host "================================================"
Write-Host " PROD-MIMIC LAB CLEANUP"
Write-Host "================================================"
Write-Host ""
Write-Host "Customers/apps:   $($Customers.Count)"
Write-Host "Resource group:   $ResourceGroupName"
Write-Host "Subscription:     $($Manifest.SubscriptionName)"
Write-Host "Purge vaults:     $PurgeDeletedVaults"
Write-Host ""

$Target = "$($Customers.Count) App Registrations and resource group '$ResourceGroupName'"
if (-not $PSCmdlet.ShouldProcess($Target, "Delete prod-mimic lab")) {
    return
}

$AppFailures = [System.Collections.Generic.List[object]]::new()

for ($i = 0; $i -lt $Customers.Count; $i++) {
    $Customer = $Customers[$i]
    Write-Progress `
        -Activity "Deleting prod-mimic App Registrations" `
        -Status "$($Customer.CustomerName) ($($i + 1) of $($Customers.Count))" `
        -PercentComplete ((($i + 1) / [Math]::Max($Customers.Count, 1)) * 100)

    try {
        & az ad app delete --id "$($Customer.ApplicationId)" --only-show-errors
        if ($LASTEXITCODE -ne 0) {
            throw "az ad app delete returned exit code $LASTEXITCODE"
        }
    }
    catch {
        $AppFailures.Add([PSCustomObject]@{
            CustomerName  = $Customer.CustomerName
            ApplicationId = $Customer.ApplicationId
            Error         = $_.Exception.Message
        }) | Out-Null
    }
}
Write-Progress -Activity "Deleting prod-mimic App Registrations" -Completed

Write-Host "Deleting resource group '$ResourceGroupName' (this can take several minutes)..."
& az group delete --name $ResourceGroupName --yes --only-show-errors
if ($LASTEXITCODE -ne 0) {
    Write-Warning "Resource group deletion returned exit code $LASTEXITCODE. Check the Azure portal."
}

if ($PurgeDeletedVaults) {
    Write-Host ""
    Write-Host "Attempting to purge soft-deleted Key Vaults..."

    foreach ($Customer in $Customers) {
        $VaultName = "$($Customer.KeyVaultName)"
        try {
            & az keyvault purge `
                --name $VaultName `
                --location $Location `
                --only-show-errors 2>$null

            if ($LASTEXITCODE -ne 0) {
                Write-Warning "Could not purge '$VaultName'. It may still be deleting, or purge permission may be unavailable."
            }
        }
        catch {
            Write-Warning "Could not purge '$VaultName': $($_.Exception.Message)"
        }
    }
}

if ($RemoveLocalFiles) {
    $ManifestPath = (Resolve-Path $ManifestFile).Path
    $ManifestDirectory = Split-Path $ManifestPath -Parent
    $CustomerCsv = Join-Path $ManifestDirectory "customers-prod-mimic.csv"

    if (Test-Path $CustomerCsv) {
        Remove-Item $CustomerCsv -Force
    }

    Remove-Item $ManifestPath -Force
}

Write-Host ""
Write-Host "================================================"
Write-Host " CLEANUP COMPLETE"
Write-Host "================================================"
Write-Host ""
Write-Host "App deletion failures: $($AppFailures.Count)"
if ($AppFailures.Count -gt 0) {
    $AppFailures | Format-Table -AutoSize
}
Write-Host ""
