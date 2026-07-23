# Template OpenWISP (rete NINUX Basilicata)

Configurazioni [netjsonconfig](https://netjsonconfig.openwisp.org/) (backend
`netjsonconfig.OpenWrt`) caricate come **template** nel controller. I file qui
dentro sono la copia versionata di riferimento; la sorgente operativa restano i
template dentro OpenWISP.

| File | Template in OpenWISP | Default | Richiesto |
|---|---|---|---|
| `bird-babel.json` | Bird2 Babel (routing) | sì | sì |
| `mesh-80211s.json` | Mesh 802.11s 2.4GHz | sì | sì |
| `ap-24ghz.json` | AP WiFi 2.4GHz | no | no |
| `ap-dualband.json` | AP WiFi 2.4+5GHz (dual band) | no | no |
| `ap-dualssid.json` | AP WiFi dual SSID 2.4+5GHz | no | no |
| `hotspot-chilli.json` | Hotspot CoovaChilli 2.4GHz | no | no |
| `hotspot-uspot.json` | Hotspot uspot 2.4GHz | no | no |

Il template **VPN-Basilicata** non sta qui: lo genera OpenWISP dall'oggetto VPN
(*VXLAN over WireGuard*). L'unica modifica fatta a mano è l'indirizzo IPv4 sulla
`vxlan1` (vedi in fondo).

## Import nella UI

