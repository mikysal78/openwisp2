# Template OpenWISP (rete NINUX Basilicata)

Configurazioni [netjsonconfig](https://netjsonconfig.openwisp.org/) (backend
`netjsonconfig.OpenWrt`) caricate come **template** nel controller. I file qui
dentro sono la copia versionata di riferimento; la sorgente operativa restano i
template dentro OpenWISP.

| File | Template in OpenWISP | Default | Richiesto |
|---|---|---|---|
| `bird-babel.json` | Bird2 Babel (routing) — nome storico, sui router gira BIRD 3 | sì | sì |
| `mesh-80211s.json` | Mesh 802.11s 2.4GHz | sì | sì |
| `ap-24ghz.json` | AP WiFi 2.4GHz | no | no |
| `ap-dualband.json` | AP WiFi 2.4+5GHz (dual band) — stesso SSID sulle due bande, con 802.11k/v e usteer che propone i 5 GHz ai client vicini (sopra -60 dBm, solo con 802.11v, nessuna disconnessione forzata) | no | no |
| `ap-dualssid.json` | AP WiFi dual SSID 2.4+5GHz | no | no |
| `ntp-servers.json` | NTP Servers — fuso orario Europe/Rome e server NTP (INRIM). Senza, il router resta in UTC | sì | no |
| `hotspot-chilli.json` | Hotspot CoovaChilli 2.4GHz — **dismesso**, chilli non è più nel firmware | no | no |
| `hotspot-uspot.json` | Hotspot uspot 2.4GHz | no | no |
| `log-remoto.json` | Log remoto (syslog) — invia il syslog al server (`/opt/router-logs/<hostname>/`, Play 5) | sì | no |
| `netconsole.json` | Netconsole — messaggi del kernel in tempo reale al server (`/opt/router-logs/netconsole-<ip>/`), anche prima di un blocco. Serve il firmware dalla build #34. **Non** su ReginaMargherita116 (ha il suo nel template del router di confine) | no | no |
| `usteer.json` | usteer — coordina gli AP con le stesse reti e sposta i client sull'AP migliore (802.11k/v, disconnessione sotto -85 dBm per gli IoT). Firmware dalla build #36. Solo sui router con più AP sulla stessa LAN (i due Zyxel); con `ap-dualssid.json`, che attiva `ieee80211k` e `bss_transition` | no | no |
| `uplink-lan-wan.json` | Uplink LAN su wan — router collegati alla LAN di ReginaMargherita116 dalla porta `wan` (WRT3200ACM, C2600, X5000R): regole firewall per Babel (UDP 6696 da `fe80::/10`) e SSH da `10.27.22.0/24` sulla zona `wan`, `management_interface` `wan`, variabile `babel_wired_extra` = `wan` (prevale sul default di Bird2 perché il template viene dopo). **Non** sui siti remoti, dove la `wan` è il modem del provider | no | no |
| `router-confine.json` | Router di confine (ReginaMargherita116) — config **completa** del router x86 di confine (WAN, /29, Serveperso, firewall, anti-spoofing…), per ricostruirlo su hardware nuovo. Credenziali = variabili del device `confine_*`. Solo ciò che i template di default non danno | no | no |

Il template **Nomi dei nodi (hosts)** (default, non richiesto) non sta qui: lo
genera e aggiorna `files/sync_node_hosts.py` (cron del playbook, tag `hosts`)
dai dati di monitoraggio. Porta `/etc/ninux-hosts` (IP → nome del nodo, letto da
dnsmasq anche per la risoluzione inversa) e una sezione dhcp `host` per nodo con
i MAC della mesh, così LuCI e gli strumenti mostrano il nome invece dell'IP.

Il template **VPN ZeroTier (client)** non sta qui: lo genera OpenWISP
dall'oggetto VPN ZeroTier (controller self-hosted sul CT OpenWISP, vedi il README
principale §4). Sul router l'interfaccia è `owzt<6hex del network id>`.

## Import nella UI

