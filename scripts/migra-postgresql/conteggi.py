# Conteggio degli oggetti per modello e checksum delle config, per confrontare
# SQLite e PostgreSQL prima del passaggio (stampa una riga JSON con "@@").
import json

from django.apps import apps
from openwisp_controller.config.models import Config

out = {"count": {}, "checksum": {}}
for m in apps.get_models():
    if m._meta.proxy or not m._meta.managed:
        continue
    out["count"][m._meta.label] = m.objects.count()
for c in Config.objects.select_related("device"):
    out["checksum"][c.device.name] = c.checksum
print("@@" + json.dumps(out))
