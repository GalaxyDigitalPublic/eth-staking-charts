# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [6.7.0] - 2026.11
### Added
- `initContainersNonRoot.enabled`: `get-configs` and `prepare` run as the validator's uid (runAsNonRoot, no privilege escalation, read-only root filesystem, all capabilities dropped, seccomp RuntimeDefault) instead of root; `prepare` no longer chowns `/data` and `get-configs` gets an in-memory `/tmp`. The render fails if its runAsUser differs from `securityContext.runAsUser`. Default off: default render unchanged. (BCE-13774)

## [6.6.0] - 2026.11
### Added
- `keyManagerApi.tokenSecret.generate`: the chart creates the keymanager token Secret (random once, kept across upgrades with `lookup`, `helm.sh/resource-policy: keep`, excluded from Velero) instead of requiring a pre-made one; the token pre-check hook is skipped in that mode. Default off. (BCE-13767)

## [6.5.0] - 2026.11
### Added
- `cliImage.extraEnv`: extra env for the `get-configs` (sync-keys) init container, e.g. `SYNC_KEYS_DB_AUTH=aws-iam` for passwordless RDS IAM auth with an IRSA role on `serviceAccount.annotations`. Default render unchanged. (BCE-13767)

## [6.4.0] - 2026.11
### Added
- Per-client `startupProbe` (Lighthouse default: `/metrics` every 2 s, up to 5 min). Readiness for Lighthouse now starts immediately and checks every 10 s instead of waiting 60 s and checking every 60 s. Pods become Ready as soon as the VC is serving. (BCE-13597)

## [2.2.0] - 2022.02
### Added
- Support for multiple beaconChainRpcEndpoints
### Changed
- All dependencies are now installed separately to simplify the installation and maintenance process
- beaconChainRpcEndpoint changed from string to list with ability to specify multiple eth2 endpoints
- vaultEndpoint should be specified manually in all cases
### Removed
- geth, erigon, prysm, lighthouse, teku, vault dependencies

## [2.0.1] - 2022.01
### Added
- Gnosis Chain Support
### Changed
- Added Gnosis Chain compatible binaries to Dockerfile
- Added Gnosis Chain support to validator init script
