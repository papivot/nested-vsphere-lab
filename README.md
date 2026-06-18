# Nested vSphere Lab

Multi-stage **Bash** automation to stand up a self-contained **nested vSphere environment with Supervisor**, designed to be left behind at a customer site for testing. Plain shell scripts — no Ansible, no Python runtime, no agents — so they are easy to read, run, and debug on any jumpbox.

- **Stage 1 (implemented):** turn a customer-provided Linux VM into the lab **router/jumpbox** — VLANs, NAT/optional-BGP routing, BIND DNS, Kea DHCP, a self-signed/BYO root CA trusted end-to-end, jumbo (9000) private fabric, and a `registry:2` OCI registry.
- **Stage 2 (next):** deploy nested ESXi + vCenter and enable Supervisor, reusing this jumpbox's DNS, DHCP, CA bundle and registry.

Every stage shares the same input file, runner, logging, state/resume and rollback conventions.

> The previous Ansible implementation has been moved to `legacy-ansible/` for reference. Delete it once you're happy with the Bash version (and have made your first commit).

## Requirements

- A Linux VM (**Ubuntu/Debian, RHEL-like, or Photon**) with:
  - at least **2 NICs** (one public/egress, one private trunk),
  - at least **100 GB** free disk,
  - running on vSphere with the private NIC's portgroup set to a **VLAN trunk (4095)** with **Promiscuous mode / Forged transmits / MAC changes = Accept** and jumbo MTU on the vSwitch.
- Run **as root, on the jumpbox itself**. The only thing `bootstrap.sh` fetches is the single static `yq` binary (plus `jq`/`openssl` from the OS repos).

## Quick start

```bash
sudo ./bootstrap.sh                              # installs yq + base utilities
cp input.example.yaml input.yaml && $EDITOR input.yaml
cp secrets.example.env secrets.env && chmod 600 secrets.env && $EDITOR secrets.env
sudo ./run.sh --stage 1
```

The `networking` step only reconfigures the **private** NIC, so an SSH session on the public/management IP stays up.

## The single input file

All stages read one YAML file (`input.yaml`). Secrets are **not** in it — they live in a gitignored `secrets.env` (see `secrets.example.env`):

- `REGISTRY_ADMIN_PASSWORD` — required only when `registry.auth: true`. Must be strong/non-default.
- `CA_KEY_PASSPHRASE` — optional passphrase for the self-signed CA key.

If a needed secret is blank, `run.sh` prompts for it (no echo).

## Runner

```bash
./run.sh --stage 1                       # full run (idempotent; re-runnable)
./run.sh --stage 1 --from-step networking  # resume: re-runs that step onward
./run.sh --stage 1 --check               # dry-run: print the plan + derived model
./run.sh --stage 1 --verify              # run the test suite only
./run.sh --stage 1 --rollback routing    # scoped rollback of one step
./run.sh --stage 1 --force               # re-run even completed steps
```

- **preflight** is always a hard gate before any change.
- Logs: `logs/stage1-<timestamp>.log`. **Master status file:** `state/stage1.state` (one completed step per line).
- On failure the runner prints the failing command and an exact resume command. Fix, then re-run with `--from-step <step>`. Each mutating step has a scoped `--rollback`.

## How it works

| File | Role |
|---|---|
| `run.sh` | Uniform entrypoint: arg parsing, logging, OS detection, dispatch. |
| `lib/common.sh` | Logging, state/checkpoints, the `run_step` framework, secrets, idempotent file writes. |
| `lib/ipcalc.sh` | Pure-bash CIDR math (gateway `.1`, last /26, /22 containment, reverse zones) — replaces Ansible's `ipaddr` filters. |
| `lib/yaml.sh` | `yq` wrappers for reading `input.yaml`. |
| `lib/os.sh` | OS family detection + per-OS package/service/path maps. |
| `stages/stage1-jumpbox/stage.sh` | Step order, the derived-VLAN model, run/rollback/check dispatch. |
| `stages/stage1-jumpbox/steps/*.sh` | One file per step (below). |
| `stages/stage1-jumpbox/rollback/*.sh` | Scoped rollback per mutating step. |
| `stages/stage1-jumpbox/verify.sh` | Live test suite. |

## Stage 1 steps (run order)

| Step | Purpose |
|---|---|
| `preflight` | Validate OS, physical NICs, ≥100 GB disk, kernel modules, /22 + /24 containment, secrets; warn on physical-vSphere portgroup needs. |
| `base_os` | sysctl/perf tuning, kernel modules, NTP **client** to upstream, proxy env, base packages, data dirs. |
| `certs` | Self-signed root CA (or BYO), optional intermediate, registry leaf cert, OS trust install, CA key lock + backup. |
| `networking` | Per-OS (netplan / NetworkManager / systemd-networkd) VLAN sub-interfaces, gateway `.1`, jumbo MTU. Public NIC untouched. |
| `routing` | nftables NAT + forwarding, persistent static routes, optional FRR/BGP. |
| `dns` | BIND9 forward zone + per-VLAN reverse zones, recursion limited to private subnets, pre-created node records. |
| `dhcp` | Kea DHCPv4 per VLAN, pool = last /26, options MTU=9000 + NTP + domain-search + reservations. |
| `registry` | Docker + `registry:2` with CA-signed TLS, jumbo-MTU daemon, optional htpasswd auth and pull-through mirror. |
| `labinfo` | Render `/etc/nested-lab/lab-info.txt` customer summary + end-of-run summary. |

## Network model

- Private VLANs are carved as `/24`s from a user-provided `/22`. VLAN 100 is native (untagged).
- Each VLAN gateway is the `.1`, owned by the jumpbox; DHCP serves the **last /26** of each `/24` (`.193`–`.254`).
- Jumbo frames (MTU 9000) on the private NIC and all VLAN sub-interfaces; the public NIC is left at the provider default.

## Tests

Two layers: fast offline **unit tests** (run anywhere — no root, no Linux) and the live **`--verify`** suite (run on the jumpbox).

```bash
bats tests/bats/                 # everything below (install bats-core first)
bats tests/bats/ipcalc.bats      # CIDR math (gateway, last /26, containment, reverse zones)
bats tests/bats/step_*.bats      # one file per step: validates each step's rendered output
bats tests/bats/structure.bats   # file presence + input.example.yaml validity (needs yq)
bats tests/bats/syntax.bats      # bash -n on every script (+ shellcheck if installed)
./run.sh --stage 1 --verify      # full live verification on a real jumpbox
```

Each step is split into a pure **render** function (testable) and an **apply** path (side effects). The `step_*.bats` files stub the YAML layer and assert on the rendered config — e.g. `step_dns` checks the zone files and recursion ACL, `step_dhcp` validates the Kea JSON (last-/26 pool, option 26 = MTU 9000, FQDN NTP dropped, per-VLAN reservations), `step_certs` runs a real openssl CA→leaf→`openssl verify` round-trip, `step_routing` checks the nftables masquerade/forward rules. 60 unit tests total.

`--verify` asserts the live system: jumbo MTU, gateway IPs, IP forwarding + masquerade, egress, forward/reverse DNS, core services running, Kea validity + option 26, CA verifies the registry leaf, registry `/v2/` health, and a docker push/pull round-trip.
