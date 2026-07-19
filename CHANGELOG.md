# Changelog

Notable changes, generated from [conventional commits](https://www.conventionalcommits.org) by
git-cliff. Do not edit by hand.
## Unreleased

### CI
- bump create-github-app-token to v3.2.0 across all mirrored components (efc9f6c)
- per-repo release workflows (publish on a vX.Y.Z tag) (277cf32)

### Chore
- drop the root license, license per-component (FSL-1.1-ALv2) (#146) (be2a5a7)
- finish the monorepo layout, kill platform stubs, unify the platform axis (O-1/O-3/O-4/O-5) (#115) (b56bb49)

### Documentation
- branded, marketable READMEs for every sub-repo (9c2a477)
- stop mentioning DNSSEC (no longer part of the design) (179a278)

### Other
- CLA gate on contributions (preserve commercial relicensing of core) (5a9aa7d)
- SECURITY.md per component + enable-security in the bootstrap script (a1492e9)
- copyright holder is Hop Mesh, LLC (7d8c514)
- fill the Apache-2.0 copyright placeholder (2026 Jason Waldrip) (2fb7d1c)
- Apache-2.0 for everything except core/ (only the protocol stays FSL) (0fe9439)
- CHANGE_REQUEST sync-back + document merge/conversation + confidentiality (9e1dec2)
- make the TLS-served reach record the only name path (drop DNSSEC-over-DoH) (#139) (8998288)
- lift HopBearer+Hns.swift 59% -> 99% + add a per-file coverage floor (#83) (4bfb245)
- decompose the 1895-line HopBearer god-object into per-concern collaborators (B- → A) (#75) (4d86f9d)
- strip em-dashes from this session's Apple coverage test files (#67) (f11147f)
- split into HopContract (no libhop) + Hop (libhop node) — unblocks the app cutover (7f0eeb3)
- thin HopDriver composing the SDK + all four bearers (889fe62)

### Refactor
- enforce purpose/platform/package (collapse sdk/wrappers, apps/web -> apps/web/site) (#116) (afd52df)

### Testing
- headless-node suite raises HopBearer.swift 12.8% -> 88.5% (F -> A) + CI coverage floor (#64) (75f4507)

