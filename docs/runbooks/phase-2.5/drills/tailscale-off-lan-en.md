# Drill — Tailscale Off-LAN Access Validation

**Date:** 2026-04-25
**Phase:** 2.5 (deferred from original Phase 2.5 close)
**Operator:** Tuhin
**Duration:** ~90 min (bulk spent on diagnosis, not just probe)
**Outcome:** ✅ Off-LAN cluster access proven working (with manual workaround)

---

## Goal

Validate that `kubectl` and SSH to lab cluster (`10.10.0.0/24`) work from a network completely outside the home LAN — not just from `192.168.68.x` where direct routing already exists.

Test medium: phone hotspot (T-Mobile, CGNAT'd, `172.20.10.x` subnet).

---

## Pre-drill state (assumed working, claimed in Phase 2.5 memory)

- pve advertising `192.168.68.0/24` and `10.10.0.0/24` as Tailscale subnet router
- Tailscale admin console subnet routes approved
- Mac Tailscale client running with `--accept-routes`
- IP forwarding enabled on pve
- Result expected: Mac off-LAN → Tailscale → pve → cluster, transparent

## Pre-drill state (actual, discovered during drill)

- pve `AdvertisedRoutes: []` — silently regressed, root cause unknown (possibly `tailscale up` partial-flag reset at some prior point)
- Tailscale Mac client was **stopped** at session start
- Admin console approval state for at least one subnet had reverted to pending
- LaunchDaemon static route `10.10.0.0/24 → 192.168.68.200` was unconditionally present (designed for home LAN, not off-LAN aware)
- Tailscale subnet route auto-install on macOS was not actually populating the kernel route table even with all preferences correct

**Lesson:** Memory/plan claims about working state are not verified state. Drill itself was the source of truth.

---

## Findings (in order of discovery)

### Finding 1 — pve no longer advertising routes

`tailscale debug prefs` on pve showed stored `AdvertiseRoutes` was empty. Phase 2.5 setup had silently regressed.

**Fix:**
```
[pve]
tailscale up \
  --accept-dns=false \
  --advertise-routes=192.168.68.0/24,10.10.0.0/24 \
  --accept-routes \
  --ssh
```

**Important — `tailscale up` partial-flag trap:**
Newer Tailscale versions throw an error when `tailscale up` is called with partial flags, suggesting the full set explicitly. Older versions silently reset other flags. Either way, `tailscale up` treats specified flags as the *complete desired state*.

**Lesson:** For incremental changes use `tailscale set --<flag>=<value>`, not `tailscale up`. `tailscale set` modifies one flag without resetting the others.

### Finding 2 — Admin console approval pending

After re-advertise, pve self-state showed routes correctly stored, but coordinator-synced view (`tailscale status`) on Mac showed `PrimaryRoutes: []`.

Tailscale design: nodes claim routes, but human operator must approve in admin console for security. Approval state can revert on node re-key or other identity refresh.

**Fix:** Admin console → `pve` → "Edit route settings" → enable both subnets → Save.

After approval, `10.10.0.0/24` propagated immediately. `192.168.68.0/24` required a second approval click (only one was toggled initially).

### Finding 3 — LaunchDaemon static route harmful off-LAN

When Mac switched to phone hotspot:
- LaunchDaemon route `10.10.0.0/24 → 192.168.68.200` remained installed
- Phone hotspot subnet was `172.20.10.x` — `192.168.68.200` unreachable
- Kernel: "can't assign requested address" (couldn't pick a source IP for the gateway)
- Tailscale path never tried because static route wins by specificity

**Fix during drill:** Manual `sudo route -n delete -net 10.10.0.0/24` while off-LAN.

**Permanent fix (deferred):** Enhance LaunchDaemon helper to probe gateway reachability and skip route-add when home LAN gateway not reachable. Tracked as follow-up.

### Finding 4 — Tailscale subnet route NOT auto-installing on macOS kernel

Despite:
- pve advertising correctly
- Admin console approving both subnets
- Mac `RouteAll: true` (i.e., `--accept-routes` honored)
- Tailscale system extension `[activated enabled]`
- pve peer `Online: True`, `AllowedIPs` including `10.10.0.0/24`

…the macOS kernel route table never gained an entry for `10.10.0.0/24` via `utun*`. On macOS, Tailscale subnet route auto-install is not deterministic — even with correct configuration, the kernel route table may not be populated. Treat this as a design limitation and plan for a fallback.

**Workaround (proven working):** Manually install kernel route pointing at peer's Tailscale IP:

```
[Mac terminal] off-LAN
sudo route add -net 10.10.0.0/24 100.111.182.119
```
⚠️ **Important limitation:** Off-LAN access currently depends on this manual route. Tailscale configuration alone is not sufficient on macOS; a kernel route override may be required.
```

After this:
- `route get 10.10.0.10` → `gateway: 100.111.182.119, interface: utun4`
- ping/kubectl work end-to-end via Tailscale tunnel

**Why it works:** kernel sees `100.111.182.119` is reachable through `utun*` (Tailscale interface), forwards `10.10.0.0/24` packets there, Tailscale tunnels to pve, pve forwards (IP forwarding enabled) into the lab subnet.

This is the same end result as Tailscale's auto-install would produce; only the installation step differs.

---

## Validated working off-LAN access path

```
Mac (172.20.10.4, T-Mobile hotspot)
  → Tailscale tunnel (DERP relay via Chicago, ~100ms baseline)
  → pve (100.111.182.119, subnet router, IP forwarding ON)
  → 10.10.0.0/24 lab subnet
  → cluster control plane 10.10.0.10:6443
```

Measured latency: 78–195 ms ICMP RTT. `kubectl get nodes` returns full 4-node Ready state.

---

## Required state for off-LAN access (consolidated)

### pve side
- `tailscale up` flags: `--advertise-routes=192.168.68.0/24,10.10.0.0/24 --accept-routes --ssh --accept-dns=false`
- `sysctl net.ipv4.ip_forward=1`, `net.ipv6.conf.all.forwarding=1` (persisted in `/etc/sysctl.d/99-ipforward.conf`)
- tailscaled service enabled and active

### Tailscale admin console
- Both subnets `192.168.68.0/24` and `10.10.0.0/24` enabled/approved on pve

### Mac side (when off-LAN)
- Tailscale running, `RouteAll: true`
- Home-LAN LaunchDaemon route deleted (`sudo route -n delete -net 10.10.0.0/24`)
- Manual peer-based route added (`sudo route add -net 10.10.0.0/24 100.111.182.119`)

### Mac side (when home-LAN)
- LaunchDaemon route active (`10.10.0.0/24 → 192.168.68.200`)
- Tailscale need not even be running for cluster access

---

## Recovery steps after off-LAN session

⚠️ Note: Check for an existing route before adding. Blind adds can create duplicate or conflicting routes.
```
[Mac terminal] back on home WiFi
sudo route -n delete -net 10.10.0.0/24
sudo route -n add -net 10.10.0.0/24 192.168.68.200
route -n get 10.10.0.10   # confirm: gateway 192.168.68.200, interface en0
kubectl get nodes         # confirm: 4 nodes Ready
```

(Mac reboot also restores LaunchDaemon route automatically.)

---

## Open follow-up items

1. **macOS Tailscale auto-install of subnet routes** — investigate why kernel route table doesn't gain `10.10.0.0/24 → utun*` entry despite all preferences correct. Possible avenues: macOS Tailscale GUI app reinstall, system extension permission re-prompt, file a Tailscale issue. Not blocking — manual workaround documented.
This is a design limitation — although a workaround exists, a long-term mitigation strategy is required.

2. **LaunchDaemon enhancement** — make the route-add helper probe `192.168.68.200` reachability before installing the route. Skip on hotspot/external networks. Auto-restore on home-LAN return. Avoids manual delete/add cycle on every off-LAN session.

3. **UDP GRO warning on pve** — `Warning: UDP GRO forwarding is suboptimally configured on vmbr0`. Performance optimization, not correctness. Apply when convenient (link in Tailscale warning).

---

## Lessons captured

1. **Memory ≠ verified state.** Phase 2.5 said "Tailscale advertising both subnets". Reality at drill time: advertising nothing. Drills are the only way to know.
2. **`tailscale up` is full-state, not incremental.** Use `tailscale set` for single-flag changes.
3. **Tailscale signaling correct ≠ kernel routing correct on macOS.** Auto-install is a separate failure surface.
4. **Static routes are convenient on a known network and dangerous on unknown ones.** LaunchDaemon needs to be conditional.
5. **Drills earn their cost.** This one exposed five real issues in 90 minutes — the kind of issues that would have caused a real incident at the wrong moment.
6. **Actual traffic path is determined by OS routing priority, not configuration intent.** Static routes, default gateways, and VPN routes compete; the kernel chooses one.