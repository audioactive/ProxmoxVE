#!/usr/bin/env bash

# Proxmox VE Cluster Erstellungs-/Join-Skript
# Copyright (c) 2025
# License: MIT (wie übrige Repo-Skripte)
# Zweck:
#   Halb-/vollautomatische Erstellung eines 3-Node Proxmox VE Clusters
#   mit den bereitgestellten Servern:
#     netcup.acidhosting.de 152.53.108.232
#     strato.acidhosting.de 217.160.15.117
#     hetzner.acidhosting.de 65.21.192.102
#
# Nutzungsszenarien:
#   1. Auf dem primären Node (z.B. netcup) ausführen -> Cluster anlegen.
#   2. Vom primären Node aus die übrigen Nodes automatisch joinen lassen (per SSH).
#   3. Alternativ auf einem Sekundärknoten ausführen -> nur "Join" Aktion wählen.
#
# Voraussetzungen:
#   - Ausführung als root.
#   - Proxmox VE 8.x.
#   - Funktionierende Namensauflösung / Einträge werden bei Bedarf in /etc/hosts ergänzt.
#   - Passwortlose root-SSH (oder SSH-Agent) vom primären Node zu den anderen Nodes, falls automatische Join-Prozedur gewünscht.
#   - Zeit möglichst via NTP synchron (timedatectl status).
#   - Firewall/Netz offen für Corosync (UDP 5405) sowie SSH usw.
#
# Sicherheit / WAN-Hinweis:
#   Ein geo-verteilter 3-Node Cluster (verschiedene Provider) kann höhere Latenz und Packet-Loss haben.
#   Die Standard-Corosync-Timeouts können deshalb angepasst werden (token/consensus). Dieses Skript bietet optional
#   ein Tuning für WAN (>10ms RTT). Bitte vor Produktivbetrieb testen.
#
# Beispiele:
#   Cluster neu erstellen (auf primärem Node):
#     bash cluster-create.sh --mode create --cluster-name acidcluster
#   Remote Join der beiden anderen Nodes (nach create, auf primärem Node):
#     bash cluster-create.sh --mode add-others
#   Nur lokalen Node zu bestehendem Cluster hinzufügen:
#     bash cluster-create.sh --mode join --primary-ip 152.53.108.232
#
# Interaktiv ohne Parameter starten: Skript fragt nach.
#
# Exit Codes:
#   0 Erfolg, !=0 Fehler.

set -euo pipefail
shopt -s inherit_errexit nullglob

# ------------------ Konfiguration (Defaults anpassbar) ------------------
PRIMARY_HOST_DEFAULT="netcup.acidhosting.de"
PRIMARY_IP_DEFAULT="152.53.108.232"
CLUSTER_NAME_DEFAULT="acidcluster"

# Assoziatives Array Host->IP (bash >=4)
declare -A NODE_MAP=( 
  [netcup.acidhosting.de]="152.53.108.232" 
  [strato.acidhosting.de]="217.160.15.117" 
  [hetzner.acidhosting.de]="65.21.192.102" 
)

# Corosync WAN Tuning (kann per Flag aktiviert werden)
WAN_TOKEN_MS=5000      # Standard 1000
WAN_CONSENSUS_MS=15000 # Standard 2000
WAN_JOIN_MS=60000
WAN_HOLD_MS=180000
WAN_MAX_MESSAGES=20

# ------------------ Farben & UI Helfer ------------------
RD=$(echo "\033[01;31m")
YW=$(echo "\033[33m")
GN=$(echo "\033[1;92m")
CL=$(echo "\033[m")
BFR="\r\033[K"
HOLD="-"
CM="${GN}✓${CL}"
CROSS="${RD}✗${CL}"

msg_info() { echo -ne " ${HOLD} ${YW}$1..."; }
msg_ok()   { echo -e  "${BFR} ${CM} ${GN}$1${CL}"; }
msg_err()  { echo -e  "${BFR} ${CROSS} ${RD}$1${CL}"; }

header() {
  clear
  cat <<'EOF'
    ____ _    ________   ____             __     ____           __        ____
   / __ \ |  / / ____/  / __ \____  _____/ /_   /  _/___  _____/ /_____ _/ / /
  / /_/ / | / / __/    / /_/ / __ \/ ___/ __/   / // __ \/ ___/ __/ __ `/ / /
 / ____/| |/ / /___   / ____/ /_/ (__  ) /_   _/ // / / (__  ) /_/ /_/ / / /
/_/     |___/_____/  /_/    \____/____/\__/  /___/_/ /_/____/\__/\__,_/_/_/

 Proxmox VE Cluster Erstellen/Joinen
EOF
}

