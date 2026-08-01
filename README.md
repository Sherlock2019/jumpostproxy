# jumphostproxy

Reach an app that lives on a **private IP** inside a FLEX / OpenStack tenant
network, and share it with colleagues, **without giving anyone a cloud
credential**.

> Your OpenStack credentials manage infrastructure. They are not, and should
> never become, the way people open your app.

```
                         ┌──────────────────────────┐
   colleague ──────────▶ │  jumphost (floating IP)  │ ─────▶ your app (10.x, private)
                         └──────────────────────────┘
                          the only public address
```

---

## Quick start

```bash
git clone git@github.com:Sherlock2019/jumpostproxy.git
cd jumpostproxy
chmod +x *.sh */*.sh                    # only if you cloned onto Windows/WSL

./install-requirements.sh --check       # what this machine is missing
sudo ./install-requirements.sh          # install it

./launch.sh --init                      # creates ./env
$EDITOR env                             # fill in the values it marks
./launch.sh                             # re-check until "Config looks complete"
```

`./launch.sh` never creates, changes or deletes anything. Run it as often as you
like, including before you have any credentials.

### Requirements

`install-requirements.sh` works out what this machine is for and installs only
that — the three machines involved need different things:

| Role | Machine | Installs |
|---|---|---|
| `control` | your laptop | `python3-openstackclient` (to create the jumphost) |
| `bastion` | the jumphost, tunnel path | `openssh-server`, `fail2ban`, `ufw` |
| `sso` | the jumphost, SSO path | `nginx`, `certbot`, **`oauth2-proxy`** |

Plus `curl`, `openssl`, `envsubst`, `jq`, `nc` everywhere. It guesses the role
and you can override with `--control` / `--bastion` / `--sso` / `--all`.

`oauth2-proxy` is not in the distro repos, so it is fetched from its GitHub
release and **verified against the `checksums.txt` published with that same
release** — not against a hash pinned in this repo that nobody would re-check.

---

## Which of the two paths do you want?

| | **Bastion + SSH tunnel** | **SSO reverse proxy** |
|---|---|---|
| Audience | engineers | anyone in the company |
| They need | an SSH key you install | their normal company login |
| Exposed publicly | nothing (port 22, your CIDR only) | one HTTPS hostname |
| MFA | no | yes, via Entra Conditional Access |
| Audit | sshd log | per-request, per-identity |
| To revoke | delete a key on the box | remove them from an Entra group |
| Setup effort | minutes | needs DNS + a cert + an Entra app registration |

They are independent and can share one jumphost. Start with the bastion if you
just need two colleagues looking at something today.

---

## Filling in `env`

Only four values matter to begin with:

| Variable | What it is | How to find it |
|---|---|---|
| `APP_PRIVATE_IP` | the app's address on the tenant network | `openstack server show <vm> -c addresses` |
| `APP_PORT` | the port it listens on | on the app VM: `ss -ltnp` |
| `COMPANY_CIDR` | who may reach the jumphost at all | ask your network team for the office/VPN egress range |
| `BASTION_FLOATING_IP` | filled in **after** you create the jumphost | printed by `provision-jumphost.sh` |

`COMPANY_CIDR` is the outer gate. **Never `0.0.0.0/0`** — the scripts refuse it.

The SSO path needs a few more (`PUBLIC_HOSTNAME`, the three `ENTRA_*` values).
Leave them alone if you are only doing the bastion.

---

## Step 1 — create the jumphost (once, for either path)

```bash
source ~/openrc.sh
./openstack/provision-jumphost.sh --plan     # prints every command, runs none
./openstack/provision-jumphost.sh            # creates it
```

Makes one VM, one floating IP, and a security group locked to `COMPANY_CIDR`.
**Your app VM is not touched.** Put the printed IP into `env` as
`BASTION_FLOATING_IP`.

### Then check the one thing everyone skips

```bash
ssh ubuntu@<floating-ip> 'nc -vz <app-private-ip> <app-port>'
```

If that fails, nothing downstream will work — the **app's** security group needs
to allow the jumphost's group. Fix it here, not after three more steps.

---

## Step 2a — bastion path

On the jumphost:

```bash
sudo ./bastion/setup-bastion.sh
sudo ./bastion/add-engineer.sh alice /tmp/alice.pub
```

Ask each engineer for their **public** key (`~/.ssh/id_ed25519.pub`). Never their
private key.

On the engineer's laptop:

```bash
./bastion/tunnel.sh --test        # probes the whole path and exits
./bastion/tunnel.sh               # opens the tunnel, hold it open
```

