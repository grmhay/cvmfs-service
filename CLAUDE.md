# Project Rules

This repo is not a Python service: it is a Nix flake (Profiles + publish tooling), Ansible roles, and
runbooks. Read `CONTEXT.md` first and use its vocabulary (Repository, Publisher, Union Store, Channel…).

## Environment
- Work inside `nix develop` (ansible, ansible-lint, sops, age, mc, shellcheck, yamllint)
- Validate before committing: `nix flake check`, `shellcheck publish/*.sh spikes/*.sh`, `(cd ansible && ansible-lint --offline playbooks/ roles/)`

## Conventions
- A Profile is a `buildEnv`; collisions must fail the build — never fix one with PATH order
- Nothing is ever deleted from the Repository (retention: never, year one); retire paths by dropping them from a Profile
- Secrets: only `*.enc.yaml` is committed (SOPS + age, same recipient as homelab-opscontrolplane); the master key never lives on the Publisher except during `resign`
- Roles **verify** the Origin bucket; they never create it (`server/minio/RUNBOOK.md`)
- Host facts (group, channel, mode, quota) come from NetBox custom fields through the dynamic inventory; do not hardcode them in playbooks
- Publishing goes to `canary`; only `promote` touches `stable`

## Out of scope (do not build)
- Replacing Docker on skyline with Nix-run services (undecided, deferred)
- A Stratum 1 or Squid: the Cache is an nginx reverse cache (ADR 0003)
- Kernel-overlayfs union stores (ADR 0002)
- Caddy redundancy for skyline's public ingress (separate follow-up)

## Agent skills

### Issue tracker
Issues and PRDs live as GitHub issues (`github.com/grmhay/cvmfs-service`). See `docs/agents/issue-tracker.md`.

### Triage labels
Default five-label vocabulary (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`). See `docs/agents/triage-labels.md`.

### Domain docs
Single-context repo — `CONTEXT.md` + `docs/adr/` at the root. See `docs/agents/domain.md`.

### Planning artefacts
- PRD files live in `prd/`; implementation plans in `plans/`
- The originating design plan: `plans/0001-nix-over-cvmfs.md`

### Daily workflow
New feature?   → /grill-with-docs → /to-prd → /to-issues
Start issue?   → /clear → @prd @plan "Do issue #N"
Hard bug?      → /diagnose
