#!/usr/bin/env python3
"""Genera bird-babel.json (template OpenWISP) dai file in router-files/."""
import json
import os

BASE = os.path.dirname(os.path.abspath(__file__))

with open(os.path.join(BASE, "router-files", "bird.conf")) as f:
    bird_conf = f.read()
with open(os.path.join(BASE, "router-files", "post-reload-hook")) as f:
    hook = f.read()

config = {
    "files": [
        {
            "path": "/etc/bird.conf",
            "mode": "0644",
            "contents": bird_conf,
        },
        {
            "path": "/etc/openwisp/post-reload-hook",
            "mode": "0755",
            "contents": hook,
        },
    ]
}

out = os.path.join(BASE, "bird-babel.json")
with open(out, "w") as f:
    json.dump(config, f, indent=4)
    f.write("\n")
print(f"scritto {out}")
