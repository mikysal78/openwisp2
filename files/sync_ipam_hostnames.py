"""
Popola il campo "description" degli IP in IPAM con il nome del device.

OpenWISP crea gli IpAddress (VPN WireGuard, subnet division) con bulk_create,
senza descrizione e senza emettere segnali: non c'e' quindi modo di agganciarsi
a un signal. Questo script fa il sync ed e' eseguito da cron.

Uso:
    /opt/openwisp2/env/bin/python /opt/openwisp2/manage.py shell < sync_ipam_hostnames.py
"""

updated = 0

# 1) IP assegnati dai tunnel VPN (WireGuard)
from openwisp_controller.config.models import VpnClient

for vc in VpnClient.objects.select_related("config__device", "ip").exclude(ip=None):
    device = vc.config.device
    label = f"{device.name} ({vc.vpn.name})"
    if vc.ip.description != label:
        vc.ip.description = label
        vc.ip.save(update_fields=["description"])
        updated += 1

# 2) IP assegnati dalle regole di subnet division (es. mesh)
try:
    from openwisp_controller.subnet_division.models import SubnetDivisionIndex

    indexes = SubnetDivisionIndex.objects.select_related(
        "config__device", "ip"
    ).exclude(ip=None)
    for index in indexes:
        if not index.config_id:
            continue
        device = index.config.device
        if index.ip.description != device.name:
            index.ip.description = device.name
            index.ip.save(update_fields=["description"])
            updated += 1
except Exception:
    # modulo subnet_division non abilitato: si ignora
    pass

print(f"IP aggiornati con hostname: {updated}")