Admin → **Templates → Add**: backend `OpenWRT`, type `Generic`, poi passa in
**modalità avanzata** (icona `</>` nell'editor) e incolla il JSON. In
alternativa, via shell Django sul server:

```sh
ssh -p 2400 root@10.27.22.18
cd /opt/openwisp2 && ./env/bin/python manage.py shell
```

```python
import json
from openwisp_controller.config.models import Template
t = Template.objects.get(name="Bird2 Babel (routing)")
t.config = json.load(open("/tmp/bird-babel.json"))
t.full_clean()   # valida contro lo schema netjsonconfig
t.save()
```

## Variabili

| Variabile | Origine | Note |
|---|---|---|
| `mesh_subnet1_ip1` | regola subnet-division `mesh` (IPAM `10.27.99.0/24`) | IP mesh univoco per device, assegnato da OpenWISP |
| `vxlan_subnet1_ip1` | regola subnet-division `vxlan` (IPAM `169.254.0.0/16`) | IP del capo router del tunnel VPN |
| `wan_interface` | `default_values` del template bird (`eth1`) | solo per lo stub OSPF: cambiala nel device se la WAN è `eth0.2`/`wan` |
| `wifi_ssid`, `wifi_password` | `default_values` dei template AP (`ninux.org` / `ninux2026`) | sovrascrivibili per device |
| `wifi_ssid2`, `wifi_password2` | `default_values` del template dual SSID (`NINUX 2` / `CHANGEME`) | secondo SSID, anch'esso sulla `lan` |
| `radius_secret` | `OPENWISP_CONTROLLER_CONTEXT` (da `secrets.yml`) | shared secret RADIUS degli hotspot: **non** è in chiaro nel repo |
| `name`, `mac_address` | OpenWISP | si risolvono per-device (NAS-Identifier / Called-Station) |

I *default values* di un template vengono copiati nelle variabili del device, e
lì **vincono su tutto**: per questo gli IP assegnati automaticamente
(`mesh_subnet1_ip1`, `vxlan_subnet1_ip1`) non hanno un default value, altrimenti
tutti i router riceverebbero lo stesso indirizzo. Il valore segnaposto che serve
solo a validare i template sta nel contesto globale (`openwisp2_context` nel
playbook, tag `context`).

## `bird-babel.json` — routing Babel sui router

Template *generic*: non configura interfacce, spinge due **file**.

- `/etc/bird.conf` (0644) — la configurazione Babel NINUX. Rispetto a quella
  storica cambia una cosa sola: la VPN non è più ZeroTier (`owzt0d3e97`) ma la
  VXLAN su WireGuard (interfaccia `vxlan*`, pattern che copre qualunque nome
  assegni netifd). Restano invariati `router id from "br-lan"`, i protocolli
  kernel4/kernel6, `protocol direct lan`, Babel su `br-lan` e `br-mesh`
  (`type wireless`, `rxcost 600`), il BFD su `br-mesh` e l'OSPFv3 che impara la
  **default route solo da `br-mesh`** — per i router senza uplink proprio, che
  prendono il gateway da una mesh vicina. La default non entra mai in Babel:
  OpenWISP non fa da gateway.
- `/etc/openwisp/post-reload-hook` (0755) — openwisp-config lo esegue da solo
  dopo ogni applicazione della configurazione: installa `bird2` se manca
  (`opkg`/`apk`), valida con `bird -p` e **ricarica solo se la config è valida**
  (una config rotta lascerebbe il router isolato).

I sorgenti dei due file stanno in `router-files/`; il JSON si rigenera con:

```sh
python3 openwisp-templates/build_bird_template.py
```

> Un router **senza uplink** non può fare `opkg install bird2`: lì il pacchetto
> deve essere già nell'immagine.

## Template WiFi

- `mesh-80211s.json` — 802.11s su `radio0`, mesh id `ninux-mesh`, canale 1,
  HT20, `mesh_fwding: false` (l'inoltro lo fa Babel, non l'802.11s). Il bridge
  `mesh` diventa `br-mesh`, con l'IP mesh assegnato da IPAM.
- `ap-24ghz.json` / `ap-dualband.json` — AP sulla rete `lan`, WPA3-SAE puro
  (`sae+ccmp`, `ieee80211w: 2`). `radio0` è sul **canale 1**, lo stesso della
  mesh: è la stessa radio, non può stare su due canali. Il dual band aggiunge
  `radio1` (5GHz, canale 36, 802.11ac, 80MHz).

- `ap-dualssid.json` — identico a `ap-dualband.json` ma con **due SSID** su
  entrambe le bande (2.4+5GHz), tutti e due WPA3-SAE sulla stessa rete `lan`. Il
  primo SSID usa le variabili degli altri AP (`wifi_ssid`/`wifi_password`), il
  secondo usa `wifi_ssid2`/`wifi_password2`.
  - `default_values` consigliati sul template: `wifi_ssid2 = NINUX 2`,
    `wifi_password2 = CHANGEME`.
  - applicalo **al posto** di `ap-24ghz`/`ap-dualband` (stessi nomi radio/iface),
    non insieme.

## Template hotspot (captive portal su 2.4GHz)

Due alternative — **applicane una sola per device** (stessa subnet
192.168.182.0/24 e stesso SSID):

- `hotspot-chilli.json` — CoovaChilli (classico)
- `hotspot-uspot.json` — uspot (moderno, fw4/ucode, OpenWrt 22.03+)

Cosa adattare:

- **SSID** (`NINUX Free WiFi`) a piacere
- **`radio0`**: si assume sia la radio 2.4GHz (vero sulla quasi totalità dei
  device OpenWrt); verifica nella config del singolo device
- **uspot, regole `dest: wan`**: se sui router la zona di uscita non si chiama
  `wan` (es. zona mesh), correggi `Forward-auth-captive` e `Allow-Whitelist`

Il shared secret RADIUS non è nel JSON: arriva da `{{ radius_secret }}` e deve
coincidere con quello del NAS `NAS-BASILICATA` (10.27.0.0/16) in admin → RADIUS
→ NAS.

Prerequisiti pacchetti (nel firmware o via opkg):

- chilli: `coova-chilli` — ⚠️ il pacchetto OpenWrt standard è compilato senza
  `chilli-redir`: per il flusso di redirect delle wifi-login-pages serve il
  pacchetto del firmware demo OpenWISP o una build custom
- uspot: `uspot` + `uhttpd-mod-ucode` (gli handler in `/usr/share/uspot/` sono
  inclusi nel pacchetto)

### Lato wifi-login-pages (org `default`)

Nel file organizzazione (`owlp_organizations/default.yml`) il form del captive
portal deve puntare all'IP locale del portale, identico per tutti i router e per
entrambi i template:

- login: `http://192.168.182.1:3990/logon`
- logout: `http://192.168.182.1:3990/logoff`

Nota: niente `uamsecret` con chilli — le wifi-login-pages inviano la password in
PAP semplice al portale; impostarlo romperebbe l'autenticazione.

## Perché la `vxlan1` ha un IP `169.254.x.y/16`

Babel scambia rotte IPv4 solo se il **next-hop è on-link su entrambi i capi** del
tunnel. Il server crea le sue `vxlan-*` con NetworkManager e
`ipv4.method=link-local` (`update_vxlan.py` del ruolo `wireguard_openwisp`, che
non accetta indirizzi): si prende quindi un `169.254.x.y/16`. Di conseguenza
anche il lato router deve stare in quella /16, altrimenti il kernel rifiuta le
rotte (*nexthop has invalid gateway*) e la VPN non porta traffico.

Questi indirizzi vivono **solo dentro il tunnel**: compaiono come next-hop in
`ip route`, mai nel traffico utente. Il piano di indirizzamento vero resta tutto
in `10.27.0.0/16` (LAN dei siti, mesh `10.27.99.0/24`, WireGuard
`10.27.250.0/24`).
