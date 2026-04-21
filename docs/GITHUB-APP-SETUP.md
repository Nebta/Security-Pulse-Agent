# GitHub App setup — Security Pulse portal wizard (Wave 7c)

The portal's "New customer" wizard commits a parameters file to this
repo and dispatches `.github/workflows/onboard.yml`. Both actions run
as a dedicated **GitHub App** (not a PAT) so the blast radius is
scoped and key rotation is clean.

---

## 1. Create the GitHub App

1. GitHub → your account settings → **Developer settings → GitHub Apps → New GitHub App**.
2. Name: `Nebta-secpulse-portal` (or anything unique).
3. Homepage URL: the portal SWA default hostname (cosmetic).
4. **Uncheck** "Active" under **Webhook** — the portal doesn't consume events.
5. **Repository permissions**:
   - **Contents** — Read & write  *(commit `infra/customers/<ID>.parameters.json` to `main`)*
   - **Actions** — Read & write    *(workflow_dispatch, read runs/jobs/artifacts)*
   - **Workflows** — Read & write  *(only needed if we ever edit workflow files; safe to grant)*
   - **Metadata** — Read-only      *(implicit)*
6. Account / organization permissions: **none**.
7. **Where can this GitHub App be installed?** — "Only on this account".
8. **Create GitHub App**.

## 2. Collect the three values the portal needs

After creation, on the app's settings page:

- **App ID** — shown near the top. Plain integer.
- **Private key** — scroll to "Private keys" → **Generate a private key**. A `.pem` file downloads.
- **Installation ID** — still on the app page, click **Install App** → install on this account → select **Only select repositories** → pick `Nebta/Security-Pulse-Agent` only. After installation, the URL in the browser is `https://github.com/settings/installations/<installationId>` — copy that number.

> ⚠️  The `.pem` is unrecoverable — if you lose it, generate a new one and rotate the KV secret (keeping the old entry revoked).

## 3. Store credentials in Key Vault

`infra/portal.bicep` provisions `kv-secpulse-portal-<uniq>` in the portal RG
with RBAC authorization. The portal UAMI is granted
`Key Vault Secrets User` on it. Populate it once, manually:

```powershell
$rg    = 'rg-secpulse-portal'
$kv    = (az keyvault list -g $rg --query '[0].name' -o tsv)

# App id + installation id are not secret but live in KV for a single
# source of truth that the func can reach via the same KV reference path.
az keyvault secret set --vault-name $kv --name GitHubAppId             --value '1234567'   --only-show-errors | Out-Null
az keyvault secret set --vault-name $kv --name GitHubAppInstallationId --value '87654321'  --only-show-errors | Out-Null
az keyvault secret set --vault-name $kv --name GitHubAppPrivateKey     --file  ./nebta-secpulse-portal.YYYY-MM-DD.private-key.pem --only-show-errors | Out-Null
```

The Function App reads them via Key Vault references
(`@Microsoft.KeyVault(VaultName=<kv>;SecretName=...)`). The lookup uses
the UAMI because `portal.bicep` sets `keyVaultReferenceIdentity` to the
UAMI's resource id.

## 4. Repo-level prerequisites for the onboarding workflow

The portal's create-customer endpoint dispatches
`.github/workflows/onboard.yml`. For its extra Wave 7c steps you need:

- **Secret `PORTAL_UAMI_PRINCIPAL_ID`** — object id of the portal UAMI
  (`az identity show -g rg-secpulse-portal -n uami-secpulse-portal --query principalId -o tsv`).
  The workflow uses it to grant `Storage Blob Data Contributor` on the
  new customer's storage account and `Logic App Operator` on the new
  RG. Without it, the portal can still show the customer but
  config/template reads will 403 until you grant RBAC manually.
- **Variable `PORTAL_TRACKING_STORAGE_ACCOUNT`** — portal Function App
  backing storage account name. The workflow uploads the final
  `onboard-summary.json` to
  `tracking/onboardings/<CUSTOMER>/<request_id>.json`, which is what
  the wizard polls for completion.
- **Variable `PORTAL_TRACKING_CONTAINER`** (optional) — defaults to
  `tracking`.
- The OIDC service principal behind `AZURE_CLIENT_ID` needs
  `Storage Blob Data Contributor` on the portal tracking storage
  account. Grant once:
  `az role assignment create --assignee <oidc-sp-objectId> --role 'Storage Blob Data Contributor' --scope /subscriptions/<sub>/resourceGroups/rg-secpulse-portal/providers/Microsoft.Storage/storageAccounts/<portalFnSa>`.

## 5. Verify from the portal

Once KV is populated and the Function App is redeployed with the Wave
7c app settings, the portal should be able to:

- `POST /api/scrape {url}` — no GitHub calls, just proves the func is up.
- `POST /api/customers` — commits a new params file (visible on the repo
  within seconds) and you can see the matching `onboard.yml` run in
  Actions within ~10s.
- `GET /api/onboardings/<id>` — returns the run status; on success the
  new customer appears in the portal's customer dropdown (via the
  dynamic registry blob) without a Function App restart.

## 6. Rotation

To rotate the private key:

1. Generate a new one in the GitHub App settings.
2. Update `GitHubAppPrivateKey` in Key Vault (creates a new secret version).
3. Restart the portal Function App (the in-memory installation-token
   cache is invalidated and refetched on next request).
4. Revoke the old key in GitHub App settings.

No downtime is required if step 2 is done before step 4 — the func
still has an unexpired installation token cached for up to ~50 minutes.
