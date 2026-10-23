🇬🇧 English | [🇮🇹 Italiano](README.md)

# OpenWISP2 full + ZeroTier + WiFi Login Pages

Ansible playbook that installs on a CT (Debian 13 / Ubuntu 22.04+):

- **OpenWISP2 full**: controller, monitoring, network topology, firmware upgrader, RADIUS
- **WiFi Login Pages** (captive portal)
- **Self-hosted ZeroTier controller** on the same CT, managed by OpenWISP

The SSL certificate is **not** managed by the playbook: you upload it to the CT yourself (see below).

## Prerequisites

- CT with Debian 13 or Ubuntu 22.04/24.04, SSH access as root (or a sudo user)
- Ansible ≥ 2.13 on the machine you run the playbook from
- **If the CT is an LXC container on Proxmox**: ZeroTier uses `/dev/net/tun`,
  which must be exposed to the *unprivileged* container:

  ```
  # /etc/pve/lxc/<ID>.conf
  lxc.cgroup2.devices.allow: c 10:200 rwm
  lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
  ```

## 1. Roles and configuration

Roles and collections are installed **inside the repo** (`roles/` and
`collections/`, see `ansible.cfg`) from the latest GitHub releases.
To (re)install or update them:

```bash
ansible-galaxy role install -r requirements.yml -p roles/ --force
ansible-galaxy collection install -r requirements.yml -p collections/ --force
```

Then edit:

- `hosts` → **the inventory host name IS the OpenWISP domain**
  (the role uses it for nginx and Django): replace `openwisp.example.com`
  with your real domain and `ansible_host` with the CT IP
- `playbook.yml` → `wifi_login_pages_domains`, e-mail
- `owlp_organizations/` → organization settings for the login pages
- `secrets.yml` → copy it from `secrets.example.yml` and set the RADIUS secret

## 2. Run (OpenWISP + ZeroTier + WiFi Login Pages)

```bash
ansible-playbook -i hosts playbook.yml
```

The playbook installs, in order: OpenWISP + WiFi Login Pages (Play 1), the
ZeroTier controller (Play 2), the nftables firewall (Play 3), bird2/Babel (Play 4).

When it is done, go to `https://<your-domain>/admin`: the role creates the user
**admin / admin** — change the password right away at
`https://<your-domain>/admin/password_change/`.

> **First install — freeradius note**: on a new CT the role's "Restart
> freeradius" handler can fire before nginx is serving on 443.
> `rlm_rest` opens a pool to `https://<domain>/api/v1/freeradius` and, if
> nginx is not answering yet, freeradius does not start and the play stops. If
> that happens: `systemctl restart nginx && systemctl restart freeradius`, then
> run the playbook again (the steps already done are idempotent).

## 3. Manual SSL certificate

The playbook points to the certificate already present on the CT:

- `/etc/ssl/acme/ninux-nnxx.it.fullchain.pem`
- `/etc/ssl/acme/ninux-nnxx.it.key`

The role generates a self-signed certificate **only if the files do not exist**,
so it will never touch them: you renew them yourself (after the renewal:
`systemctl reload nginx`).

> The certificate must cover both `openwisp.ninux-nnxx.it` and
> `wifi.ninux-nnxx.it` (wildcard `*.ninux-nnxx.it` or SAN). Check with:
> `openssl x509 -in /etc/ssl/acme/ninux-nnxx.it.fullchain.pem -noout -text | grep DNS`

## 4. ZeroTier VPN

**Design**: the VPN only lets the routers see each other and exchange routes
via Babel — **each router keeps its own gateway and OpenWISP is NOT a
gateway** (no NAT, no default route through the tunnel).

It uses **ZeroTier** with a **self-hosted controller on the same CT**: ZeroTier
provides an L2 network where Babel discovers its neighbours via multicast, as in
the historical NINUX design. On the routers the interface is called
`owzt<6 hex digits of the network id>`, and Babel runs on it.

### 4a. ZeroTier controller (Play 2)

Play 2 (`--tags zerotier`) installs `zerotier-one` on the CT (official signed
script) and starts the service. The node becomes the controller of the network
OpenWISP will create. At the end the play prints the **node address** and the
path of the API token.

### 4b. Create the VPN in OpenWISP

Admin → **VPN servers** → Add:

- Backend: **ZeroTier**
- Host: `127.0.0.1:9993` (the controller runs on the same CT as OpenWISP;
  the ZeroTier API listens locally on 9993)