Then they open `http://localhost:<APP_PORT>`.

Managing people:

```bash
sudo ./bastion/add-engineer.sh --list
sudo ./bastion/add-engineer.sh --revoke alice
```

**What their key can and cannot do.** The account has no shell, no SFTP and no
agent forwarding, and the key is installed with `restrict,permitopen="app:port"`
— it can forward to exactly one host and port. If that key leaks, it still
cannot reach any other machine on your tenant network. A bastion that hands out
a shell is just another internet-facing server; this one is a gate.

---

## Step 2b — SSO path

Prerequisites, in this order:

1. A DNS **A record** for `PUBLIC_HOSTNAME` pointing at the floating IP.
2. An **Entra app registration** — single tenant, redirect URI
   `https://PUBLIC_HOSTNAME/oauth2/callback`, byte for byte. A client secret.
   Ask your identity team to scope the MFA Conditional Access policy to it.
3. `oauth2-proxy` installed on the jumphost
   ([releases](https://github.com/oauth2-proxy/oauth2-proxy/releases)).

Then:

```bash
sudo ./sso-proxy/setup-sso-proxy.sh --dry-run    # renders, installs nothing
sudo ./sso-proxy/setup-sso-proxy.sh              # installs + starts
./sso-proxy/setup-sso-proxy.sh --verify
```

Share `https://PUBLIC_HOSTNAME`. Colleagues sign in with their company account
and Authenticator. **You share a link, not a credential.**

### The two checks that decide whether this is safe

`--verify` runs both. Re-run it after any config change.

```bash
# 1. an unauthenticated request must REDIRECT (302), not succeed (200)
curl -sI https://<host>/ | head -1

# 2. a forged identity header must still redirect
curl -sI -H 'X-Forwarded-User: nobody@example.com' https://<host>/ | head -1
```

A `200` on either means the app is open to the internet. nginx forwards unknown
client headers verbatim, so the site blanks every header an app might trust —
without that, a visitor could type a header and become anyone.

---

## Troubleshooting

**"I can't reach the private IP from my laptop."** Correct, and expected. A
`10.x` address is not routable outside the tenant network. That is the entire
problem this repo solves — you need the jumphost.

**The app answers on `127.0.0.1` but not on its private IP.** It is bound to
localhost. Check with `ss -ltnp` on the app VM: if you see `127.0.0.1:PORT`
instead of `0.0.0.0:PORT`, change the app's bind address. This is the single most
common cause.

**`tunnel.sh` connects but the page does not load.** Something else already holds
the local port. Run `LOCAL_PORT=9001 ./bastion/tunnel.sh`.

**"Permission denied" running any script.** Cloned onto Windows/WSL, which drops
the executable bit: `chmod +x *.sh */*.sh`.

---

## What is in here

```
install-requirements.sh           installs what this machine's role needs
launch.sh                         dry-run everything; --init creates env
selftest.sh                       33 checks, touches no infrastructure
env.example                       every setting, one place
lib.sh                            shared helpers + the placeholder guard
openstack/provision-jumphost.sh   VM + floating IP + locked security group
bastion/setup-bastion.sh          harden into a tunnel-only host
bastion/add-engineer.sh           add / list / revoke one person
bastion/tunnel.sh                 client side, run on a laptop
sso-proxy/nginx-app-sso.conf.tmpl the proxy site (template)
sso-proxy/setup-sso-proxy.sh      render / install / verify
```

## Safety properties

- Every script **refuses to run while `env` holds example values**, so a
  half-configured run cannot publish an open proxy.
- `provision-jumphost.sh` **refuses `COMPANY_CIDR=0.0.0.0/0`**.
- `--plan` / `--dry-run` on both infrastructure scripts.
- `setup-bastion.sh` validates sshd with `sshd -t` **before** reloading, so a bad
  edit cannot lock you out of the VM.
- `env` and the rendered `oauth2-proxy.cfg` are gitignored — they hold internal
  addresses and a client secret.

```bash
./selftest.sh     # 33 checks: syntax, guards, IPv4 validation, nginx accepting
                  # the rendered site, header blanking, SSH key restrictions,
                  # and that no secret can reach git
```

## Never

- **Share your OpenRC file or an application credential.** Those grant API
  control of the whole project — create, delete, rotate.
- **Open a security group to `0.0.0.0/0`** in front of an app with no auth.
  Scanners find it within hours.
- **Give the tunnel account a real shell.** Then it is a foothold, not a gate.
