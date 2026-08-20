BeforeAll {
    $ModulePath = Join-Path $PSScriptRoot "../modules/Rotation.psm1"
    Import-Module $ModulePath -Force
}

Describe "Invoke-SecretRotationTransaction" {

    InModuleScope Rotation {

        BeforeEach {
            $Application = [PSCustomObject]@{
                id          = "application-object-id"
                appId       = "application-client-id"
                displayName = "CustomerAppLab"
            }

            $GraphHeaders = @{
                Authorization  = "Bearer test-token"
                "Content-Type" = "application/json"
            }

            $Credential = [PSCustomObject]@{
                displayName = "rotation-test"
                keyId       = "new-key-id"
                secretText  = "test-secret-value"
                endDateTime = "2028-08-20T19:30:32Z"
            }

            $Metadata = [PSCustomObject]@{
                name    = "CustomerAppLab-ClientSecret"
                enabled = $true
                updated = "2026-08-20T19:30:33Z"
            }

            Mock Test-KeyVaultExists { $true }
            Mock New-AppRegistrationSecret { $Credential }
            Mock Set-CustomerKeyVaultSecret { [PSCustomObject]@{ name = "CustomerAppLab-ClientSecret" } }
            Mock Get-KeyVaultSecretMetadata { $Metadata }
            Mock Remove-AppRegistrationSecret { }
        }

        It "returns success when credential creation, Key Vault write, and verification succeed" {
            $Result = Invoke-SecretRotationTransaction `
                -Application $Application `
                -CustomerName "CustomerAppLab" `
                -KeyVaultName "test-vault" `
                -KeyVaultSecretName "CustomerAppLab-ClientSecret" `
                -GraphHeaders $GraphHeaders `
                -ValidityMonths 24

            $Result.Success | Should -BeTrue
            $Result.CredentialKeyId | Should -Be "new-key-id"
            $Result.KeyVaultWriteSucceeded | Should -BeTrue
            $Result.RollbackStatus | Should -Be "NotRequired"
            $Result.Metadata.name | Should -Be "CustomerAppLab-ClientSecret"

            Should -Invoke New-AppRegistrationSecret -Times 1 -Exactly
            Should -Invoke Set-CustomerKeyVaultSecret -Times 1 -Exactly
            Should -Invoke Get-KeyVaultSecretMetadata -Times 1 -Exactly
            Should -Invoke Remove-AppRegistrationSecret -Times 0 -Exactly
        }

        It "rolls back the new Entra credential when the Key Vault write fails" {
            Mock Set-CustomerKeyVaultSecret { throw "simulated Key Vault write failure" }

            $Result = Invoke-SecretRotationTransaction `
                -Application $Application `
                -CustomerName "CustomerAppLab" `
                -KeyVaultName "test-vault" `
                -KeyVaultSecretName "CustomerAppLab-ClientSecret" `
                -GraphHeaders $GraphHeaders `
                -ValidityMonths 24

            $Result.Success | Should -BeFalse
            $Result.CredentialKeyId | Should -Be "new-key-id"
            $Result.KeyVaultWriteSucceeded | Should -BeFalse
            $Result.RollbackStatus | Should -Be "Succeeded"
            $Result.Message | Should -Match "simulated Key Vault write failure"
            $Result.Message | Should -Match "Automatic rollback removed credential"

            Should -Invoke Remove-AppRegistrationSecret -Times 1 -Exactly -ParameterFilter {
                $ObjectId -eq "application-object-id" -and $KeyId -eq "new-key-id"
            }
            Should -Invoke Get-KeyVaultSecretMetadata -Times 0 -Exactly
        }

        It "returns a manual-cleanup failure when rollback itself fails" {
            Mock Set-CustomerKeyVaultSecret { throw "simulated Key Vault write failure" }
            Mock Remove-AppRegistrationSecret { throw "simulated rollback failure" }

            $Result = Invoke-SecretRotationTransaction `
                -Application $Application `
                -CustomerName "CustomerAppLab" `
                -KeyVaultName "test-vault" `
                -KeyVaultSecretName "CustomerAppLab-ClientSecret" `
                -GraphHeaders $GraphHeaders `
                -ValidityMonths 24

            $Result.Success | Should -BeFalse
            $Result.KeyVaultWriteSucceeded | Should -BeFalse
            $Result.RollbackStatus | Should -Be "Failed"
            $Result.Message | Should -Match "Automatic rollback FAILED"
            $Result.Message | Should -Match "simulated rollback failure"

            Should -Invoke Remove-AppRegistrationSecret -Times 1 -Exactly
        }

        It "retains the new credential when Key Vault write succeeds but metadata verification fails" {
            Mock Get-KeyVaultSecretMetadata { throw "simulated metadata verification failure" }

            $Result = Invoke-SecretRotationTransaction `
                -Application $Application `
                -CustomerName "CustomerAppLab" `
                -KeyVaultName "test-vault" `
                -KeyVaultSecretName "CustomerAppLab-ClientSecret" `
                -GraphHeaders $GraphHeaders `
                -ValidityMonths 24

            $Result.Success | Should -BeFalse
            $Result.CredentialKeyId | Should -Be "new-key-id"
            $Result.KeyVaultWriteSucceeded | Should -BeTrue
            $Result.RollbackStatus | Should -Be "CredentialRetained"
            $Result.Message | Should -Match "simulated metadata verification failure"

            Should -Invoke Set-CustomerKeyVaultSecret -Times 1 -Exactly
            Should -Invoke Remove-AppRegistrationSecret -Times 0 -Exactly
        }

        It "does not create a credential when Key Vault is inaccessible" {
            Mock Test-KeyVaultExists { $false }

            $Result = Invoke-SecretRotationTransaction `
                -Application $Application `
                -CustomerName "CustomerAppLab" `
                -KeyVaultName "missing-vault" `
                -KeyVaultSecretName "CustomerAppLab-ClientSecret" `
                -GraphHeaders $GraphHeaders `
                -ValidityMonths 24

            $Result.Success | Should -BeFalse
            $Result.CredentialKeyId | Should -Be ""
            $Result.KeyVaultWriteSucceeded | Should -BeFalse
            $Result.RollbackStatus | Should -Be "NotRequired"
            $Result.Message | Should -Match "is not accessible"

            Should -Invoke New-AppRegistrationSecret -Times 0 -Exactly
            Should -Invoke Set-CustomerKeyVaultSecret -Times 0 -Exactly
            Should -Invoke Remove-AppRegistrationSecret -Times 0 -Exactly
        }

        It "does not attempt rollback when Graph credential creation fails before a credential exists" {
            Mock New-AppRegistrationSecret { throw "simulated Graph creation failure" }

            $Result = Invoke-SecretRotationTransaction `
                -Application $Application `
                -CustomerName "CustomerAppLab" `
                -KeyVaultName "test-vault" `
                -KeyVaultSecretName "CustomerAppLab-ClientSecret" `
                -GraphHeaders $GraphHeaders `
                -ValidityMonths 24

            $Result.Success | Should -BeFalse
            $Result.CredentialKeyId | Should -Be ""
            $Result.KeyVaultWriteSucceeded | Should -BeFalse
            $Result.RollbackStatus | Should -Be "NotRequired"
            $Result.Message | Should -Match "simulated Graph creation failure"

            Should -Invoke Remove-AppRegistrationSecret -Times 0 -Exactly
            Should -Invoke Set-CustomerKeyVaultSecret -Times 0 -Exactly
        }
    }
}
