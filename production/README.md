# App Registration Secret Rotation – Operator Guide

## Purpose

`rotate_secrets.ps1` is an **operator-run bulk secret rotation tool** for Microsoft Entra App Registrations.

It is designed to replace the time-consuming process of manually rotating client secrets customer-by-customer.

The operator can first use `build_rotation_input.ps1` to discover App Registrations with credentials approaching expiry and generate the rotation input CSV. The rotation tool can then work through that approved list and:

1. Discover each App Registration.
2. Create a replacement client secret.
3. Store the new secret value in the correct Azure Key Vault.
4. Record the exact old and new credential Key IDs.
5. Validate that the new Key Vault secret actually works.
6. Retire only the exact previous credential(s) associated with the rotation.
7. Continue processing remaining customers if an individual customer fails.
8. Produce detailed audit and batch-summary logs.

This is an **ad-hoc operator tool**. It is not scheduled and does not automatically rotate credentials without an operator initiating the process.

---

# 1. Production Package

The clean production package should contain:

```text
production/
├── rotate_secrets.ps1
├── build_rotation_input.ps1
└── README.md
```

Older development scripts, test harnesses, backups and lab-only files should not be used as the production working copy.

Recommended source of truth:

```text
GitHub repository
        ↓
persistent Cloud Shell working copy
        ↓
~/clouddrive/azure-secret-rotation/production
```

---

# 2. Recommended Operator Workflow

The normal workflow is:

```text
build_rotation_input.ps1
        ↓
review generated CSV
        ↓
DISCOVER
        ↓
ROTATE -WHATIF
        ↓
ROTATE
        ↓
VALIDATE
        ↓
REVIEW RESULTS
        ↓
RETIRE -WHATIF
        ↓
RETIRE
```

Do not skip directly from Rotate to Retire.

---

# 3. Cloud Shell Setup

## Persistent storage

Cloud Shell itself is temporary, so keep the working copy under the persistent Azure Files-backed `clouddrive`.

Example:

```powershell
cd ~/clouddrive
```

Clone the production branch:

```powershell
git clone https://github.com/verajack/rotate-secrets.git azure-secret-rotation
cd azure-secret-rotation
git checkout feature/batch-processing
git pull
cd production
```

The working directory should then contain:

```text
rotate_secrets.ps1
build_rotation_input.ps1
README.md
```

## Confirm current Azure context

Before a production run:

```powershell
az account show
```

Check:

- tenant
- subscription
- signed-in identity

If required:

```powershell
az login
```

Never proceed with customer changes until the displayed tenant/subscription are confirmed.

---

# 4. Microsoft Graph Authentication

The scripts use the configured automation App Registration to authenticate to Microsoft Graph.

The current scripts first look for:

```powershell
$env:AUTOMATION_CLIENT_SECRET
```

On macOS there is a Keychain fallback, but that does **not** apply to Cloud Shell.

Therefore, in Cloud Shell, the automation secret must be injected securely into the session before the scripts are run.

Do **not**:

- hard-code the secret in the script
- put the secret in `customers.csv`
- commit the secret to Git
- echo the secret to the terminal
- put the secret directly into shell-history commands

Where possible, retrieve it securely from an approved secret store and assign it to:

```powershell
$env:AUTOMATION_CLIENT_SECRET
```

After the session ends, the environment variable is lost.

---

# 5. Building the Rotation Input Automatically

Use:

```text
build_rotation_input.ps1
```

to discover App Registrations with credentials approaching expiry.

Example – credentials expiring within 30 days:

```powershell
./build_rotation_input.ps1 `
    -ExpiresWithinDays 30 `
    -OutputFile ./customers-generated.csv
```

Example – credentials expiring on or before a specific date:

```powershell
./build_rotation_input.ps1 `
    -ExpiresOnOrBefore "2026-08-28" `
    -OutputFile ./customers-generated.csv
```

The builder:

