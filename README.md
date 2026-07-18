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
- Run **as root, on the jumpbox itself**. `bootstrap.sh` fetches the static `yq` and `govc` binaries and installs base utilities (`jq`, `curl`, `openssl`, `ca-certificates`, `tar`, `gzip`, `sshpass`, `envsubst`) from the OS repos.

**Additional requirements for Stage 2:**
- An **underlying vSphere target** to host the nested VMs — a standalone ESXi host *or* an existing vCenter (`stage2.underlying.type`) — with enough CPU/RAM/disk for the nested cluster (3 nested ESXi + VCSA + Supervisor is resource-hungry) and a **VLAN-trunk portgroup** carrying the private fabric.
- The **binaries staged under `artifacts.dir`**: the nested-ESXi OVA and the VCSA installer ISO (downloaded from Broadcom; filenames set in `stage2.esxi.ova` / `stage2.vcsa.iso`).
- **≥ 3 nested ESXi** entries in `dns.records` (required for vSAN FTT=1).
- **`sshpass`** (installed by `bootstrap.sh`) — the `vsanhealth` step drives the VCSA over SSH+RVC and hard-fails without it.

## Quick start

```bash
sudo ./bootstrap.sh                              # installs yq + govc + base utilities (incl. envsubst, sshpass)
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
- `VCSA_SSO_PASSWORD` — (Stage 2) SSO administrator + appliance **root** password for the nested vCenter. The `vcenter` step's `vcsa-deploy` templates set both from this one secret and enable SSH (`ssh_enable: true`), so it also doubles as the **SSH login password the `vsanhealth` step uses (via RVC) to reach the VCSA as root**.

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
| `vcenter` | Deploy the VCSA with the supported `vcsa-deploy` CLI from the mounted installer ISO, resize the VCSA VM to the configured vCPU/RAM (hot-add if supported, else a graceful power-cycle), then wait for the appliance + vCenter APIs to come up. |
| `imageseed` | **One-time manual gate** (see the note below). Ensures the datacenter exists, then — if the vLCM depot lacks the nested ESXi build — prompts you to Add the first ESXi in the vCenter UI with **"Extract the image on the host"** and, after you type `done`, **re-verifies the depot** before letting `cluster` run. A silent pass once the image is present; idempotent; nothing to roll back. |
| `cluster` | Create the datacenter + cluster (DRS); add the nested hosts (the seed host moves in from the datacenter); set the cluster's desired image to the seeded build so Supervisor sees an image-compliant cluster; build the VDS + per-VLAN portgroups + edge trunk uplinks; enable **vSAN (OSA) + HA**; create the WCP storage tag/policy. |
| `vsanhealth` | Remediate 3 vSAN health findings that are universal on nested/virtual hardware — **"NVMe device is VMware certified"** (HCL) and **"vSAN Support Insight"** are silenced (unfixable on virtual disks); **"Performance service status"** is genuinely fixed (the service is enabled — off by default on every fresh cluster). Left unfixed, these block Supervisor's Spherelet install. No REST/vim25 API exists for this; driven via **RVC over SSH** to the VCSA appliance. Idempotent (gated on live vSAN health), nothing to roll back. |
| `supervisor` | Resolve the mgmt/workload networks, create a content library, and enable **Supervisor** with the Foundation Load Balancer (validated payload from `templates/enable_flb.json.tmpl`), then wait for `RUNNING`. |
| `labinfo` | Render `/etc/nested-lab/lab2-info.txt` access sheet (vCenter URL/creds, ESXi hosts, cluster, Supervisor, `kubectl vsphere login`). |

### Stage 2 configuration highlights (`stage2:` in `input.yaml`)

- **Names/IPs reuse Stage 1:** nested ESXi are derived from `dns.records` matching `stage2.esxi.dns_prefix`; the VCSA IP/FQDN come from its `dns.records` entry; VLANs are referenced by `network.vlans[].name`. Stage 2 does not redefine IPs.
- **Underlying target** (`stage2.underlying.type`): `esxi` (standalone host) or `vcenter` (existing vCenter — also set `.datacenter` and `.cluster`). The VCSA deploy template and govc placement are selected automatically.
- **VCSA sizing** (`stage2.vcsa`): `size` is the `vcsa-deploy` deployment_option (`tiny`…`large`); the VCSA VM is then resized to `cpu` / `mem_gb` (default **6 vCPU / 26 GB**) via hot-add, falling back to a power-cycle. Only ever increased.
- **vSAN (OSA)** (`stage2.cluster.vsan`): an OSA disk group per host — needs one distinct **`vsan_cache`** + one **`vsan_capacity`** disk under `stage2.esxi.disks` (matched by size at claim time). OSA is used deliberately: far lighter on memory than ESA, which suits nested hosts.
- **Supervisor networking** (`stage2.supervisor.ranges`): explicit control-plane, FLB management/frontend, workload-node and VIP ranges — must sit outside the DHCP pool, and the VIP range must sit inside the workload/frontend subnet (the Foundation LB requires it).

#### One-time depot image seed (fresh vCenter)

A freshly deployed vSphere 9.x vCenter carries only **older fallback** ESXi base images in its vLCM depot — not the build your nested ESXi run. The cluster (and therefore Supervisor) can only be made image-compliant once that build is in the depot, and the **only** way to get a host's *running* image into the depot offline is the vCenter UI: **right-click the datacenter → Add Host → pick a nested ESXi → at the image step choose "Extract the image on the host."** (Requires the nested ESXi to have a persistent ESX-OSData volume on a dedicated disk.)

The dedicated **`imageseed`** step handles this: it prints the exact instruction and (on an interactive terminal) waits for you to type `done`, then **re-verifies the depot** — the `cluster` step runs only once the image is actually present. On a headless run it stops with a `--from-step imageseed` re-run hint instead. There is no supported REST API that extracts a host's installed image into the depot, so this remains a single manual click; everything else in Stage 2 is automated.

## Accessing the lab from your workstation (SSH SOCKS proxy)

The nested vCenter, ESXi hosts and Supervisor live on the private VLANs behind the jumpbox and have **no route from your laptop**. Tunnel through the jumpbox with an SSH SOCKS proxy, and — crucially — send **DNS through the tunnel too**, so `*.<domain>` resolves via the jumpbox's BIND (Stage 1's `dns.use_local_resolver: true` makes the jumpbox resolve the lab names + reverse zones).

1. **Open the tunnel** (leave it running in a terminal):
   ```bash
   ssh -N -D 5555 <user>@<jumpbox-public-ip>
   ```
   `-D 5555` opens a local **SOCKS5** proxy on `127.0.0.1:5555`; `-N` runs no remote shell.

2. **Point the browser at the proxy and resolve DNS remotely** (over the SOCKS5 connection), so lab names resolve on the jumpbox rather than on your laptop:
   - **Firefox** (recommended — proxy is per-app, no OS changes):
     Settings → **Network Settings** → **Manual proxy configuration** →
     **SOCKS Host** `127.0.0.1`, **Port** `5555`, select **SOCKS v5**, and tick
     **“Proxy DNS when using SOCKS v5.”** Then turn **DNS over HTTPS OFF**
     (Settings → Privacy & Security → DNS over HTTPS → *Off*) — DoH bypasses the
     SOCKS DNS and the lab names won't resolve.
   - **Chrome/Edge**: launch with `--proxy-server="socks5://127.0.0.1:5555"`.
     The `socks5://` scheme (not `socks5h`-vs-`socks5` in curl terms) makes
     Chromium send DNS through the proxy by default.

