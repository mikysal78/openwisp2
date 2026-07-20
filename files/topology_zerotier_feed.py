# Alimenta le topology ZeroTier (parser ZeroTierParser, strategy receive)
# interrogando il controller ZeroTier locale. Eseguito da cron via:
#   manage.py shell < topology_zerotier_feed.py
import urllib.request
from swapper import load_model

Topology = load_model('topology', 'Topology')
token = open('/var/lib/zerotier-one/authtoken.secret').read().strip()
req = urllib.request.Request('http://localhost:9993/peer', headers={'X-ZT1-Auth': token})
peers = urllib.request.urlopen(req, timeout=10).read().decode()

for t in Topology.objects.filter(parser='netdiff.ZeroTierParser', strategy='receive'):
    try:
        t.receive(peers)
        print('fed:', t.label)
    except Exception as e:
        print('errore su', t.label, '->', str(e)[:120])
