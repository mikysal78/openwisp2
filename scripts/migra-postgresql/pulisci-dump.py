"""Toglie dal dump le metriche duplicate a meno del formato JSON di main_tags.

Fino al 9/9/2026 main_tags era salvato indentato, dopo compatto: su SQLite il
vincolo unique confronta il testo e OpenWISP ha creato una seconda metrica per
ogni interfaccia; su PostgreSQL (jsonb) le due coppie violano il vincolo. Si
tiene la piu' recente (quella in uso), si scartano la vecchia e i suoi grafici
e le notifiche che la citano. I dati restano in InfluxDB (chiave + tag).
"""
import json
import sys

src, dst = sys.argv[1], sys.argv[2]
objs = json.load(open(src))

gruppi = {}
for o in objs:
    if o["model"] != "monitoring.metric":
        continue
    f = o["fields"]
    tags = f["main_tags"]
    if isinstance(tags, str):
        tags = json.loads(tags)
    k = (f["key"], f["field_name"], json.dumps(f["content_type"]), f["object_id"],
         json.dumps(tags, sort_keys=True))
    gruppi.setdefault(k, []).append(o)

scarta = set()
for lista in gruppi.values():
    lista.sort(key=lambda o: o["fields"]["modified"])
    scarta.update(o["pk"] for o in lista[:-1])

def via(o):
    m, f = o["model"], o.get("fields", {})
    if m == "monitoring.metric":
        return o["pk"] in scarta
    if m in ("monitoring.chart", "monitoring.alertsettings"):
        return f.get("metric") in scarta
    if m == "openwisp_notifications.notification":
        return any(str(f.get(c)) in scarta for c in
                   ("actor_object_id", "action_object_object_id", "target_object_id"))
    return False

out = [o for o in objs if not via(o)]
json.dump(out, open(dst, "w"))
tolti = {}
for o in objs:
    if via(o):
        tolti[o["model"]] = tolti.get(o["model"], 0) + 1
print("metriche duplicate scartate:", len(scarta), "| oggetti tolti:", tolti)
