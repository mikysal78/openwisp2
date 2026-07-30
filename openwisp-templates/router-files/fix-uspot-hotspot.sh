#!/bin/sh
# =============================================================================
# fix-uspot-hotspot.sh — rimedio live per l'hotspot uspot sui router NINUX
#
# Riproduce la patch applicata a mano sul C2600 (10.27.32.1) il 2026-07-30.
# Idempotente: si puo' rilanciare senza effetti collaterali.
#
# Corregge due problemi distinti:
#
#   BUG A (firmware) — /usr/share/uspot/uspot.uc del pacchetto uspot 913980c0
#     ha un typo di sintassi ucode a riga 632 (ternario con ramo vuoto:
#     "... ? : +disconnect_delay ...") -> il daemon uspot va in crash-loop,
#     niente auth. Fix upstream: 87080bf ("uspot: fix syntax error typo").
#     Questa patch e' un TAMPONE: sparisce a ogni reflash. La soluzione
#     definitiva e' ricompilare il firmware con il feed 'packages' pinnato a
#     un commit >= 1c938cd1 (branch openwrt-25.12).
#
#   BUG B (config) — la uhttpd principale (LuCI) ascolta su 0.0.0.0:80, quindi
#     occupa anche 192.168.182.1:80 e l'istanza uspot del captive (/cpd) non
#     riesce a bindare. Si sposta la uhttpd captive su :8080, si fa puntare li'
#     il DNAT della porta 80 e si apre :8080 in input. La login UAM resta :3990.
#     Questa parte e' gia' nel template OpenWISP "Hotspot uspot 2.4GHz"; qui
#     serve per un router non ancora allineato o per una fix immediata.
#
# Uso:  sh fix-uspot-hotspot.sh        (in locale sul router)
#   o:  ssh root@<router> 'sh -s' < fix-uspot-hotspot.sh
# =============================================================================
set -e

log() { echo "[fix-uspot] $*"; }

# --- BUG A: patch del typo in uspot.uc -------------------------------------
F=/usr/share/uspot/uspot.uc
if [ -f "$F" ] && grep -q '? : +disconnect_delay' "$F"; then
    [ -f "$F.orig" ] || cp "$F" "$F.orig"
    sed -i 's/? : +disconnect_delay/? +disconnect_delay/' "$F"
    log "uspot.uc: typo corretto (backup in $F.orig)"
else
    log "uspot.uc: gia' corretto o non presente, salto"
fi

# --- BUG B: uhttpd captive su :8080 ----------------------------------------
if uci -q get uhttpd.uspot >/dev/null; then
    uci set uhttpd.uspot.listen_http='192.168.182.1:8080'
    uci commit uhttpd
    log "uhttpd.uspot listen -> 192.168.182.1:8080"
else
    log "uhttpd.uspot assente (template hotspot non applicato?), salto parte B"
fi

# le sezioni firewall sono anonime: le individuo per l'opzione 'name'
fw_section_by_name() {
    uci show firewall 2>/dev/null | \
        sed -n "s/^firewall\.\([^.]*\)\.name='$1'\$/\1/p" | head -1
}

RED=$(fw_section_by_name 'Redirect-unauth-captive-CPD' || true)
if [ -n "$RED" ]; then
    uci set firewall."$RED".dest_port='8080'
    log "redirect CPD dest_port -> 8080 (firewall.$RED)"
fi

RULE=$(fw_section_by_name 'Allow-captive-CPD-WEB-UAM' || true)
if [ -n "$RULE" ]; then
    uci set firewall."$RULE".dest_port='80 443 3990 8080'
    log "input captive dest_port -> 80 443 3990 8080 (firewall.$RULE)"
fi

uci commit firewall

# --- restart servizi -------------------------------------------------------
/etc/init.d/uhttpd restart 2>/dev/null || true
/etc/init.d/firewall reload 2>/dev/null || true
/etc/init.d/uspot restart 2>/dev/null || true
sleep 3

# --- verifica --------------------------------------------------------------
log "--- verifica ---"
log "uspot status: $(/etc/init.d/uspot status 2>&1)"
if ubus list 2>/dev/null | grep -q '^uspot$'; then
    log "ubus 'uspot': presente (daemon vivo)"
else
    log "ubus 'uspot': ASSENTE (daemon non partito)"
fi
log "listener captive:"
netstat -ltnp 2>/dev/null | grep -E '192\.168\.182\.1:(8080|3990)' || log "  (nessun listener :8080/:3990)"
log "fatto."
