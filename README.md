# Lokale HTTPS-Entwicklungsumgebung mit Traefik und Wildcard-DNS

Lokale Dev-Dienste unter einer eigenen Domain mit **echtem, gültigem
Wildcard-Zertifikat** von Let's Encrypt – erreichbar

- **vom Browser auf dem Host**: `https://myapp.dev.example.com`
- **aus anderen Docker-Containern** (z.B. Devcontainern) unter **demselben
  Namen**: `https://myapp.dev.example.com`

Ohne `/etc/hosts`-Pflege, ohne selbstsignierte Zertifikate, ohne
`host.docker.internal`-Sonderfälle und ohne `dns:`-Eintrag in jedem
Compose-File. Ein neuer Dienst braucht nur ein paar Traefik-Labels.

> **Plattform:** Linux mit Docker Engine und systemd-resolved (z.B. Ubuntu,
> Debian, Fedora, Arch mit resolved). Docker Desktop (macOS/Windows) wird
> nicht unterstützt.

---

## Inhalt

1. [Wie es funktioniert](#wie-es-funktioniert)
2. [Voraussetzungen](#voraussetzungen)
3. [Einrichtung Schritt für Schritt](#einrichtung-schritt-für-schritt)
4. [Eigene Dienste anbinden](#eigene-dienste-anbinden)
5. [Sicherheit](#sicherheit)
6. [Fehlersuche](#fehlersuche)
7. [Deinstallation](#deinstallation)
8. [Dateien im Repository](#dateien-im-repository)
9. [Lizenz](#lizenz)

---

## Wie es funktioniert

Derselbe Name muss je nach Fragesteller auf eine **andere Adresse** zeigen:
Für den Browser ist Traefik unter `127.0.0.1` erreichbar, für Container
unter der Adresse der Docker-Bridge (`docker0`, Standard `172.17.0.1`) –
`127.0.0.1` wäre im Container der Container selbst.

Deshalb gibt es zwei kleine dnsmasq-Instanzen (beide als Container im
Host-Netz) und zwei Traefik-Entrypoints:

```
 Browser (Host)                                 Container (beliebiges Docker-Netz)
      │ myapp.dev.example.com?                        │ myapp.dev.example.com?
      ▼                                               ▼
 systemd-resolved (127.0.0.53)                  Docker-DNS (127.0.0.11)
      │ Routing-Domain ~dev.example.com               │ "dns" aus /etc/docker/daemon.json
      ▼                                               ▼
 host-dns  127.0.0.1:5354                       container-dns  172.17.0.1:53
      │ → 127.0.0.1                                   │ → 172.17.0.1
      │                                               │ (andere Namen → systemd-resolved)
      ▼                                               ▼
 Traefik "websecure"  127.0.0.1:443             Traefik "devsecure"  172.17.0.1:443
   alle Router (Default), Dashboard               nur Router, die das per Label wollen
      └──────────────────────┬────────────────────────┘
                             ▼
                  Dienst-Container (Bridge-IP)
```

| Komponente | Lauscht auf | Antwort für `*.<domain>` | Zweck |
|---|---|---|---|
| `host-dns` | `127.0.0.1:5354` | `127.0.0.1` | Namensauflösung für den Host |
| `container-dns` | `<HOST_GATEWAY_IP>:53` | `<HOST_GATEWAY_IP>` | Namensauflösung für Container |
| Traefik `websecure` | `127.0.0.1:443` | – | HTTPS für den Browser (Default-Entrypoint) |
| Traefik `devsecure` | `<HOST_GATEWAY_IP>:443` | – | HTTPS für Container (nur freigegebene Dienste) |
| Traefik `web` / `devweb` | `:80` auf denselben Adressen | – | Weiterleitung HTTP → HTTPS |

Das **Zertifikat** holt Traefik per **DNS-01-Challenge** über die API deines
DNS-Providers. Dafür muss nichts aus dem Internet erreichbar sein, und es
werden **keine öffentlichen A-Records** für die Dev-Domain benötigt.

Auf dem Host selbst wird nur zweierlei konfiguriert (per Skript):

- ein Drop-in für systemd-resolved, der `*.<domain>` an `host-dns` leitet,
- der Eintrag `"dns": ["<HOST_GATEWAY_IP>"]` in `/etc/docker/daemon.json`.

---

## Voraussetzungen

- **Linux** mit **Docker Engine** und **Docker Compose v2.17+**
  (`docker compose version`)
- **systemd-resolved** im Stub-Modus – prüfen:
  ```bash
  systemctl is-active systemd-resolved
  ```
  ```bash
  readlink -f /etc/resolv.conf
  ```
  Erwartet: `active` und `/run/systemd/resolve/stub-resolv.conf`.
- **Eine eigene Domain** (oder Subdomain, z.B. `dev.example.com`), deren
  DNS-Zone bei einem Provider liegt, den Traefik für die DNS-Challenge
  unterstützt (Hetzner, Cloudflare, INWX, Route53, … – siehe
  [Provider-Liste](https://doc.traefik.io/traefik/https/acme/#providers)),
  und ein **API-Token** dafür. Empfehlung: Token nur mit Rechten auf diese
  eine Zone.
- **`jq`** für das Setup-Skript (`sudo apt install jq`)
- **Freie Ports**:
  `127.0.0.1:80`, `127.0.0.1:443`, `127.0.0.1:5354`,
  `<HOST_GATEWAY_IP>:53`, `<HOST_GATEWAY_IP>:80`, `<HOST_GATEWAY_IP>:443`.
  Prüfen mit:
  ```bash
  sudo ss -tulpn | grep -E ':(80|443|53|5354)\s'
  ```
  Ein lokal installierter Webserver (Apache, nginx) oder ein Host-`dnsmasq`
  muss ggf. gestoppt bzw. umkonfiguriert werden.

---

## Einrichtung Schritt für Schritt

### 1. Repository klonen

Der Ort ist beliebig, z.B.:

```bash
git clone https://github.com/<user>/<repo>.git ~/local-dev-traefik
```
```bash
cd ~/local-dev-traefik
```

### 2. Adresse der Docker-Bridge ermitteln

```bash
ip -4 -br addr show docker0
```

Die Adresse vor dem `/` (z.B. `172.17.0.1`) ist `HOST_GATEWAY_IP`. Dass
`docker0` als `DOWN` angezeigt wird, ist normal, solange kein Container im
Default-Bridge-Netz läuft – die Adresse ist trotzdem nutzbar.

### 3. `.env` anlegen

```bash
cp .env.example .env && chmod 600 .env
```

Dann `.env` bearbeiten:

| Variable | Beispiel | Bedeutung |
|---|---|---|
| `DEV_HTTPS_DOMAIN` | `dev.example.com` | Basis-Domain, alle `*.dev.example.com` werden lokal aufgelöst |
| `HOST_GATEWAY_IP` | `172.17.0.1` | Adresse aus Schritt 2 |
| `ACME_EMAIL` | `admin@example.com` | Kontaktadresse für Let's Encrypt |
| `ACME_DNS_PROVIDER` | `hetzner` | Provider-Kürzel laut [Traefik-Doku](https://doc.traefik.io/traefik/https/acme/#providers) |
| *Provider-Zugangsdaten* | `HETZNER_API_TOKEN=…` | Variablennamen je nach Provider (siehe Doku-Link) |
| `HOST_DNS_UPSTREAM` | *(optional)* | Upstream für Nicht-Dev-Namen in Containern, Standard `127.0.0.53` |

> `.env` enthält Zugangsdaten und ist per `.gitignore` vom Repository
> ausgeschlossen. Niemals einchecken, niemals in Issues/Logs posten.

### 4. Host konfigurieren

Das Skript zeigt jede Änderung als Diff an, legt Sicherungen an und fragt vor
jedem Schritt nach. Aus `.env` liest es nur `DEV_HTTPS_DOMAIN` und
`HOST_GATEWAY_IP`.

Erst ansehen, was passieren würde:

```bash
./scripts/setup-host.sh --dry-run
```

Dann ausführen:

```bash
./scripts/setup-host.sh
```

Es richtet ein:

1. `/etc/systemd/resolved.conf.d/local-dev-dns.conf`:
   ```ini
   [Resolve]
   DNS=127.0.0.1:5354
   Domains=~dev.example.com
   ```
   und startet systemd-resolved neu.
2. `"dns": ["172.17.0.1"]` in `/etc/docker/daemon.json` (vorhandene
   Einstellungen bleiben erhalten) und – nach Rückfrage – startet Docker neu.
   **Achtung:** Dabei werden alle laufenden Container neu gestartet.

<details>
<summary>Manuell statt per Skript</summary>

```bash
sudo mkdir -p /etc/systemd/resolved.conf.d
```
```bash
printf '[Resolve]\nDNS=127.0.0.1:5354\nDomains=~dev.example.com\n' | sudo tee /etc/systemd/resolved.conf.d/local-dev-dns.conf
```
```bash
sudo systemctl restart systemd-resolved
```

`/etc/docker/daemon.json` um `"dns": ["172.17.0.1"]` ergänzen (Datei ggf.
neu anlegen, gültiges JSON beachten), z.B.:

```json
{
  "dns": ["172.17.0.1"]
}
```

```bash
sudo systemctl restart docker
```
</details>

### 5. Starten

```bash
docker compose up -d --build
```

Beim ersten Start fordert Traefik das Wildcard-Zertifikat an. Das dauert
durch die DNS-Propagation etwa 1–2 Minuten:

```bash
docker logs -f traefik
```

Fehlerfrei ist es, wenn keine `Unable to obtain ACME certificate`-Meldungen
erscheinen. Das Zertifikat landet in `letsencrypt/acme.json` und wird
automatisch erneuert.

### 6. Testen

**Host:**

```bash
resolvectl query test.dev.example.com
```

Erwartet: `127.0.0.1`. Das Dashboard ist dann unter
`https://traefik.dev.example.com` erreichbar.

**Beispiel-Dienst starten** (aus `examples/whoami`):

```bash
cd examples/whoami && docker compose --env-file ../../.env up -d && cd ../..
```
```bash
curl https://whoami.dev.example.com
```

**Aus einem Container:**

```bash
docker run --rm curlimages/curl -sS https://whoami.dev.example.com
```

Beide `curl`-Aufrufe sollten die Antwort von whoami liefern (Hostname, IPs) –
ohne Zertifikatsfehler.

---

## Eigene Dienste anbinden

Der Dienst muss **kein** gemeinsames Netz mit Traefik haben und braucht
**keine** Port-Freigabe (`ports:`). Traefik läuft im Host-Netz und erreicht
jeden Container über dessen Bridge-IP. Es genügen Labels:

```yaml
services:
  myapp:
    image: my/app
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.myapp.rule=Host(`myapp.${DEV_HTTPS_DOMAIN}`)"
      - "traefik.http.routers.myapp.tls=true"
      - "traefik.http.routers.myapp.tls.certresolver=letsencrypt"
      # Nur Browser:          Zeile weglassen (websecure ist Default)
      # Browser + Container:  beide Entrypoints
      - "traefik.http.routers.myapp.entrypoints=websecure,devsecure"
      # Port, auf dem die App IM Container lauscht
      - "traefik.http.services.myapp.loadbalancer.server.port=3000"
```

`${DEV_HTTPS_DOMAIN}` wird von Compose aus der `.env` **des jeweiligen
Projekts** ersetzt – entweder dort eintragen oder den Namen fest
hinschreiben, oder mit `--env-file` auf die `.env` dieses Repos zeigen.

| Wer soll zugreifen? | `entrypoints`-Label |
|---|---|
| Nur Browser auf dem Host | weglassen oder `websecure` |
| Browser und Container | `websecure,devsecure` |
| Nur Container | `devsecure` |

Router ohne `entrypoints`-Label hängen nur an `websecure` – Dienste sind aus
Containern also nur erreichbar, wenn du das ausdrücklich willst.

**Devcontainer** brauchen nichts Besonderes: Durch den Eintrag in
`daemon.json` lösen alle Container `*.<domain>` automatisch auf. Ein eigenes
`dns:` im Compose-File ist nicht nötig (und würde den globalen Eintrag
überschreiben).

---

## Sicherheit

- **Nichts ist von außen erreichbar.** Alle Entrypoints und DNS-Server
  binden an `127.0.0.1` bzw. die `docker0`-Adresse, nicht an LAN/WLAN.
- **Dashboard** nur über `websecure`, also nur vom Host. Es hat keine
  Authentifizierung – auf Mehrbenutzersystemen ggf. eine
  [BasicAuth-Middleware](https://doc.traefik.io/traefik/middlewares/http/basicauth/)
  ergänzen.
- **Docker-Socket:** `:ro` schützt nur die Socket-Datei, nicht die API.
  Traefik hat damit faktisch Root-Rechte auf dem Host. Für eine lokale
  Entwicklungsumgebung üblich; strenger wäre ein Socket-Proxy wie
  [tecnativa/docker-socket-proxy](https://github.com/Tecnativa/docker-socket-proxy).
- **`.env`** (API-Token) und **`letsencrypt/acme.json`** (private Schlüssel)
  sind per `.gitignore` ausgeschlossen und sollten Rechte `600` haben.
- **API-Token** nach Möglichkeit auf die eine DNS-Zone beschränken.
- Die Dev-Domain erscheint – wie jede Let's-Encrypt-Domain – in den
  öffentlichen [Certificate-Transparency-Logs](https://crt.sh). Durch das
  Wildcard-Zertifikat werden dort aber keine einzelnen Dienstnamen sichtbar.

---

## Fehlersuche

**Host löst die Domain nicht auf**

```bash
resolvectl status | head -8
```

Unter `Global` muss `DNS Servers: 127.0.0.1:5354` und
`DNS Domain: ~<domain>` stehen. Sonst Drop-in prüfen und
`sudo systemctl restart systemd-resolved`. Läuft `host-dns`?

```bash
docker logs host-dns
```

Direkt testen:

```bash
dig @127.0.0.1 -p 5354 test.dev.example.com +short
```

**Container lösen die Domain nicht auf / bekommen `127.0.0.1`**

- `/etc/docker/daemon.json` prüfen – `"dns"` muss gesetzt und Docker danach
  neu gestartet worden sein. Test: `docker run --rm alpine cat /etc/resolv.conf`
  (im Default-Netz muss dort `nameserver <HOST_GATEWAY_IP>` stehen).
- Container mit eigenem `dns:` im Compose-File ignorieren den globalen
  Eintrag.
- Läuft `container-dns`? `docker logs container-dns`
- Direkt testen: `dig @172.17.0.1 test.dev.example.com +short`

**Container erreichen `<HOST_GATEWAY_IP>` nicht (Timeout)**

Eine Host-Firewall (ufw, firewalld) kann Verbindungen aus Docker-Netzen zum
Host blockieren. Beispiel für ufw (Netz an eigene Docker-Adresspools
anpassen):

```bash
sudo ufw allow from 172.16.0.0/12 to 172.17.0.1 port 53
```
```bash
sudo ufw allow from 172.16.0.0/12 to 172.17.0.1 port 80,443 proto tcp
```

**`address already in use` beim Start**

Ein anderer Dienst belegt einen der Ports (siehe
[Voraussetzungen](#voraussetzungen)). Häufig: ein Host-`dnsmasq`
(`sudo systemctl disable --now dnsmasq`) oder ein lokaler Webserver.

**Zertifikat wird nicht ausgestellt**

```bash
docker logs traefik 2>&1 | grep -i acme
```

Typische Ursachen: falscher `ACME_DNS_PROVIDER`, falsche Variablennamen für
die Zugangsdaten, Token ohne Schreibrechte auf die Zone, Zone nicht beim
angegebenen Provider. Let's Encrypt hat
[Rate-Limits](https://letsencrypt.org/docs/rate-limits/) – beim
Experimentieren `acme.json` nicht ständig löschen.

**Image `local-dev-dnsmasq` lässt sich nicht bauen**

Der Build nutzt bewusst das Host-Netz (`build.network: host`), damit er auch
funktioniert, solange `container-dns` nicht läuft. Prüfen, ob der Host selbst
Internet/DNS hat.

**IP-Konflikte mit VPN oder Firmennetz**

Überschneidet sich `172.17.0.0/16` mit einem anderen Netz, Docker in
`daemon.json` andere Adressen geben (`"bip"` bzw. `"default-address-pools"`),
Docker neu starten und `HOST_GATEWAY_IP` in `.env` anpassen. Danach
`./scripts/setup-host.sh` erneut ausführen.

---

## Deinstallation

```bash
docker compose down
```
```bash
./scripts/setup-host.sh --uninstall
```

Das entfernt den resolved-Drop-in und den `"dns"`-Eintrag aus
`daemon.json` (mit Rückfrage und Sicherung). Optional danach das Image
entfernen:

```bash
docker image rm local-dev-dnsmasq:local
```

---

## Dateien im Repository

| Datei | Inhalt |
|---|---|
| `docker-compose.yml` | Traefik, `host-dns`, `container-dns` |
| `.env.example` | Vorlage für `.env` (Domain, Gateway, ACME, Provider) |
| `scripts/setup-host.sh` | Host-Konfiguration einrichten/entfernen |
| `examples/whoami/` | Beispiel-Dienst mit Labels für beide Entrypoints |
| `letsencrypt/` | Ablage für `acme.json` (Inhalt nicht im Repository) |
| `LICENSE` | MIT-Lizenz |

---

## Lizenz

[MIT](LICENSE) – Nutzung auf eigene Verantwortung. Das Setup-Skript ändert
Systemdateien; vorher mit `--dry-run` prüfen.