usage() {
  cat <<EOF
Verwendung: $0 [Optionen]

Optionen:
  --mode <create|add-others|join|remove-node|leave>   Aktion (interaktiv, falls nicht angegeben)
  --cluster-name <NAME>             Clustername (Standard: ${CLUSTER_NAME_DEFAULT})
  --primary-host <HOSTNAME>         Primärer Host FQDN (Standard: ${PRIMARY_HOST_DEFAULT})
  --primary-ip <IP>                 Primäre IP (Standard: ${PRIMARY_IP_DEFAULT})
  --remove-node <NAME|FQDN>         Zu entfernender (anderer) Node bei --mode remove-node
  --wan-tune                        WAN optimierte Corosync Timeouts setzen
  --no-wan-tune                     WAN Tuning deaktivieren (Standard)
  --auto-yes                        Nicht-interaktiv (alle Rückfragen mit 'ja')
  --help                            Diese Hilfe

Beispiele:
  $0 --mode create --cluster-name acidcluster
  $0 --mode add-others
  $0 --mode join --primary-ip 152.53.108.232
  $0 --mode remove-node --remove-node strato
  $0 --mode leave
EOF
}

# ------------------ Argument Parsing ------------------
MODE=""
CLUSTER_NAME="${CLUSTER_NAME_DEFAULT}"
PRIMARY_HOST="${PRIMARY_HOST_DEFAULT}"
PRIMARY_IP="${PRIMARY_IP_DEFAULT}"
WAN_TUNE=0
AUTO_YES=0
REMOVE_NODE_NAME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="$2"; shift 2;;
    --cluster-name) CLUSTER_NAME="$2"; shift 2;;
    --primary-host) PRIMARY_HOST="$2"; shift 2;;
    --primary-ip) PRIMARY_IP="$2"; shift 2;;
    --wan-tune) WAN_TUNE=1; shift;;
    --no-wan-tune) WAN_TUNE=0; shift;;
    --auto-yes) AUTO_YES=1; shift;;
    --remove-node) REMOVE_NODE_NAME="$2"; shift 2;;
    --help|-h) usage; exit 0;;
    *) echo "Unbekannte Option: $1"; usage; exit 1;;
  esac
done

# ------------------ Preflight Checks ------------------
require_root() {
  if [[ $(id -u) -ne 0 ]]; then
    msg_err "Bitte als root ausführen"
    exit 1
  fi
}

check_pve_version() {
  if ! command -v pveversion >/dev/null 2>&1; then
    msg_err "pveversion nicht gefunden (kein Proxmox?)"
    exit 1
  fi
  if ! pveversion | grep -Eq "pve-manager/8\.[0-9]"; then
    msg_err "Proxmox VE 8.x benötigt"
    exit 1
  fi
}

is_cluster() {
  # Liefert 0 falls Node schon im Cluster ist
  if pvecm status >/dev/null 2>&1; then
    return 0
  else
    return 1
  fi
}

confirm() {
  local prompt="$1"
  if [[ $AUTO_YES -eq 1 ]]; then
    return 0
  fi
  read -r -p "$prompt [y/N]: " ans
  [[ $ans =~ ^[Yy]$ ]]
}

ensure_hosts_entries() {
  msg_info "/etc/hosts Einträge prüfen"
  local updated=0
  for host in "${!NODE_MAP[@]}"; do
    local ip="${NODE_MAP[$host]}"
    local short="${host%%.*}"
    if ! grep -Eq "^${ip}.*${host}" /etc/hosts; then
      echo "${ip} ${host} ${short}" >> /etc/hosts
      updated=1
    fi
  done
  if [[ $updated -eq 1 ]]; then
    msg_ok "/etc/hosts ergänzt"
  else
    msg_ok "/etc/hosts ok"
  fi
}

ping_nodes() {
  msg_info "Netzwerkkonnektivität prüfen"
  local failed=0
  for host in "${!NODE_MAP[@]}"; do
    local ip="${NODE_MAP[$host]}"
    if ! ping -c1 -W1 "$ip" >/dev/null 2>&1; then
      echo -e "\n  ${CROSS} ${host} (${ip}) nicht erreichbar" >&2
      failed=1
    fi
  done
  if [[ $failed -eq 1 ]]; then
    msg_err "Mindestens ein Node nicht erreichbar"
    exit 1
  fi
  msg_ok "Alle Nodes erreichbar"
}

