# Nested vSphere Lab

Multi-stage **Bash** automation to stand up a self-contained **nested vSphere environment with Supervisor**, designed to be left behind at a customer site for testing. Plain shell scripts — no Ansible, no Python runtime, no agents — so they are easy to read, run, and debug on any jumpbox.

- **Stage 1 (implemented):** turn a customer-provided Linux VM into the lab **router/jumpbox** — VLANs, NAT/optional-BGP routing, BIND DNS, Kea DHCP, a self-signed/BYO root CA trusted end-to-end, jumbo (9000) private fabric, and a `registry:2` OCI registry.
- **Stage 2 (implemented):** deploy nested ESXi + vCenter (VCSA) and enable **Supervisor** (vSphere with Tanzu) with the vSphere Foundation Load Balancer, reusing this jumpbox's DNS, DHCP, CA bundle and registry. Uses **govc + curl + `vcsa-deploy`** — still plain Bash, no PowerCLI.

Every stage shares the same input file, runner, logging, state/resume and rollback conventions.

> The earlier Ansible implementation was removed; it is recoverable from git history (commit `e165037`, under `legacy-ansible/`).

## Requirements

- A Linux VM (**Ubuntu/Debian, RHEL-like, or Photon**) with:
  - at least **2 NICs** (one public/egress, one private trunk),
  - at least **100 GB** free disk (default; configurable via `jumpbox.min_disk_gb`),
  - running on vSphere with the private NIC's portgroup set to a **VLAN trunk (4095)** with **Promiscuous mode / Forged transmits / MAC changes = Accept** and jumbo MTU on the vSwitch.
- Run **as root, on the jumpbox itself**. `bootstrap.sh` fetches the static `yq` and `govc` binaries and installs base utilities (`jq`, `openssl`, `curl`, `envsubst`) from the OS repos.

**Additional requirements for Stage 2:**
- An **underlying vSphere target** to host the nested VMs — a standalone ESXi host *or* an existing vCenter (`stage2.underlying.type`) — with enough CPU/RAM/disk for the nested cluster (3 nested ESXi + VCSA + Supervisor is resource-hungry) and a **VLAN-trunk portgroup** carrying the private fabric.
- The **binaries staged under `artifacts.dir`**: the nested-ESXi OVA and the VCSA installer ISO (downloaded from Broadcom; filenames set in `stage2.esxi.ova` / `stage2.vcsa.iso`).
- **≥ 3 nested ESXi** entries in `dns.records` (required for vSAN FTT=1).

## Quick start

```bash
sudo ./bootstrap.sh                              # installs yq + govc + base utilities (incl. envsubst)
cp input.example.yaml input.yaml && $EDITOR input.yaml
cp secrets.example.env secrets.env && chmod 600 secrets.env && $EDITOR secrets.env
sudo ./run.sh --stage 1
# then, after staging the OVA/ISO under artifacts.dir:
sudo ./run.sh --stage 2
```

The `networking` step only reconfigures the **private** NIC, so an SSH session on the public/management IP stays up.

## The single input file

All stages read one YAML file (`input.yaml`). Secrets are **not** in it — they live in a gitignored `secrets.env` (see `secrets.example.env`):

- `REGISTRY_ADMIN_PASSWORD` — required only when `registry.auth: true`. Must be strong/non-default.
- `CA_KEY_PASSPHRASE` — optional passphrase for the self-signed CA key.
- `UNDERLYING_PASSWORD` — (Stage 2) root/SSO password for the underlying ESXi or vCenter target.
- `ESXI_ROOT_PASSWORD` — (Stage 2) root password set on each nested ESXi.
- `VCSA_SSO_PASSWORD` — (Stage 2) SSO administrator + appliance root password for the nested vCenter.

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
| `lib/govc.sh` | Stage 2 helpers: govc target selector, vim25 task poller, vCenter REST session/call, HTTPS wait. |
| `stages/stage1-jumpbox/stage.sh` | Step order, the derived-VLAN model, run/rollback/check dispatch. |
| `stages/stage1-jumpbox/steps/*.sh` | One file per step (below). |
| `stages/stage1-jumpbox/rollback/*.sh` | Scoped rollback per mutating step. |
| `stages/stage1-jumpbox/verify.sh` | Live test suite. |
| `stages/stage2-nested-vsphere/` | Same shape as Stage 1: `stage.sh`, `steps/`, `rollback/`, `verify.sh`, plus `templates/` (envsubst JSON for vcsa-deploy, the nested-ESXi import options, and the Supervisor enable payload). |

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
| `registry` | Docker + `registry:2` (`registry.<domain>`) with CA-signed TLS, jumbo-MTU daemon. **Bound private-only** on its VLAN IP (not exposed on the public NIC). Setup images pulled via a configurable mirror (`registry.image_mirror`, default `mirror.gcr.io/library`) to dodge Docker Hub rate limits. Optional htpasswd auth + pull-through cache. |
| `labinfo` | Render `/etc/nested-lab/lab-info.txt` customer summary + end-of-run summary. |