Admin → **Templates → Add**: backend `OpenWRT`, type `Generic`, poi passa in
**modalità avanzata** (icona `</>` nell'editor) e incolla il JSON. I file AP
(`ap-*.json`) hanno invece la forma `{backend, config, default_values}`, come
li restituisce l'API: nell'editor va incollato solo il contenuto di `config`,
mentre `default_values` va nel campo **Configuration variables** del template.
In alternativa, via shell Django sul server:

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
| `wan_interface` | `default_values` del template bird (`wan`) | solo per lo stub OSPF: cambiala nel device se la WAN ha un altro nome (es. `eth1`, `eth0.2`) |
| `mesh_password` | `default_values` del template mesh, **solo in OpenWISP** (copia in `secrets.yml`, non versionato) | chiave SAE della mesh 802.11s (`wpa3_personal` → UCI `sae+ccmp`). Su 802.11s OpenWrt usa comunque SAE con qualunque cifratura: WPA2 non esiste. Deve essere uguale su tutti i nodi, altrimenti non si collegano tra loro. Nel repo pubblico non c'è, nemmeno come segnaposto |
| `wifi_ssid`, `wifi_password` | `default_values` dei template AP (`ninux.org` / `CHANGEME`) | sovrascrivibili per device; nel repo la password è un segnaposto: quella reale si imposta nel template su OpenWISP o nelle variabili del device |
| `wifi_encryption`, `wifi_pmf` | `default_values` dei template AP (`wpa2_personal_mixed` / `1`) | cifratura e PMF del SSID principale, sovrascrivibili per device (es. `wpa3_personal` + `2` per WPA3 puro) |
| `wifi_ssid2`, `wifi_password2` | `default_values` del template dual SSID (`NINUX 2` / `CHANGEME`) | secondo SSID, anch'esso sulla `lan` |
| `radius_secret` | `OPENWISP_CONTROLLER_CONTEXT` (da `secrets.yml`) | shared secret RADIUS degli hotspot: **non** è in chiaro nel repo |
| `name`, `mac_address` | OpenWISP | si risolvono per-device (NAS-Identifier / Called-Station) |

I *default values* di un template vengono copiati nelle variabili del device, e
lì **vincono su tutto**: per questo gli IP assegnati automaticamente
(es. `mesh_subnet1_ip1`) non hanno un default value, altrimenti
tutti i router riceverebbero lo stesso indirizzo. Il valore segnaposto che serve
solo a validare i template sta nel contesto globale (`openwisp2_context` nel
playbook, tag `context`).

## `bird-babel.json` — routing Babel sui router

Template *generic*: non configura interfacce, spinge due **file**.

- `/etc/bird.conf` (0644) — la configurazione Babel NINUX: `router id from
  "br-lan"`, protocolli kernel4/kernel6, `protocol direct lan`, Babel su
  `owzt*` (la VPN ZeroTier, `rxcost 600`), su `br-lan` (peering con i vicini
  della stessa L2, es. il border sul /29; innocuo sui nodi foglia) e su
  `br-mesh` (`type wireless`), il BFD su `br-mesh` e l'OSPFv3 che impara la
  **default route solo da `br-mesh`** — per i router senza uplink proprio, che
  prendono il gateway da una mesh vicina. La default non entra mai in Babel:
  OpenWISP non fa da gateway.
- `/etc/openwisp/post-reload-hook` (0755) — openwisp-config lo esegue da solo
  dopo ogni applicazione della configurazione: crea le zone firewall VPN/mesh,
  valida con `bird -p` e **ricarica solo se la config è valida** (una config
  rotta lascerebbe il router isolato). Se BIRD manca del tutto (immagine OpenWrt
  non Ninux) prova a installare `bird2` con `apk`/`opkg`.

> **Versioni BIRD**: il firmware Ninux (OpenWrt 25.12) include **bird3**
> (3.2.x, in conflitto con `bird2`), che installa gli stessi percorsi
> (`/usr/sbin/bird`, `/etc/init.d/bird`, `/etc/bird.conf`): la config è
> compatibile con entrambe. Il server OpenWISP usa `bird2` di Debian (2.17).

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
- `ap-24ghz.json` / `ap-dualband.json` — AP sulla rete `lan`, cifratura da
  variabile: di default WPA2-PSK/WPA3-SAE misto
  (`wifi_encryption = wpa2_personal_mixed`, che netjsonconfig traduce in UCI
  `sae-mixed`; cifrario CCMP, PMF opzionale `wifi_pmf = 1`). `radio0` è sul **canale 1**, lo stesso della
  mesh: è la stessa radio, non può stare su due canali. Il dual band aggiunge
  `radio1` (5GHz, canale 36, 802.11ac, 80MHz).

- `ap-dualssid.json` — identico a `ap-dualband.json` ma con **due SSID** su
  entrambe le bande (2.4+5GHz), tutti e due sulla stessa rete `lan`. Il primo
  SSID usa le variabili degli altri AP (`wifi_ssid`/`wifi_password`/
  `wifi_encryption`/`wifi_pmf`), il secondo usa `wifi_ssid2`/`wifi_password2`
  ed è fisso in WPA/WPA2-PSK misto (`wpa_personal_mixed`, cifrario automatico,
  PMF disattivato).
  - `default_values` sul template: `wifi_ssid2 = NINUX 2`,
    `wifi_password2 = CHANGEME` (segnaposto, vedi tabella Variabili).
  - applicalo **al posto** di `ap-24ghz`/`ap-dualband` (stessi nomi radio/iface),
    non insieme.

## Template hotspot (captive portal su 2.4GHz)

Due alternative — **applicane una sola per device** (stessa subnet
192.168.182.0/24 e stesso SSID):

- `hotspot-chilli.json` — CoovaChilli (classico)
- `hotspot-uspot.json` — uspot (moderno, fw4/ucode, OpenWrt 22.03+)

Cosa adattare:

- **SSID** (`NINUX Free WiFi`) a piacere
- **radio** (uspot): variabile `hotspot_radio`, default `radio0` (2.4GHz sulla
  quasi totalità dei device OpenWrt). Dove la 2.4GHz è un'altra radio va messa
  nelle variabili del device: sul WRT3200ACM `radio0` è la 5GHz, quindi
  `hotspot_radio = radio1`. La radio deve essere attiva (`disabled 0`) sul
  router: il template non la tocca. Sul chilli resta `radio0` fisso
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

### Captive in HTTPS (uam3990) — obbligatorio per evitare mixed-content

Le wifi-login-pages girano in HTTPS: un submit del form verso un endpoint
`http://<ip>:3990` viene bloccato dal browser (mixed content) e il login non
parte. Per questo `hotspot-uspot.json` serve il portale UAM in **HTTPS** su un
**dominio**, non su IP:

- `uhttpd.uam3990`: `listen_https 192.168.182.1:3990` + `cert`/`key`
  (`/etc/uspot/wifiauth.crt` e `.key`)
- `uspot.captive.uam_sslurl = https://wifiauth.ninux-nnxx.it:3990/`
- split-DNS: `wifiauth.ninux-nnxx.it → 192.168.182.1` (uci-defaults
  `96-hotspot-splitdns`, idempotente) così il dominio del cert risolve
  sull'IP locale del captive

**Certificato**: il template distribuisce il wildcard `*.ninux-nnxx.it`
(Let's Encrypt) come file `files[]`. ⚠️ Nel repo i due file
`/etc/uspot/wifiauth.{crt,key}` hanno **solo un placeholder**: il contenuto
reale (chiave privata inclusa) **non è versionato in git**, vive solo nel DB
del controller OpenWISP. Al rinnovo del cert va riaggiornato lì.

### Lato wifi-login-pages (org `default`)

Nel file organizzazione (`owlp_organizations/default.yml`) il form del captive
portal deve puntare all'IP locale del portale, identico per tutti i router e per
entrambi i template:

- login: `http://192.168.182.1:3990/logon`
- logout: `http://192.168.182.1:3990/logoff`

Nota: niente `uamsecret` con chilli — le wifi-login-pages inviano la password in
PAP semplice al portale; impostarlo romperebbe l'autenticazione.
