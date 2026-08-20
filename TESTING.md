# Step 6 testing

## Goal

Keep the existing rotation transaction unchanged while supporting three explicit authentication modes:

- `ClientSecret`: local/lab fallback.
- `AzureCli`: local development or a federated CI identity already established in Azure CLI.
- `ManagedIdentity`: Azure-hosted production mode; the script explicitly runs `az login --identity`.

## Unit tests

Run:

```powershell
Invoke-Pester ./tests -Output Detailed
```

Step 6 adds Managed Identity login tests in addition to the existing authentication and rotation tests. These are mocked and do not log into Azure or change real credentials.

## Local regression test

Keep `AuthenticationMode = "AzureCli"` on the Mac and use the existing interactive `az login` only for the smoke test:

```powershell
./rotate_secrets_step6.ps1 `
    -Mode Rotate `
    -InputFile ./customers.csv `
    -WhatIf
```

This should behave like Step 5.

## Managed Identity mode

Do not test `AuthenticationMode = "ManagedIdentity"` on the Mac. `az login --identity` requires an Azure resource with an enabled managed identity.

Once an Azure host exists and permissions are bootstrapped, configure:

```powershell
AuthenticationMode      = "ManagedIdentity"
ManagedIdentityClientId = ""  # system-assigned, or UAMI client ID
SubscriptionId          = "<subscription-guid>"
```

Then run `-WhatIf` on that host first. A production Managed Identity test is complete only when:

1. Azure CLI reports the managed identity/service principal context.
2. Microsoft Graph authentication succeeds.
3. Customer app discovery succeeds.
4. Key Vault pre-flight succeeds on a real `Rotate -WhatIf`/controlled test.
5. No `AUTOMATION_CLIENT_SECRET` exists in the process environment.
