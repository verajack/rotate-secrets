# Managed Identity production design

## Why this mode exists

`AuthenticationMode = "ManagedIdentity"` is the intended Azure-hosted production mode.

It differs deliberately from `AzureCli`:

- `AzureCli` reuses an identity that was already logged into Azure CLI. This is convenient for local development and CI/workload federation.
- `ManagedIdentity` explicitly executes `az login --identity` before doing anything else. This prevents a production host from accidentally reusing a cached human login.

No `AUTOMATION_CLIENT_SECRET` is used in ManagedIdentity mode.

## System-assigned vs user-assigned

For a system-assigned managed identity, leave `ManagedIdentityClientId` empty.

For a user-assigned managed identity, set `ManagedIdentityClientId` to the identity's client ID. The script then executes the equivalent of:

```bash
az login --identity --client-id <managed-identity-client-id>
```

Set `SubscriptionId` when the identity can see multiple subscriptions so Key Vault operations are deterministic.

## Microsoft Graph permission

The rotation workflow calls `application/addPassword` and `application/removePassword`.

Least privilege for application authentication is `Application.ReadWrite.OwnedBy` when the managed identity's service principal is an owner of each target App Registration. `Application.ReadWrite.All` is broader and should only be used if the identity must manage applications it does not own.

`Application.ReadWrite.OwnedBy` requires admin consent. Ownership is a separate one-time bootstrap action; another service principal can be an application owner.

### Bootstrap outline

An administrator must perform these steps outside the rotation runtime:

1. Enable/create the managed identity on the chosen Azure host.
2. Grant the managed identity's service principal the Microsoft Graph application role `Application.ReadWrite.OwnedBy` (or, if unavoidable, `Application.ReadWrite.All`).
3. Add the managed identity service principal as an owner of every target application when using `Application.ReadWrite.OwnedBy`.
4. Grant Key Vault data-plane permission at the narrowest practical scope.

Do not give the runtime identity permission to grant itself Graph permissions or owners. Bootstrap privileges such as `AppRoleAssignment.ReadWrite.All` are administrative and should not be present on the runtime identity.

## Key Vault authorization

The current workflow needs to check the vault, write a new secret version and read secret metadata. For Azure RBAC vaults, `Key Vault Secrets Officer` provides the required secret data-plane capabilities (but is still broader than a custom role tailored to only the required data actions).

The current pre-flight check also calls `az keyvault show`, which is a management-plane read. Until that pre-flight is changed to a data-plane-only check, the runtime identity also needs a narrow Azure `Reader` assignment on the vault resource (or equivalent custom management-plane read permission).

Prefer assigning both roles at the required vault scope rather than subscription scope. If the production design has one vault per security boundary, vault-level assignment is usually clearer than subscription-wide access.

## Expected production flow

```text
Azure host
   |
   | az login --identity
   v
Managed Identity
   |------------------------------|
   v                              v
Microsoft Graph                Azure Key Vault
add/remove app password        set/read metadata
```

The generated customer secret exists in plaintext only in process memory long enough to write it to Key Vault. It must never be logged or committed.
