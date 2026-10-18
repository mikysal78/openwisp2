"""
Template OpenWISP "Nomi dei nodi (hosts)": nome di ogni nodo NINUX per i suoi IP
e per i MAC della mesh, distribuito a tutti i router.

Senza, sulla mesh si vedono solo indirizzi (10.27.99.x, 10.27.255.x): nessun
DNS conosce il nome dei nodi e la risoluzione inversa da' NXDOMAIN. Il template
porta sui router:
  - /etc/ninux-hosts, letto da dnsmasq (addnhosts), anche per la risoluzione
    inversa (LuCI "Connessioni", nslookup, traceroute):
        10.27.99.1   X5000R        (mesh)
        10.27.255.2  X5000R-zt     (ZeroTier)
        10.27.30.1   X5000R-lan    (br-lan)
        10.27.22.244 C2600-mgmt    (IP di gestione, se non e' gia' tra i precedenti)
  - una sezione dhcp 'host' per nodo con i MAC di mesh0/br-mesh: LuCI
    (rpcd-mod-luci, getHostHints) la usa per dare un nome alle stazioni
    associate. Non si tocca /etc/ethers, che sui router ha voci locali.
dnsmasq non rilegge da solo i file addnhosts: l'opzione ninux_hosts_rev
(impronta del contenuto, ignorata dall'init di dnsmasq) cambia /etc/config/dhcp
a ogni modifica dell'elenco, e openwisp-config ricarica dnsmasq.

Dati: le interfacce che i router inviano a openwisp-monitoring (DeviceData),
con l'IP mesh della subnet division come riserva. Il template si aggiorna solo
se il contenuto cambia (ogni salvataggio fa riscaricare la config a tutti).
L'assegnazione ai device esistenti si fa una volta a mano: "default" vale solo
per i device nuovi, e lo script non rimette il template a chi lo ha tolto.

Uso (cron, vedi playbook):
    /opt/openwisp2/env/bin/python /opt/openwisp2/manage.py shell < sync_node_hosts.py
"""

import hashlib
import ipaddress
import re

from openwisp_controller.config.models import Device, Template
from openwisp_users.models import Organization

ORG_SLUG = "basilicata"
TEMPLATE_NAME = "Nomi dei nodi (hosts)"
HOSTS_PATH = "/etc/ninux-hosts"
NINUX_NET = ipaddress.ip_network("10.27.0.0/16")


def ipv4_of(interface):
    return [
        a["address"]
        for a in interface.get("addresses", [])
        if a.get("family") == "ipv4" and a.get("address")
    ]


def node_entries(device):
    """(ip, nome) e MAC della mesh di un device."""
    try:
        from openwisp_monitoring.device.models import DeviceData

        data = DeviceData.objects.get(pk=device.pk).data or {}
    except Exception:
        data = {}
    ips, macs = [], []
    for iface in data.get("interfaces", []):
        name = iface.get("name", "")
        if name == "br-mesh":
            suffix = ""
        elif name.startswith("owzt"):
            suffix = "-zt"
        elif name == "br-lan":
            suffix = "-lan"
        else:
            suffix = None
        if suffix is not None:
            ips += [(ip, device.name + suffix) for ip in ipv4_of(iface)]
        if name in ("br-mesh", "mesh0") and iface.get("mac"):
            macs.append(iface["mac"].lower())
    # riserva: IP mesh assegnato da OpenWISP (subnet division)
    if not any(n == device.name for _, n in ips):
        mesh_ip = device.config.get_context().get("mesh_subnet1_ip1")
        if mesh_ip:
            ips.append((mesh_ip, device.name))
    # IP di gestione: per C2600/WRT3200ACM e' quello della 'wan' sulla LAN NINUX
    if device.management_ip and all(ip != device.management_ip for ip, _ in ips):
        ips.append((device.management_ip, device.name + "-mgmt"))
    return ips, sorted(set(macs))


def build_config(org):
    lines, hosts, seen = [], [], set()
    devices = Device.objects.filter(organization=org).select_related("config")
    for device in devices.order_by("name"):
        if not re.fullmatch(r"[A-Za-z0-9-]+", device.name):
            continue  # non e' un nome DNS valido
        ips, macs = node_entries(device)
        for ip, name in ips:
            if ipaddress.ip_address(ip) not in NINUX_NET or ip in seen:
                continue
            seen.add(ip)
            lines.append(f"{ip}\t{name}")
        if macs:
            hosts.append(
                {
                    "config_name": "host",
                    "config_value": "ninux_" + device.name.lower().replace("-", "_"),
                    "name": device.name,
                    "mac": macs,
                }
            )
    contents = "# Generato da OpenWISP (sync_node_hosts.py): non modificare a mano\n"
    contents += "\n".join(lines) + "\n"
    rev = hashlib.sha256(
        (contents + repr(hosts)).encode()
    ).hexdigest()[:12]
    return {
        "files": [{"path": HOSTS_PATH, "mode": "0644", "contents": contents}],
        "dhcp": [
            {
                "config_name": "dnsmasq",
                "config_value": "dnsmasq1",
                "addnhosts": [HOSTS_PATH],
                "ninux_hosts_rev": rev,
            }
        ]
        + hosts,
    }


org = Organization.objects.get(slug=ORG_SLUG)
config = build_config(org)
template = Template.objects.filter(name=TEMPLATE_NAME, organization=org).first()
if template is None:
    template = Template(
        name=TEMPLATE_NAME,
        organization=org,
        backend="netjsonconfig.OpenWrt",
        type="generic",
        default=True,
        required=False,
    )
if template.pk is None or template.config != config:
    template.config = config
    template.full_clean()
    template.save()
    print(f"{TEMPLATE_NAME}: aggiornato ({len(config['dhcp']) - 1} nodi)")
else:
    print(f"{TEMPLATE_NAME}: invariato")