- AuthToken: the content of `/var/lib/zerotier-one/authtoken.secret` on the CT
  (`sudo cat /var/lib/zerotier-one/authtoken.secret`)
- Subnet: `10.27.255.0/24` (the same as `bird_vpn_subnet_v4` /
  `firewall_radius_sources_v4` in the plays) — the network managed by ZeroTier

On save, OpenWISP detects the controller's node address and **creates the
ZeroTier network**, whose members and addresses it then manages.

> The public name `zerotier.ninux-nnxx.it` (a CNAME of openwisp) is only a DNS
> reference: the VPN object still uses `127.0.0.1:9993`, because OpenWISP
> talks to the controller's local API.

### 4c. Client template

In Admin → **Templates** → Add:

- Type: **VPN-client**
- VPN: the ZeroTier VPN created above
- Automatic tunnel provisioning: **enabled** (for each device OpenWISP generates
  `zerotier_member_id`, `identity_secret` and the internal IP, and authorizes it
  on the network)

On the router the resulting interface is `owzt<id>`: Babel builds its
adjacencies on it (already configured in the bird template as `owzt*`). The rest
of the router configuration (kernel/direct/babel/OSPF for the default route via
`br-mesh`) is unchanged.

> **Routers without their own Internet connection**: they work without changes.
> They learn the default route from the neighbouring mesh nodes via OSPF on
> `br-mesh`, and ZeroTier reaches its peers through the current gateway (UDP
> 9993, it follows the default route). The Babel filters make sure the default
> route never comes from the VPN.

## 4d. Firewall

The `firewall` play (nftables) applies a **default drop** inbound policy.
No NAT: OpenWISP is not a gateway; forwarding is allowed **only**
`zt* → zt*` (router↔router traffic through the hub; on the server the ZeroTier
interface is `zt<id>`, on the routers `owzt<id>`).

CT interfaces: **ens18** = management network (10.27.22.18, 2a07:7e81:3f1c::18),
**ens19** = public IP (194.28.98.61/29), **zt<id>** = ZeroTier VPN (10.27.255.1).

| Port | Proto | From | Service |
|-------|-------|-----|----------|
| 2400  | TCP   | management network only (`10.27.0.0/16`) | SSH |
| 80, 443 | TCP | anywhere | nginx (OpenWISP + WiFi Login Pages) |
| 9993  | UDP   | anywhere | ZeroTier (controller + data plane) |
| 1812–1813 | UDP | VPN (10.27.255.0/24) and management (10.27.0.0/16) only | FreeRADIUS |
| 6696  | UDP   | `zt*`, `ens18` and `ens19` interfaces only | Babel (bird2) |

The play can also be applied on its own with `--tags firewall`.

<a id="babel"></a>
## 4e. BIRD / Babel (NINUX network)

Routing between the NINUX nodes is done by **Babel** (RFC 8966), a
distance-vector protocol designed for mixed wireless and wired networks. In
community networks it does the same job as OLSR or batman-adv. It is
implemented by **BIRD**: Debian's `bird2` (2.17) on the server, **BIRD 3**
(3.3.x) on the routers running the NINUX firmware on OpenWrt 25.12. The Babel
configuration is the same in both versions.

![Babel topology of the NINUX network in OpenWISP](docs/topology-babel.png)

*The "Babel NINUX" topology on 21/10/2026, drawn with netjsongraph.js (the
library used by the OpenWISP visualizer) and with its colours. Only links that
are up are shown. On the left the ReginaMargherita116 site (cable and radio),
on the right the remote sites, reachable only through the VPN.*

### Links and rxcost

Each node announces its own LAN (`br-lan`, one /24 per node) and learns the
others'. Babel picks the path with the lowest total metric, and the `rxcost`
values are set so that **cable always beats radio, and radio always beats the VPN**:

| Link | Interface (router / server) | Babel type | `rxcost` |
|---|---|---|---|
| Cable (same LAN) | `br-lan`, and `wan` where needed / `ens18`, `ens19` | `wired` | 96 |
| 802.11s radio (SAE-encrypted mesh) | `br-mesh` / – | `wireless` | 256 and up, depending on link quality |
| ZeroTier VPN | `owzt*` / `zt*` | default | 600 |

Rules shared by all nodes:

- the **default route never goes through Babel**, neither announced nor
  imported (filters `net != 0.0.0.0/0` and `net != ::/0`): every node keeps its
  own Internet gateway;
