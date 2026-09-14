# `terraform/secrets/` — CI credential material

| File | Committed? | What |
|---|---|---|
| `routeros-ci.env.template` | yes | The shape of the credential file + the exact sops command |
| `routeros-ci.env` | **no** (gitignored, mode 600) | The plaintext source of truth — stays on the box that encrypts it |
| `enc.routeros-ci.env` | yes | The sops-encrypted file the workflow decrypts |

The committed `enc.routeros-ci.env` currently holds **placeholder values**
(`CHANGE_ME_*`), encrypted to the estate age recipient. That is deliberate: it
makes the repository shape final and the decrypt path end-to-end testable, while
the credentials themselves stay out of git. Replace it in one command (see the
template) when the RouterOS users and the state store exist.

This flow is **path (b)** in [`../README.md`](../README.md). Path (a) — a cluster
Secret mounted into the runner pod, no age key in the pod — is preferred and
needs nothing in this directory.
