#!/usr/bin/env python3
"""Genera la pagina pubblica dell'informativa privacy della pagina wifi.

Facebook e Google chiedono un URL pubblico per la privacy e per le istruzioni
di cancellazione dei dati, ma la pagina wifi mostra l'informativa solo in una
finestra interna. Questo script la ricostruisce da server_assets/privacy-*.md
in client_assets/privacy.html, servita su
https://wifi.ninux-nnxx.it/assets/basilicata/privacy.html
(sezione cancellazione: #cancellazione e #deletion).

Rilanciarlo a ogni modifica di privacy-it.md o privacy-en.md.
I .md usano solo titoli «#», paragrafi in **grassetto**, elenchi «- » e link.
"""
import html
import re
from pathlib import Path

ORG = Path(__file__).resolve().parent.parent / "owlp_organizations" / "basilicata"
# id delle sezioni da linkare direttamente (istruzioni di cancellazione)
ANCHORS = {"Cancellazione dei dati": "cancellazione", "Data deletion": "deletion"}


def inline(text):
    text = html.escape(text, quote=False)
    text = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", text)
    return re.sub(
        r"\[([^\]]+)\]\(([^)]+)\)",
        lambda m: f'<a href="{html.escape(m.group(2))}">{m.group(1)}</a>',
        text,
    )


def convert(md):
    out = []
    for block in re.split(r"\n\s*\n", md.strip()):
        lines = block.splitlines()
        if block.startswith("# "):
            out.append(f"<h2>{inline(block[2:].strip())}</h2>")
        elif re.fullmatch(r"\*\*[^*]+\*\*", block.strip()):
            title = block.strip()[2:-2]
            anchor = ANCHORS.get(title)
            attr = f' id="{anchor}"' if anchor else ""
            out.append(f"<h3{attr}>{inline(title)}</h3>")
        elif lines[0].startswith("- "):
            items, cur = [], []
            for line in lines:
                if line.startswith("- ") and cur:
                    items.append(" ".join(cur))
                    cur = []
                cur.append(line[2:].strip() if line.startswith("- ") else line.strip())
            items.append(" ".join(cur))
            out.append("<ul>" + "".join(f"<li>{inline(i)}</li>" for i in items) + "</ul>")
        else:
            out.append(f"<p>{inline(' '.join(l.strip() for l in lines))}</p>")
    return "\n".join(out)


PAGE = """<!doctype html>
<html lang="it">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Privacy - NINUX Free WiFi</title>
<style>
body {{ font-family: sans-serif; line-height: 1.5; max-width: 760px;
  margin: 0 auto; padding: 16px; color: #222; background: #fff; }}
header img {{ height: 56px; }}
nav a {{ margin-right: 12px; }}
section {{ border-top: 1px solid #ddd; margin-top: 24px; }}
a {{ color: #c0392b; }}
</style>
</head>
<body>
<header><img src="ninux-logo.svg" alt="NINUX"></header>
<nav><a href="#it">Italiano</a><a href="#en">English</a></nav>
<section id="it" lang="it">
{it}
</section>
<section id="en" lang="en">
{en}
</section>
</body>
</html>
"""

if __name__ == "__main__":
    src = ORG / "server_assets"
    page = PAGE.format(
        it=convert((src / "privacy-it.md").read_text()),
        en=convert((src / "privacy-en.md").read_text()),
    )
    dest = ORG / "client_assets" / "privacy.html"
    dest.write_text(page)
    print(dest)