3. **Browse the lab:** `https://vcsa.<domain>/ui` (log in as `administrator@<sso_domain>`), the ESXi hosts, or the Supervisor control-plane/VIP. Trust the lab **CA** (from Stage 1, under `certs.dir`) to avoid TLS warnings. The `kubectl vsphere login` line for the Supervisor is printed in `/etc/nested-lab/lab2-info.txt` (`labinfo` step).

> Why the DNS toggle matters: without “remote DNS”, the browser resolves names **locally** (where `*.<domain>` doesn't exist) and only the *IP* traffic is tunnelled — so name-based access fails. Sending DNS over SOCKS5 is what makes `vcsa.<domain>` resolve through the jumpbox.

## Tests

Two layers: fast offline **unit tests** (run anywhere — no root, no Linux) and the live **`--verify`** suite (run on the jumpbox).

```bash
bats tests/bats/                 # everything below (install bats-core first)
bats tests/bats/ipcalc.bats        # CIDR math (gateway, last /26, containment, reverse zones)
bats tests/bats/lib_write_file.bats # write_file's FILE_CHANGED semantics + the `< <(render_fn)` idiom
bats tests/bats/step_*.bats        # one file per step: validates each step's rendered output
bats tests/bats/structure.bats     # file presence + input.example.yaml validity (needs yq)
bats tests/bats/syntax.bats        # bash -n on every script (+ shellcheck if installed)
./run.sh --stage 1 --verify      # full live verification on a real jumpbox
```

Each step is split into a pure **render** function (testable) and an **apply** path (side effects). The `step_*.bats` files stub the YAML layer and assert on the rendered config — e.g. `step_dns` checks the zone files and recursion ACL, `step_dhcp` validates the Kea JSON (last-/26 pool, option 26 = MTU 9000, FQDN NTP dropped, per-VLAN reservations), `step_certs` runs a real openssl CA→leaf→`openssl verify` round-trip, `step_routing` checks the nftables masquerade/forward rules.

Stage 2's render tests cover the JSON its steps emit: `step_esxi` (import options + guestinfo), `step_vcenter` (both `vcsa-deploy` template variants — standalone-ESXi and existing-vCenter targets), `step_cluster` (the vim25 HA reconfigure spec + the vLCM base-image spec), and `step_supervisor` (the Foundation-LB enable payload — host addresses not CIDRs, workload networks wired). `structure.bats` also asserts the Stage 2 steps, rollbacks and templates are present.

`--verify` asserts the live system. Stage 1: jumbo MTU, gateway IPs, IP forwarding + masquerade, egress, forward/reverse DNS, core services running, Kea validity + option 26, CA verifies the registry leaf, registry `/v2/` health, and a docker push/pull round-trip. Stage 2 (`./run.sh --stage 2 --verify`): nested ESXi VMs up and API-responsive, VCSA reachable, the cluster has all hosts, the vSAN datastore is visible, and Supervisor reports `RUNNING`.
