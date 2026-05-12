# cpuGovernor Releases

Dieses Repository enthaelt oeffentliche Release-Pakete fuer cpuGovernor.

## Schnellstart

Stable installieren oder aktualisieren:

```bash
curl -fsSL https://raw.githubusercontent.com/ehive-dev/cpuGovernor_releases/main/install.sh | sudo bash
```

Pre-Release installieren:

```bash
curl -fsSL https://raw.githubusercontent.com/ehive-dev/cpuGovernor_releases/main/install.sh | sudo bash -s -- --pre
```

Bestimmte Version installieren:

```bash
curl -fsSL https://raw.githubusercontent.com/ehive-dev/cpuGovernor_releases/main/install.sh | sudo bash -s -- --tag v0.1.0
```

## Service

```bash
systemctl status cpuGovernor --no-pager
journalctl -u cpuGovernor -f
```

## Lizenz

Die Nutzung ist fuer private und nicht-kommerzielle Zwecke erlaubt. Kommerzielle Nutzung benoetigt eine vorherige schriftliche Zustimmung von ehive. Siehe `LICENSE.txt` und `THIRD_PARTY_NOTICES.txt`.
