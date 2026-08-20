@{
    # Authentication modes:
    # - ClientSecret: local/lab fallback using AUTOMATION_CLIENT_SECRET.
    # - AzureCli: local/dev or federated CI identity already logged into az.
    # - ManagedIdentity: production Azure-hosted execution. The script runs
    #   `az login --identity` itself before requesting a Graph token.
    AuthenticationMode       = "ClientSecret"

    # Required in all modes so tokens and CLI context are tenant-scoped.
    TenantId                 = "00000000-0000-0000-0000-000000000000"

    # Required only for ClientSecret mode. Optional in AzureCli / ManagedIdentity.
    # Keeping this populated also protects against accidentally rotating that
    # App Registration if it appears in the customer input.
    AutomationClientId       = "00000000-0000-0000-0000-000000000000"

    # Optional. Leave blank for a system-assigned managed identity. Set the
    # CLIENT ID of a user-assigned managed identity to force that identity.
    ManagedIdentityClientId  = ""

    # Optional. Recommended when the managed identity can see more than one
    # subscription so Key Vault operations are deterministic.
    SubscriptionId           = ""

    # Used when -ValidityMonths is not supplied on the command line.
    DefaultValidityMonths    = 24
}
