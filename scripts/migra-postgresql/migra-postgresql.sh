#!/bin/sh
# =============================================================================
# migra-postgresql.sh — passa OpenWISP da SQLite a PostgreSQL + PostGIS
#
# Con SQLite i tanti scrittori concorrenti (uwsgi, daphne, worker celery, cron)
# davano "database is locked": il task che aggiorna i checksum delle config
# falliva e i router appena flashati restavano in loop su "checksum mismatch".
#
# Va lanciato DAL PROPRIO PC, dalla radice del repo (usa ssh e ansible):
#   scripts/migra-postgresql/migra-postgresql.sh
#
# Passi (OpenWISP resta fermo dal 3 al 7, una ventina di minuti):
#   1. PostgreSQL, utente, database ed estensione postgis (play, tag postgresql)
#   2. copia degli script sul server
#   3. stop di cron, freeradius e di tutti i programmi supervisor
#   4. backup del file SQLite e dumpdata
#   5. migrate su PostgreSQL, flush e loaddata con i segnali spenti (carica.py),
#      togliendo prima le metriche duplicate (pulisci-dump.py)
#   6. confronto dei conteggi per modello e dei checksum delle config: se c'e'
#      una differenza inattesa si ferma qui, con SQLite ancora intatto
#   7. playbook completo con ninux_postgresql=true: settings.py e freeradius
#      passano a PostgreSQL, i servizi ripartono
#
# Il caricamento va fatto PRIMA del playbook: con il database vuoto
# load_initial_data.py del ruolo creerebbe admin/admin e un'organizzazione.
#
# Dopo: mettere ninux_postgresql: true in playbook.yml (altrimenti il prossimo
# deploy torna a SQLite).
# Ritorno a SQLite: ansible-playbook playbook.yml -e ninux_postgresql=false
# (il file SQLite non viene toccato; i dati scritti nel frattempo su PostgreSQL
# andrebbero persi).
# =============================================================================
set -eu

SSH="ssh -p 2400 root@10.27.22.18"
OWDIR=/opt/openwisp2
WORK=/root/migrazione-pg
DIR=$(dirname "$0")
STAMP=$(date +%Y%m%d-%H%M)
PGPASSWORD=$(python3 -c 'import yaml; print(yaml.safe_load(open("secrets.yml"))["vault_postgresql_password"])')

TMP=$(mktemp -d)
passo() { printf '\n===== %s  %s\n' "$(date +%H:%M:%S)" "$*"; }

# Se qualcosa va storto prima del playbook, settings.py punta ancora a SQLite
# (intatto): si fanno ripartire i servizi com'erano.
FERMI=0
ripristina() {
    if [ "$FERMI" = 1 ]; then
        echo "ERRORE: riavvio i servizi su SQLite" >&2
        $SSH "rm -f $OWDIR/openwisp2/settings_migrazione.py
          systemctl start cron freeradius; supervisorctl start all" || true
    fi
    rm -rf "$TMP"
}
trap ripristina EXIT

passo "1. PostgreSQL e database"
ansible-playbook playbook.yml --tags postgresql

passo "2. copia degli script sul server"
$SSH "mkdir -p $WORK"
scp -q -P 2400 "$DIR/pulisci-dump.py" "$DIR/carica.py" "$DIR/conteggi.py" root@10.27.22.18:$WORK/
scp -q -P 2400 "$DIR/settings_migrazione.py" root@10.27.22.18:$OWDIR/openwisp2/settings_migrazione.py

passo "3. stop dei servizi"
FERMI=1
$SSH "systemctl stop cron freeradius && supervisorctl stop all && supervisorctl status || true"

passo "4. backup di SQLite e dumpdata"
$SSH "set -e; cd $OWDIR
  sqlite3 db.sqlite3 '.backup db.sqlite3.pre-postgresql-$STAMP'
  env/bin/python manage.py dumpdata --natural-foreign --exclude contenttypes \
    --exclude auth.permission --exclude sessions -o $WORK/dump.json
  env/bin/python $WORK/pulisci-dump.py $WORK/dump.json $WORK/dump-pulito.json
  env/bin/python manage.py shell < $WORK/conteggi.py | grep '^@@' > $WORK/conteggi-sqlite.json"

passo "5. schema e dati su PostgreSQL"
$SSH "set -e; cd $OWDIR
  export PGPASSWORD='$PGPASSWORD' DJANGO_SETTINGS_MODULE=openwisp2.settings_migrazione
  env/bin/python manage.py migrate --no-input > $WORK/migrate.log
  env/bin/python manage.py flush --no-input
  DUMP=$WORK/dump-pulito.json env/bin/python manage.py shell < $WORK/carica.py
  env/bin/python manage.py shell < $WORK/conteggi.py | grep '^@@' > $WORK/conteggi-pg.json"

passo "6. confronto SQLite / PostgreSQL"
$SSH "cat $WORK/conteggi-sqlite.json" | cut -c3- > "$TMP/sqlite.json"
$SSH "cat $WORK/conteggi-pg.json" | cut -c3- > "$TMP/pg.json"
python3 - "$TMP/sqlite.json" "$TMP/pg.json" <<'EOF'
import json, sys
a, b = (json.load(open(f)) for f in sys.argv[1:3])
# contenttypes/permessi: SQLite ha voci di modelli che non esistono piu',
# PostgreSQL le ricrea da zero; metriche e grafici: duplicati scartati.
attese = {"contenttypes.ContentType", "auth.Permission", "monitoring.Metric", "monitoring.Chart"}
diff = {k: (v, b["count"].get(k)) for k, v in a["count"].items() if v != b["count"].get(k)}
print("differenze nei conteggi:", diff)
cs = [n for n in a["checksum"] if a["checksum"][n] != b["checksum"].get(n)]
print("config con checksum diverso:", cs)
if set(diff) - attese or cs:
    sys.exit("differenze inattese: mi fermo, SQLite e' intatto")
EOF

passo "7. playbook con PostgreSQL"
$SSH "rm -f $OWDIR/openwisp2/settings_migrazione.py"
FERMI=0
ansible-playbook playbook.yml -e ninux_postgresql=true
# gli handler del ruolo riavviano solo alcuni programmi supervisor
$SSH "systemctl start cron freeradius; supervisorctl start all; sleep 5; supervisorctl status; systemctl is-active freeradius postgresql
  grep -A3 '^DATABASES' $OWDIR/openwisp2/settings.py"

passo "fatto: ora mettere ninux_postgresql: true in playbook.yml"