## Network model

- Private VLANs are carved as `/24`s from a user-provided `/22`. VLAN 100 is native (untagged).
- Each VLAN gateway is the `.1`, owned by the jumpbox; DHCP serves the **last /26** of each `/24` (`.193`–`.254`).
- Jumbo frames (MTU 9000) on the private NIC and all VLAN sub-interfaces; the public NIC is left at the provider default.

## Stage 2 steps (run order)

`sudo ./run.sh --stage 2` — same runner, flags, state/resume and rollback as Stage 1 (`state/stage2.state`, `logs/stage2-*.log`, `--from-step`, `--rollback`, `--verify`, `--check`).

| Step | Purpose |
|---|---|
| `preflight` | Assert Stage 1 is healthy (CA bundle, DNS resolves the planned ESXi/VCSA names, registry `/v2/` up), the underlying target is reachable with the datastore + trunk portgroup, the OVA/ISO are present under `artifacts.dir`, capacity fits, and `≥3` nested ESXi records exist. |
| `esxi` | Deploy N nested-ESXi VMs from the OVA (committed `esxi.template.json` via envsubst; guestinfo injected via `vm.change -e`), size CPU/mem, enable nested-HV + disk UUIDs, and attach the vSAN data disks before first power-on. |
| `vcenter` | Deploy the VCSA with the supported `vcsa-deploy` CLI from the mounted installer ISO, then wait for the appliance + vCenter APIs to come up. |
| `cluster` | Create the datacenter + cluster (DRS), add the nested hosts, build the VDS + per-VLAN portgroups + edge trunk uplinks, enable **vSAN + HA**, and create the WCP storage tag/policy. |
| `supervisor` | Resolve the mgmt/workload networks, create a content library, and enable **Supervisor** with the Foundation Load Balancer (validated payload from `templates/enable_flb.json.tmpl`), then wait for `RUNNING`. |
| `labinfo` | Render `/etc/nested-lab/lab2-info.txt` access sheet (vCenter URL/creds, ESXi hosts, cluster, Supervisor, `kubectl vsphere login`). |

### Stage 2 configuration highlights (`stage2:` in `input.yaml`)

- **Names/IPs reuse Stage 1:** nested ESXi are derived from `dns.records` matching `stage2.esxi.dns_prefix`; the VCSA IP/FQDN come from its `dns.records` entry; VLANs are referenced by `network.vlans[].name`. Stage 2 does not redefine IPs.
- **Underlying target** (`stage2.underlying.type`): `esxi` (standalone host) or `vcenter` (existing vCenter — also set `.datacenter` and `.cluster`). The VCSA deploy template and govc placement are selected automatically.
- **vSAN mode** (`stage2.cluster.vsan.mode`): **`osa`** (default; lighter, recommended for nested — needs a distinct `vsan_cache` + `vsan_capacity` disk) or **`esa`** (memory-intensive; pooled `vsan_data` disks).
- **Supervisor networking** (`stage2.supervisor.ranges`): explicit control-plane, FLB management/frontend, workload-node and VIP ranges — must sit outside the DHCP pool, and the VIP range must be routed to the workload network (see `routing.static_routes`).

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

Each step is split into a pure **render** function (testable) and an **apply** path (side effects). The `step_*.bats` files stub the YAML layer and assert on the rendered config — e.g. `step_dns` checks the zone files and recursion ACL, `step_dhcp` validates the Kea JSON (last-/26 pool, option 26 = MTU 9000, FQDN NTP dropped, per-VLAN reservations), `step_certs` runs a real openssl CA→leaf→`openssl verify` round-trip, `step_routing` checks the nftables masquerade/forward rules.

Stage 2's render tests cover the JSON its steps emit: `step_esxi` (import options + guestinfo), `step_vcenter` (both `vcsa-deploy` template variants — standalone-ESXi and existing-vCenter targets), `step_cluster` (the vim25 vSAN/HA reconfigure specs), and `step_supervisor` (the Foundation-LB enable payload — host addresses not CIDRs, workload networks wired). `structure.bats` also asserts the Stage 2 steps, rollbacks and templates are present.

`--verify` asserts the live system. Stage 1: jumbo MTU, gateway IPs, IP forwarding + masquerade, egress, forward/reverse DNS, core services running, Kea validity + option 26, CA verifies the registry leaf, registry `/v2/` health, and a docker push/pull round-trip. Stage 2 (`./run.sh --stage 2 --verify`): nested ESXi VMs up and API-responsive, VCSA reachable, the cluster has all hosts, the vSAN datastore is visible, and Supervisor reports `RUNNING`.
