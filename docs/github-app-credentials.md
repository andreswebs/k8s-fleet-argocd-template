# Give Argo CD access to a private GitHub repository with a GitHub App

Argo CD needs read access to the repository holding this configuration. A GitHub App is the credential to prefer over a deploy key: it is scoped to chosen repositories rather than one, its tokens are short-lived and minted on demand, and it survives the person who created it leaving the organisation.

This page covers creating the App, finding the two identifiers Argo CD needs, building the Secret, and where the credential lives and how it rotates afterwards. The Secret itself is created outside this repository, normally by the infrastructure-as-code that creates the cluster, at the moment of cluster creation. Nothing in this repository creates it and no private key belongs in Git.

## Before you start

- Owner rights on the GitHub organisation, or admin on the repository if you install the App on a single repository.
- A cluster with Argo CD installed, as described in the repository's `README.md`.
- The `gh` CLI, authenticated, if you want to look up the installation ID from a shell rather than a browser.

## 1. Create the App

1. Go to the organisation's settings, then Developer settings, then GitHub Apps, then New GitHub App. For an App owned by a personal account the same page lives under your own Developer settings.
2. Give it a name and a homepage URL. Neither matters to Argo CD; the name is what appears in the repository's installed Apps list, so name it after the cluster fleet rather than after a person.
3. Under Permissions, open Repository permissions and set Contents to Read-only. Leave everything else at No access. Metadata is read-only implicitly and cannot be turned off.
4. Uncheck Active under Webhook. Argo CD polls, and an App with a webhook but no listener produces failed deliveries.
5. Choose whether the App may be installed only in this organisation or in any account. Only this organisation is the right answer for a fleet.
6. Create the App. The App ID is on the resulting settings page, near the top, a six-digit number. Keep it.

Argo CD uses exactly three values from the App: the App ID, the installation ID and the private key. The settings page also shows a client ID and offers to generate a client secret. Those are for signing users in through the App with OAuth, and Argo CD never uses them. Do not generate a client secret for this App: an unused secret is only one more thing to protect, rotate and leak.

## 2. Install it and find the installation ID

An App that exists but is not installed grants nothing. Install it, then record the installation ID, which is a different number from the App ID and is the value most often got wrong.

1. On the App's settings page choose Install App, pick the organisation, and select either all repositories or only the repository holding this configuration. Choose the narrow option unless the fleet genuinely spans repositories.
2. After installing you land on the installation's settings page. Its URL ends in the installation ID:

   ```text
   https://github.com/organizations/<org>/settings/installations/<installation-id>
   ```

Or ask the API, which is less error-prone. As an organisation owner, list the organisation's installations and pick out this App's by its slug, the App's name as it appears in its URL:

```sh
GITHUB_APP_SLUG="my-fleet-app"
gh api "/orgs/${GITHUB_ORG}/installations" \
  --jq ".installations[] | select(.app_slug == \"${GITHUB_APP_SLUG}\") | {id, app_id, repository_selection, permissions}"
```

That returns the installation ID together with the App ID and the permissions the installation was granted, so one call checks all three. For an App installed on a personal account, use `/user/installations` in place of `/orgs/${GITHUB_ORG}/installations`.

Do not reach for `/repos/${GITHUB_ORG}/${GITHUB_REPO}/installation`, although it looks like the direct answer. That endpoint authenticates as the App itself, with a JSON web token signed by the App's private key, and your own `gh` token gets HTTP 401, "A JSON web token could not be decoded".

## 3. Generate the private key

On the App's settings page, under Private keys, choose Generate a private key. The browser downloads a `.pem` file, and GitHub shows it to you once.

GitHub issues this key as a PKCS#1 PEM file, with a `-----BEGIN RSA PRIVATE KEY-----` header. Argo CD accepts that form unchanged: do not convert it, and do not strip the header, the footer or the trailing newline.

