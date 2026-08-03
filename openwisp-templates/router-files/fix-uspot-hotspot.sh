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
#   BUG D (firmware) — il pacchetto libradcli NON installa alcun file
#     dizionario e il Makefile di uspot non installa le VSA WISPr/ChilliSpot,
#     percio' /etc/radcli/dictionary MANCA. Senza dizionario uspot-radius
#     fallisce ('couldn't open dictionary' e poi 'Failed to lookup attribute
#     key 23' = WISPr-Logoff-URL) e NON invia nessuna Access-Request/Accounting
#     -> il login captive gira all'infinito e su freeradius non compaiono
#     sessioni. Si posa un dizionario completo (radcli 1.3.0 + WISPr 14122 +
#     ChilliSpot 14559). Anche questo e' nel template OpenWISP (files[]).
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

# --- BUG D: dizionario radcli mancante nel firmware -----------------------
# uspot-radius (libradcli) legge /etc/radcli/dictionary. Il firmware non lo
# installa e mancano le VSA WISPr/ChilliSpot: lo posiamo noi. Rileviamo il
# problema se il file manca o non contiene la VSA WISPr-Logoff-URL.
D=/etc/radcli/dictionary
if [ ! -f "$D" ] || ! grep -q 'WISPr-Logoff-URL' "$D" 2>/dev/null; then
    mkdir -p /etc/radcli
    cat > "$D" <<'RADCLI_DICT_EOF'
#
# Updated 97/06/13 to livingston-radius-2.01 miquels@cistron.nl
#
#	This file contains dictionary translations for parsing
#	requests and generating responses.  All transactions are
#	composed of Attribute/Value Pairs.  The value of each attribute
#	is specified as one of 4 data types.  Valid data types are:
#
#	string - 0-253 octets
#	ipv4addr- 4 octets in network byte order
#	ipv6addr  - 16 octets in network byte order
#	ipv6prefix- up to 16 octets in network byte order, plus prefix length
#	integer - 32 bit value in big endian order (high byte first)
#	date - 32 bit value in big endian order - seconds since
#					00:00:00 GMT,  Jan.  1,  1970
#
#	Enumerated values are stored in the user file with dictionary
#	VALUE translations for easy administration.
#
#	Example:
#
#	ATTRIBUTE	  VALUE
#	---------------   -----
#	Framed-Protocol = PPP
#	7		= 1	(integer encoding)
#

