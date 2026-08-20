BeforeAll {
    $ModulePath = Join-Path $PSScriptRoot "../modules/Authentication.psm1"
    Import-Module $ModulePath -Force
}

Describe "Get-AutomationGraphAccessToken" {

    It "returns a token using ClientSecret mode" {

        InModuleScope Authentication {

            Mock Invoke-RestMethod {
                [PSCustomObject]@{
                    access_token = "client-secret-token"
                }
            }

            $Result =
                Get-AutomationGraphAccessToken `
                    -AuthenticationMode ClientSecret `
                    -TenantId "11111111-1111-1111-1111-111111111111" `
                    -AutomationClientId "22222222-2222-2222-2222-222222222222" `
                    -AutomationClientSecret "test-secret"

            $Result | Should -Be "client-secret-token"
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly
        }
    }

    It "requires a secret in ClientSecret mode" {

        InModuleScope Authentication {

            {
                Get-AutomationGraphAccessToken `
                    -AuthenticationMode ClientSecret `
                    -TenantId "11111111-1111-1111-1111-111111111111" `
                    -AutomationClientId "22222222-2222-2222-2222-222222222222" `
                    -AutomationClientSecret $null
            } | Should -Throw "*requires AUTOMATION_CLIENT_SECRET*"
        }
    }

    It "returns the Azure CLI Microsoft Graph token in AzureCli mode" {

        InModuleScope Authentication {

            Mock Invoke-AzureCliCommand {
                [PSCustomObject]@{
                    ExitCode = 0
                    Output   = @("azure-cli-token")
                }
            }

            $Result =
                Get-AutomationGraphAccessToken `
                    -AuthenticationMode AzureCli `
                    -TenantId "11111111-1111-1111-1111-111111111111"

            $Result | Should -Be "azure-cli-token"
            Should -Invoke Invoke-AzureCliCommand -Times 1 -Exactly
        }
    }

    It "returns the Microsoft Graph token in ManagedIdentity mode after login has been established" {

        InModuleScope Authentication {

            Mock Invoke-AzureCliCommand {
                [PSCustomObject]@{
                    ExitCode = 0
                    Output   = @("managed-identity-token")
                }
            }

            $Result =
                Get-AutomationGraphAccessToken `
                    -AuthenticationMode ManagedIdentity `
                    -TenantId "11111111-1111-1111-1111-111111111111"

            $Result | Should -Be "managed-identity-token"
            Should -Invoke Invoke-AzureCliCommand -Times 1 -Exactly
        }
    }

    It "throws when Azure CLI token acquisition fails" {

        InModuleScope Authentication {

            Mock Invoke-AzureCliCommand {
                [PSCustomObject]@{
                    ExitCode = 1
                    Output   = @("simulated az failure")
                }
            }

            {
                Get-AutomationGraphAccessToken `
                    -AuthenticationMode ManagedIdentity `
                    -TenantId "11111111-1111-1111-1111-111111111111"
            } | Should -Throw "*failed to acquire a Microsoft Graph access token*"
        }
    }
}

Describe "Get-AzureCliContext" {

    It "returns the authenticated account when the tenant matches" {

        InModuleScope Authentication {

            Mock Invoke-AzureCliCommand {
                [PSCustomObject]@{
                    ExitCode = 0
                    Output   = @('{"id":"sub-1","name":"Subscription 1","tenantId":"11111111-1111-1111-1111-111111111111","user":{"type":"servicePrincipal"}}')
                }
            }

            $Result =
                Get-AzureCliContext `
                    -ExpectedTenantId "11111111-1111-1111-1111-111111111111"

            $Result.id | Should -Be "sub-1"
            $Result.user.type | Should -Be "servicePrincipal"
        }
    }

    It "rejects an Azure CLI context from the wrong tenant" {

        InModuleScope Authentication {

            Mock Invoke-AzureCliCommand {
                [PSCustomObject]@{
                    ExitCode = 0
                    Output   = @('{"id":"sub-1","name":"Subscription 1","tenantId":"33333333-3333-3333-3333-333333333333","user":{"type":"servicePrincipal"}}')
                }
            }

            {
                Get-AzureCliContext `
                    -ExpectedTenantId "11111111-1111-1111-1111-111111111111"
            } | Should -Throw "*does not match configured tenant*"
        }
    }
}

