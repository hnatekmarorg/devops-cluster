# CSS610 cut-over runbook — the first window where devices move

`vlan-port-assignment.md` sets the conventions and the order; this is the operational script for step 3,
the one device in the estate with **no API** (SwOS Lite 2.21, `admin` / empty password, web UI only).
It is also the box on the path to the **work PC** and the Spark management NICs, which is why the
recovery step is written before the change, not after.

## What this window does, and what it deliberately does not

| | Ports | Target |
|---|---|---|
| **In this window** | `Port7` | **trunk** — native/compat VLAN 1 untagged, **tagged members for 10 and 30** |
| | `Port8`, `Port6`, `Port5`, `Port3` (Spark 1…4) | **lab access** — untagged, VLAN 30 only |
| | `Port2` (charon, the work PC) | **mgmt access** — untagged, VLAN 10 only — **last** |
| **Not in this window** | `Port4` (CRS804 `ether1`, the spine's management) | stays **compat** until the CRS804's own move (step 5). Setting it to mgmt now would take the spine off the compat L2 and strand `172.16.100.113` |
| | `Port1` | stays **compat access** — the recovery perch (see below) |

**Why Port1 stays compat rather than "mgmt" like the other switches' escape ports:** the CSS610's only
management address, `172.16.100.117`, lives in **compat**. A laptop on a mgmt-VLAN access port could not
reach it, so the recovery hatch would be useless exactly when it is needed. The convention's *intent*
("a laptop on that port still reaches the gear") is met either way while compat exists — this is the one
local exception, and it is revisited at compat retirement (step 7).

## Preconditions — do not start without these

1. **The trunk VLANs are applied and verified.** The router's `ether4` and the CRS326's `ether18`/`ether4`
   must carry **tagged 10 and 30** (additive change: `terraform/*/stage2-filtering.tf`, `lab_trunk` + the
   extended `mgmt` entry). Verify by reading `/interface/bridge/vlan` on both devices, not from memory —
   and check that the compat LAN is still fine (`172.16.100.1`, `.2`, `.113`, `.117` all answering).
   Without this, a moved port resolves nothing: VLAN 30 has no port on any device, and VLAN 10 does not
   cross the uplink.
2. **A config backup of the CSS610** — SwOS Lite *System → Backup* downloads its config. Do this before
   the first change; restoring is then one upload instead of remembering modes.
3. **A screenshot of the current per-port VLAN state** (the box's own labels), so "what it was" is on
   record next to "what we set".
4. **The ladder:** laptop + patch cable, and the person doing this is **not** on charon. Everything in
   step 4 below is one port-setting away from being reverted from the laptop.
5. The read-only facts to hand: Spark MACs → lab leases `172.16.30.136` (Spark 1), `.137` (Spark 2),
   `.112` (Spark 3), `.110` (Spark 4), all pre-created on the router as static leases; the mgmt pool for
   charon is `172.16.10.200-250`; the CSS610 itself is `172.16.100.117`.

## The window, in order

### 0. Perch (2 min)
Laptop on `Port1`, logged into `http://172.16.100.117`. Confirm from there that you can still reach
`172.16.100.1`, `.2`, `.113` and that the cable you would use to fix a mistake is within reach.

### 1. `Port7` → trunk
Set `Port7` to carry the native/compat VLAN untagged **and** tagged members for VLAN 10 and 30. Nothing
downstream changes yet: every other port is still compat, and compat is still what the trunk's native
VLAN carries.

**Verify:** charon, the four Sparks, the spine and the CSS610's own management all still answer; the
CRS326 and router still answer. If a device drops here, the trunk is wrong — revert `Port7` from the
laptop, nothing else has moved yet.

### 2. The four Sparks → lab access, one port at a time
`Port8` (Spark 1), `Port6` (Spark 2), `Port5` (Spark 3), `Port3` (Spark 4). After each one:

```
ping -c2 172.16.30.<suffix>              # 136 / 137 / 112 / 110 — the static lab lease for that MAC
curl -s http://172.16.30.<suffix>:8000/v1/models | head    # the inference endpoint answers there
```

The management NIC is also the inference NIC, so the endpoint answering on the new address *is* the
device's acceptance test. **Rollback per port:** set that one port back to compat (untagged VLAN 1) — the
Spark re-leases from the flat pool.

**Spark 1 has a config dependency** — the only Spark referenced by name/address on the Hermes host:
`/root/workspace/lmproxy/config.yaml` (`http://172.16.100.136:8000` → `http://172.16.30.136:8000`) plus
`systemctl restart lmproxy`, in the same window or fleet routing points at a dead address. The other
Sparks are referenced only by ad-hoc scripts (`bench_coding.py`, `benchtok.py`), which take a `--host`.

### 3. charon (the work PC) → mgmt access, last
Only once the four Sparks are green: set `Port2` to untagged **VLAN 10 only**. charon should take a lease
from the mgmt pool and reach the gear.

**Before you flip it,** prove the mgmt path is real from *outside* this box: a laptop on the **CRS326's
`ether3`** (the escape port) should get a mgmt lease and reach `172.16.10.1` *and* `172.16.10.2`. That
test is the step-1 acceptance for the CRS326 and it validates the same trunk this window depends on. If
it fails, stop — do not move charon.

**Rollback:** from the laptop on `Port1`, set `Port2` back to compat. charon comes back on its flat
address; you have lost nothing but the time.

### 4. Close out
State out loud what is now where (trunk 7; lab 8/6/5/3; mgmt 2; compat 4 and 1), and note that the
CSS610's own management address is still compat — so compat retirement is not this window's problem. Step 4
of the plan ("move devices one access port at a time") continues from here as the other devices come
across, and step 5 (CRS804) follows, gated on charon already being in mgmt — which it now is.

## Acceptance for the window

| Check | Expected |
|---|---|
| Every Spark's inference endpoint | answers on `172.16.30.{136,137,112,110}:8000` |
| charon | answers on its mgmt address, reaches router + switches |
| CSS610 management | `172.16.100.117` reachable from the `Port1` laptop |
| CRS326 | still `24/24 hw=yes` (`/interface/bridge/port`, bonds included), `172.16.100.2` answering |
| Router | plan/apply clean (`No changes`), compat LAN unaffected |
| VLAN tables | `10` tagged on `ether4`/`ether18`; `30` present with the uplink ports; `ether3` still untagged mgmt |

## Rollback summary

| Broke | Undo |
|---|---|
| `Port7` (everything behind the box drops) | from the `Port1` laptop: `Port7` → compat-only |
| one Spark | set that port back to compat |
| charon | from the `Port1` laptop: `Port2` → compat |
| the box itself unreachable | `Port1` is compat by design; if that fails, config restore from the backup taken in precondition 2 |