#
#	Following are the proper new names. Use these.
#
ATTRIBUTE	User-Name		1	string
ATTRIBUTE	Password		2	string
ATTRIBUTE	CHAP-Password		3	string
ATTRIBUTE	NAS-IP-Address		4	ipv4addr
ATTRIBUTE	NAS-Port-Id		5	integer
ATTRIBUTE	Service-Type		6	integer
ATTRIBUTE	Framed-Protocol		7	integer
ATTRIBUTE	Framed-IP-Address	8	ipv4addr
ATTRIBUTE	Framed-IP-Netmask	9	ipv4addr
ATTRIBUTE	Framed-Routing		10	integer
ATTRIBUTE	Filter-Id		11	string
ATTRIBUTE	Framed-MTU		12	integer
ATTRIBUTE	Framed-Compression	13	integer
ATTRIBUTE	Login-IP-Host		14	ipv4addr
ATTRIBUTE	Login-Service		15	integer
ATTRIBUTE	Login-TCP-Port		16	integer
ATTRIBUTE	Reply-Message		18	string
ATTRIBUTE	Callback-Number		19	string
ATTRIBUTE	Callback-Id		20	string
ATTRIBUTE	Framed-Route		22	string
ATTRIBUTE	Framed-IPX-Network	23	ipv4addr
ATTRIBUTE	State			24	string
ATTRIBUTE	Class			25	string
ATTRIBUTE	Vendor-Specific		26	string
ATTRIBUTE	Session-Timeout		27	integer
ATTRIBUTE	Idle-Timeout		28	integer
ATTRIBUTE	Termination-Action	29	integer
ATTRIBUTE	Called-Station-Id	30	string
ATTRIBUTE	Calling-Station-Id	31	string
ATTRIBUTE	NAS-Identifier		32	string
ATTRIBUTE	Proxy-State		33	string
ATTRIBUTE	Login-LAT-Service	34	string
ATTRIBUTE	Login-LAT-Node		35	string
ATTRIBUTE	Login-LAT-Group		36	string
ATTRIBUTE	Framed-AppleTalk-Link	37	integer
ATTRIBUTE	Framed-AppleTalk-Network	38	integer
ATTRIBUTE	Framed-AppleTalk-Zone	39	string
ATTRIBUTE	Acct-Status-Type	40	integer
ATTRIBUTE	Acct-Delay-Time		41	integer
ATTRIBUTE	Acct-Input-Octets	42	integer
ATTRIBUTE	Acct-Output-Octets	43	integer
ATTRIBUTE	Acct-Session-Id		44	string
ATTRIBUTE	Acct-Authentic		45	integer
ATTRIBUTE	Acct-Session-Time	46	integer
ATTRIBUTE	Acct-Input-Packets	47	integer
ATTRIBUTE	Acct-Output-Packets	48	integer
ATTRIBUTE	Acct-Terminate-Cause	49	integer
ATTRIBUTE	Acct-Multi-Session-Id	50	string
ATTRIBUTE	Acct-Link-Count		51	integer
ATTRIBUTE	Acct-Input-Gigawords	52	integer
ATTRIBUTE	Acct-Output-Gigawords	53	integer
ATTRIBUTE	Event-Timestamp		55	integer
ATTRIBUTE	Egress-VLANID		56	string
ATTRIBUTE	Ingress-Filters		57	integer
ATTRIBUTE	Egress-VLAN-Name	58	string
ATTRIBUTE	User-Priority-Table	59	string
ATTRIBUTE	CHAP-Challenge		60	string
ATTRIBUTE	NAS-Port-Type		61	integer
ATTRIBUTE	Port-Limit		62	integer
ATTRIBUTE	Login-LAT-Port		63	integer
ATTRIBUTE	Tunnel-Type		64	string
ATTRIBUTE	Tunnel-Medium-Type	65	string
ATTRIBUTE	Tunnel-Client-Endpoint	66	string
ATTRIBUTE	Tunnel-Server-Endpoint	67	string
ATTRIBUTE	Acct-Tunnel-Connection	68	string
ATTRIBUTE	Tunnel-Password		69	string
ATTRIBUTE	ARAP-Password		70	string
ATTRIBUTE	ARAP-Features		71	string
ATTRIBUTE	ARAP-Zone-Access	72	integer
ATTRIBUTE	ARAP-Security		73	integer
ATTRIBUTE	ARAP-Security-Data	74	string
ATTRIBUTE	Password-Retry		75	integer
ATTRIBUTE	Prompt			76	integer
ATTRIBUTE	Connect-Info		77	string
ATTRIBUTE	Configuration-Token	78	string
ATTRIBUTE	EAP-Message		79	string
ATTRIBUTE	Message-Authenticator	80	string
ATTRIBUTE	Tunnel-Private-Group-ID	81	string
ATTRIBUTE	Tunnel-Assignment-ID	82	string
ATTRIBUTE	Tunnel-Preference	83	string
ATTRIBUTE	ARAP-Challenge-Response	84	string
ATTRIBUTE	Acct-Interim-Interval	85	integer
ATTRIBUTE	Acct-Tunnel-Packets-Lost	86	integer
ATTRIBUTE	NAS-Port-Id-String	87	string
ATTRIBUTE	Framed-Pool		88	string
ATTRIBUTE	Chargeable-User-Identity	89	string
ATTRIBUTE	Tunnel-Client-Auth-ID	90	string
ATTRIBUTE	Tunnel-Server-Auth-ID	91	string
ATTRIBUTE	NAS-Filter-Rule		92	string
ATTRIBUTE	Originating-Line-Info	94	string
ATTRIBUTE	NAS-IPv6-Address	95	ipv6addr
ATTRIBUTE	Framed-Interface-Id	96	string
ATTRIBUTE	Framed-IPv6-Prefix	97	ipv6prefix
ATTRIBUTE	Login-IPv6-Host		98	ipv6addr
ATTRIBUTE	Framed-IPv6-Route	99	string
ATTRIBUTE	Framed-IPv6-Pool	100	string
ATTRIBUTE	Error-Cause		101	integer
ATTRIBUTE	EAP-Key-Name		102	string

