# Infrastructure map

This document maps the physical and logical network. Use it to identify devices and addresses.

## Network domains

| Domain | Purpose | Addressing | Routed | Notes |
|---|---|---|---|---|
| LAN | Estate, servers, and clients | 172.16.0.0/12 | Yes | Carved into class blocks |
| Storage island | NAS block storage | 192.168.88.0/24 | No | No gateway by design; the NAS is 192.168.88.25 |
| Compute fabric | Spark nodes and NAS | 192.168.0.0/24 | No | NAS on the fabric is 192.168.0.250; spine bridge 10.0.0.1/24; jumbo MTU 9000 |

## Device table

| Management name | Role | Model / OS | Address(es) | Class | Access method |
|---|---|---|---|---|---|
| router.mgmt.hnatekmar.dev | Core router | RB5009, RouterOS 7.24.2 | 172.16.10.1; compat 172.16.100.1; WAN on ether5 | mgmt | RouterOS API/SSH |
| crs326.mgmt.hnatekmar.dev | Main switch | CRS326-24G-2S+, RouterOS 7.24.2 | 172.16.10.2; compat 172.16.100.2 | mgmt | RouterOS API/SSH |
| crs804.mgmt.hnatekmar.dev | Compute spine | CRS804-4DDQ, RouterOS 7.24.2 | 172.16.10.201 | mgmt | RouterOS API/SSH |
| crs317.mgmt.hnatekmar.dev | Storage switch | CRS317-1G-16S+ | 172.16.10.203 | mgmt | Hand-applied (non-IaC) |
| — | Access switch | CSS610-8G-2S+, SwOS Lite 2.21 | 172.16.100.117 | compat | Web UI |
| bmc-balteus.mgmt.hnatekmar.dev (IPMI 172.16.10.46) | Proxmox host | Proxmox VE (46 guests) | compat 172.16.100.38 (target srv); rescue 192.168.0.38; storage 192.168.88.20 | srv | SSH root |
| — | Future server | — | idle LACP bond ether23+ether24 on crs326 | srv | None |
| truenas.srv.hnatekmar.dev = 172.16.40.148 and truenas.storage.hnatekmar.dev = 192.168.88.25 | NAS | TrueNAS | iot NIC 172.16.70.148 | srv | SSH root |
| minio.srv.hnatekmar.dev = 172.16.40.148 | S3 store | MinIO | 172.16.40.148 | srv | S3 credentials |
| spark1.lab.hnatekmar.dev = 172.16.30.136, spark2.lab = 172.16.30.137, spark3.lab = 172.16.30.112, spark4.lab = 172.16.30.110 | AI compute | 4 nodes | fabric on 192.168.0.x | lab | SSH martin |
| inference.lab.hnatekmar.dev = 172.16.30.189 | Inference VM | — | 172.16.30.189 | lab | lmproxy |
| runner.mgmt.hnatekmar.dev = 172.16.10.140 | CI runner | ZimaBoard | 172.16.10.140 | mgmt | SSH root |
| personal-hermes.mgmt.hnatekmar.dev = 172.16.10.180 | Operator host | — | 172.16.10.180 | mgmt | SSH root |
| bao.srv.hnatekmar.dev = 172.16.40.33 | Vault | OpenBao | 172.16.40.33 | srv | SSH root |
| adonai.srv.hnatekmar.dev = 172.16.40.24 | k3s mgmt | — | 172.16.40.24 | srv | SSH root |
| proxy.srv.hnatekmar.dev and edge.srv.hnatekmar.dev = 172.16.40.30 | Reverse proxy | — | storage 192.168.88.64 | srv | SSH root |
| gitea.srv.hnatekmar.dev = 172.16.40.124 | Git service | — | 172.16.40.124 | srv | — |
| github-dind.srv = .145 | CI docker | — | 172.16.40.145 | srv | — |
| coder.srv = .210 | Dev env | — | 172.16.40.210 | srv | — |
| kubernetes-sandbox.srv = .111 | Sandbox | — | 172.16.40.111 | srv | — |
| stories-hermes.srv = .188 | Stories UI | — | 172.16.40.188 | srv | — |
| sister-hermes.srv = .203 | Sister host | — | 172.16.40.203 | srv | — |
| dev-cp1.srv.hnatekmar.dev = 172.16.40.100, dev-w1.srv.hnatekmar.dev = 172.16.40.101 | Talos cluster | Talos | alias dev-k8s.srv.hnatekmar.dev | srv | SSO kubeconfig |
| prod-cp1.srv = 172.16.40.120, prod-cp2.srv = .121, prod-cp3.srv = .122, prod-w1.srv = .123 | Talos cluster | Talos | alias prod-k8s.srv | srv | SSO kubeconfig |
| charon.mgmt.hnatekmar.dev = 172.16.10.200 | Operator PC | — | 172.16.10.200 | mgmt | — |
| reader.iot.hnatekmar.dev = 172.16.70.25 | E-reader | Redmi Pad | 172.16.70.25 | iot | — |
| — | TV gateway | — | 172.16.70.125 | iot | — |

