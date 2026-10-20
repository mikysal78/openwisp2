"""
Template OpenWISP "Hotspot uspot 2.4GHz": certificato del portale UAM locale
(https://wifiauth.ninux-nnxx.it:3990) allineato al wildcard *.ninux-nnxx.it
rinnovato sul server in /etc/ssl/acme.

Il template ne porta una copia (files[]) che non si aggiorna da sola: il
20/10/2026 era scaduta da tre settimane e il browser rifiutava il login sul
captive. uhttpd legge il certificato solo all'avvio, e procd riavvia
l'istanza solo se cambia la sua riga di comando: per questo l'impronta del
certificato sta nel NOME dei file (/etc/uspot/wifiauth-<impronta>.crt/.key)
e nelle opzioni cert/key della sezione uhttpd. openwisp-config toglie dal
router i file che non sono più nel template.

Il template si salva solo se qualcosa cambia (ogni salvataggio fa riscaricare
la config ai router che lo usano).

Uso (cron, vedi playbook):
    /opt/openwisp2/env/bin/python /opt/openwisp2/manage.py shell < sync_uspot_cert.py
"""

import hashlib
import json

from openwisp_controller.config.models import Template

TEMPLATE = "Hotspot uspot 2.4GHz"
UHTTPD_SECTION = "uam3990"
CERT = "/etc/ssl/acme/ninux-nnxx.it.fullchain.pem"
KEY = "/etc/ssl/acme/ninux-nnxx.it.key"
PREFIX = "/etc/uspot/wifiauth"

template = Template.objects.get(name=TEMPLATE)
config = template.config
prima = json.dumps(config, sort_keys=True)

cert, key = open(CERT).read(), open(KEY).read()
rev = hashlib.sha256(cert.encode()).hexdigest()[:12]
cert_path, key_path = f"{PREFIX}-{rev}.crt", f"{PREFIX}-{rev}.key"

# via le copie precedenti (con o senza impronta), poi le nuove
files = [f for f in config.get("files", []) if not f["path"].startswith(PREFIX)]
files.append({"path": cert_path, "mode": "0644", "contents": cert})
files.append({"path": key_path, "mode": "0600", "contents": key})
config["files"] = files
for sec in config.get("uhttpd", []):
    if sec.get("config_value") == UHTTPD_SECTION:
        sec["cert"], sec["key"] = cert_path, key_path
        sec.pop("ninux_cert_rev", None)

if json.dumps(config, sort_keys=True) != prima:
    template.full_clean()
    template.save()
    print(f"{TEMPLATE}: certificato aggiornato ({rev})")
