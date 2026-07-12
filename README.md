# OpenWISP2 full + WireGuard + WiFi Login Pages

Playbook Ansible che installa su un CT (Debian 12 / Ubuntu 22.04+):

- **OpenWISP2 full**: controller, monitoring, network topology, firmware upgrader, RADIUS
- **WiFi Login Pages** (captive portal)
- **Server WireGuard** integrato con OpenWISP (peer aggiornati automaticamente via webhook)

Il certificato SSL **non** viene gestito dal playbook: lo carichi tu manualmente sul CT (vedi sotto).

## Prerequisiti

- CT con Debian 12 o Ubuntu 22.04/24.04, accesso SSH come root (o utente sudo)
- Ansible ≥ 2.13 sulla macchina da cui lanci il playbook
- **Se il CT è un LXC su Proxmox**: il modulo `wireguard` è nel kernel dell'host
  (kernel ≥ 5.6, quindi ok su Proxmox 7+). Per un container *unprivileged*
  assicurati che sia disponibile `/dev/net/tun`:

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

## 2. Prima esecuzione (OpenWISP + WiFi Login Pages)

```bash
ansible-playbook -i hosts playbook.yml
```

Il play WireGuard si auto-esclude finché UUID/key della VPN sono i placeholder.

Al termine vai su `https://<tuo-dominio>/admin`: il ruolo crea l'utente
**admin / admin** — cambia subito la password da
`https://<tuo-dominio>/admin/password_change/`.

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

## 4. WireGuard (VXLAN over WireGuard)

**Design**: la VPN serve solo a far vedere i router tra loro e a scambiare
le rotte via Babel — **ogni router mantiene il proprio gateway e OpenWISP
NON fa da gateway** (nessun NAT, nessuna default route via tunnel).

Per questo il backend consigliato è **VXLAN over WireGuard**: la VXLAN crea
una L2 sopra il tunnel (l'equivalente della vecchia ZeroTier), che permette
a Babel di scoprire i vicini via multicast — cosa che su WireGuard "puro"
hub-and-spoke non funziona, perché il cryptokey routing blocca i pacchetti
link-local/multicast di Babel.

### 4a. Crea la VPN in OpenWISP

1. Admin → **VPN servers** → Add:
   - Backend: **VXLAN over WireGuard**
   - Host: `194.28.98.61` (IP pubblico del CT), porta `51820`
   - Subnet: crea una subnet dedicata (`10.27.250.0/24`, la stessa di
     `firewall_wg_subnet_v4` nel play firewall) — è la rete dei tunnel
   - Webhook endpoint: `https://openwisp.ninux-nnxx.it:8081/trigger-update`
   - Webhook AuthToken: lo stesso valore di `openwisp2_wireguard_flask_key` nel playbook
2. Salva e copia **UUID** e **Key** dell'oggetto VPN.

### 4b. Deploy del server WireGuard

Incolla UUID, key e token nel play `wireguard` di `playbook.yml`, poi:

```bash
ansible-playbook -i hosts playbook.yml --tags wireguard
```

Il ruolo installa anche NetworkManager e lo script `update_vxlan.py`: quando
un device si registra, OpenWISP chiama il webhook e sul server vengono creati
peer WireGuard e interfacce `vxlan<VNI>` automaticamente.

### 4c. Template client

In Admin → **Templates** → Add:

- Type: **VPN-client**
- VPN: la VPN creata sopra
- Automatic tunnel provisioning: attivo

Usa la configurazione **auto-generata senza modificarla**: `allowed_ips`
resta la subnet della VPN (10.27.250.0/24), così nel tunnel passa solo il
traffico tra router (e la VXLAN incapsulata) e ogni router continua a usare
il **proprio** gateway per tutto il resto. Non impostare `0.0.0.0/0`: faresti
di OpenWISP il gateway di tutti i nodi.

Sul router l'interfaccia VXLAN risultante è quella su cui va agganciato
Babel nella config bird del nodo (al posto della vecchia `owzt0d3e97` di
ZeroTier); il resto della tua config dei router (kernel/direct/babel/OSPF
per la default via `br-mesh`) resta identico.

> **Router senza internet propria**: funzionano senza modifiche. La default
> la imparano dalla mesh vicina via OSPF su `br-mesh` (come già previsto
> dalla tua config), e il tunnel WireGuard verso `194.28.98.61` esce
> semplicemente attraverso quel gateway: per WireGuard è normale traffico
> UDP che segue la rotta di default del momento. I filtri Babel continuano
> a garantire che la default non arrivi mai dalla VPN, quindi ogni nodo
> usa sempre il gateway della propria zona (WAN locale o mesh vicina).

## 4d. Firewall

Il play `firewall` (nftables) applica una policy **default drop** in ingresso.
Niente NAT: OpenWISP non fa da gateway; il forward è permesso **solo**
`wg0 → wg0` (traffico router↔router attraverso l'hub).

Interfacce del CT: **eth0** = rete di gestione (10.27.22.18),
**eth1** = IP pubblico (194.28.98.61 / 2a07:7e81:3f1c::18).

| Porta | Proto | Da | Servizio |
|-------|-------|-----|----------|
| 2400  | TCP   | solo `eth0` (gestione) | SSH |
| 80, 443 | TCP | ovunque | nginx (OpenWISP + WiFi Login Pages) |
| 51820 | UDP   | ovunque | WireGuard |
| 4789  | UDP   | solo da `wg0` | VXLAN (incapsulata nel tunnel) |
| 8081  | TCP   | solo loopback e IP del CT | webhook aggiornamento peer |
| 1812–1813 | UDP | solo VPN (10.27.250.0/24) e gestione (10.27.0.0/16) | FreeRADIUS |
| 6696  | UDP   | solo interfacce `vxlan*` e `eth1` | Babel (bird2) |

Il play si applica anche da solo con `--tags firewall`.

## 4e. bird2 / Babel (rete NINUX)

Il play `bird` (tag omonimo) installa **bird2** e applica
`templates/bird.conf.j2`, allineata alla config dei router NINUX:

- **Babel** gira sulle interfacce `vxlan*` (la L2 sopra WireGuard, al posto
  della vecchia ZeroTier) e su `eth1`, con `check link yes` e `rxcost 600`
- il protocollo **direct `vpn`** annuncia via Babel la subnet dei tunnel
  (10.27.250.0/24) presa da `wg0`
- come sui router, la **default route non viene mai né annunciata né
  importata** via Babel (filtri identici ai tuoi: `net != 0.0.0.0/0` /
  `net != ::/0`): ogni nodo tiene il suo gateway
- kernel4/kernel6 con `scan time 20`, `learn yes`, `merge paths yes` come
  sui router; il router id è ricavato da `eth1`

La config viene validata con `bird -p` prima dell'applicazione.

> NB: `wg0` e le `vxlan*` esistono solo dopo il deploy WireGuard (passo 4b)
> e la registrazione dei primi device; con `check link yes` bird le ignora
> finché non compaiono, quindi il play si può lanciare anche prima.

## 5. WiFi Login Pages

Le login pages rispondono su `https://wifi.example.com`. Per ogni
organizzazione serve un file YAML in `owlp_organizations/` con UUID e token
RADIUS (vedi `owlp_organizations/README.md`), poi rilancia il playbook.