#
#	RFC6911 IPv6 attributes
#
ATTRIBUTE       Delegated-IPv6-Prefix   123     ipv6prefix
ATTRIBUTE	Framed-IPv6-Address	168	ipv6addr
ATTRIBUTE	DNS-Server-IPv6-Address	169	ipv6addr
ATTRIBUTE	Route-IPv6-Information	170	ipv6prefix

ATTRIBUTE	Huntgroup-Name		221	string
#
#	Non-Protocol Attributes
#	These attributes are used internally by the server
#
ATTRIBUTE	Expiration		  21	date
ATTRIBUTE	Auth-Type		1000	integer
ATTRIBUTE	Menu			1001	string
ATTRIBUTE	Termination-Menu	1002	string
ATTRIBUTE	Prefix			1003	string
ATTRIBUTE	Suffix			1004	string
ATTRIBUTE	Group			1005	string
ATTRIBUTE	Crypt-Password		1006	string
ATTRIBUTE	Connect-Rate		1007	integer
ATTRIBUTE	User-Category		1029	string
ATTRIBUTE	Group-Name		1030	string
ATTRIBUTE	Simultaneous-Use	1034	integer
ATTRIBUTE	Strip-User-Name		1035	integer
ATTRIBUTE	Fall-Through		1036	integer
ATTRIBUTE	Add-Port-To-IP-Address	1037	integer
ATTRIBUTE	Exec-Program		1038	string
ATTRIBUTE	Exec-Program-Wait	1039	string
ATTRIBUTE	Hint			1040	string


#
#	Integer Translations
#

#	User Types

VALUE		Service-Type		Login-User		1
VALUE		Service-Type		Framed-User		2
VALUE		Service-Type		Callback-Login-User	3
VALUE		Service-Type		Callback-Framed-User	4
VALUE		Service-Type		Outbound-User		5
VALUE		Service-Type		Administrative-User	6
VALUE		Service-Type		NAS-Prompt-User		7
VALUE		Service-Type		Authenticate-Only	8
VALUE		Service-Type		Callback-NAS-Prompt	9
VALUE		Service-Type		Call-Check		10
VALUE		Service-Type		Callback-Administrative	11

#	Framed Protocols

VALUE		Framed-Protocol		PPP			1
VALUE		Framed-Protocol		SLIP			2
VALUE		Framed-Protocol		ARAP			3
VALUE		Framed-Protocol		GANDALF-SLMLP		4
VALUE		Framed-Protocol		XYLOGICS-IPX-SLIP	5
VALUE		Framed-Protocol		X75			6

#	Framed Routing Values

VALUE		Framed-Routing		None			0
VALUE		Framed-Routing		Broadcast		1
VALUE		Framed-Routing		Listen			2
VALUE		Framed-Routing		Broadcast-Listen	3

#	Framed Compression Types

VALUE		Framed-Compression	None			0
VALUE		Framed-Compression	Van-Jacobson-TCP-IP	1
VALUE		Framed-Compression	IPX-Header		2
VALUE		Framed-Compression	Stac-LZS		3

#	Login Services

