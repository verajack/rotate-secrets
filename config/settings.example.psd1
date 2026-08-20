@{
    # Production recommendation: AzureCli
    #   - Azure-hosted runner: establish CLI context with `az login --identity`
    #   - GitHub Actions: azure/login with OIDC establishes the CLI context
    # Local/lab compatibility: ClientSecret
    AuthenticationMode      = "ClientSecret"

    # Environment-specific identifiers only. Do NOT put secret values here.
    TenantId                = "00000000-0000-0000-0000-000000000000"
    AutomationClientId      = "00000000-0000-0000-0000-000000000000"

    # Used when -ValidityMonths is not supplied on the command line.
    DefaultValidityMonths   = 24
}
