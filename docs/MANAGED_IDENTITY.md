# Managed identity / workload identity design

## Runtime model

The production script uses `AuthenticationMode = "AzureCli"`.

The Azure CLI context must be established before the script starts:

- Azure-hosted system-assigned managed identity: `az login --identity`
- Azure-hosted user-assigned managed identity: `az login --identity --client-id <client-id>`
- GitHub Actions: use `azure/login` with OIDC/workload federation

The script calls `az account get-access-token --resource-type ms-graph` for Microsoft Graph and uses the same Azure CLI context for Key Vault.

## Microsoft Graph permission

For `application/addPassword` and `application/removePassword`, Microsoft Graph supports:

- `Application.ReadWrite.OwnedBy` as the least-privileged application permission when the automation identity owns the target applications.
- `Application.ReadWrite.All` if the identity must manage applications it does not own.

Prefer `Application.ReadWrite.OwnedBy` where operationally feasible.

## Key Vault authorization

The runtime identity must be able to:

- access the vault metadata used by the current pre-flight check;
- set a secret value;
- read secret metadata for verification.

Scope those permissions to the required vault(s), not the whole subscription where possible.

## Production note

`AUTOMATION_CLIENT_SECRET` is not required in `AzureCli` mode. Keep `ClientSecret` mode only as a transitional/local development path until the production host and identity are finalized.
