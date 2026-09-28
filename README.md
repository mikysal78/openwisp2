# OpenWISP2 full + ZeroTier + WiFi Login Pages

Playbook Ansible che installa su un CT (Debian 13 / Ubuntu 22.04+):

- **OpenWISP2 full**: controller, monitoring, network topology, firmware upgrader, RADIUS
- **WiFi Login Pages** (captive portal)
- **Controller ZeroTier self-hosted** sulla stessa CT, gestito da OpenWISP

Il certificato SSL **non** viene gestito dal playbook: lo carichi tu manualmente sul CT (vedi sotto).

## Prerequisiti

- CT con Debian 13 o Ubuntu 22.04/24.04, accesso SSH come root (o utente sudo)
- Ansible ≥ 2.13 sulla macchina da cui lanci il playbook
- **Se il CT è un LXC su Proxmox**: ZeroTier usa `/dev/net/tun`, che va esposto
  nel container *unprivileged*:

  ```
  # /etc/pve/lxc/<ID>.conf
  lxc.cgroup2.devices.allow: c 10:200 rwm
  lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
  ```

## 1. Installazione ruoli e configurazione

Ruoli e collections sono installati **dentro il repo** (`roles/` e
`collections/`, vedi `ansible.cfg`) dalle release GitHub più recenti.
Per (re)installarli o aggiornarli:

```bash
ansible-galaxy role install -r requirements.yml -p roles/ --force
ansible-galaxy collection install -r requirements.yml -p collections/ --force
```

Poi modifica:

- `hosts` → **il nome host dell'inventario È il dominio di OpenWISP**
  (il ruolo lo usa per nginx e Django): sostituisci `openwisp.example.com`
  con il tuo dominio reale e `ansible_host` con l'IP del CT
- `playbook.yml` → `wifi_login_pages_domains`, email
- `owlp_organizations/` → configurazione delle organizzazioni per le login pages
- `secrets.yml` → copia da `secrets.example.yml` e metti il secret RADIUS

## 2. Esecuzione (OpenWISP + ZeroTier + WiFi Login Pages)

```bash
ansible-playbook -i hosts playbook.yml
```

Il playbook installa in sequenza: OpenWISP + WiFi Login Pages (Play 1), il
controller ZeroTier (Play 2), il firewall nftables (Play 3), bird2/Babel (Play 4).

Al termine vai su `https://<tuo-dominio>/admin`: il ruolo crea l'utente
**admin / admin** — cambia subito la password da
`https://<tuo-dominio>/admin/password_change/`.

> **Prima installazione — nota su freeradius**: su un CT nuovo l'handler
> "Restart freeradius" del ruolo può scattare prima che nginx serva su 443.
> `rlm_rest` apre un pool verso `https://<dominio>/api/v1/freeradius` e, se
> nginx non risponde ancora, freeradius non parte e il play si ferma. Se
> capita: `systemctl restart nginx && systemctl restart freeradius`, poi
> rilancia il playbook (le parti già fatte sono idempotenti).

## 3. Certificato SSL manuale

Il playbook punta al certificato già presente sul CT:

- `/etc/ssl/acme/ninux-nnxx.it.fullchain.pem`
- `/etc/ssl/acme/ninux-nnxx.it.key`

Il ruolo genera un self-signed **solo se i file non esistono**, quindi non li
toccherà mai: li rinnovi tu in autonomia (dopo il rinnovo:
`systemctl reload nginx`).

> Il certificato deve coprire sia `openwisp.ninux-nnxx.it` sia
> `wifi.ninux-nnxx.it` (wildcard `*.ninux-nnxx.it` o SAN). Verifica con:
> `openssl x509 -in /etc/ssl/acme/ninux-nnxx.it.fullchain.pem -noout -text | grep DNS`

## 4. VPN ZeroTier

**Design**: la VPN serve solo a far vedere i router tra loro e a scambiare le
rotte via Babel — **ogni router mantiene il proprio gateway e OpenWISP NON fa
da gateway** (nessun NAT, nessuna default route via tunnel).

