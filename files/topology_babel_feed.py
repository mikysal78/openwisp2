# Alimenta la topology "Babel NINUX" (parser NetJsonParser, strategy receive)
# leggendo le tabelle dei vicini Babel di BIRD sul server e su ogni router.
# Eseguito da cron via:
#   manage.py shell < topology_babel_feed.py
# Con BABEL_FEED_DRY_RUN=1 stampa il NetworkGraph invece di inviarlo.
#
# Babel è distance-vector: nessun nodo conosce la topologia intera, quindi si
# uniscono i 'show babel neighbors' di tutti i nodi. Un vicino è un indirizzo
# fe80::; lo si attribuisce al router che lo dichiara come proprio next hop v6
# in 'show babel interfaces'. Se un router non risponde si usano la mappa
# salvata all'ultimo giro (CACHE) e l'EUI-64 del MAC del device.
#
# Gli id dei nodi sono "<MAC del device>@babel": è il formato che
# auto_create_netjsongraph (integrations.device) usa per legare nodo e device.
import fnmatch
import json
import os
import subprocess
from concurrent.futures import ThreadPoolExecutor

from swapper import load_model

TOPOLOGY_LABEL = 'Babel NINUX'
CACHE = '/opt/openwisp2/topology_babel_cache.json'
SERVER_ID = 'openwisp@babel'
# Sulla VPN ZeroTier ogni nodo vede tutti gli altri (maglia completa); dove
# c'è anche radio o cavo vince comunque il più economico, come in Babel, e la
# VPN resta tra le adiacenze di riserva. Con False i siti collegati solo via
# VPN restano nodi isolati.
VPN_IFACES = ('owzt*', 'zt*')
INCLUDE_VPN = True
BIRDC = 'birdc show status; birdc show babel interfaces; birdc show babel neighbors'
SSH = [
    'ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5',
    '-o', 'StrictHostKeyChecking=accept-new',
]

Device = load_model('config', 'Device')
Topology = load_model('topology', 'Topology')


def run_birdc(ip):
    """Output di BIRDC in locale (ip=None) o via SSH; None se non risponde."""
    cmd = ['sh', '-c', BIRDC] if ip is None else SSH + [f'root@{ip}', BIRDC]
    try:
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    except subprocess.TimeoutExpired:
        return None
    return res.stdout if res.returncode == 0 and 'ready.' in res.stdout else None


def parse_birdc(text):
    """Router ID, hostname, link-local propri e vicini (addr, iface, metrica)."""
    info = {'router_id': None, 'hostname': None, 'own': {}, 'neighbors': []}
    mode = None
    for line in text.splitlines():
        parts = line.split()
        if not parts:
            continue
        if line.startswith('BIRD '):
            mode = None
        elif line.startswith('Router ID is '):
            info['router_id'] = parts[-1]
        elif line.startswith('Hostname is '):
            info['hostname'] = parts[-1]
        elif parts[:2] == ['Interface', 'State']:
            mode = 'interfaces'
        elif parts[:2] == ['IP', 'address']:
            mode = 'neighbors'
        elif mode == 'interfaces' and len(parts) >= 8 and parts[7].startswith('fe80:'):
            info['own'][parts[7]] = parts[0]
        elif mode == 'neighbors' and len(parts) >= 3 and parts[0].startswith('fe80:'):
            try:
                info['neighbors'].append((parts[0], parts[1], int(parts[2])))
            except ValueError:
                pass
    return info


def eui64_link_local(mac):
    """fe80:: che il kernel deriva dal MAC (vale per le interfacce col MAC del device)."""
    b = [int(x, 16) for x in mac.split(':')]
    b[0] ^= 0x02
    w = [b[0] << 8 | b[1], b[2] << 8 | 0xff, 0xfe << 8 | b[3], b[4] << 8 | b[5]]
    return 'fe80::' + ':'.join(f'{x:x}' for x in w)


def link_type(iface):
    if any(fnmatch.fnmatch(iface, p) for p in VPN_IFACES):
        return 'vpn'
    if 'mesh' in iface or iface.startswith(('wlan', 'phy')):
        return 'radio'
    return 'cavo'


def load_cache():
    try:
        with open(CACHE) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save_cache(owner):
    tmp = CACHE + '.tmp'
    with open(tmp, 'w') as f:
        json.dump(owner, f, indent=1, sort_keys=True)
    os.replace(tmp, CACHE)


