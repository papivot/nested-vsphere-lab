# Stage 2 — planning seed

Status: **not started.** This is a starting frame for planning, not a final
plan. Read `CLAUDE.md` first for repo conventions. Stage 2 must stay uniform
with Stage 1 (same `stages/stageN-*/` shape, `run.sh --stage 2`, idempotent
steps with render/apply split + bats tests, single `input.yaml`, scoped
rollback + `--verify`).

## Goal

Deploy a **nested vSphere environment with Supervisor (vSphere with Tanzu)** that
reuses the Stage 1 jumpbox services:
- DNS (BIND) — register vCenter + ESXi names (records can be pre-seeded in
  Stage 1's `dns.records`).
- DHCP (Kea) — address the nested management VLAN, MTU 9000, NTP option.
- CA bundle — vCenter/ESXi certs trusted end-to-end; distributed to nested nodes.
- registry (`registry:2`) — serve OCI images to Supervisor / workloads.
- NAT egress + jumbo private fabric already in place.

## Recommended tooling (keep it Bash, like Stage 1)

- **govc** (govmomi CLI) for OVA/OVF deploy + vCenter inventory/config — the
  Bash-native equivalent of PowerCLI. `bootstrap.sh` would fetch the static govc
  binary (like it does yq).
- **curl + jq** for the VCSA installer REST and the Supervisor / Workload
  Management APIs.
- Avoid PowerCLI/Ansible/Terraform to stay uniform and dependency-light. (The
  original brief explicitly allowed recommending the tool; govc+curl is the
  uniform choice.)

## Likely step breakdown (one file per step, mirrors Stage 1)

1. **preflight** — assert Stage 1 is healthy (DNS resolves the planned names, CA
   bundle present, registry `/v2/` 200, DHCP serving); validate the *underlying*
   vSphere target creds + capacity; validate OVAs/ISOs exist (artifacts.dir);
   validate nested sizing fits.
2. **esxi** — deploy N nested-ESXi VMs (William Lam's Nested ESXi OVA) onto the
   underlying vSphere, attached to the private VLAN trunk portgroup; configure
   hostname/DNS/NTP, install the lab CA, prep disks (vSAN claim or local).
3. **vcenter** — deploy VCSA (vcsa-deploy CLI or OVA) with a lab-CA cert, SSO
   domain, sized for a lab; register in DNS.
4. **cluster** — datacenter + cluster, add hosts, vDS + portgroups (MTU 9000),
   storage (vSAN / NFS-from-jumpbox / iSCSI), HA/DRS.
5. **supervisor** — content library, storage policy, management + workload
   networks, load balancer (HAProxy or NSX-ALB/Avi), then enable Workload
   Management; wire the registry as the image source.
6. **verify** — vCenter API healthy, hosts connected, Supervisor running,
   `kubectl`/`kubectl vsphere login` works, a test pod pulls from the jumpbox
   registry; certs verify against the lab CA.

## Open decisions to resolve before building (ask the user)

- **Underlying platform:** where do the nested VMs deploy — the customer's
  vCenter, or a standalone ESXi host? Need target host/datacenter/cluster/
  datastore/portgroup mapping + creds (creds in `secrets.env`).
- **Storage for the nested cluster:** vSAN (needs ≥3 hosts + cache/capacity
  disks per host) vs shared NFS exported from the jumpbox vs iSCSI. vSAN is the
  most "real" but heaviest.
- **Supervisor networking + load balancer:** vDS + HAProxy (lightest), vDS +
  NSX-ALB/Avi, or full NSX-T (heaviest). Pick the lightest that meets the goal.
- **Versions + image sources:** vCenter/ESXi versions; where the OVAs/ISOs come
  from (pre-staged in `artifacts.dir`, or downloaded).
- **Host count + sizing:** 3 nested ESXi (typical for vSAN + Supervisor); CPU/
  RAM/disk per host; the underlying host must have the capacity (Supervisor
  control plane is resource-hungry).
- **IP plan:** which Stage 1 VLAN is management vs workload; Supervisor control-
  plane VIPs and LB VIP range (Stage 1 already supports `static_routes` for a
  Supervisor LB VIP range — see input.example `routing.static_routes`).

## input.yaml additions (sketch — a new `stage2:` section)

```yaml
stage2:
  underlying:                 # where nested VMs are deployed (creds in secrets.env)
    vcenter: ...; datacenter: ...; cluster: ...; datastore: ...
    portgroup_trunk: ...      # the VLAN-trunk portgroup backing the private fabric
  esxi:
    count: 3; cpu: ...; mem_gb: ...; disks: [...]; vlan: 100   # DHCP from Stage 1
  vcsa:
    fqdn: vcsa.env1.lab.test; ip: ...; sso_domain: ...; size: tiny
  supervisor:
    mgmt_vlan: 100; workload_vlan: 101
    lb: { type: haproxy, vip_range: 192.168.103.0/24 }
    storage_policy: ...; content_library: ...
```

## First actions for the planning session

1. Resolve the open decisions above with the user (use AskUserQuestion).
2. Confirm govc+curl tooling and add govc to `bootstrap.sh`.
3. Scaffold `stages/stage2-nested-vsphere/` (stage.sh + empty step stubs +
   verify.sh) and extend `run.sh`/dispatch for `--stage 2`.
4. Build step-by-step, each with a render/apply split + bats tests, exactly like
   Stage 1.