- reads App Registration credential metadata from Microsoft Graph
- identifies credentials in the requested expiry window
- scans accessible Key Vault secret metadata
- attempts to map each App Registration to one exact Key Vault secret
- does **not** read Key Vault secret values
- generates an input CSV for review

Typical output columns include:

```text
CustomerName
ApplicationId
KeyVaultName
KeyVaultSecretName
Enabled
CredentialExpiryUtc
ExpiringCredentialName
ExpiringCredentialKeyId
ExpiringCredentialCount
MappingStatus
MappingSource
```

---

# 6. First-Run / Bootstrap Mapping

The first production run may require a one-time manual mapping step.

Microsoft Entra does not inherently know:

```text
App Registration
      ↓
which Key Vault
      ↓
which Key Vault secret
```

If the production estate has never previously been managed by this rotation tool, some existing Key Vault secrets may not contain enough metadata for automatic mapping.

In that situation the builder should leave the row disabled, for example:

```csv
CustomerName,ApplicationId,KeyVaultName,KeyVaultSecretName,Enabled
CouncilA,11111111-1111-1111-1111-111111111111,,,false
```

The operator should supply only the missing relationship:

```text
KeyVaultName
KeyVaultSecretName
```

and then change:

```text
Enabled=false
```

to:

```text
Enabled=true
```

after reviewing the mapping.

Do not guess the Key Vault relationship.

## Why future runs are easier

Once the current rotation script successfully rotates a customer, it records metadata on the Key Vault secret including the current credential Key ID and previous credential Key IDs.

That gives future runs a reliable relationship between:

```text
App Registration
        ↕
exact credential Key ID
        ↕
Key Vault secret
```

As a result, customers already managed by the tool can normally be rediscovered and mapped automatically on later runs.

---

# 7. Rotation CSV

The rotation script requires these core columns:

```csv
CustomerName,ApplicationId,KeyVaultName,KeyVaultSecretName,Enabled
```

Example:

```csv
CustomerName,ApplicationId,KeyVaultName,KeyVaultSecretName,Enabled
CustomerA,11111111-1111-1111-1111-111111111111,customer-a-kv,CustomerA-ClientSecret,true
CustomerB,22222222-2222-2222-2222-222222222222,customer-b-kv,CustomerB-ClientSecret,true
CustomerC,33333333-3333-3333-3333-333333333333,customer-c-kv,CustomerC-ClientSecret,false
```

`Enabled` determines whether the row is processed.

Supported enabled values include:

```text
true
yes
1
```

Disabled customers remain visible in the batch results but are not changed.

---

# 8. CSV Preflight Safety Checks

Before customer operations begin, the script validates the entire input file.

The whole batch is rejected if it detects an unsafe input configuration.

Checks include:

- required CSV columns
- missing customer values
- invalid Application IDs
- invalid `Enabled` values
- automation App Registration accidentally included as a customer target
- duplicate enabled Application IDs
- duplicate enabled Key Vault secret destinations

Example:

```text
CSV preflight failed.
Duplicate enabled ApplicationId entries detected.
No customer operations were started.
```

This is intentional.

A dangerous batch-level input problem must be corrected before any customer changes begin.

---

# 9. Individual Customer Failures

Once CSV preflight succeeds, customers are processed independently.

A problem with one customer does **not** stop the remaining customers.

Example:

```text
CustomerA         Rotate      SUCCESS
CustomerB         Rotate      FAILED
CustomerC         Rotate      SUCCESS
CustomerD         Rotate      DISABLED
```

The script continues and reports failed customers separately at the end.

---

# 10. Stage 1 – Discover

Run Discover first:

```powershell
./rotate_secrets.ps1 `
    -Mode Discover `
    -InputFile ./customers-generated.csv
```

Discover does not create or delete credentials.

For each enabled customer it shows:

- App Registration name
- Application / Client ID
- Object ID
- existing credentials
- start dates
- expiry dates

Review all failures before progressing.

---

# 11. Stage 2 – Rotate Dry Run

