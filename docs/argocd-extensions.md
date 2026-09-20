# Add an Argo CD UI extension

This template does not install any Argo CD extension, and does not install Argo Rollouts. It used to ship the Argo Rollouts UI extension, and this page preserves the recipe so that a consumer who wants that extension, or any other, has the whole procedure in one place.

The worked example throughout is the Argo Rollouts extension, because it is the one the template used to carry. Any extension distributed as a tarball is installed the same way.

## Before you start

You need:

- an Argo CD installed from the community Helm chart, as this template installs it under `.argocd`
- the release URL of an extension tarball, and the knowledge that it was built for the Argo CD major version you run (see [Extensions must be built for React 19](#extensions-must-be-built-for-react-19))
- for the Rollouts extension specifically, the Argo Rollouts controller itself running in the cluster, which is a separate install described in [Adding the Argo Rollouts controller](#adding-the-argo-rollouts-controller)

## How Argo CD loads a UI extension

An Argo CD UI extension is a JavaScript bundle that the `argocd-server` UI loads at runtime. It is not baked into the server image. Instead:

1. The chart adds an init container to the `argocd-server` Deployment, one per entry in the extension list, using the `argocd-extension-installer` image.
2. That init container downloads the tarball named by its `EXTENSION_URL` and unpacks it into the directory named by `EXTENSIONS_DIR`.
3. Both the init container and the server container mount the same `extensions` volume at that directory, so the unpacked bundle is in place before the server starts.
4. The server serves the bundle to the browser, which loads it into the already running UI.

The chart exposes this through `server.extensions`.

### Steps

1. Add the extension to the Argo CD values. In this template the natural place is `.argocd/base/argocd.helm.values.yaml` for an extension every cluster gets, or `.argocd/overlays/<cluster-name>/argocd.helm.values.yaml` for one cluster only:

   ```yaml
   server:
     extensions:
       enabled: true
       extensionList:
         - name: rollout-extension
           env:
             - name: EXTENSION_URL
               value: https://github.com/argoproj-labs/rollout-extension/releases/download/v0.4.0/extension.tar
   ```

2. Render the overlay and confirm the init container appears:

   ```sh
   ARGOCD_OVERLAY=".argocd/overlays/dev-1"
   kustomize build --enable-helm --load-restrictor LoadRestrictionsNone "${ARGOCD_OVERLAY}" \
     | yq -N 'select(.kind=="Deployment" and .metadata.name=="argocd-server") | .spec.template.spec.initContainers'
   ```

   At Argo CD chart 10.9.2 this produces an init container named after the list entry, running `quay.io/argoprojlabs/argocd-extension-installer:v1.1.0`, with `EXTENSIONS_DIR` set to `/tmp/extensions` alongside the `EXTENSION_URL` given above, mounting the `extensions` volume at `/tmp/extensions/`.

3. Commit the change. Argo CD is self-managing in this template, so it rolls out the new `argocd-server` Deployment itself.

### Verification

1. Open the Argo CD UI and select any Application.
2. The extension's tab appears on the Application view. For the Rollouts extension this is a Rollout tab, populated only for Applications that contain a Rollout resource.
3. Open the browser console. There must be no `Extension ... failed to load` error. If there is one, read the next section.

## Extensions must be built for React 19

The Argo CD UI moved from React 16 to React 19 in Argo CD 3.5. An extension built against an older Argo CD UI fails to load until it is rebuilt, and the host UI reports it in the browser console as:

```text
Extension <name>.js failed to load: TypeError: Cannot read properties of undefined (reading '<prop>')
```

The property name and the stack frames vary with the bundle, so do not match on them. The reliable signals are that the failure is a `TypeError` at load time, before the extension renders anything, and that the extension's bundler config does not externalize `react/jsx-runtime`.

The cause is that Argo CD's host UI exposes its own React to extensions on `window`, including the JSX runtime as `window.ReactJSXRuntime`. An extension that bundles its own copy of the runtime reaches into a React internals object that React 19 removed. Libraries such as `antd` import `react/jsx-runtime` directly, so an extension can hit this without ever writing JSX against it.

The fix belongs to whoever builds the extension: add `react/jsx-runtime` to the bundler's `externals` map next to `react` and `react-dom`, then rebuild. If it still fails after that, the extension depends on a library version that is not React 19 compatible and needs bumping.

For a consumer of a published extension, the practical rule is to take a release built after its maintainers applied that change. For the Argo Rollouts extension that is `v0.4.0` or newer: the React 19 fix and that release landed on the same day, and the `v0.3.5` this template used to pin predates it by two years and will not load on Argo CD 3.5.

Sources: the `3.4-3.5` upgrade guide and the `ui-extensions-react-19-upgrading` page, both under `docs/operator-manual/upgrading/` in the [argoproj/argo-cd](https://github.com/argoproj/argo-cd) repository and published at [UI Extensions: React 19 Upgrade](https://argo-cd.readthedocs.io/en/stable/operator-manual/upgrading/ui-extensions-react-19-upgrading/).

## Adding the Argo Rollouts controller

The UI extension only renders Rollout resources. It does nothing without the Argo Rollouts controller, which is a separate Helm chart and a separate decision.

If you add it, add it as an application, not as part of the Argo CD bootstrap. The bootstrap under `.argocd` exists to install Argo CD itself and to hand it over to itself; putting another product there couples an unrelated upgrade to the Argo CD upgrade. The template used to make exactly that mistake, carrying `argo-rollouts` as a second `helmCharts` entry beside `argo-cd`.

The shape to follow is any existing infrastructure application, for example `apps/cert-manager`:

1. Create `apps/argo-rollouts/base` with a `kustomization.yaml` and a values file, and `apps/argo-rollouts/overlays/<cluster-name>` pulling the chart:

   ```yaml
   helmCharts:
     - name: argo-rollouts
       repo: https://argoproj.github.io/argo-helm
       version: 2.43.2
       namespace: argo-rollouts
       releaseName: argo-rollouts
       valuesFile: ../../base/argo-rollouts.helm.values.yaml
       additionalValuesFiles:
         - argo-rollouts.helm.values.yaml
   ```

2. Add an element for it to the infra ApplicationSet patch in `clusters/<cluster-name>/patches/infra.appset.yaml`, choosing a sync wave that puts it after the namespace and CRD prerequisites it needs.

3. Add it to the `apps` list in `clusters/<cluster-name>/README.md`, which mirrors that ApplicationSet.

Two chart defaults are worth knowing before you commit to it. The chart sets `installCRDs: true`, so the Rollout CRDs come with the release, and `keepCRDs: true`, so uninstalling the release leaves those CRDs in the cluster. That default is deliberate and protective: removing a CRD garbage collects every object of that kind, so an accidental uninstall would delete every Rollout in the cluster. The consequence is that removing the application from the ApplicationSet does not leave a clean cluster, and the CRDs have to be deleted by hand once you are certain nothing depends on them.

## Proxy extensions

UI extensions are one of two extension mechanisms. The other is proxy extensions, which are a server-side feature: Argo CD's API server proxies requests from the UI to a backend service you nominate, handling authentication and RBAC, so an extension can show data that only that backend has. They are configured in the `argocd-cm` ConfigMap rather than through an init container, and they are independent of the React version, because the proxying happens before any browser code runs. A UI extension frequently pairs with a proxy extension: the bundle draws the tab, the proxy feeds it. See [Proxy Extensions](https://argo-cd.readthedocs.io/en/stable/developer-guide/extensions/proxy-extensions/) in the operator manual, and [UI Extensions](https://argo-cd.readthedocs.io/en/stable/developer-guide/extensions/ui-extensions/) for writing one of your own.
