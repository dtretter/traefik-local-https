#!/bin/bash
# Sammelt auf dem HOST die DNS- und Netzkonfiguration, damit im Devcontainer
# nachvollzogen werden kann, warum VPN-Namen (z. B. git.tripledigital.de) in
# Containern nicht aufloesen. Nur lesend, aendert nichts. Schreibt keine
# Schluessel/Tokens: VPN-Konfigurationsdateien und Container-Umgebungen werden
# bewusst NICHT ausgelesen.
#
# Ergebnis: .host-diag/dns-<Zeitstempel>.txt im Workspace (gitignored).
# Vor dem Weitergeben kurz durchsehen.
#
# Aufruf (Host, VPN aktiv): scripts/host-dns-diagnose.sh [weitere VPN-Namen ...]
# Mit sudo davor werden zusaetzlich die Prozesse an Port 53 und die
# Host-Firewall angezeigt; ohne sudo fehlen nur diese Teile.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
outdir="$root/.host-diag"
mkdir -p "$outdir"
out="$outdir/dns-$(date +%Y%m%d-%H%M%S).txt"
names=("git.tripledigital.de" "tripledigital.de" "github.com" "$@")

section() { printf '\n===== %s =====\n' "$1"; }
run() {
    printf '\n$ %s\n' "$*"
    if command -v "$1" >/dev/null 2>&1 || [ "$1" = "sudo" ]; then
        "$@" 2>&1
    else
        echo "(nicht installiert)"
    fi
}

{
    section "Allgemein"
    date -Is
    uname -a
    run docker version --format 'Docker {{.Server.Version}}'

    section "Docker-Daemon"
    run cat /etc/docker/daemon.json

    section "Resolver des Hosts"
    run ls -l /etc/resolv.conf
    run cat /etc/resolv.conf
    run cat /run/systemd/resolve/resolv.conf
    run cat /etc/systemd/resolved.conf
    for f in /etc/systemd/resolved.conf.d/*.conf; do [ -e "$f" ] && run cat "$f"; done
    run resolvectl status
    run cat /etc/NetworkManager/NetworkManager.conf
    for f in /etc/NetworkManager/conf.d/*.conf /etc/NetworkManager/dnsmasq.d/*; do [ -e "$f" ] && run cat "$f"; done
    for f in /etc/dnsmasq.conf /etc/dnsmasq.d/*; do [ -e "$f" ] && run grep -v -E '^\s*(#|$)' "$f"; done

    section "Aufloesung auf dem Host"
    for n in "${names[@]}"; do
        run getent ahosts "$n"
        command -v resolvectl >/dev/null 2>&1 && run resolvectl query "$n"
    done

    section "Netz-Interfaces und Routen"
    run ip -brief addr
    run ip route
    run ip rule
    run nmcli -t -f NAME,TYPE,DEVICE connection show --active
    run nmcli -f IP4.DNS,IP4.DOMAIN,GENERAL.DEVICE device show

    section "Wer lauscht auf Port 53"
    if [ "$(id -u)" -eq 0 ]; then
        run ss -lntup 'sport = :53'
    else
        run ss -lntu 'sport = :53'
        echo "(ohne sudo keine Prozessnamen)"
    fi

    section "Docker-Netze und Container"
    run docker network ls
    for net in $(docker network ls -q 2>/dev/null); do
        docker network inspect "$net" --format \
            '{{.Name}}  driver={{.Driver}}  {{range .IPAM.Config}}subnet={{.Subnet}} gw={{.Gateway}} {{end}}' 2>&1
    done
    run docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Ports}}\t{{.Networks}}'
    echo
    echo "# Container mit Port 53 oder DNS-/Traefik-Bezug (ohne Umgebungsvariablen):"
    for c in $(docker ps -q 2>/dev/null); do
        info="$(docker inspect "$c" --format \
            '{{.Name}} image={{.Config.Image}} netmode={{.HostConfig.NetworkMode}} cmd={{json .Config.Cmd}} ports={{json .HostConfig.PortBindings}} mounts={{range .Mounts}}{{.Source}}->{{.Destination}} {{end}}' 2>/dev/null)"
        if printf '%s' "$info" | grep -q -i -E '53/|dns|traefik|coredns|dnsmasq|unbound|pihole|adguard'; then
            echo "$info"
        fi
    done

    section "Host-Firewall (nur mit sudo)"
    if [ "$(id -u)" -eq 0 ]; then
        run ufw status verbose
        run iptables -S INPUT
        run iptables -S DOCKER-USER
        run nft list ruleset
    else
        echo "(uebersprungen, ohne sudo)"
    fi
} >"$out" 2>&1

echo "Geschrieben: $out"
echo "Bitte kurz durchsehen, dann im Devcontainer Bescheid geben."