Si usa **ZeroTier** con **controller self-hosted sulla stessa CT**: ZeroTier
fornisce una L2 su cui Babel scopre i vicini via multicast, come nel design
storico NINUX. L'interfaccia sui router torna a chiamarsi `owzt<6hex del
network id>` e su di essa gira Babel.

### 4a. Controller ZeroTier (Play 2)

Il Play 2 (`--tags zerotier`) installa `zerotier-one` sulla CT (script ufficiale
firmato) e avvia il servizio. Il nodo diventa il controller della rete che
OpenWISP creerà. A fine play vengono stampati il **node address** e il percorso
del token API.

### 4b. Crea la VPN in OpenWISP

Admin → **VPN servers** → Add:

- Backend: **ZeroTier**
- Host: `127.0.0.1:9993` (il controller gira sulla stessa CT di OpenWISP;
  l'API ZeroTier ascolta in locale su 9993)
- AuthToken: il contenuto di `/var/lib/zerotier-one/authtoken.secret` sul CT
  (`sudo cat /var/lib/zerotier-one/authtoken.secret`)
- Subnet: `10.27.255.0/24` (la stessa di `bird_vpn_subnet_v4` /
  `firewall_radius_sources_v4` nei play) — è la rete gestita ZeroTier

Salvando, OpenWISP rileva il node address del controller e **crea la rete
ZeroTier**, di cui gestisce membri e indirizzi.

> Il nome pubblico `zerotier.ninux-nnxx.it` (CNAME di openwisp) è solo un
> riferimento DNS: per l'oggetto VPN si usa comunque `127.0.0.1:9993`, perché
> OpenWISP parla all'API locale del controller.

### 4c. Template client

In Admin → **Templates** → Add:

- Type: **VPN-client**
- VPN: la VPN ZeroTier creata sopra
- Automatic tunnel provisioning: **attivo** (OpenWISP genera per ogni device
  `zerotier_member_id`, `identity_secret` e l'IP interno, e lo autorizza sulla rete)

Sul router l'interfaccia risultante è `owzt<id>`: è quella su cui Babel aggancia
le adiacenze (già configurato nel template bird come `owzt*`). Il resto della
config dei router (kernel/direct/babel/OSPF per la default via `br-mesh`) resta
identico.

> **Router senza internet propria**: funzionano senza modifiche. La default la
> imparano dalla mesh vicina via OSPF su `br-mesh`, e ZeroTier raggiunge i peer
> uscendo dal gateway del momento (UDP 9993, segue la rotta di default). I filtri
> Babel garantiscono che la default non arrivi mai dalla VPN.

## 4d. Firewall

Il play `firewall` (nftables) applica una policy **default drop** in ingresso.
Niente NAT: OpenWISP non fa da gateway; il forward è permesso **solo**
`zt* → zt*` (traffico router↔router attraverso l'hub; sul server l'interfaccia
ZeroTier è `zt<id>`, sui router `owzt<id>`).

Interfacce del CT: **ens18** = rete di gestione (10.27.22.18, 2a07:7e81:3f1c::18),
**ens19** = IP pubblico (194.28.98.61/29), **zt<id>** = VPN ZeroTier (10.27.255.1).

| Porta | Proto | Da | Servizio |
|-------|-------|-----|----------|
| 2400  | TCP   | solo rete di gestione (`10.27.0.0/16`) | SSH |
| 80, 443 | TCP | ovunque | nginx (OpenWISP + WiFi Login Pages) |
| 9993  | UDP   | ovunque | ZeroTier (controller + data plane) |
| 1812–1813 | UDP | solo VPN (10.27.255.0/24) e gestione (10.27.0.0/16) | FreeRADIUS |
| 6696  | UDP   | solo interfacce `zt*`, `ens18` e `ens19` | Babel (bird2) |

Il play si applica anche da solo con `--tags firewall`.

## 4e. bird2 / Babel (rete NINUX)

> Il server usa `bird2` di Debian (2.17); i router, con il firmware Ninux su
> OpenWrt 25.12, usano **BIRD 3** (3.2.x). La configurazione Babel è compatibile.

Il play `bird` (tag omonimo) installa **bird2** e applica
`templates/bird.conf.j2`, allineata alla config dei router NINUX:

- **Babel** gira su `zt*` (la VPN ZeroTier), `ens18` (LAN di gestione, dove
  peera con i router della stessa L2) e `ens19` (pubblica), con
  `check link yes` e `rxcost 600`
- il protocollo **direct `vpn`** annuncia via Babel la subnet ZeroTier
  (10.27.255.0/24) presa da `zt*` e la LAN di gestione da `ens18`
- come sui router, la **default route non viene mai né annunciata né importata**
  via Babel (filtri identici ai router: `net != 0.0.0.0/0` / `net != ::/0`):
  ogni nodo tiene il suo gateway
- kernel4/kernel6 con `scan time 20`, `learn yes`, `merge paths yes`; il router
  id è ricavato da `ens19`

La config viene validata con `bird -p` prima dell'applicazione.

> NB: l'interfaccia `zt*` del server esiste solo dopo che la VPN è stata creata
> in OpenWISP e il CT ha joinato la rete ZeroTier; con `check link yes` bird la
> ignora finché non compare, quindi il play si può lanciare anche prima.

## 5. WiFi Login Pages

Le login pages rispondono su `https://wifi.<dominio>`. L'app
[openwisp-wifi-login-pages](https://github.com/openwisp/openwisp-wifi-login-pages)
la clona e builda il ruolo `openwisp.wifi_login_pages` (nulla da fare a mano).
Per ogni organizzazione serve un file YAML in `owlp_organizations/` con UUID e
token RADIUS (vedi `owlp_organizations/README.md`), poi rilancia il playbook.