Always preview the production batch:

```powershell
./rotate_secrets.ps1 `
    -Mode Rotate `
    -InputFile ./customers-generated.csv `
    -WhatIf
```

Expected:

```text
CSV preflight: PASSED
```

and proposed actions such as:

```text
What if: Performing the operation
"Create a new App Registration client secret and apply it to Key Vault"
```

No App Registration credentials or Key Vault values are changed during `-WhatIf`.

Review the full output before running Rotate for real.

---

# 12. Stage 3 – Rotate

After reviewing the dry run:

```powershell
./rotate_secrets.ps1 `
    -Mode Rotate `
    -InputFile ./customers-generated.csv
```

For the first production runs, leave confirmation prompts enabled.

For a fully reviewed larger batch:

```powershell
./rotate_secrets.ps1 `
    -Mode Rotate `
    -InputFile ./customers-generated.csv `
    -Confirm:$false
```

Use `-Confirm:$false` only after reviewing the `-WhatIf` results.

## Rotate performs the following

For each enabled customer:

1. Finds the exact App Registration by Application ID.
2. Checks the Key Vault is accessible.
3. Records the existing credential Key IDs.
4. Creates a new App Registration client secret.
5. Applies the configured secret lifetime, normally 24 months.
6. Adjusts the calculated expiry to avoid an undesirable Friday/weekend expiry where the current script's expiry policy requires it.
7. Writes the new secret value to the correct Key Vault secret.
8. Stores metadata linking Key Vault to the exact new Entra credential.
9. Stores the exact previous credential Key ID(s) associated with the rotation.
10. Verifies the Key Vault metadata.
11. Adds the outcome to the audit and batch summary.

The client-secret value is never written to the normal console output or audit CSV.

---

# 13. Secret Lifetime and Expiry Placement

The normal replacement lifetime is:

```text
24 months
```

The intent is not merely to extend the secret, but also to avoid creating another operationally awkward expiry date.

The current rotation version includes logic to avoid a replacement credential deliberately expiring on Friday/weekend where applicable.

Always confirm the production organisation's required secret lifetime and expiry-day policy before running a real customer batch.

---

# 14. Exact Credential Tracking

Retirement does **not** rely on credential names such as:

```text
rotation-*
```

Existing production credentials can have arbitrary names.

Instead, Rotate records exact Key IDs.

Conceptually:

```text
Before rotation

Credential A
Key ID: AAAA
        │
        ▼
ROTATE
        │
        ├── record AAAA as previous credential
        │
        ├── create Credential B
        │   Key ID: BBBB
        │
        └── update Key Vault
             │
             ├── current Key ID = BBBB
             └── previous Key ID = AAAA
```

Retire later protects:

```text
BBBB
```

and can remove only the specifically recorded:

```text
AAAA
```

Unrelated credentials are not selected for retirement merely because they are old or have a particular name.

---

# 15. Old Credential Remains After Rotate

Rotate deliberately leaves the previous credential in place.

Immediately after rotation an App Registration may temporarily have:

```text
OLD credential
    +
NEW credential
```

Example:

```text
legacy-expiry-20260828      28/08/2026
rotation-20260824-191324    24/08/2028
```

This is expected.

The Entra portal may continue showing:

```text
Expiring soon
```

while the old expiring credential remains present.

Do not manually delete it at this point.

---

# 16. Stage 4 – Validate

After Rotate:

```powershell
./rotate_secrets.ps1 `
    -Mode Validate `
    -InputFile ./customers-generated.csv
```

Validate:

1. locates the App Registration
2. checks the Key Vault
3. retrieves the current Key Vault secret securely
4. authenticates using that secret
5. checks that the Key Vault metadata maps to one exact current Entra credential
6. confirms the Key ID mapping
7. reports success/failure

Successful output includes:

```text
Credential mapping verified:

Credential: rotation-YYYYMMDD-HHMMSS
Key ID:     xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx

VALIDATION SUCCESSFUL
```

