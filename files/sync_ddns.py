"""
DDNS della zona dyn.ninux-nnxx.it fatto dal server OpenWISP invece che dai
router: <nome device>.dyn.ninux-nnxx.it -> IPv4 di br-lan.

Prima lo faceva ogni router (template "DDNS nsupdate (br-lan / LuCI)": cron,
script, chiave TSIG e bind-client, che si porta dietro bind-libs e OpenSSL:
~2,9 MB di firmware). br-lan e' assegnata a mano sul router, ma l'agente di
monitoring la riporta a OpenWISP: qui si legge quel dato e si manda a BIND un
solo nsupdate per tutti. La chiave TSIG resta sul server (la stessa del
template, nei suoi Default Values).

Regole:
  - solo device attivi, con un dato di monitoring piu' recente di MAX_AGE;
    un router spento o muto non viene toccato (il record resta com'e');
  - solo IPv4 di br-lan dentro 10.27.0.0/16 (sul router di confine br-lan ha
    anche l'IP pubblico: non va nella zona interna);
  - device in EXCLUDE ignorati;
  - si scrivono solo i record diversi (nessun bump di serial a vuoto).

Uso (senza NINUX_DDNS_APPLY=1 stampa le differenze e non scrive niente):
    cd /opt/openwisp2 && env/bin/python manage.py shell < sync_ddns.py
    NINUX_DDNS_APPLY=1 env/bin/python manage.py shell < sync_ddns.py
"""

import ipaddress
import os
import subprocess
import tempfile
from datetime import datetime, timedelta, timezone

from openwisp_controller.config.models import Template
from openwisp_monitoring.device.models import DeviceData

TEMPLATE = "DDNS nsupdate (br-lan / LuCI)"
INTERFACE = "br-lan"
NETWORK = ipaddress.ip_network("10.27.0.0/16")
MAX_AGE = timedelta(minutes=30)
EXCLUDE = set(os.environ.get("NINUX_DDNS_EXCLUDE", "").split(",")) - {""}
APPLY = os.environ.get("NINUX_DDNS_APPLY") == "1"

dv = Template.objects.get(name=TEMPLATE).default_values
zone = dv["ddns_zone"]
server = dv["dns_primary_ip"]
ttl = int(dv.get("ddns_ttl", 60))


def lan_ipv4(data):
    for iface in data.get("interfaces", []):
        if iface.get("name") != INTERFACE:
            continue
        for a in iface.get("addresses", []):
            if a.get("family") == "ipv4":
                ip = ipaddress.ip_address(a["address"])
                if ip in NETWORK:
                    return str(ip)
    return None


# Il primary accetta gli update firmati ma rifiuta le query normali
# (REFUSED): lo stato attuale si legge dal primo NS della zona.
QUERY_NS = os.environ.get("NINUX_DDNS_QUERY_NS", "ns1.ninux-nnxx.it")


def current(fqdn):
    out = subprocess.run(
        ["dig", "+short", "+norecurse", "A", fqdn, f"@{QUERY_NS}"],
        capture_output=True, text=True, timeout=10,
    ).stdout.split()
    return sorted(out)


now = datetime.now(timezone.utc)
updates = []
for d in DeviceData.objects.select_related("monitoring").order_by("name"):
    name = d.name
    fqdn = f"{name}.{zone}".lower()
    if name in EXCLUDE:
        print(f"  escluso   {fqdn}")
        continue
    if getattr(d, "monitoring", None) and d.monitoring.status == "deactivated":
        print(f"  disattivo {fqdn}")
        continue
    data = d.data or {}
    ts = d.data_timestamp
    if ts:
        ts = datetime.fromisoformat(str(ts))
    if not ts or now - ts > MAX_AGE:
        print(f"  muto      {fqdn} (ultimo dato: {ts or 'mai'}): non tocco")
        continue
    ip = lan_ipv4(data)
    if not ip:
        print(f"  senza IP  {fqdn}: nessun IPv4 {INTERFACE} in {NETWORK}")
        continue
    now_dns = current(fqdn)
    if now_dns == [ip]:
        print(f"  uguale    {fqdn} -> {ip}")
        continue
    print(f"  CAMBIA    {fqdn}: {now_dns or 'assente'} -> {ip}")
    updates.append((fqdn, ip))

print(f"{len(updates)} record da aggiornare" + ("" if APPLY else " (prova a secco)"))

if APPLY and updates:
    lines = [f"server {server}", f"zone {zone}"]
    for fqdn, ip in updates:
        lines += [f"update delete {fqdn}. A", f"update add {fqdn}. {ttl} A {ip}"]
    lines.append("send")
    key = (
        f'key "{dv["ddns_key_name"]}" {{\n'
        f'    algorithm {dv["ddns_algorithm"]};\n'
        f'    secret "{dv["ddns_secret"]}";\n}};\n'
    )
    with tempfile.NamedTemporaryFile("w", suffix=".key") as kf:
        os.chmod(kf.name, 0o600)
        kf.write(key)
        kf.flush()
        r = subprocess.run(
            ["nsupdate", "-k", kf.name], input="\n".join(lines) + "\n",
            capture_output=True, text=True, timeout=30,
        )
    print("nsupdate:", "ok" if r.returncode == 0 else f"ERRORE {r.returncode} {r.stderr.strip()}")
