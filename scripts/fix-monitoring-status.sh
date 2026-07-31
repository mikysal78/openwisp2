#!/bin/sh
# =============================================================================
# fix-monitoring-status.sh — ricalcola l'health status in OpenWISP-monitoring
#
# In openwisp-monitoring lo status di un device si aggiorna SOLO quando una
# metrica attraversa una soglia (segnale threshold_crossed). Se lo status viene
# resettato a 'unknown' (device disattivato→riattivato, org disabilitata, check
# critico rimosso) e poi le metriche restano stabilmente sane, non c'e' nessun
# "crossing" e lo status resta bloccato su 'unknown' pur essendo il device ok.
# Questo script ricalcola lo status con la STESSA logica di openwisp
# (threshold_crossed): 'ok' se nessuna metrica critica e' unhealthy, altrimenti
# 'problem'/'critical'. update_status() non fa nulla se lo status e' gia' giusto.
#
# Va eseguito SUL SERVER dove gira OpenWISP (default /opt/openwisp2).
#
# Uso:
#   ./fix-monitoring-status.sh                 # sistema TUTTI i device 'unknown'
#   ./fix-monitoring-status.sh "Nome Device"   # sistema un singolo device
#   DEVICE="Nome Device" ./fix-monitoring-status.sh
#
# Da remoto (dal proprio pc):
#   ssh -p 2400 root@10.27.22.18 'sh -s' < scripts/fix-monitoring-status.sh
#   ssh -p 2400 root@10.27.22.18 'DEVICE="Nome Device" sh -s' < scripts/fix-monitoring-status.sh
#
# Variabili: OPENWISP_DIR (default /opt/openwisp2).
# =============================================================================
set -e

OWDIR="${OPENWISP_DIR:-/opt/openwisp2}"
DEV="${1:-${DEVICE:-}}"

if [ ! -x "$OWDIR/env/bin/python" ]; then
    echo "ERRORE: OpenWISP non trovato in $OWDIR (imposta OPENWISP_DIR)" >&2
    exit 1
fi
cd "$OWDIR"

DEVICE="$DEV" ./env/bin/python manage.py shell <<'PY'
import os
from openwisp_monitoring.device.models import DeviceMonitoring
from openwisp_monitoring.device import settings as app_settings


def recompute(dm):
    if dm.status == "deactivated":
        print(f"{dm.device.name}: deactivated (salto)")
        return
    status, crit = "ok", 0
    for m in dm.related_metrics.filter(is_healthy=False):
        status = "problem"
        if dm.is_metric_critical(m):
            crit += 1
    if crit == len(app_settings.CRITICAL_DEVICE_METRICS):
        status = "critical"
    old = dm.status
    dm.update_status(status)
    dm.refresh_from_db()
    flag = "" if old == dm.status else "  <-- cambiato"
    print(f"{dm.device.name}: {old} -> {dm.status}{flag}")


name = (os.environ.get("DEVICE") or "").strip()
if name:
    qs = DeviceMonitoring.objects.filter(device__name=name)
    if not qs:
        raise SystemExit(f"Device '{name}' non trovato")
else:
    qs = DeviceMonitoring.objects.filter(status="unknown")
    print(f"Ricalcolo {qs.count()} device in stato 'unknown'...")

for dm in qs:
    recompute(dm)
PY
