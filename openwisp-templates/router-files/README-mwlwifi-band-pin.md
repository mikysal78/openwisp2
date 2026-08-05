# mwlwifi-band-pin — fix banda non-deterministica WRT3200ACM (mvebu/mwlwifi)

Sul Linksys WRT3200ACM le due radio 88W8964 (mwlwifi) ricevono la banda in modo
**non deterministico** tra un boot e l'altro: lo stesso PCI-path a volte sale
2.4GHz, a volte 5GHz. `radio0` (hotspot+mesh 2.4GHz) è pinnata per path, quindi se
quel path questo boot è 5GHz → il setup fallisce (`band.ht_capa` null, ucode
mac80211.sh) e la radio resta giù (niente hotspot né mesh).

## Fix
- `mwlwifi-band-pin` (→ `/usr/sbin/`): trova il phy mwlwifi che espone la 2.4GHz
  (`iw phy ... | grep 2412.0 MHz`) e ci pinna `wireless.radio0.path`; `wifi reload`
  solo se cambia.
- `mwlwifi-band-pin.init` (→ `/etc/init.d/mwlwifi-band-pin`, `enable`): lo lancia 20s
  dopo il boot.

## Install
    scp mwlwifi-band-pin      root@ROUTER:/usr/sbin/        # chmod +x
    scp mwlwifi-band-pin.init root@ROUTER:/etc/init.d/mwlwifi-band-pin  # chmod +x
    ssh root@ROUTER /etc/init.d/mwlwifi-band-pin enable

Nota: OpenWISP NON gestisce `radio0.path` per questo device (0 radios nel config),
quindi la modifica live non viene sovrascritta al check-in.
