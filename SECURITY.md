# Security policy

## Supported versions

Only the latest release gets fixes. Upgrade to it before reporting a problem.

## Reporting a vulnerability

Report vulnerabilities privately with
[Report a vulnerability](https://github.com/636B65/terraform-kubernetes/security/advisories/new)
on the Security tab. Do not open a public issue. Describe the problem, the
affected version and, if possible, how to reproduce it. Expect a first answer
within a week.

## Verifying a release

Every release since the signing workflow was added has these assets, made by
[`sign-release.yml`](.github/workflows/sign-release.yml) on GitHub Actions:

| Asset | What it is |
|-------|------------|
| `terraform-kubernetes-<version>.tar.gz` | Source archive of the release tag |
| `SHA256SUMS` | SHA-256 checksum of the archive |
| `*.sigstore.json` | [Sigstore](https://www.sigstore.dev/) bundles: keyless signatures made with the workflow's GitHub identity, recorded in the public Rekor log |
| `terraform-kubernetes-<version>.intoto.jsonl` | [SLSA](https://slsa.dev/) level 3 build provenance |

Check the signature with [cosign](https://docs.sigstore.dev/cosign/system_config/installation/):

```bash
version=0.10.0
cosign verify-blob \
  --bundle "terraform-kubernetes-$version.tar.gz.sigstore.json" \
  --certificate-identity-regexp '^https://github\.com/636B65/terraform-kubernetes/\.github/workflows/sign-release\.yml@' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  "terraform-kubernetes-$version.tar.gz"
```

Check the provenance with [slsa-verifier](https://github.com/slsa-framework/slsa-verifier):

```bash
slsa-verifier verify-artifact "terraform-kubernetes-$version.tar.gz" \
  --provenance-path "terraform-kubernetes-$version.intoto.jsonl" \
  --source-uri github.com/636B65/terraform-kubernetes \
  --source-tag "v$version"
```

## Security checks

[OpenSSF Scorecard](https://scorecard.dev/viewer/?uri=github.com/636B65/terraform-kubernetes)
checks this repository's practices every week and on every push to `main`
([`scorecard.yml`](.github/workflows/scorecard.yml)). The findings are under
Security > Code scanning.