VALUE		Login-Service		Telnet			0
VALUE		Login-Service		Rlogin			1
VALUE		Login-Service		TCP-Clear		2
VALUE		Login-Service		PortMaster		3
VALUE		Login-Service		LAT			4
VALUE		Login-Service		X.25-PAD		5
VALUE		Login-Service		X.25-T3POS		6
VALUE		Login-Service		TCP-Clear-Quiet		8

#	Status Types

VALUE		Acct-Status-Type	Start			1
VALUE		Acct-Status-Type	Stop			2
VALUE		Acct-Status-Type	Alive			3
VALUE		Acct-Status-Type	Accounting-On		7
VALUE		Acct-Status-Type	Accounting-Off		8

#	Authentication Types

VALUE		Acct-Authentic		RADIUS			1
VALUE		Acct-Authentic		Local			2
VALUE		Acct-Authentic		Remote			3

#	Termination Options

VALUE		Termination-Action	Default			0
VALUE		Termination-Action	RADIUS-Request		1

#	NAS Port Types, available in 3.3.1 and later

VALUE		NAS-Port-Type		Async			0
VALUE		NAS-Port-Type		Sync			1
VALUE		NAS-Port-Type		ISDN			2
VALUE		NAS-Port-Type		ISDN-V120		3
VALUE		NAS-Port-Type		ISDN-V110		4
VALUE		NAS-Port-Type		Virtual			5
VALUE		NAS-Port-Type		PIAFS			6
VALUE		NAS-Port-Type		HDLC-Clear-Channel	7
VALUE		NAS-Port-Type		X.25			8
VALUE		NAS-Port-Type		X.75			9
VALUE		NAS-Port-Type		G.3-Fax			10
VALUE		NAS-Port-Type		SDSL			11
VALUE		NAS-Port-Type		ADSL-CAP		12
VALUE		NAS-Port-Type		ADSL-DMT		13
VALUE		NAS-Port-Type		IDSL			14
VALUE		NAS-Port-Type		Ethernet		15

#	Acct Terminate Causes, available in 3.3.2 and later

VALUE           Acct-Terminate-Cause    User-Request            1
VALUE           Acct-Terminate-Cause    Lost-Carrier            2
VALUE           Acct-Terminate-Cause    Lost-Service            3
VALUE           Acct-Terminate-Cause    Idle-Timeout            4
VALUE           Acct-Terminate-Cause    Session-Timeout         5
VALUE           Acct-Terminate-Cause    Admin-Reset             6
VALUE           Acct-Terminate-Cause    Admin-Reboot            7
VALUE           Acct-Terminate-Cause    Port-Error              8
VALUE           Acct-Terminate-Cause    NAS-Error               9
VALUE           Acct-Terminate-Cause    NAS-Request             10
VALUE           Acct-Terminate-Cause    NAS-Reboot              11
VALUE           Acct-Terminate-Cause    Port-Unneeded           12
VALUE           Acct-Terminate-Cause    Port-Preempted          13
VALUE           Acct-Terminate-Cause    Port-Suspended          14
VALUE           Acct-Terminate-Cause    Service-Unavailable     15
VALUE           Acct-Terminate-Cause    Callback                16
VALUE           Acct-Terminate-Cause    User-Error              17
VALUE           Acct-Terminate-Cause    Host-Request            18

#
#	Non-Protocol Integer Translations
#

VALUE		Auth-Type		Local			0
VALUE		Auth-Type		System			1
VALUE		Auth-Type		SecurID			2
VALUE		Auth-Type		Crypt-Local		3
VALUE		Auth-Type		Reject			4

#
#	Cistron extensions
#
VALUE		Auth-Type		Pam			253
VALUE		Auth-Type		Accept			254

#
#	Experimental Non-Protocol Integer Translations for Cistron-Radiusd
#
VALUE		Fall-Through		No			0
VALUE		Fall-Through		Yes			1
VALUE		Add-Port-To-IP-Address	No			0
VALUE		Add-Port-To-IP-Address	Yes			1

