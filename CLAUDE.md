# CLAUDE.md — project context for Claude Code

Read this first. It is the durable, portable context for this repo (it loads
automatically in every Claude Code session, on any account/machine). The chat
history that built this does NOT travel; this file is the source of truth.

## What this is

Multi-stage **Bash** automation that turns a customer Linux VM into a
self-contained **nested vSphere lab with Supervisor**, to be left behind at a
customer site. Plain shell — no Ansible, no Python runtime, no agents — chosen
for easy debugging/maintenance. It was converted from an earlier Ansible
implementation (removed; recoverable from git history at commit e165037 under
`legacy-ansible/`).

- **Stage 1 (DONE, field-validated on Ubuntu 26.04):** jumpbox = router/NAT,
  VLANs, BIND DNS, Kea DHCP, self-signed/BYO root CA, jumbo (9000) private
  fabric, and a `registry:2` OCI registry.
- **Stage 2 (NEXT, to plan):** deploy nested ESXi + vCenter and enable
  Supervisor, reusing Stage 1's DNS/DHCP/CA bundle/registry. See
  `docs/STAGE2-PLAN.md`.

## Architecture (keep Stage 2 uniform with this)

```
run.sh                 entrypoint: --stage --from-step --rollback --check --verify --force
bootstrap.sh           installs yq (mikefarah) + base utils
lib/common.sh          logging, master status file + run_step checkpoints, secrets, write_file
lib/ipcalc.sh          pure-bash CIDR math (replaces ansible ipaddr)
lib/yaml.sh            yq wrappers (cfg / cfg_len / cfg_bool) over input.yaml
lib/os.sh              OS family detection + per-OS package/service/path maps; kea helpers
stages/stage1-jumpbox/
  stage.sh             ordered step list, compute_derived (the model), dispatch
  steps/NN-name.sh     one file per step; each defines step_<name> + pure render fns
  rollback/NN-name.sh  rollback_<name> per mutating step
  verify.sh            live test suite (verify_main)
tests/bats/            ipcalc, write_file, structure, syntax, and step_*.bats unit tests
```

A new stage = a new `stages/stageN-*/` dir with the same shape, plus extending
`stage_dir`/STEPS dispatch in `run.sh`/`stage.sh`.

## Conventions and HARD-WON RULES (do not regress these)

- **Idempotency, two layers:** (1) `state/stageN.state` checkpoints skip done
  steps; (2) every step is itself idempotent. Re-running is always safe.
- **`write_file PATH MODE < <(render_fn)` — NEVER `render_fn | write_file`.** A
  pipeline runs write_file in a subshell so its `FILE_CHANGED` global is lost,
  and conditional service restarts silently never fire. Tests pin this
  (`tests/bats/lib_write_file.bats`).
- **Each step splits a pure `render` fn (testable) from the `apply` path.** Unit
  tests stub the YAML layer (`cfg`/`cfg_len`) and assert on rendered output. Add
  step_*.bats for every new step. Run: `bats tests/bats/` (needs `bats` + `jq`;
  `yq`/`shellcheck` optional and auto-skip).
- **Errors:** scripts run `set -Eeuo pipefail` + an ERR trap (`on_err`). Use
  `|| die "..."` for expected failures; `die` prints a `--from-step` resume hint.
- **Secrets:** gitignored `secrets.env` (sourced) + interactive no-echo prompt
  fallback (`require_secret`). Never commit secrets. `input.yaml` is gitignored;
  only `input.example.yaml` is committed.
- **Target shell is bash 4.4+ (jumpbox).** The dev mac has bash 3.2, so avoid
  empty-array-under-`set -u` in any code path exercised by local test harnesses.
- **Kea must be validated AS the `_kea` user** (`kea_validate` in lib/os.sh),
  not root — Ubuntu's Kea AppArmor profile denies root `dac_override`. Kea logs
  go under `/var/log/kea/` (AppArmor-permitted).
- **nftables uses uniquely-named tables** (`nested_lab_nat`/`nested_lab_filter`)
  and NEVER `flush ruleset`, so it coexists with Docker's `ip nat` (which would
  otherwise clobber our masquerade, and vice-versa). Forward chain is `policy
  accept` + explicit drops so Docker's forwarded traffic isn't dropped.
- **The registry binds PRIVATE-ONLY** on its VLAN IP (`REGISTRY_ADDR:443`), so
  it's never exposed on the public NIC. The jumpbox must OWN that IP — if
  `registry.ip` is a dedicated address, networking assigns it as a secondary
  address on its VLAN (`V_EXTRA`).
- **Pull Docker Hub images through a mirror** (`registry.image_mirror`, default
  `mirror.gcr.io/library`, via the `_img` helper) to avoid rate limits.

## Run / test

```bash
sudo ./bootstrap.sh
cp input.example.yaml input.yaml && $EDITOR input.yaml
cp secrets.example.env secrets.env && chmod 600 secrets.env && $EDITOR secrets.env
sudo ./run.sh --stage 1                 # idempotent
sudo ./run.sh --stage 1 --from-step X   # resume / redo from a step
sudo ./run.sh --stage 1 --verify        # live test suite
bats tests/bats/                        # unit tests (offline)
```

## Working agreements

- The jumpbox is a DEPLOY target, not an edit spot: pull only (use `git stash`
  if you must experiment there).
- Commit/push only when the user asks. Branch off `main` for new work.
- Keep the network model facts straight: VLAN /24s carved from a user `/22`;
  gateway = `.1`; DHCP pool = last /26 (`.193`–`.254`); jumbo MTU 9000 private.