This proves:

```text
Key Vault value
      ↓
actually authenticates
      ↓
as the intended App Registration
      ↓
and maps to the exact current credential
```

Do not retire a previous credential for a customer that has failed validation.

---

# 17. Stage 5 – Retire Dry Run

After successful validation:

```powershell
./rotate_secrets.ps1 `
    -Mode Retire `
    -InputFile ./customers-generated.csv `
    -WhatIf
```

Retire performs its own safety validation before any deletion.

Expected output:

```text
Protected current credential:

Credential: rotation-...
Key ID:     <CURRENT KEY ID>

Current Key Vault credential authentication verified.

Retirement candidates (exact mapped Key IDs only):

<OLD CREDENTIAL>
<OLD KEY ID>
```

Review the result carefully.

The protected current Key ID must never appear as a retirement candidate.

---

# 18. Stage 6 – Retire

Once `Retire -WhatIf` has been reviewed:

```powershell
./rotate_secrets.ps1 `
    -Mode Retire `
    -InputFile ./customers-generated.csv
```

For an already reviewed bulk batch:

```powershell
./rotate_secrets.ps1 `
    -Mode Retire `
    -InputFile ./customers-generated.csv `
    -Confirm:$false
```

Before deletion for each customer, Retire:

1. reads the current Key Vault metadata
2. identifies and protects the exact current credential
3. retrieves the current Key Vault secret
4. authenticates with it again
5. locates only the exact mapped previous Key ID(s)
6. removes those mapped previous credentials
7. records the result

---

# 19. Verification After Retirement

For an independent verification:

```powershell
$customers = Import-Csv ./customers-generated.csv

foreach ($customer in $customers) {

    if ($customer.Enabled -notmatch "^(true|yes|1)$") {
        continue
    }

    Write-Host ""
    Write-Host "===== $($customer.CustomerName) ====="

    az ad app credential list `
        --id $customer.ApplicationId `
        --query "[].{Name:displayName,Expires:endDateTime,KeyId:keyId}" `
        -o table
}
```

After successful retirement, the unwanted old expiring credential should be gone.

---

# 20. Batch Results

Each run prints a per-customer result table.

Example:

```text
Customer       Stage      Status      Details
--------       -----      ------      -------
CustomerA      Rotate     SUCCESS     New credential created and applied
CustomerB      Rotate     FAILED      Key Vault inaccessible
CustomerC      Rotate     SUCCESS     New credential created and applied
CustomerD      Rotate     DISABLED    Disabled in input file
```

The summary includes totals such as:

```text
Customers supplied:   100
Enabled:                98
Disabled:                2
Successful:             96
Warnings:                0
Failed:                  2
WhatIf:                  0
Skipped:                 0
```

Failed customers are listed separately with the reason.

---

# 21. Audit Files

Each rotation run creates files under:

```text
./logs/
```

Typical files:

```text
rotation-YYYYMMDD-HHMMSS.csv
summary-YYYYMMDD-HHMMSS.csv
```

The detailed audit log records:

- timestamp
- customer
- Application ID
- Key Vault
- action
- status
- credential Key ID
- message

The summary CSV records the per-customer outcome.

Client-secret values must not appear in these files.

---

# 22. Lab / Bootstrap Utilities

Lab-only utilities may exist in the repository under:

```text
tools/lab/
```

Examples include:

```text
setup_prod_mimic_100.ps1
cleanup_prod_mimic_100.ps1
backfill_prod_mimic_previous_ids.ps1
```

These are not part of the normal production operator workflow.

Do not use lab/backfill utilities casually against production.

---

# 23. Production Rollout Recommendation

The tool has been functionally proven in a production-mimic environment, but first production use should remain controlled.

Recommended progression:

```text
Lab proven
    ↓
Peer/code review
    ↓
1–5 low-risk real customers
    ↓
Review audit + validation results
    ↓
Small production batch
    ↓
