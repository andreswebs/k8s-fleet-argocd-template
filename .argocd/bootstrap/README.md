# Argo CD self-management application

This application bootstraps the Argo CD self-management configuration.

It is applied with `kubectl apply --server-side --force-conflicts`, because
the CRDs it brings with it exceed the size limit of client-side apply. The
full bootstrap procedure is in the [repository README](../../README.md).
