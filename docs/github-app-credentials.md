# Give Argo CD access to a private GitHub repository with a GitHub App

Argo CD needs read access to the repository holding this configuration. A GitHub App is the credential to prefer over a deploy key: it is scoped to chosen repositories rather than one, its tokens are short-lived and minted on demand, and it survives the person who created it leaving the organisation.

This page covers creating the App, finding the two identifiers Argo CD needs, and building the Secret. The Secret itself is created outside this repository, normally by the infrastructure-as-code that creates the cluster, at the moment of cluster creation. Nothing in this repository creates it and no private key belongs in Git.

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

## 2. Install it and find the installation ID

An App that exists but is not installed grants nothing. Install it, then record the installation ID, which is a different number from the App ID and is the value most often got wrong.

1. On the App's settings page choose Install App, pick the organisation, and select either all repositories or only the repository holding this configuration. Choose the narrow option unless the fleet genuinely spans repositories.
2. After installing you land on the installation's settings page. Its URL ends in the installation ID:

   ```text
   https://github.com/organizations/<org>/settings/installations/<installation-id>
   ```

Or ask the API, which is less error-prone:

```sh
gh api "/repos/${GITHUB_ORG}/${GITHUB_REPO}/installation" --jq .id
```

That endpoint answers for the repository you name, so it returns the installation that actually governs the repository Argo CD will read. This is exactly the check to run when Argo CD reports a repository as inaccessible.

## 3. Generate the private key

On the App's settings page, under Private keys, choose Generate a private key. The browser downloads a `.pem` file, and GitHub shows it to you once.

GitHub issues this key in PEM format, with a `-----BEGIN RSA PRIVATE KEY-----` header. Argo CD accepts that form unchanged: do not convert it, and do not strip the header, the footer or the trailing newline.

Treat the file as a secret. It belongs in whatever your infrastructure-as-code uses for secret material, never in this repository.

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

For GitHub Enterprise Server, add `githubAppEnterpriseBaseUrl` with your instance's API base URL, and use your instance's host in `url`.

## 5. Verify

```sh
argocd repocreds list
argocd repo list
```

`repocreds list` shows the credentials template and the URL prefix it covers. `repo list` shows each repository Argo CD knows and its connection status, which is what actually proves the credential works.

If the connection status is a failure:

- Check the label first. `kubectl --namespace argocd get secret --selector argocd.argoproj.io/secret-type` lists only the Secrets Argo CD can see. If yours is absent, the label is wrong or missing.
- Then check the installation ID. A connection that fails with an authentication error, while the App ID and key are right, is nearly always an installation ID belonging to a different installation of the App, often one on another organisation or on a personal account. Re-read it with the `gh api` command above, which answers for the specific repository.
- Then check the URL form. An SSH URL with GitHub App credentials cannot work, and a prefix that does not match the Applications' `repoURL` matches nothing.