- nodes without their own connection learn the default route from their mesh
  neighbours via **OSPF**, on `br-mesh` only, with BFD to quickly detect a radio
  link going down;
- `check link yes`: an interface with no link (or that does not exist yet, like
  the VPN before joining) is ignored, so it can be configured in advance.

### Server (Play 4)

The `bird` play (same-named tag) installs **bird2** and applies
`templates/bird.conf.j2`. The configuration is validated with `bird -p` before
it is applied.

| Variable | Value | Purpose |
|---|---|---|
| `bird_wan_interface` | `ens19` | the router id is taken from here |
| `bird_vpn_interface` | `zt*` | ZeroTier VPN: Babel with `rxcost 600` |
| `bird_vpn_subnet_v4` | `10.27.255.0/24` | ZeroTier subnet, announced as a connected network |
| `bird_direct_extra_interfaces` | `ens18` | the management LAN is announced as connected too |
| `bird_babel_interfaces` | `zt*`, `ens19`, `ens18` | interfaces where the server speaks Babel |

- the **direct `vpn`** protocol announces the ZeroTier subnet and the
  management LAN. Originating them on the server makes them reach the routers
  with a metric of ~0: the remote routers route back through the server,
  instead of through a test node with its WAN on the same LAN;
- `kernel4`/`kernel6` with `scan time 20`, `learn yes`, `merge paths yes` and
  `import` closed: the server already has its default route and imports
  nothing from the kernel;
- the firewall (Play 3) accepts Babel (UDP 6696) only on `zt*`, `ens18` and
  `ens19`.

> Note: the server's `zt*` interface only exists after the VPN has been created
> in OpenWISP and the CT has joined the ZeroTier network; with `check link yes`
> bird ignores it until it shows up, so the play can be run before that.

### Routers ("Bird2 Babel (routing)" template)

On the routers the configuration comes from OpenWISP through the **Bird2 Babel
(routing)** template (default and required). The source is
`openwisp-templates/router-files/bird.conf`; the template JSON is regenerated
with `openwisp-templates/build_bird_template.py`, which also includes
`post-reload-hook`. openwisp-config runs it after every configuration apply:
it creates the "VPN" (`owzt*`) and "mesh" (`br-mesh`) firewall zones, without
which the inbound REJECT policy blocks Babel (one-way adjacency, infinite
metric), then installs or reloads bird.

- `protocol direct lan`: announces the node's LAN (`br-lan`);
- `protocol babel ninux`: interfaces `owzt*` (VPN, `rxcost 600`), `br-lan` (cable, `rxcost 96`),
  `br-mesh` (radio) and `{{ babel_wired_extra }}`;
- `babel_wired_extra` is for nodes whose wired uplink is on an interface other
  than `br-lan`. Routers connected to the ReginaMargherita116 LAN through their
  `wan` port (WRT3200ACM, C2600, X5000R) use the **Uplink LAN su wan** template
  (`openwisp-templates/uplink-lan-wan.json`): it sets the variable to `wan`,
  allows Babel and SSH from the LAN in the `wan` zone and puts the agent's
  management on `wan`. The default `none-babel` matches no interface, so
  elsewhere the block does nothing. Do not use it for the `wan` of remote sites,
  which there is the ISP modem;
- `protocol ospf v3 internet_v4`: only for the default route via `br-mesh`;
  `wan_interface` (default `wan`, from the template `default_values`) is the
  stub from which a node with its own Internet connection announces it.