create_cluster() {
  if is_cluster; then
    msg_err "Dieser Node ist bereits Teil eines Clusters"
    exit 1
  fi
  msg_info "Cluster '${CLUSTER_NAME}' erstellen"
  pvecm create "${CLUSTER_NAME}" >/dev/null 2>&1 || { msg_err "pvecm create fehlgeschlagen"; exit 1; }
  msg_ok "Cluster erstellt"
}

join_cluster() {
  if is_cluster; then
    msg_err "Node ist bereits in einem Cluster"
    exit 1
  fi
  msg_info "Diesem Node dem Cluster bei ${PRIMARY_IP} hinzufügen"
  pvecm add "${PRIMARY_IP}" --force 1>/tmp/pvecm_add.log 2>&1 || { msg_err "pvecm add fehlgeschlagen (siehe /tmp/pvecm_add.log)"; exit 1; }
  msg_ok "Node dem Cluster hinzugefügt"
}

remote_join_nodes() {
  msg_info "Remote Join der übrigen Nodes"
  local primary_fqdn=$(hostname -f)
  for host in "${!NODE_MAP[@]}"; do
    [[ $host == $PRIMARY_HOST ]] && continue
    local ip="${NODE_MAP[$host]}"
    echo -ne "\n  -> ${host} (${ip}) join..."
    # Prüfe ob bereits im Cluster: remote pvecm status
    if ssh -o BatchMode=yes -o ConnectTimeout=5 root@"${ip}" 'pvecm status >/dev/null 2>&1'; then
      echo -e " bereits im Cluster"; continue
    fi
    if ssh -o BatchMode=yes -o ConnectTimeout=5 root@"${ip}" "pvecm add ${PRIMARY_IP}" >/dev/null 2>&1; then
      echo -e " ok"
    else
      echo -e " FEHLER"; msg_err "Remote Join fehlgeschlagen bei ${host}"; exit 1
    fi
  done
  msg_ok "Alle Remotes verarbeitet"
}

remove_node() {
  if ! is_cluster; then
    msg_err "Dieser Node ist nicht in einem Cluster"
    exit 1
  fi
  local name="$REMOVE_NODE_NAME"
  if [[ -z $name ]]; then
    msg_err "--remove-node <Name> erforderlich"
    exit 1
  fi
  local short="${name%%.*}"
  local local_short="$(hostname -s)"
  if [[ $short == $local_short ]]; then
    msg_err "Lokalen Node nicht mit remove-node entfernen – benutze --mode leave"
    exit 1
  fi
  if ! pvecm nodes | awk 'NR>1 {print $2}' | grep -Fxq "$short"; then
    msg_err "Node ${short} nicht im Cluster"
    exit 1
  fi
  local total_nodes
  total_nodes=$(pvecm nodes | awk 'NR>1 {print $2}' | wc -l)
  if (( total_nodes <= 2 )); then
    msg_err "Entfernung würde auf <=1 Node reduzieren – abgebrochen"
    exit 1
  fi
  if ! confirm "Node ${short} entfernen? Sicherstellen, dass er heruntergefahren / leer ist."; then
    msg_err "Abgebrochen"
    exit 1
  fi
  msg_info "Entferne Node ${short}"
  if pvecm delnode "$short" >/tmp/pvecm_delnode.log 2>&1; then
    msg_ok "Node ${short} entfernt"
  else
    msg_err "Fehler beim Entfernen (siehe /tmp/pvecm_delnode.log)"
    exit 1
  fi
}

leave_cluster() {
  if ! is_cluster; then
    msg_err "Dieser Node ist nicht in einem Cluster"
    exit 1
  fi
  local short="$(hostname -s)"
  local total_nodes
  total_nodes=$(pvecm nodes | awk 'NR>1 {print $2}' | wc -l)
  if (( total_nodes <= 1 )); then
    msg_err "Dies ist der letzte Node – leave nicht sinnvoll"
    exit 1
  fi
  if ! confirm "Lokalen Node (${short}) aus Cluster entfernen? (pvecm leave)"; then
    msg_err "Abgebrochen"
    exit 1
  fi
  msg_info "Verlasse Cluster"
  if pvecm leave >/tmp/pvecm_leave.log 2>&1; then
    msg_ok "Node aus Cluster entfernt. Hinweis: /etc/pve Reste ggf. manuell säubern."
  else
    msg_err "Fehler beim Verlassen (siehe /tmp/pvecm_leave.log)"
    exit 1
  fi
}

