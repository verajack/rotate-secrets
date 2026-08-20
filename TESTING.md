# Step 4 - External configuration

This step removes environment-specific Tenant ID and automation App ID values from the script.
No secret values are stored in the settings file.

## Setup

Copy the example settings file:

```powershell
Copy-Item ./config/settings.example.psd1 ./config/settings.psd1
```

Edit `config/settings.psd1` and set the lab values for `TenantId` and `AutomationClientId`.
Keep `config/settings.psd1` out of Git. Add the supplied ignore snippet to your existing `.gitignore`.

The automation secret is still supplied through:

```powershell
$env:AUTOMATION_CLIENT_SECRET
```

Optional environment overrides are also supported:

```powershell
$env:AZURE_TENANT_ID
$env:AUTOMATION_CLIENT_ID
```

They override the corresponding values in `settings.psd1`.

## Unit tests

```powershell
Invoke-Pester ./tests/Rotation.Tests.ps1 -Output Detailed
```

Expected: 6 passed, 0 failed.

## Safe behaviour check

```powershell
./rotate_secrets_step4.ps1 `
    -Mode Rotate `
    -InputFile ./customers.csv `
    -WhatIf
```

No Azure credential or Key Vault secret should be changed in `-WhatIf` mode.