## VLAN table

| Class | VLAN ID | Interface | Subnet | Gateway | Host space | Notes |
|---|---|---|---|---|---|---|
| compat | 1 | bridge | 172.16.100.0/24 | 172.16.100.1 | 172.16.100.x | Legacy flat LAN |
| mgmt | 10 | vlan10-mgmt | 172.16.0.0/20 | 172.16.10.1 | 172.16.10.x | Admin plane |
| retired | 20 | none | 172.16.20.0/24 | — | — | Retired |
| lab | 30 | vlan30-lab | 172.16.16.0/20 | 172.16.30.1 | 172.16.30.x | AI compute |
| srv | 40 | vlan40-srv | 172.16.32.0/19 | 172.16.40.1 | 172.16.40.x | Keepers |
| retired | 50 | none | 172.16.50.0/24 | — | — | Retired |
| vpn | 60 | vlan60-vpn | 172.16.96.0/20 | 172.16.96.1 | 172.16.96.x | VPN zone |
| iot | 70 | vlan70-iot | 172.16.64.0/20 | 172.16.70.1 | 172.16.70.x | WiFi and TV |
| parking | 999 | none | — | — | — | Unrouted tag |

## Trunk configuration

The final trunk tag list is: 10, 30, 40, 60, 70.

Use PVID 1 while the compat VLAN drains. Use PVID 999 after the compat VLAN is retired.

## DNS naming

The router is the internal resolver.

The public zone carries a `*.hnatekmar.dev` wildcard. This wildcard answers the ingress VIP 172.16.100.15. The wildcard is not the internal resolver.

The iot class is handed public DNS. It cannot resolve internal names. The reader is the only exception.

### Internal records by class

| Class | Records |
|---|---|
| mgmt | router.mgmt, crs326.mgmt, crs804.mgmt, crs317.mgmt, charon.mgmt, bmc-balteus.mgmt, runner.mgmt, personal-hermes.mgmt |
| srv | truenas.srv, minio.srv, gitea.srv, github-dind.srv, coder.srv, kubernetes-sandbox.srv, stories-hermes.srv, sister-hermes.srv, bao.srv, adonai.srv, proxy.srv, edge.srv, truenas.storage |
| lab | inference.lab, spark1.lab, spark2.lab, spark3.lab, spark4.lab |
| iot | reader.iot |
| cluster | dev-cp1.srv, dev-w1.srv, dev-k8s.srv, prod-cp1.srv, prod-cp2.srv, prod-cp3.srv, prod-w1.srv, prod-k8s.srv |

## Scope

The compute/RDMA fabric bridge and the storage island are not part of the VLAN carve. IPv6 is out of scope.

## Diagrams

The following diagrams are measured as-is:

- [Network wiring](../agent/network-wiring.svg)
- [Network map current](../agent/network-map-current.svg)
- [VLAN port assignment](../agent/vlan-port-assignment.svg)
