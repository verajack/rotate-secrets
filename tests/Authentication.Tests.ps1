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
                    -TenantId "11111111-1111-1111-1111-111111111111" `
                    -AutomationClientId "22222222-2222-2222-2222-222222222222"

            $Result | Should -Be "azure-cli-token"
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
                    -AuthenticationMode AzureCli `
                    -TenantId "11111111-1111-1111-1111-111111111111" `
                    -AutomationClientId "22222222-2222-2222-2222-222222222222"
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
