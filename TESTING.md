# Pester tests

These tests mock Microsoft Graph and Azure Key Vault operations. They do not create, update, or delete real Azure credentials or Key Vault secrets.

## Install Pester (if needed)

```powershell
Get-Module -ListAvailable Pester
```

If Pester 5 is not installed:

```powershell
Install-Module Pester -Scope CurrentUser -Force
```

## Run

From the repository root:

```powershell
Invoke-Pester ./tests/Rotation.Tests.ps1 -Output Detailed
```

Expected result: 6 tests passed, 0 failed.