#
#	Configuration Values
#	uncomment these two lines to turn account expiration on
#

#VALUE		Server-Config		Password-Expiration	30
#VALUE		Server-Config		Password-Warning	5

#$INCLUDE /etc/radcli/dictionary.microsoft
#$INCLUDE /etc/radcli/dictionary.roaringpenguin


#
# --- uspot VSA: WISPr (WBAL 14122) ---

VENDOR		WISPr	14122	WISPr

ATTRIBUTE	WISPr-Location-ID			1	string	WISPr
ATTRIBUTE	WISPr-Location-Name			2	string	WISPr
ATTRIBUTE	WISPr-Logoff-URL			3	string	WISPr
ATTRIBUTE	WISPr-Redirection-URL			4	string	WISPr
ATTRIBUTE	WISPr-Bandwidth-Min-Up			5	integer	WISPr
ATTRIBUTE	WISPr-Bandwidth-Min-Down		6	integer	WISPr
ATTRIBUTE	WISPr-Bandwidth-Max-Up			7	integer	WISPr
ATTRIBUTE	WISPr-Bandwidth-Max-Down		8	integer	WISPr
ATTRIBUTE	WISPr-Session-Terminate-Time		9	string	WISPr
ATTRIBUTE	WISPr-Billing-Class-Of-Service		11	string	WISPr

# --- uspot VSA: ChilliSpot (14559) ---
VENDOR	ChilliSpot	14559 ChilliSpot

ATTRIBUTE	ChilliSpot-Max-Input-Octets		1	integer	ChilliSpot
ATTRIBUTE	ChilliSpot-Max-Output-Octets		2	integer	ChilliSpot
ATTRIBUTE	ChilliSpot-Max-Total-Octets		3	integer	ChilliSpot
ATTRIBUTE	ChilliSpot-Bandwidth-Max-Up		4	integer	ChilliSpot
ATTRIBUTE	ChilliSpot-Bandwidth-Max-Down		5	integer	ChilliSpot
ATTRIBUTE	ChilliSpot-Config			6	string	ChilliSpot
ATTRIBUTE	ChilliSpot-Lang				7	string	ChilliSpot
ATTRIBUTE	ChilliSpot-Version			8	string	ChilliSpot
ATTRIBUTE	ChilliSpot-OriginalURL			9	string	ChilliSpot
ATTRIBUTE	ChilliSpot-Max-Input-Gigawords		21	integer	ChilliSpot
ATTRIBUTE	ChilliSpot-Max-Output-Gigawords		22	integer	ChilliSpot
ATTRIBUTE	ChilliSpot-Max-Total-Gigawords		23	integer	ChilliSpot
ATTRIBUTE	ChilliSpot-UAM-Allowed			100	string ChilliSpot
ATTRIBUTE	ChilliSpot-MAC-Allowed			101	string ChilliSpot
ATTRIBUTE	ChilliSpot-Interval			102	integer ChilliSpot
RADCLI_DICT_EOF
    log "dizionario radcli posato in $D (radcli + WISPr + ChilliSpot)"
else
    log "dizionario radcli gia' completo, salto"
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

# walled-garden: entry STATICA verso il portale nell'ipset wlist. Serve perche'
# il dnsmasq del firmware e' 'no-nftset' e non popola il set via DNS -> senza
# questa entry il captive fa REJECT verso il portale (ERR_CONNECTION_REFUSED).
PORTAL_IP="${PORTAL_IP:-194.28.98.61}"
WLIST=$(uci show firewall 2>/dev/null | sed -n "s/^firewall\.\([^.]*\)\.name='wlist'\$/\1/p" | head -1)
if [ -n "$WLIST" ]; then
    uci -q del_list firewall."$WLIST".entry="$PORTAL_IP" 2>/dev/null || true
    uci add_list firewall."$WLIST".entry="$PORTAL_IP"
    log "wlist entry statica -> $PORTAL_IP (firewall.$WLIST)"
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
