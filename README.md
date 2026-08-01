# Reaching a private-IP app on FLEX, without sharing cloud credentials

Your app sits on a tenant network with a private IP. Nobody outside that network
can route to it. These are the two ways to fix that without ever handing out an
OpenRC file or an application credential.

**Your OpenStack credentials manage infrastructure. They are not, and should
never become, the way people open your app.**

```
                         ┌──────────────────────────┐
   colleague ──────────▶ │  jumphost (floating IP)  │ ─────▶ app (10.x, private)
                         └──────────────────────────┘
                          the only public address
```

## Which path

| | Bastion + SSH tunnel | SSO reverse proxy |
|---|---|---|
| Audience | engineers | anyone in the company |
| They need | an SSH key you install | their normal company login |
| Exposed publicly | nothing (port 22 to your CIDR) | one HTTPS host |
| MFA | no | yes, via Entra Conditional Access |
| Access log | sshd | per-request, per-identity |
| Revoke | delete a key on the box | remove from an Entra group |
| Setup | minutes | needs DNS, a cert, an app registration |

Run both if you like — they are independent and can share one jumphost.

## Setup

```bash
cp env.example env && chmod 600 env && $EDITOR env
chmod +x lib.sh bastion/*.sh sso-proxy/*.sh openstack/*.sh
./selftest.sh                     # sanity-check the kit, touches nothing
```

Every script refuses to run while `env` still holds example values, so a
half-configured run cannot publish an open proxy.

### 1. The jumphost VM (once, for either path)

```bash
source ~/openrc.sh
./openstack/provision-jumphost.sh --plan     # prints commands, runs nothing
./openstack/provision-jumphost.sh
```

Creates one VM, one floating IP, and a security group restricted to
`COMPANY_CIDR`. Your app VM is not touched.

Then confirm the jumphost can actually see the app — this is the step people
skip and then debug for an hour:

```bash
ssh ubuntu@<floating-ip> 'nc -vz <app-private-ip> <port>'
```

If it fails, the **app's** security group needs to allow the jumphost's group.

### 2a. Bastion path

```bash
# on the jumphost
sudo ./bastion/setup-bastion.sh
sudo ./bastion/add-engineer.sh alice /tmp/alice.pub

# on the engineer's laptop
./bastion/tunnel.sh --test
./bastion/tunnel.sh          # then open http://localhost:<port>
```

The account you hand out has **no shell, no SFTP, no agent forwarding**, and can
forward to exactly one host and port. Even a leaked key cannot reach anything
else on your tenant network. That restriction is the entire value of a bastion —
one that gives out a shell is just another internet-facing server.

### 2b. SSO path

Needs, in this order: a DNS A record for `PUBLIC_HOSTNAME` pointing at the
floating IP, an Entra app registration (see
`../cloudmax/docs/SSO_MICROSOFT_ENTRA.md`), and its redirect URI set to
`https://PUBLIC_HOSTNAME/oauth2/callback` — byte for byte.

```bash
sudo ./sso-proxy/setup-sso-proxy.sh --dry-run   # render, install nothing
sudo ./sso-proxy/setup-sso-proxy.sh
./sso-proxy/setup-sso-proxy.sh --verify
```

Then share the URL. No credential changes hands.

## The two checks that matter

`--verify` runs both, and you should re-run them after any config change:

1. **An unauthenticated request must redirect (302), not succeed (200).**
   A 200 means the proxy is open and the app is on the public internet.
2. **A forged identity header must still redirect.**
   ```bash
   curl -sI -H 'X-Forwarded-User: nobody@example.com' https://<host>/
   ```
   nginx passes unknown client headers straight through, so the site blanks
   every header an app might trust. If this returns 200, someone can walk in by
   typing a header.

## Do not

- **Share your OpenRC file or an application credential.** Those grant API
  control of the whole project — create, delete, rotate.
- **Open the security group to `0.0.0.0/0`.** An unauthenticated app on a public
  IP is found by scanners within hours. `provision-jumphost.sh` refuses this.
- **Give the tunnel account a real shell.** Then it is a foothold, not a gate.

## Files

```
env.example                       every setting, one place
lib.sh                            shared helpers, placeholder guard
selftest.sh                       verifies the kit without touching infra
openstack/provision-jumphost.sh   VM + floating IP + security group
bastion/setup-bastion.sh          harden into a tunnel-only host
bastion/add-engineer.sh           add / list / revoke one person
bastion/tunnel.sh                 client side, run on a laptop
sso-proxy/nginx-app-sso.conf.tmpl the proxy site (template)
sso-proxy/setup-sso-proxy.sh      render, install, verify
```
