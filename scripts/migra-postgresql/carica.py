# loaddata con i segnali dei modelli spenti: alcuni handler di OpenWISP non
# controllano raw=True e durante l'import cercherebbero oggetti non ancora
# caricati (o chiamerebbero servizi esterni, es. il controller ZeroTier).
import os

from django.core.management import call_command
from django.db.models import signals
from django.dispatch import Signal

SPENTI = {
    signals.pre_save, signals.post_save, signals.pre_delete,
    signals.post_delete, signals.m2m_changed, signals.pre_init, signals.post_init,
}
_send, _send_robust = Signal.send, Signal.send_robust
Signal.send = lambda self, sender, **kw: [] if self in SPENTI else _send(self, sender, **kw)
Signal.send_robust = lambda self, sender, **kw: [] if self in SPENTI else _send_robust(self, sender, **kw)
try:
    call_command("loaddata", os.environ["DUMP"], verbosity=1)
finally:
    Signal.send, Signal.send_robust = _send, _send_robust