Describe "Connect-ManagedIdentityAzureCli" {

    It "logs in with the system-assigned identity when no client ID is configured" {

        InModuleScope Authentication {

            $script:Calls = @()

            Mock Invoke-AzureCliCommand {
                param($Arguments)
                $script:Calls += ,@($Arguments)

                if ($Arguments[0] -eq "login") {
                    return [PSCustomObject]@{ ExitCode = 0; Output = @() }
                }

                return [PSCustomObject]@{
                    ExitCode = 0
                    Output   = @('{"id":"sub-1","name":"Subscription 1","tenantId":"11111111-1111-1111-1111-111111111111","user":{"type":"servicePrincipal"}}')
                }
            }

            $Result =
                Connect-ManagedIdentityAzureCli `
                    -ExpectedTenantId "11111111-1111-1111-1111-111111111111"

            $Result.id | Should -Be "sub-1"
            $script:Calls[0] | Should -Contain "--identity"
            $script:Calls[0] | Should -Not -Contain "--client-id"
        }
    }

    It "selects a user-assigned managed identity by client ID" {

        InModuleScope Authentication {

            $script:Calls = @()

            Mock Invoke-AzureCliCommand {
                param($Arguments)
                $script:Calls += ,@($Arguments)

                if ($Arguments[0] -eq "login") {
                    return [PSCustomObject]@{ ExitCode = 0; Output = @() }
                }

                return [PSCustomObject]@{
                    ExitCode = 0
                    Output   = @('{"id":"sub-1","name":"Subscription 1","tenantId":"11111111-1111-1111-1111-111111111111","user":{"type":"servicePrincipal"}}')
                }
            }

            $Result =
                Connect-ManagedIdentityAzureCli `
                    -ExpectedTenantId "11111111-1111-1111-1111-111111111111" `
                    -ManagedIdentityClientId "44444444-4444-4444-4444-444444444444"

            $Result.id | Should -Be "sub-1"
            $script:Calls[0] | Should -Contain "--client-id"
            $script:Calls[0] | Should -Contain "44444444-4444-4444-4444-444444444444"
        }
    }

    It "sets an explicit subscription after managed identity login" {

        InModuleScope Authentication {

            $script:Calls = @()

            Mock Invoke-AzureCliCommand {
                param($Arguments)
                $script:Calls += ,@($Arguments)

                if ($Arguments[0] -eq "account" -and $Arguments[1] -eq "show") {
                    return [PSCustomObject]@{
                        ExitCode = 0
                        Output   = @('{"id":"55555555-5555-5555-5555-555555555555","name":"Subscription 1","tenantId":"11111111-1111-1111-1111-111111111111","user":{"type":"servicePrincipal"}}')
                    }
                }

                return [PSCustomObject]@{ ExitCode = 0; Output = @() }
            }

            $null =
                Connect-ManagedIdentityAzureCli `
                    -ExpectedTenantId "11111111-1111-1111-1111-111111111111" `
                    -SubscriptionId "55555555-5555-5555-5555-555555555555"

            Should -Invoke Invoke-AzureCliCommand `
                -Times 1 `
                -Exactly `
                -ParameterFilter {
                    $Arguments[0] -eq "account" -and
                    $Arguments[1] -eq "set" -and
                    $Arguments -contains "55555555-5555-5555-5555-555555555555"
                }
        }
    }

    It "throws when managed identity login fails" {

        InModuleScope Authentication {

            Mock Invoke-AzureCliCommand {
                [PSCustomObject]@{
                    ExitCode = 1
                    Output   = @("identity endpoint unavailable")
                }
            }

            {
                Connect-ManagedIdentityAzureCli `
                    -ExpectedTenantId "11111111-1111-1111-1111-111111111111"
            } | Should -Throw "*Managed Identity Azure CLI login failed*"
        }
    }
}
