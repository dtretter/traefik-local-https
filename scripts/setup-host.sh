#!/usr/bin/env bash
# Richtet die Host-Seite der lokalen Dev-DNS-Umgebung ein (oder entfernt sie):
#
#   1. systemd-resolved: *.<domain> -> host-dns (127.0.0.1:5354)
#      Datei: /etc/systemd/resolved.conf.d/local-dev-dns.conf
#   2. Docker: "dns": [<HOST_GATEWAY_IP>] in /etc/docker/daemon.json,
#      damit alle Container container-dns nutzen.
#
# Aus .env werden ausschliesslich DEV_HTTPS_DOMAIN und HOST_GATEWAY_IP
# gelesen (per grep, die Datei wird nicht ausgefuehrt). Alternativ beide Werte
# per --domain / --gateway uebergeben.
#
# Jede Aenderung wird vorher angezeigt und muss bestaetigt werden
# (ausser mit --yes). Benoetigt sudo, fuer Schritt 2 ausserdem jq.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"
RESOLVED_DROPIN="/etc/systemd/resolved.conf.d/local-dev-dns.conf"
DAEMON_JSON="/etc/docker/daemon.json"
HOST_DNS_ADDR="127.0.0.1:5354"

DOMAIN=""
GATEWAY=""
DRY_RUN=0
ASSUME_YES=0
DO_RESOLVED=1
DO_DOCKER=1
UNINSTALL=0

usage() {
  cat <<EOF
Verwendung: $(basename "$0") [Optionen]

  --domain DOMAIN    Dev-Domain (Standard: DEV_HTTPS_DOMAIN aus .env)
  --gateway IP       docker0-Adresse (Standard: HOST_GATEWAY_IP aus .env)
  --env-file DATEI   Andere .env verwenden (Standard: ${ENV_FILE})
  --skip-resolved    systemd-resolved nicht anfassen
  --skip-docker      /etc/docker/daemon.json nicht anfassen
  --uninstall        Einstellungen wieder entfernen
  --dry-run          Nur anzeigen, nichts aendern
  --yes              Keine Rueckfragen
  -h, --help         Diese Hilfe
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)        DOMAIN="${2:?--domain braucht einen Wert}"; shift 2 ;;
    --gateway)       GATEWAY="${2:?--gateway braucht einen Wert}"; shift 2 ;;
    --env-file)      ENV_FILE="${2:?--env-file braucht einen Wert}"; shift 2 ;;
    --skip-resolved) DO_RESOLVED=0; shift ;;
    --skip-docker)   DO_DOCKER=0; shift ;;
    --uninstall)     UNINSTALL=1; shift ;;
    --dry-run)       DRY_RUN=1; shift ;;
    --yes|-y)        ASSUME_YES=1; shift ;;
    -h|--help)       usage; exit 0 ;;
    *) echo "Unbekannte Option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARNUNG:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mFEHLER:\033[0m %s\n' "$*" >&2; exit 1; }

confirm() {
  (( ASSUME_YES )) && return 0
  local answer
  read -r -p "$1 [j/N] " answer
  [[ "$answer" =~ ^([jJyY]|ja|Ja|yes)$ ]]
}

# Liest genau einen Schluessel aus der .env, ohne sie auszufuehren.
read_env_var() {
  local key="$1"
  [[ -r "$ENV_FILE" ]] || return 0
  { grep -E "^[[:space:]]*${key}=" "$ENV_FILE" || true; } | tail -n1 | cut -d= -f2- \
    | sed -E 's/[[:space:]]+#.*$//; s/^[[:space:]]+|[[:space:]]+$//g; s/^"(.*)"$/\1/; s/^'\''(.*)'\''$/\1/'
}

# Schreibt Inhalt nach Anzeige des Diffs und Bestaetigung als root.
write_root_file() {
  local target="$1" content="$2" tmp
  tmp="$(mktemp)"
  printf '%s\n' "$content" > "$tmp"
  if [[ -f "$target" ]] && cmp -s "$tmp" "$target"; then
    info "$target ist bereits aktuell."
    rm -f "$tmp"; return 1
  fi
  echo "--- Aenderung an $target:"
  if [[ -f "$target" ]]; then diff -u "$target" "$tmp" || true; else cat "$tmp"; fi
  echo "---"
  if (( DRY_RUN )); then info "(dry-run) nicht geschrieben."; rm -f "$tmp"; return 1; fi
  if ! confirm "So nach $target schreiben?"; then
    info "Uebersprungen."; rm -f "$tmp"; return 1
  fi
  if [[ -f "$target" ]]; then
    sudo cp -a "$target" "${target}.bak.$(date +%Y%m%d%H%M%S)"
    info "Sicherung: ${target}.bak.*"
  fi
  sudo install -D -m 0644 "$tmp" "$target"
  rm -f "$tmp"
  return 0
}

# --- Werte bestimmen und pruefen -------------------------------------------

[[ -n "$DOMAIN"  ]] || DOMAIN="$(read_env_var DEV_HTTPS_DOMAIN)"
[[ -n "$GATEWAY" ]] || GATEWAY="$(read_env_var HOST_GATEWAY_IP)"
[[ -n "$GATEWAY" ]] || GATEWAY="172.17.0.1"

if (( ! UNINSTALL )); then
  [[ -n "$DOMAIN" ]] || die "Keine Domain: DEV_HTTPS_DOMAIN in .env setzen oder --domain angeben."
  [[ "$DOMAIN" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]] \
    || die "Ungueltige Domain: '$DOMAIN' (nur Kleinbuchstaben, z.B. dev.example.com)"