Treat the file as a secret. It belongs in whatever your infrastructure-as-code uses for secret material, never in this repository. Once it is stored there, delete the download; [Storing and rotating the credential](#6-storing-and-rotating-the-credential) says where it should live.

## 4. Create the Secret

Argo CD reads repository credentials from Secrets in its own namespace, identified by a label. Two shapes exist:

- `argocd.argoproj.io/secret-type: repo-creds` with a URL prefix, which becomes a credentials template matching every repository underneath that prefix. This is what a fleet usually wants.
- `argocd.argoproj.io/secret-type: repository` with the full repository URL, which scopes the credential to that one repository.

**The label is required.** A Secret without it is invisible to Argo CD, and a missing label is the single most common reason a bootstrap fails with an authentication error despite the Secret existing and being correct.

The URL must be the HTTPS form, `https://github.com/<org>`, not an SSH URL. GitHub App authentication mints a token and presents it over HTTPS; there is no SSH path for it. It must also match the `repoURL` your Applications use, prefix against prefix.

`examples/repo-creds.github-app.yaml` is the manifest form. To create it from a shell, working from the key file rather than pasting it:

```sh
export GITHUB_ORG="example-org"
export GITHUB_APP_ID="123456"
export GITHUB_APP_INSTALLATION_ID="12345678"
export GITHUB_APP_PRIVATE_KEY_FILE="${HOME}/.secrets/argocd-github-app.pem"

kubectl --namespace argocd create secret generic github-app-repo-creds \
  --from-literal=type=git \
  --from-literal=url="https://github.com/${GITHUB_ORG}" \
  --from-literal=githubAppID="${GITHUB_APP_ID}" \
  --from-literal=githubAppInstallationID="${GITHUB_APP_INSTALLATION_ID}" \
  --from-file=githubAppPrivateKey="${GITHUB_APP_PRIVATE_KEY_FILE}" \
  --dry-run=client --output yaml \
  | kubectl label --local --filename - argocd.argoproj.io/secret-type=repo-creds --output yaml \
  | kubectl apply --server-side --force-conflicts --filename -
```

The key goes in with `--from-file`, not `--from-literal`, even though every other value uses the latter. A literal is an argument on the command line, so the key would appear in the process list and in shell history; a file path shows only the path. Keep it that way when adapting the command for your own pipeline.

For GitHub Enterprise Server, add `githubAppEnterpriseBaseUrl` with your instance's API base URL, and use your instance's host in `url`.

## 5. Verify

```sh
argocd repocreds list
```

That lists the credentials template and the URL prefix it covers. Expect one row, with the prefix you set as `url`.

**`argocd repo list` is expected to be empty, and that is not a failure.** It lists repositories registered individually, and this page creates a credentials *template* (`secret-type: repo-creds`) rather than a per-repository entry (`secret-type: repository`). A repository that an Application merely references by `repoURL` is never registered, so it never appears there. Do not read an empty list as a broken credential.

What actually proves the credential works is an Application reaching `Synced` against a **private** repository, since a private repository cannot be cloned without authentication:

```sh
kubectl --namespace argocd get applications \
  --output custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'
```

If an Application reports `Unknown` with a `ComparisonError`, or stays `OutOfSync` with an authentication message:

- Check the label first. `kubectl --namespace argocd get secret --selector argocd.argoproj.io/secret-type` lists only the Secrets Argo CD can see. If yours is absent, the label is wrong or missing.
- Then check the installation ID. A connection that fails with an authentication error, while the App ID and key are right, is nearly always an installation ID belonging to a different installation of the App, often one on another organisation or on a personal account. Re-read it with the `gh api` command above and compare the `id` it returns with the one in the Secret. That command lists the installation, not the repositories it covers: if `repository_selection` is `selected`, confirm on the installation's settings page that the repository Argo CD reads is among them, since listing them from a shell needs a token issued to the App rather than to you.
- Then check the URL form. An SSH URL with GitHub App credentials cannot work, and a prefix that does not match the Applications' `repoURL` matches nothing.

## 6. Storing and rotating the credential

Creating the Secret is a one-off step, but the credential behind it outlives the bootstrap. Three things are worth settling before the first cluster, because they apply to every cluster after it.

### One stored copy for the fleet

One App serves every cluster, so there is one private key, and it wants one source of truth. Keep it in a secrets manager, typically in a central account that the cluster pipelines can read, and build each cluster's `repo-creds` Secret from that copy. Avoid a copy inside each cluster's infrastructure-as-code: every copy is one more place to update on rotation and one more place to leak from.

Store the App ID and the installation ID beside the key. They are not secret, but the Secret needs all three, and keeping them together means one lookup builds it.

Once the key is stored, delete the downloaded `.pem`.

### Why External Secrets cannot deliver it on day 0

This template installs External Secrets, so an `ExternalSecret` looks like the natural way to create `repo-creds`. It cannot be the first one. Argo CD needs the credential to read the repository that installs External Secrets, so the first `repo-creds` Secret has to exist before the bootstrap, or be created as part of it, as section 4 does.

After the bootstrap there are two options:

- Keep creating the Secret from the pipeline, as at bootstrap. Rotation then means re-running that step on each cluster.
- Let an `ExternalSecret` take the Secret over, reading from the same central store. Rotation then propagates by itself on the next refresh. The `ExternalSecret` must produce the same name, keys and `argocd.argoproj.io/secret-type: repo-creds` label as the Secret it replaces.

Either way, the pipeline keeps the ability to create the Secret from scratch, since a new cluster starts without External Secrets.

### Rotating the key without downtime

A GitHub App can hold up to 25 private keys at once, and every one of them is valid until it is deleted. That is what makes rotation safe: the new key works before the old one stops working. See [Managing private keys for GitHub Apps](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/managing-private-keys-for-github-apps).

1. On the App's settings page, generate a new private key.
2. Replace the key in the stored copy with the new one.
3. Re-apply the `repo-creds` Secret on every cluster, with the same pipeline as section 4, or wait for the `ExternalSecret` to refresh if one owns it. `kubectl apply --server-side --force-conflicts` updates the existing Secret in place.
4. On every cluster, confirm that the Applications still reach `Synced`, as in section 5. Force a refresh first if you do not want to wait for the next poll:

   ```sh
   APP_NAME="root"
   kubectl --namespace argocd annotate application "${APP_NAME}" \
     argocd.argoproj.io/refresh=hard --overwrite
   ```

5. Only then delete the old key on the App's settings page, and delete the new key's download.

Deleting the old key before every cluster has the new one is the one way to turn a rotation into an outage.