apply_wan_tuning() {
  [[ $WAN_TUNE -eq 1 ]] || return 0
  msg_info "WAN Corosync Timeouts anwenden"
  local conf="/etc/pve/corosync.conf"
  if [[ ! -f $conf ]]; then
    msg_err "corosync.conf nicht gefunden"
    return 1
  fi
  # Falls Einträge existieren ersetzen, sonst hinzufügen.
  # Nutzen sed inline Ersetzungen; Datei in Cluster-FS -> vorsichtig, kurze Pausen.
  sed -i -r "s/^(\s*token:) .*/\1 ${WAN_TOKEN_MS}/" "$conf" || true
  sed -i -r "s/^(\s*consensus:) .*/\1 ${WAN_CONSENSUS_MS}/" "$conf" || true
  sed -i -r "s/^(\s*join:) .*/\1 ${WAN_JOIN_MS}/" "$conf" || true
  sed -i -r "s/^(\s*hold:) .*/\1 ${WAN_HOLD_MS}/" "$conf" || true
  sed -i -r "s/^(\s*max_messages:) .*/\1 ${WAN_MAX_MESSAGES}/" "$conf" || true
  # Falls Keys fehlen, am Ende von totem {} einfügen
  if ! grep -q "token:" "$conf"; then sed -i "/totem {$/a \\ttoken: ${WAN_TOKEN_MS}" "$conf"; fi
  if ! grep -q "consensus:" "$conf"; then sed -i "/totem {$/a \\tconsensus: ${WAN_CONSENSUS_MS}" "$conf"; fi
  if ! grep -q "join:" "$conf"; then sed -i "/totem {$/a \\tjoin: ${WAN_JOIN_MS}" "$conf"; fi
  if ! grep -q "hold:" "$conf"; then sed -i "/totem {$/a \\thold: ${WAN_HOLD_MS}" "$conf"; fi
  if ! grep -q "max_messages:" "$conf"; then sed -i "/totem {$/a \\tmax_messages: ${WAN_MAX_MESSAGES}" "$conf"; fi
  systemctl restart corosync >/dev/null 2>&1 || { msg_err "Corosync Restart fehlgeschlagen"; return 1; }
  sleep 2
  if corosync-quorumtool -s >/dev/null 2>&1; then
    msg_ok "WAN Tuning angewendet"
  else
    msg_err "WAN Tuning evtl. fehlerhaft (Quorumtool)"
  fi
}

print_status() {
  echo
  if pvecm status >/dev/null 2>&1; then
    pvecm status | sed 's/^/  /'
  else
    echo "  (kein Cluster Status)"
  fi
}

# ------------------ Interaktive Auswahl wenn nötig ------------------
interactive_mode() {
  echo "Interaktiver Modus"; echo
  if is_cluster; then
    echo "Dieser Node ist bereits in einem Cluster:"; print_status; echo
    confirm "WAN Tuning jetzt anwenden?" && WAN_TUNE=1 && apply_wan_tuning
    exit 0
  fi
  local PS3="Aktion wählen (1-3): "
  select opt in "Cluster erstellen" "Diesem Node join ausführen" "Abbrechen"; do
    case $REPLY in
      1) MODE="create"; break;;
      2) MODE="join"; break;;
      3) exit 0;;
      *) echo "Ungültig";;
    esac
  done
  read -r -p "Cluster Name [${CLUSTER_NAME}]: " tmp || true
  [[ -n ${tmp:-} ]] && CLUSTER_NAME="$tmp"
  if [[ $MODE == "join" ]]; then
    read -r -p "Primäre Cluster IP [${PRIMARY_IP}]: " tmp || true
    [[ -n ${tmp:-} ]] && PRIMARY_IP="$tmp"
  fi
  confirm "WAN Tuning aktivieren?" && WAN_TUNE=1
}

# ------------------ Hauptlogik ------------------
main() {
  header
  require_root
  check_pve_version
  ensure_hosts_entries
  ping_nodes

  if [[ -z $MODE ]]; then
    interactive_mode
  fi

  case $MODE in
    create)
      create_cluster
      apply_wan_tuning || true
      if confirm "Andere Nodes automatisch joinen?"; then
        remote_join_nodes
        apply_wan_tuning || true
      fi
      ;;
    add-others)
      if ! is_cluster; then
        msg_err "Dieser Node ist nicht im Cluster (erst create oder join)"
        exit 1
      fi
      remote_join_nodes
      apply_wan_tuning || true
      ;;
    join)
      join_cluster
      apply_wan_tuning || true
      ;;
    remove-node)
      remove_node
      ;;
    leave)
      leave_cluster
      ;;
    *)
      msg_err "Unbekannter MODE: $MODE"
      usage
      exit 1
      ;;
  esac
  print_status
  msg_ok "Fertig"
}

main "$@"