def build_graph(devices):
    nodes = {SERVER_ID: {'id': SERVER_ID, 'label': 'OpenWISP', 'properties': {}}}
    targets = {SERVER_ID: None}
    for d in devices:
        node_id = f'{d.mac_address.upper()}@babel'
        nodes[node_id] = {
            'id': node_id,
            'label': d.name,
            'local_addresses': [str(d.management_ip or d.mac_address)],
            'properties': {},
        }
        if d.management_ip:
            targets[node_id] = str(d.management_ip)

    with ThreadPoolExecutor(max_workers=8) as pool:
        outputs = dict(zip(targets, pool.map(run_birdc, targets.values())))
    infos = {n: parse_birdc(out) for n, out in outputs.items() if out}

    # fe80 -> nodo: cache < EUI-64 dei MAC < dati appena letti
    owner = load_cache()
    for d in devices:
        owner[eui64_link_local(d.mac_address)] = f'{d.mac_address.upper()}@babel'
    for node_id, info in infos.items():
        for addr in info['own']:
            owner[addr] = node_id
        props = nodes[node_id]['properties']
        if info['router_id']:
            props['router_id'] = info['router_id']
        props['babel_interfaces'] = sorted(set(info['own'].values()))
    save_cache({a: n for a, n in owner.items() if n in nodes})

    # costo per coppia, verso e interfaccia; il link usa il più economico, come Babel
    paths = {}
    for src, info in infos.items():
        for addr, iface, cost in info['neighbors']:
            if not INCLUDE_VPN and link_type(iface) == 'vpn':
                continue
            dst = owner.get(addr, addr)
            if dst == src:
                continue
            if dst not in nodes:
                nodes[dst] = {'id': dst, 'label': f'{addr} (non gestito)',
                              'properties': {'interface': iface}}
            by_iface = paths.setdefault((src, dst), {})
            by_iface[iface] = min(cost, by_iface.get(iface, cost))

    links = []
    for a, b in sorted({tuple(sorted(pair)) for pair in paths}):
        dirs = [(s, t) for s, t in ((a, b), (b, a)) if (s, t) in paths]
        seen = {s: min((c, i) for i, c in paths[(s, t)].items()) for s, t in dirs}
        label = {n: nodes[n]['label'] for n in (a, b)}
        types = sorted({link_type(iface) for _, iface in seen.values()})
        # il diff di netdiff mette le proprietà dei link in un set:
        # servono valori hashable, quindi stringhe e non dict
        links.append({
            'source': a,
            'target': b,
            'cost': max(c for c, _ in seen.values()),
            'cost_text': f"{'/'.join(types)} {'/'.join(str(c) for c, _ in seen.values())}",
            'properties': {
                'type': types[0] if len(types) == 1 else 'misto',
                'costs': ' / '.join(f'{label[s]} {c}' for s, (c, _) in seen.items()),
                'interfaces': ' / '.join(f'{label[s]} {i}' for s, (_, i) in seen.items()),
                # tutte le adiacenze, anche quelle di riserva (es. radio + cavo)
                'all_costs': '; '.join(
                    f'{label[s]}: '
                    + ', '.join(f'{i} {c}' for i, c in sorted(paths[(s, t)].items()))
                    for s, t in dirs
                ),
            },
        })

    return {
        'type': 'NetworkGraph',
        'protocol': 'babel',
        'version': 'BIRD',
        'metric': 'babel',
        'label': TOPOLOGY_LABEL,
        'nodes': list(nodes.values()),
        'links': links,
    }, sorted(set(targets) - set(infos))


for t in Topology.objects.filter(
    label=TOPOLOGY_LABEL, parser='netdiff.NetJsonParser', strategy='receive'
):
    devices = Device.objects.exclude(mac_address='')
    if t.organization_id:
        devices = devices.filter(organization_id=t.organization_id)
    devices = [d for d in devices if not d.is_deactivated()]
    graph, unreachable = build_graph(devices)
    if unreachable:
        print('non raggiungibili:', ', '.join(unreachable))
    if os.environ.get('BABEL_FEED_DRY_RUN'):
        print(json.dumps(graph, indent=2))
        continue
    try:
        t.receive(json.dumps(graph))
        print('fed:', t.label, len(graph['nodes']), 'nodi', len(graph['links']), 'link')
    except Exception as e:
        print('errore su', t.label, '->', str(e)[:120])
