# Settings temporanei per caricare i dati su PostgreSQL mentre i servizi sono
# fermi e settings.py punta ancora a SQLite: broker in memoria senza worker
# (nessun task parte), cache e channel layer in memoria. Lo script lo cancella
# alla fine.
import os

from .settings import *  # noqa

DATABASES = {
    "default": {
        "ENGINE": "django.contrib.gis.db.backends.postgis",
        "NAME": "openwisp2",
        "USER": "openwisp2",
        "PASSWORD": os.environ["PGPASSWORD"],
        "HOST": "localhost",
        "PORT": "5432",
    }
}
CELERY_BROKER_URL = "memory://"
CELERY_TASK_ALWAYS_EAGER = False
CACHES = {
    "default": {"BACKEND": "django.core.cache.backends.locmem.LocMemCache"},
    "sessions": {"BACKEND": "django.core.cache.backends.locmem.LocMemCache"},
}
CHANNEL_LAYERS = {"default": {"BACKEND": "channels.layers.InMemoryChannelLayer"}}
EMAIL_BACKEND = "django.core.mail.backends.locmem.EmailBackend"