Full approved batch
```

For the initial production pilot:

- keep confirmation prompts enabled
- use a reviewed customer list
- run Discover first
- run Rotate with `-WhatIf`
- validate every replacement
- run Retire with `-WhatIf`
- independently verify the first few customers afterwards

---

# 24. First-Time Production Checklist

## Build Input

- [ ] Confirm Cloud Shell is using persistent `clouddrive`.
- [ ] Confirm the production scripts are the current Git versions.
- [ ] Confirm Graph authentication is configured.
- [ ] Confirm Azure CLI tenant/subscription.
- [ ] Run `build_rotation_input.ps1`.
- [ ] Review all `Mapped`, `NotFound` and `Ambiguous` rows.
- [ ] For first-run unmapped customers, fill in `KeyVaultName` and `KeyVaultSecretName` manually.
- [ ] Set `Enabled=true` only after the mapping is confirmed.

## Discover

- [ ] Run Discover.
- [ ] Review App Registration names and credential expiry dates.
- [ ] Investigate any failures.

## Rotate

- [ ] Run Rotate with `-WhatIf`.
- [ ] Review all targets.
- [ ] Run Rotate.
- [ ] Review the batch summary.
- [ ] Do not manually remove old credentials.

## Validate

- [ ] Run Validate.
- [ ] Confirm `VALIDATION SUCCESSFUL`.
- [ ] Confirm exact credential mapping is verified.
- [ ] Investigate any warnings/failures.

## Retire

- [ ] Run Retire with `-WhatIf`.
- [ ] Confirm the correct current credential is protected.
- [ ] Confirm only expected previous Key IDs are retirement candidates.
- [ ] Run Retire.
- [ ] Review final results.

## Completion

- [ ] Verify old credentials were removed.
- [ ] Verify replacement expiry dates.
- [ ] Review Entra expiry status after portal refresh/propagation.
- [ ] Retain logs according to operational requirements.

---

# 25. Normal Recurring Use

Once a customer has been successfully managed by the current tool, future runs should normally be simpler because Key Vault metadata exists.

Typical recurring process:

```powershell
./build_rotation_input.ps1 `
    -ExpiresWithinDays 30 `
    -OutputFile ./customers-generated.csv
```

Review the generated list.

Then:

```powershell
./rotate_secrets.ps1 -Mode Discover -InputFile ./customers-generated.csv
```

```powershell
./rotate_secrets.ps1 -Mode Rotate -InputFile ./customers-generated.csv -WhatIf
```

```powershell
./rotate_secrets.ps1 -Mode Rotate -InputFile ./customers-generated.csv
```

```powershell
./rotate_secrets.ps1 -Mode Validate -InputFile ./customers-generated.csv
```

```powershell
./rotate_secrets.ps1 -Mode Retire -InputFile ./customers-generated.csv -WhatIf
```

```powershell
./rotate_secrets.ps1 -Mode Retire -InputFile ./customers-generated.csv
```

---

# 26. Golden Rules

1. **Always confirm tenant and subscription first.**
2. **Always review the generated input CSV.**
3. **Never guess an unknown Key Vault mapping.**
4. **Always run Discover before Rotate.**
5. **Always run Rotate with `-WhatIf` first.**
6. **Never delete the previous credential during Rotate.**
7. **Always Validate the replacement credential.**
8. **Always run Retire with `-WhatIf` first.**
9. **Retire by exact mapped Key ID, never by display-name pattern alone.**
10. **Never expose client-secret values in Git, CSVs, logs or console output.**
11. **One customer failure should not stop other valid customers.**
12. **A dangerous CSV configuration should stop the batch before changes begin.**
13. **Use `-Confirm:$false` only after the batch has already been reviewed.**
14. **Keep the production working copy under persistent Cloud Shell storage.**

The objective is not simply to create another secret.

The objective is to safely move each customer from:

```text
OLD WORKING CREDENTIAL
```

to:

```text
NEW WORKING + VALIDATED CREDENTIAL
```

before the exact previous credential is retired.
