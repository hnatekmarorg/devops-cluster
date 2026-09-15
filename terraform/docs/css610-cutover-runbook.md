# CSS610 cut-over runbook — the first window where devices move

`vlan-port-assignment.md` sets the conventions and the order; this is the operational script for step 3,
the one device in the estate with **no API** (SwOS Lite 2.21, `admin` / empty password, web UI only).
It is also the box on the path to the **work PC** and the Spark management NICs, which is why the
recovery step is written before the change, not after.

## What this window does, and what it deliberately does not

| | Ports | Target |
|---|---|---|
| **In this window** | `Port7` | **trunk** — native/compat VLAN 1 untagged, **tagged members for 10 and 30** |
| | `Port2` (charon, the work PC, `.227`) | **mgmt access** — untagged, VLAN 10 only |
| | `Port8`, `Port6`, `Port5`, `Port3` (Spark 1…4) | **lab access** — untagged, VLAN 30 only |
| **Not in this window** | `Port4` (CRS804 `ether1`, the spine's management) | **done 2026-09-15** — the spine moved to mgmt (`172.16.10.201`, DHCP, now pinned in IaC) and its compat `.113` retired. Leaving it compat during this window was deliberate: moving it then would have stranded the spine mid-window |
| | `Port1` | stays **compat access** — the recovery perch (see below) |

**Why Port1 stays compat rather than "mgmt" like the other switches' escape ports:** the CSS610's only
management address, `172.16.100.117`, lives in **compat**. A laptop on a mgmt-VLAN access port could not
reach it, so the recovery hatch would be useless exactly when it is needed. The convention's *intent*
("a laptop on that port still reaches the gear") is met either way while compat exists — this is the one
local exception, and it is revisited at compat retirement.

**Open question on `Port2`'s final class — settle it before locking the port.** The port-assignment
diagram puts charon in **mgmt**; the device tracker and the plan describe charon as a **WireGuard peer
whose mgmt+lab ingress *is* the tunnel**, with positional mgmt access for everyday-driver laptops
"denied by design". Both cannot hold in the end state. Using `Port2` for the sanity check below is fine
either way (it is the cheapest way to prove the trunk), but if charon should not end up in mgmt
positionally, move it back to compat after the check and let the VPN be its ingress — decide, don't drift.

## Preconditions — do not start without these

1. **The trunk VLANs are applied and verified.** The router's `ether4` and the CRS326's `ether18`/`ether4`
   must carry **tagged 10 and 30**. Verify by reading `/interface/bridge/vlan` on both devices, not from
   memory — and check that the compat LAN is still fine (`172.16.100.1`, `.2`, `.117`, and the spine on its mgmt address `172.16.10.201` — its compat `.113` retired on 2026-09-15 — answering).
2. **Run the baseline:** `scripts/css610-window-check.sh pre` on the Hermes host — it records the Sparks'
   flat addresses, their endpoints, charon, and what lmproxy points at. Keep the output.
3. **A config backup of the CSS610** — SwOS Lite *System → Backup* downloads its config. Do this before
   the first change; restoring is then one upload instead of remembering modes.
4. **A screenshot of the current per-port VLAN state** (the box's own labels), so "what it was" is on
   record next to "what we set".
5. **The ladder:** laptop + patch cable, and the person doing this is **not** on charon. Every move below
   is one port-setting away from being reverted from the laptop.
6. The read-only facts to hand: Spark management NICs and their prepared static **lab** leases —
   `172.16.30.136` (Spark 1, from `.136`), `.137` (Spark 2), `.112` (Spark 3), `.110` (Spark 4), all
   pre-created on the router; charon today is `172.16.100.227` and its mgmt lease will come from
   `172.16.10.200-250`; the CSS610 itself is `172.16.100.117`.
7. **The three edits that are not port-settings** (see the next section): lmproxy's endpoint, and
   `sparkrun`'s cluster files on each Spark. Prepare them before the window — they are the parts nobody
   can do remotely while the move is happening.

## The agent goes dark in this window — plan for its absence

The agent's own inference runs on **spark1 via lmproxy** (`model.provider: custom:lmproxy` →
`/opt/lmproxy/config.yaml` → `http://172.16.100.136:8000`). The moment Spark 1's port changes VLAN, the
agent loses its brain and cannot help until lmproxy points at `172.16.30.136` and has been restarted.
So the window is executed **by hand**, and these are the edits to make in it:

```bash
# 1. lmproxy — the LIVE config is /opt/lmproxy/config.yaml, not the workspace checkout.
sudo sed -i 's|http://172.16.100.136:8000|http://172.16.30.136:8000|' /opt/lmproxy/config.yaml
sudo systemctl restart lmproxy          # expect the agent to come back once Spark 1 answers on .30.136

# 2. sparkrun — on each Spark, its peers are pinned by IP. On spark1 (reachable with the infra key):
#    ~/.config/sparkrun/clusters/infernal.yaml    hosts: peers as .137/.110/.112 (itself as 127.0.0.1)
#    ~/.config/sparkrun/clusters/infernal.manifest.yaml  repeats all four IPs (~9 places)
#    → the three peer addresses become 172.16.30.137 / .30.110 / .30.112 on every node.
#    SSH as martin with the infra key is REFUSED on .137/.112/.110 — those nodes need another way in
#    (console, or the key they do accept); do not start the Sparks' move without it.
```

## The window, in order

### 0. Perch (2 min)
Laptop on `Port1`, logged into `http://172.16.100.117`. Confirm from there that you can still reach
`172.16.100.1`, `.2` and that the cable you would use to fix a mistake is within reach. (The spine is no longer on compat: it moved to mgmt at `172.16.10.201` on 2026-09-15.)

### 1. `Port7` → trunk
Set `Port7` to carry the native/compat VLAN untagged **and** tagged members for VLAN 10 and 30. Nothing
downstream changes yet: every other port is still compat, and compat is still what the trunk's native
VLAN carries.

**Verify:** charon, the four Sparks, the spine and the CSS610's own management all still answer; the
CRS326 and router still answer. If a device drops here, the trunk is wrong — revert `Port7` from the
laptop, nothing else has moved yet.

### 2. charon → mgmt — **the trunk's sanity check, first**
Set `Port2` to untagged **VLAN 10 only**. charon should take a lease from the mgmt pool and reach the
gear. This is deliberately *before* the Sparks: it exercises the CSS610's tagged mgmt path end to end
(`Port2 → Port7 → CRS326 ether4 → ether18 → router → dhcp-mgmt`) with nothing of the agent's on the line,
so if the trunk is subtly wrong you find out while everything still works.

**Ordering caveat:** keep this step *last* instead if you are working **from** charon — the sequencing is
about which machine you can afford to lose, not about the check itself. Either way the rollback is one
setting from the perch.

**Verify:** charon has a `172.16.10.20x` address, reaches `172.16.10.1` and `.2`, and the CSS610 still
answers on `172.16.100.117`. **Rollback:** from the laptop on `Port1`, set `Port2` back to compat.

### 3. The four Sparks → lab access, one port at a time
`Port8` (Spark 1), `Port6` (Spark 2), `Port5` (Spark 3), `Port3` (Spark 4). After each one:

```
ping -c2 172.16.30.<suffix>        # 136 / 137 / 112 / 110 — the static lab lease for that MAC
```

**Only Spark 1 serves inference** (`:8000` answered on `.136`; `.137/.112/.110` refused at the time of
writing), so its endpoint is the *device* acceptance test and the others are verified by ping + SSH.

**Do Spark 1 as the last of the four**, or accept that the agent stays dark until lmproxy is repointed:
Spark 1 is the agent's brain. The lmproxy edit above is the thing that brings it back.

**Also per Spark:** update `sparkrun`'s peer addresses (section above) — its cluster files name the other
three nodes by IP, so a moved Spark cannot reach its peers until they are updated.

**Rollback per port:** set that one port back to compat (untagged VLAN 1) — the Spark re-leases from the
flat pool. Note the flat lease was *dynamic*, so the old address may not come back byte-for-byte; the lab
leases are static by MAC, which is why they are the reliable identity.

### 4. Close out
Run `scripts/css610-window-check.sh post`. State what is now where (trunk 7; mgmt 2; lab 8/6/5/3; compat
4 and 1), and note that the CSS610's own management address is still compat — compat retirement is not
this window's problem. Step 5 (CRS804) follows, gated on charon already being in mgmt.

## Acceptance for the window

| Check | Expected |
|---|---|
| Every Spark | answers on `172.16.30.{136,137,112,110}`; Spark 1's inference endpoint answers on `.30.136:8000` |
| charon | answers on a `172.16.10.20x` lease, reaches router + switches |
| lmproxy | `/opt/lmproxy/config.yaml` points at `172.16.30.136`, service `active`, agent responsive |
| `sparkrun` | peers updated on every node; a cluster command still reaches all four |
| CSS610 management | `172.16.100.117` reachable from the `Port1` laptop |
| CRS326 | still `24/24 hw=yes` (`/interface/bridge/port`, bonds included), `172.16.100.2` answering |
| Router | plan/apply clean (`No changes`), compat LAN unaffected |
| VLAN tables | `10` tagged on `ether4`/`ether18`; `30` present with the uplink ports; `ether3` still untagged mgmt |

## Rollback summary

| Broke | Undo |
|---|---|
| `Port7` (everything behind the box drops) | from the `Port1` laptop: `Port7` → compat-only |
| charon | from the `Port1` laptop: `Port2` → compat |
| one Spark | set that port back to compat; if the agent is dark, restore lmproxy's endpoint first |
| the agent stops answering | expected while Spark 1 moves — the lmproxy edit is the fix, not a fault |
| the box itself unreachable | `Port1` is compat by design; if that fails, config restore from the backup taken in precondition 3 |
