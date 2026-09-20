# Network schema

This document defines the rules for the network.

## Subnets and blocks

Use one subnet per class. Each class has a block size.

The gateway is the .1 address of the class host area.

**NOTE:** The VLAN ID is not the same as the third octet of the subnet. For example, the mgmt class uses VLAN 10. The subnet for mgmt is 172.16.0.0/20. The hosts for mgmt use 172.16.10.x.

## DHCP and identities

Lease time is 10 minutes.

| Class | DHCP Pool Range |
|---|---|
| mgmt | .10.200–.250 |
| lab | .30.20–.99, .30.200–.250 |
| srv | .40.20–.99, .40.200–.250 |
| iot | .70.20–.99, .70.200–.250 |

DHCP pools avoid addresses .100 to .199. This avoids conflicts with fixed identities.

Fixed identities keep their suffix when they move classes.
Example: spark1 keeps .136 when moving from compat 172.16.100.136 to lab 172.16.30.136.

## Service VIPs

The service VIP block is 172.16.48.0/20 inside srv. MetalLB uses L2 mode. The node and pool are in the same subnet.

## Naming scheme

| Type | Format | Example |
|---|---|---|
| Machine | `<host>.<class>.hnatekmar.dev` | spark1.lab.hnatekmar.dev |
| Service | `<service>.srv.hnatekmar.dev` | gitea.srv.hnatekmar.dev |

## Resolver rules

Each class is handed the router's address in that class. The iot class gets public DNS. DNS records are not access control.

## Exceptions

### Storage and fabric

The storage and compute fabric networks are air-gapped. They have no gateway.

The NAS has two names:
- `truenas.srv`: Answers on the 1G management plane.
- `truenas.storage`: Answers on the 10G fabric.

Storage clients must use the storage name. If a client uses the wrong name, it uses the 1G path. The connection does not fail.

### Retired VLANs

Do not allocate addresses for retired VLAN numbers.
