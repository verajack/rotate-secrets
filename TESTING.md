# Step 5 testing

## Goal

Support two authentication modes without changing the tested rotation transaction:

- `ClientSecret` for local/lab compatibility.
- `AzureCli` for production/workload identity. The Azure CLI context may be established by managed identity or OIDC/workload federation.

## Local regression test

Keep `AuthenticationMode = "ClientSecret"` in `config/settings.psd1`, load `AUTOMATION_CLIENT_SECRET`, then run:

```powershell
Invoke-Pester ./tests -Output Detailed

./rotate_secrets_step5.ps1 `
    -Mode Rotate `
    -InputFile ./customers.csv `
    -WhatIf
```

## Azure CLI identity test on the Mac

For a non-production smoke test, set `AuthenticationMode = "AzureCli"`. Your current `az login` user context will be used to obtain the Graph token. No `AUTOMATION_CLIENT_SECRET` is required.

```powershell
Remove-Item Env:AUTOMATION_CLIENT_SECRET -ErrorAction SilentlyContinue

./rotate_secrets_step5.ps1 `
    -Mode Rotate `
    -InputFile ./customers.csv `
    -WhatIf
```

This proves the code path, but a human `az login` is not the intended production identity.

## Production managed identity

On an Azure compute resource with a system-assigned managed identity:

```bash
az login --identity
```

For a user-assigned managed identity, use its client/object/resource ID with `az login --identity`.

Set `AuthenticationMode = "AzureCli"`. The script then gets its Microsoft Graph token from the authenticated Azure CLI context and uses the same CLI identity for Key Vault operations.