fi
[[ "$GATEWAY" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "Ungueltige IPv4-Adresse: '$GATEWAY'"

info "Domain:  ${DOMAIN:-(nicht benoetigt)}"
info "Gateway: $GATEWAY"
(( DRY_RUN )) && info "Modus:   dry-run (es wird nichts geaendert)"

# --- Voraussetzungen -------------------------------------------------------

if (( ! UNINSTALL )); then
  if ! systemctl is-active --quiet systemd-resolved; then
    die "systemd-resolved laeuft nicht - diese Einrichtung setzt ihn voraus (siehe README)."
  fi
  if [[ "$(readlink -f /etc/resolv.conf)" != */systemd/resolve/stub-resolv.conf ]]; then
    warn "/etc/resolv.conf zeigt nicht auf den systemd-resolved-Stub ($(readlink -f /etc/resolv.conf))."
    warn "Programme, die resolv.conf direkt lesen, sehen die Dev-Domain dann nicht."
  fi
  docker0_ip="$(ip -4 -o addr show docker0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
  if [[ -z "$docker0_ip" ]]; then
    warn "Interface docker0 nicht gefunden - laeuft Docker Engine (nicht Docker Desktop)?"
  elif [[ "$docker0_ip" != "$GATEWAY" ]]; then
    warn "docker0 hat die Adresse $docker0_ip, HOST_GATEWAY_IP ist $GATEWAY."
    warn "HOST_GATEWAY_IP in .env auf $docker0_ip setzen (ausser du weisst genau, was du tust)."
    confirm "Trotzdem mit $GATEWAY fortfahren?" || exit 1
  fi
  if systemctl is-active --quiet dnsmasq 2>/dev/null; then
    warn "Der Host-Dienst 'dnsmasq' laeuft. Er kann Port 5354/53 belegen und mit host-dns/container-dns kollidieren."
  fi
fi

# --- 1. systemd-resolved ---------------------------------------------------

if (( DO_RESOLVED )); then
  info "Schritt 1: systemd-resolved"
  if (( UNINSTALL )); then
    if [[ -f "$RESOLVED_DROPIN" ]]; then
      echo "Entferne $RESOLVED_DROPIN"
      if (( ! DRY_RUN )) && confirm "Datei loeschen und systemd-resolved neu starten?"; then
        sudo rm -f "$RESOLVED_DROPIN"
        sudo systemctl restart systemd-resolved
        info "Entfernt."
      fi
    else
      info "$RESOLVED_DROPIN existiert nicht."
    fi
  else
    dropin_content="# Von scripts/setup-host.sh erzeugt (local-dev-dns).
# *.${DOMAIN} an host-dns (dnsmasq im Container) weiterleiten.
[Resolve]
DNS=${HOST_DNS_ADDR}
Domains=~${DOMAIN}"
    if write_root_file "$RESOLVED_DROPIN" "$dropin_content"; then
      sudo systemctl restart systemd-resolved
      info "systemd-resolved neu gestartet."
    fi
  fi
fi

# --- 2. Docker daemon.json -------------------------------------------------

if (( DO_DOCKER )); then
  info "Schritt 2: Docker-DNS ($DAEMON_JSON)"
  command -v jq >/dev/null || die "jq fehlt (z.B. 'sudo apt install jq') - oder --skip-docker und manuell eintragen."

  current="{}"
  if [[ -f "$DAEMON_JSON" ]]; then
    if [[ -r "$DAEMON_JSON" ]]; then current="$(cat "$DAEMON_JSON")"; else current="$(sudo cat "$DAEMON_JSON")"; fi
    [[ -n "${current//[[:space:]]/}" ]] || current="{}"
    jq -e . >/dev/null 2>&1 <<<"$current" || die "$DAEMON_JSON ist kein gueltiges JSON - bitte zuerst reparieren."
  fi

  if (( UNINSTALL )); then
    new="$(jq --arg ip "$GATEWAY" '
      if (.dns // []) == [$ip] then del(.dns)
      elif has("dns") then .dns |= map(select(. != $ip))
      else . end' <<<"$current")"
  else
    existing_dns="$(jq -c '.dns // empty' <<<"$current")"
    if [[ -n "$existing_dns" && "$existing_dns" != "[\"$GATEWAY\"]" ]]; then
      warn "In $DAEMON_JSON ist bereits \"dns\": $existing_dns gesetzt - wird ersetzt durch [\"$GATEWAY\"]."
    fi
    new="$(jq --arg ip "$GATEWAY" '.dns = [$ip]' <<<"$current")"
  fi

  if [[ "$(jq -S . <<<"$current")" == "$(jq -S . <<<"$new")" ]]; then
    info "$DAEMON_JSON ist bereits aktuell."
  elif write_root_file "$DAEMON_JSON" "$new"; then
    warn "Ein Neustart von Docker startet alle laufenden Container neu."
    if confirm "Docker jetzt neu starten?"; then
      sudo systemctl restart docker
      info "Docker neu gestartet."
    else
      info "Wirksam erst nach: sudo systemctl restart docker"
    fi
  fi
fi

# --- Abschluss -------------------------------------------------------------

echo
if (( UNINSTALL )); then
  info "Fertig. Container stoppen mit: docker compose down (im Projektverzeichnis)"
else
  info "Fertig. Naechste Schritte:"
  echo "    docker compose up -d --build"
  echo "    resolvectl query test.${DOMAIN}        # erwartet: 127.0.0.1"
  echo "    docker run --rm alpine nslookup test.${DOMAIN}   # erwartet: ${GATEWAY}"
fi
