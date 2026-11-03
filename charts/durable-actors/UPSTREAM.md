# Vendored upstream chart: durable-actors

This directory is the TerseAI/durable-actors release chart, unpacked verbatim.
Do not edit `Chart.yaml`, `values.yaml`, `values.schema.json`, `README.md`,
`.helmignore` or `templates/`. Report problems upstream and re-vendor.

| Field | Value |
| --- | --- |
| Upstream | https://github.com/TerseAI/durable-actors (MIT) |
| Tag | `v0.14.6` |
| Tag commit | `5f0a2d62ed08e3060befd9b009333e1f0c3c6cd8` |
| Release asset | `durable-actors-0.14.6.tgz` |
| Asset sha256 | `a489cd15c5b4319b2607114701db711f79b4ae5faddd4dd25beb0ac6cab15bee` |
| Also published at | `oci://ghcr.io/terseai/charts/durable-actors --version 0.14.6` |

Image digests pinned by the release chart (`images.*` in `values.yaml`), all in
`us-central1-docker.pkg.dev/fluid-analogy-473415-c2/public/durable-actors`
(multi-arch, linux/amd64 and linux/arm64):

| Image | Digest |
| --- | --- |
| controlPlane | `sha256:a83d21bc05a471dfe1727dd297a98d0bd1588b037a67e03e00637dd8d593e8ef` |
| typescript (actor host runtime) | `sha256:d5ad5fe0ade42e97670446666fa86f1c1dfcaaf1ef31246781642b7372ef5925` |
| python (actor host runtime) | `sha256:86d3861336940d92ee2b05604fb9dda4f5ef83ebd552807ef9a6ac03421413ca` |

## Local additions (not upstream)

- `UPSTREAM.md` (this file).
- `ci/*-values.yaml`: placeholder fixtures so `scripts/ci/charts.sh static`
  can lint and render the chart; they are not shipped values.

Patches to upstream files: **none**.

## Re-vendoring

```sh
VERSION=0.14.6
gh release download "v${VERSION}" -R TerseAI/durable-actors -p "durable-actors-${VERSION}.tgz"
shasum -a 256 "durable-actors-${VERSION}.tgz"   # record it above
rm -rf charts/durable-actors/{Chart.yaml,values.yaml,values.schema.json,README.md,.helmignore,templates}
tar xzf "durable-actors-${VERSION}.tgz" -C charts/
```

Then bump the umbrella's `durable-actors` dependency version, run
`helm dependency update charts/agent-relay`, and update the tag, commit,
sha256 and digests above.

## Notes for this repo

- Sandbox pods are created by the control plane, not by this chart. Upstream
  sets `runtimeClassName: gvisor`, `nodeSelector: sandbox.gke.io/runtime: gvisor`
  and a zone affinity from `placement.zone` (`src/sandbox/gke/kubernetes.rs`);
  GKE's `gvisor` RuntimeClass adds the toleration for the sandbox node taint.
  Controllers carry a required anti-affinity for gVisor nodes. No patch needed.
- `replicaCount > 1` requires `redis.urlSecretKey` (socket bus).
- The sandbox NetworkPolicy denies RFC1918 egress from actor pods. Actors
  therefore cannot call cluster-internal services; they may only reach the
  control plane (7100), DNS and public addresses.
- Only GKE Sandbox and Modal providers exist upstream. There is no
  kind/MinIO/S3 provider: local proofs use `durable-actors dev` instead (see
  docs/self-hosted-durable-actors.md).