**The firmware must stay in sync**: the static bird files in the
[ansible-ninux-openwrt](https://github.com/mikysal78/ansible-ninux-openwrt)
repo must be updated if interfaces or templates change here.

### Checking

On the server (`ssh -p 2400 root@10.27.22.18`) or on a router:

```bash
birdc show babel interfaces     # Babel interfaces, rxcost, number of neighbours
birdc show babel neighbors      # neighbours (fe80::), metric, interface
birdc show route protocol ninux # routes learned via Babel
birdc show route for 10.27.1.0/24 all   # which way a LAN is reached
```

A neighbour listed in `show babel neighbors` with a stable metric is a working
link; `Routes 0` means a neighbour that is seen but from which nothing is
learned.

<a id="babel-topology"></a>
### Babel topology in Network Topology

netdiff, the library OpenWISP Network Topology uses to read topologies, has
parsers for OLSR, batman-adv, BMX6, OpenVPN, WireGuard and ZeroTier, but
**none for Babel**. Moreover Babel is distance-vector: each node only knows its
own neighbours, so the whole topology can only be obtained by merging what all
nodes see. We discussed it with the maintainers in
[openwisp/netdiff#101](https://github.com/openwisp/netdiff/issues/101): the
solution stays this script, documented here for anyone using BIRD/Babel.

The script `files/topology_babel_feed.py` (cron every 5 minutes, tag
`topology`):

1. runs `birdc show status; birdc show babel interfaces; birdc show babel
   neighbors` on the server and, over SSH with the server's root key, on every
   device at its management IP (in parallel, 30 s timeout);
2. merges the neighbour tables into a **NetJSON NetworkGraph**;
3. passes it to `Topology.receive()` of the **"Babel NINUX"** topology.

How nodes and links are built:

- **Nodes**: id `<device MAC>@babel`. This is the format the
  `openwisp_network_topology.integrations.device` integration (enabled through
  `openwisp2_extra_django_apps`) uses to bind the node to the device, so the
  device page can be opened from the topology. The server is the
  `openwisp@babel` node. Properties include the router id and the Babel
  interfaces.
- **Neighbours**: an `fe80::` neighbour is assigned to the router that lists it
  as its own v6 next hop in `show babel interfaces`. If a router does not
  answer, the map from the previous run
  (`/opt/openwisp2/topology_babel_cache.json`) and the EUI-64 of the device MAC
  are used. An `fe80::` address that belongs to no device becomes an
  "(unmanaged)" node.
- **Links**: one per pair of nodes, using the cheapest adjacency in each
  direction (as Babel does). The link `cost` is the worse of the two directions;
  `type` (`cavo` = cable, `radio`, `vpn` or `misto` = mixed), `costs`,
  `interfaces` and `all_costs` (backup adjacencies too, e.g. radio + cable) are
  in the properties. This is why AP-1 and AP-2 in the picture, connected both by
  cable and by radio, appear as a cable link.
- **VPN included** (`INCLUDE_VPN = True`): on the ZeroTier VPN everyone sees
  everyone, so between ZeroTier nodes the graph is a full mesh (`vpn` links,
  `cost` ~600). Where there is also radio or cable, the link uses the cheapest
  adjacency and the VPN stays in `all_costs`. With `False` the sites connected
  only through the VPN show up as isolated nodes.

**Creating the topology** (once, in admin → Network Topology → Topologies →
Add): label `Babel NINUX`, parser **NetJSON NetworkGraph**
(`netdiff.NetJsonParser`), strategy **RECEIVE**, expiration time **330** s
(a bit more than the 5-minute cron: a link that is no longer reported goes
down). The receive key is not needed, because the script writes directly to the
model.

Dry run (prints the NetworkGraph without sending it):

```bash
cd /opt/openwisp2
BABEL_FEED_DRY_RUN=1 env/bin/python manage.py shell < topology_babel_feed.py
```

**Colours in the visualizer**: the OpenWISP visualizer colours links only by
status (up green, down red). The playbook (tag `topology`) installs a copy of
`netjsongraph/netjsongraph-script.html` in `/opt/openwisp2/templates/`, which
Django reads before the one in the package. This copy colours up links by
`type`: **cable blue**, **VPN purple, dashed and thin**, **mixed teal**; radio
and links without a type (e.g. the ZeroTier topology) stay green, and all down
links red. The template is copied from openwisp-network-topology **1.3**: after
every upgrade of the module it must be compared with the original and realigned
(`files/django-templates/netjsongraph/netjsongraph-script.html`).

## 5. WiFi Login Pages

The login pages answer on `https://wifi.<domain>`. The
[openwisp-wifi-login-pages](https://github.com/openwisp/openwisp-wifi-login-pages)
app is cloned and built by the `openwisp.wifi_login_pages` role (nothing to do
by hand). Each organization needs a YAML file in `owlp_organizations/` with its
UUID and RADIUS token (see `owlp_organizations/README.md`), then run the
playbook again.

## 6. Router logs (syslog and netconsole)

The server collects two log streams from the routers (Play 5, rsyslog), under
`/opt/router-logs/`:

| Stream | On the router | On the server |
|---|---|---|
| syslog (kernel + services) | **Log remoto (syslog)** template, UDP 514 | `/opt/router-logs/<hostname>/syslog.log` |
| netconsole (kernel only, real time) | **Netconsole** template, UDP 6666 | `/opt/router-logs/netconsole-<device name>/netconsole.log` |

netconsole is meant for hangs and kernel panics: messages keep arriving until
the very last moment, even when syslog has no time to send them. It has no
syslog header: the template uses the extended format and adds to every message
the `ninux_node` userdata with the device name in OpenWISP, which rsyslog uses
for the folder. This way the logs of a router stay together even when the IP it
sends from changes (LAN, `wan`, mesh, ZeroTier). The userdata requires the
firmware from build #37 onwards (`kmod-netconsole` built with
`NETCONSOLE_DYNAMIC`); messages without a name (older firmware, fragments of
long messages) go to `netconsole-<source ip>/`.

The same logs can be read in OpenWISP, in the **Netconsole** tab of the device
page: [openwisp-netconsole](https://github.com/mikysal78/openwisp-netconsole)
module, installed by Play 1 (`openwisp2_extra_python_packages` and
`openwisp2_extra_django_apps`). It shows the folder named after the device and
the ones named after its IPs (management IP and last IP), refreshes by itself
and lets you download the rotated files. OpenWISP (`www-data`) reads the logs
through the `router-logs` group (Play 5), read-only.

Reading them (from the server, `ssh -p 2400 root@10.27.22.18`):

```bash
ls /opt/router-logs/                                    # one folder per router
tail -f /opt/router-logs/X5000R/syslog.log              # real time
tail -f /opt/router-logs/netconsole-*/netconsole.log    # kernel of all routers
grep -i "oops\|panic\|watchdog" /opt/router-logs/*/syslog.log
zgrep -i "panic" /opt/router-logs/C2600/syslog.log.*.gz # previous days
```

Rotation: daily, or above 50 MB (checked every hour,
`/etc/cron.d/router-logs`). Logs are kept for at most 15 days and 30 files, the
older ones compressed. These are the Play 5 starting values: they can be changed
in OpenWISP on the **Monitoring → Router log rotation** page (superusers only),
within fixed ranges (5–100 MB, 7–90 days, 7–60 files). OpenWISP only saves a
JSON file. The root script `/usr/local/sbin/router-logs-rotation` checks it
again every hour, generates `/etc/logrotate-router-logs.conf` and runs
logrotate; running the playbook again does not overwrite the chosen values.

The firewall (Play 3) accepts logs only from the NINUX network (10.27.0.0/16 on
the LAN, 10.27.255.0/24 via ZeroTier) and from the public IP of the border
router, with a per-source rate limit. netconsole on the routers requires the
NINUX firmware from build #34 onwards (`kmod-netconsole` in `base.config`,
which also brings netpoll support into the kernel); before that, the template
script writes in the router's syslog that the module was not loaded.

## 7. Router LuCI from OpenWISP

On every device page the **LuCI ↗** button opens the web interface of the
router in a new tab, through the server: module
[openwisp-luci](https://github.com/mikysal78/openwisp-luci) (Play 6). The
router only needs to be reachable from the server, not from the browser; the
LuCI login is still the router's own.

- Address: `https://<device uuid without dashes>.luci.ninux-nnxx.it`, one host
  per router (cookies and sessions of a router never reach the other ones).
  It needs the `*.luci.ninux-nnxx.it` DNS record (`*.luci` alias of the
  `openwisp` record in ansible-dns) and the `luci.ninux-nnxx.it` + `*.luci`
  certificate (`acme_domains` in ansible-dns, deployed to 10.27.22.18): Play 6
  stops if the certificate is missing.
- Only users who can change the device see the button; the link is valid once
  for 60 seconds, then a cookie for 4 hours. On every request nginx asks
  OpenWISP (auth_request) whether the user is still allowed and which IP to use.
- The proxy only goes to the management IP of the device and only within
  10.27.0.0/16, over HTTPS (self-signed router certificate, not verified).
- Routers managed on the wan (**Uplink LAN su wan** template): the
  `Allow-LuCI-OpenWISP` rule opens port 443 to 10.27.22.18 only.
- The OpenWISP session cookie is named `__Host-sessionid`: the `*.luci`
  subdomains cannot overwrite it.
- Every opening is in the OpenWISP log (`LuCI di <device> aperta da <user>`),
  the requests in `/var/log/nginx/openwisp-luci.access.log`.
