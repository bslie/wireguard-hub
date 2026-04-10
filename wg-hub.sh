#!/usr/bin/env bash
set -euo pipefail

WG_HUB_HOME="${WG_HUB_HOME:-/opt/wg-hub}"
STATE_DIR="$WG_HUB_HOME/state"
OUTPUT_DIR="$WG_HUB_HOME/output"
LISTS_DIR="$STATE_DIR/lists"
BOOTSTRAP_DIR="$OUTPUT_DIR/bootstrap"
CLIENTS_DIR="$OUTPUT_DIR/clients"
SERVER_PEERS_DIR="$OUTPUT_DIR/server-peers"
BACKUP_DIR="$WG_HUB_HOME/backups"
NODES_DB="$STATE_DIR/nodes.db"
CLIENTS_DB="$STATE_DIR/clients.db"
META_ENV="$STATE_DIR/meta.env"

log() { printf '[wg-hub] %s\n' "$*"; }
err() { printf '[wg-hub][error] %s\n' "$*" >&2; }

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    err "Запускать нужно от root."
    exit 1
  fi
}

require_debian13() {
  local version
  version="$(. /etc/os-release && echo "${VERSION_ID:-}")"
  if [[ "$version" != "13" ]]; then
    err "Скрипт рассчитан на Debian 13. Обнаружено: ${version:-unknown}."
    exit 1
  fi
}

require_cmd() {
  local c="$1"
  command -v "$c" >/dev/null 2>&1 || {
    err "Не найдено: $c"
    exit 1
  }
}

install_dependencies() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y wireguard-tools whiptail nftables iproute2 qrencode git curl iputils-ping
}

ensure_minimal_menu_deps() {
  if ! command -v whiptail >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y whiptail
  fi
}

init_layout() {
  mkdir -p "$STATE_DIR" "$LISTS_DIR" "$BOOTSTRAP_DIR" "$CLIENTS_DIR" "$SERVER_PEERS_DIR" "$BACKUP_DIR"
  touch "$LISTS_DIR/fra_domains.txt" "$LISTS_DIR/fra_ips.txt" "$LISTS_DIR/ams_domains.txt" "$LISTS_DIR/ams_ips.txt"

  if [[ ! -f "$NODES_DB" ]]; then
    printf 'id|role|reserve|fqdn|public_ip|public_iface|bb_ip|bb_port|bb_priv|bb_pub|users_ip_cidr|users_subnet|users_port|created_at\n' >"$NODES_DB"
  fi
  if [[ ! -f "$CLIENTS_DB" ]]; then
    printf 'client_id|device_id|client_name|device_name|device_priv|device_pub|ip_octet|created_at\n' >"$CLIENTS_DB"
  fi
  if [[ ! -f "$META_ENV" ]]; then
    cat >"$META_ENV" <<'EOF'
NEXT_CLIENT_OCTET=10
EOF
  fi
}

default_public_iface() {
  local iface
  iface="$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')"
  printf '%s' "${iface:-eth0}"
}

derive_node_id_from_fqdn() {
  local fqdn="$1"
  local host="${fqdn%%.*}"
  host="$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/-/g')"
  [[ -n "$host" ]] || host="node"
  printf '%s' "$host"
}

valid_fqdn() {
  [[ -n "$1" && "$1" != *"|"* && "$1" != *" "* ]] || return 1
  [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]] || [[ "$1" =~ ^[a-zA-Z0-9]$ ]]
}

bb_ip_in_use() {
  local ip="$1"
  awk -F'|' -v ip="$ip" 'NR>1 && $7==ip {found=1} END{exit !found}' "$NODES_DB"
}

allocate_bb_for_entry_exit() {
  local secondary_count
  secondary_count="$(awk -F'|' 'NR>1 && $2=="entry-exit" && $1!="msk-1" {c++} END{print c+0}' "$NODES_DB")"
  if [[ "$secondary_count" -eq 0 ]] && ! bb_ip_in_use "10.77.0.11"; then
    printf '%s' "10.77.0.11"
    return
  fi
  local x=14
  while bb_ip_in_use "10.77.0.$x"; do
    x=$((x + 1))
  done
  printf '%s' "10.77.0.$x"
}

allocate_bb_for_exit_only() {
  local cand
  for cand in 12 13; do
    if ! bb_ip_in_use "10.77.0.$cand"; then
      printf '%s' "10.77.0.$cand"
      return
    fi
  done
  local x=14
  while bb_ip_in_use "10.77.0.$x"; do
    x=$((x + 1))
  done
  printf '%s' "10.77.0.$x"
}

users_vlan_in_use() {
  local n="$1"
  awk -F'|' -v n="$n" 'NR>1 && ($12 ~ "^10\\.88\\." n "\\.0/24$" || $11 ~ "^10\\.88\\." n "\\.1/24$") {found=1} END{exit !found}' "$NODES_DB"
}

next_users_vlan() {
  local n=2
  while users_vlan_in_use "$n"; do
    n=$((n + 1))
  done
  printf '%s' "$n"
}

sanitize_nodes_db() {
  [[ -f "$NODES_DB" ]] || return 0
  local tmp hdr
  tmp="$(mktemp)"
  hdr="$(head -n 1 "$NODES_DB")"
  printf '%s\n' "$hdr" >"$tmp"
  awk -F'|' -v OFS='|' '
    function trim(s) {
      gsub(/\r/, "", s)
      gsub(/^[ \t]+/, "", s)
      gsub(/[ \t]+$/, "", s)
      return s
    }
    function valid_id(s) { return s ~ /^[a-z0-9][a-z0-9._-]*$/ }
    function valid_ip(s) { return s ~ /^([0-9]{1,3}\.){3}[0-9]{1,3}$/ }
    function valid_port(s) { return s ~ /^[0-9]+$/ && s >= 0 && s <= 65535 }
    function valid_wg_b64(s) { return s ~ /^[A-Za-z0-9+\/]+=*$/ && length(s) >= 40 && length(s) <= 48 }
    NR == 1 { next }
    NF != 14 { next }
    {
      for (i = 1; i <= NF; i++) $i = trim($i)
    }
    valid_id($1) && ($2 == "entry-exit" || $2 == "exit-only") && valid_ip($7) && valid_port($8) && valid_wg_b64($9) && valid_wg_b64($10) && valid_port($13) {
      print
    }
  ' "$NODES_DB" >>"$tmp"
  mv "$tmp" "$NODES_DB"
}

msg() {
  whiptail --title "WG HUB" --msgbox "$1" 14 90
}

input() {
  local title="$1" prompt="$2" default="${3:-}"
  local value
  value="$(whiptail --title "$title" --inputbox "$prompt" 12 90 "$default" 3>&1 1>&2 2>&3)"
  # Убираем CR/управляющие символы: они ломают nodes.db и bootstrap.
  printf '%s' "$value" \
    | tr -d '\r' \
    | sed -e 's/[^[:print:]\t]//g' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

menu_main() {
  whiptail --title "WG HUB" --menu "Выберите действие" 24 100 14 \
    "1" "Инициализация хаба (обязательно сначала)" \
    "2" "Добавить entry-exit (только домен VPS)" \
    "3" "Добавить exit-only (только домен VPS)" \
    "4" "Создать клиента (1-2 устройства)" \
    "5" "Показать QR существующего клиента" \
    "6" "Открыть файлы списков FRA/AMS" \
    "7" "Сгенерировать bootstrap заново" \
    "8" "Health-check сводка" \
    "9" "Backup состояния" \
    "t" "Статус нод (онлайн / офлайн)" \
    "0" "Выход" \
    3>&1 1>&2 2>&3
}

node_exists() {
  local node_id="$1"
  awk -F'|' -v id="$node_id" 'NR>1 && $1==id {found=1} END{exit !found}' "$NODES_DB"
}

fqdn_registered() {
  local fqdn="$1"
  awk -F'|' -v fqdn="$fqdn" 'NR>1 && $4==fqdn {found=1} END{exit !found}' "$NODES_DB"
}

ensure_unique_node_id() {
  local base="$1" id="$1" n=2
  while node_exists "$id"; do
    id="${base}-${n}"
    n=$((n + 1))
  done
  printf '%s' "$id"
}

upsert_node() {
  local row="$1"
  local node_id
  node_id="$(printf '%s' "$row" | cut -d'|' -f1)"
  local tmp
  tmp="$(mktemp)"
  awk -F'|' -v id="$node_id" 'NR==1 || $1!=id' "$NODES_DB" >"$tmp"
  printf '%s\n' "$row" >>"$tmp"
  mv "$tmp" "$NODES_DB"
}

gen_keypair() {
  local priv pub
  priv="$(wg genkey)"
  pub="$(printf '%s' "$priv" | wg pubkey)"
  printf '%s|%s' "$priv" "$pub"
}

get_node_field() {
  local node_id="$1" idx="$2"
  awk -F'|' -v id="$node_id" -v idx="$idx" 'NR>1 && $1==id {print $idx; exit}' "$NODES_DB"
}

list_nodes_by_role() {
  local role="$1"
  awk -F'|' -v role="$role" 'NR>1 && $2==role {print $1}' "$NODES_DB"
}

save_meta_octet() {
  local n="$1"
  cat >"$META_ENV" <<EOF
NEXT_CLIENT_OCTET=$n
EOF
}

next_client_octet() {
  # shellcheck disable=SC1090
  source "$META_ENV"
  echo "${NEXT_CLIENT_OCTET:-10}"
}

ensure_hub_seed_node() {
  if node_exists "msk-1"; then
    return
  fi

  local fqdn public_ip iface bb_port users_port users_ip_cidr users_subnet keys bb_priv bb_pub ukeys users_priv users_pub now
  fqdn="$(input "Хаб (MSK-1)" "Домен этой VPS (FQDN)" "vps-msk-1.securedlink.ru")"
  if ! valid_fqdn "$fqdn" || [[ "$fqdn" == *"|"* ]]; then
    msg "Некорректный домен (FQDN). Без символа |."
    return
  fi
  public_ip=""
  iface="$(default_public_iface)"
  bb_port="51820"
  users_port="51821"
  users_ip_cidr="10.88.1.1/24"
  users_subnet="10.88.1.0/24"
  keys="$(gen_keypair)"
  bb_priv="${keys%%|*}"
  bb_pub="${keys##*|}"
  ukeys="$(gen_keypair)"
  users_priv="${ukeys%%|*}"
  users_pub="${ukeys##*|}"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  upsert_node "msk-1|entry-exit|no|$fqdn|$public_ip|$iface|10.77.0.1|$bb_port|$bb_priv|$bb_pub|$users_ip_cidr|$users_subnet|$users_port|$now"
  printf '%s\n' "$users_pub" >"$STATE_DIR/msk-1.users.pub"
  printf '%s\n' "$users_priv" >"$STATE_DIR/msk-1.users.priv"
}

render_backbone_peers_for_node() {
  local node_id="$1"
  awk -F'|' -v self="$node_id" '
    function trim(s) {
      gsub(/\r/, "", s)
      gsub(/^[ \t]+/, "", s)
      gsub(/[ \t]+$/, "", s)
      return s
    }
    function valid_node_id(s) { return s ~ /^[a-z0-9][a-z0-9._-]*$/ }
    function valid_ipv4(s) { return s ~ /^([0-9]{1,3}\.){3}[0-9]{1,3}$/ }
    function valid_port(s) { return s ~ /^[0-9]+$/ && s >= 1 && s <= 65535 }
    function valid_wg_key(s) { return s ~ /^[A-Za-z0-9+\/]+=*$/ && length(s) >= 40 && length(s) <= 48 }
    NR == 1 { next }
    NF != 14 { next }
    NR>1 && $1!=self {
      peer_id=trim($1); role=trim($2); fqdn=trim($4); pub_ip=trim($5); bb_ip=trim($7); bb_port=trim($8); bb_pub=trim($10); users_subnet=trim($12);
      if (peer_id == "" || !valid_node_id(peer_id)) next;
      if (!valid_ipv4(bb_ip) || !valid_port(bb_port) || !valid_wg_key(bb_pub)) next;
      if (self != "msk-1" && peer_id != "msk-1") next;

      endpoint=(pub_ip==""?fqdn:pub_ip);
      if (endpoint == "") next;
      allowed=bb_ip"/32";
      if (role=="entry-exit" && users_subnet!="") {
        allowed=allowed","users_subnet;
      }
      printf "# peer:%s\n[Peer]\nPublicKey = %s\nEndpoint = %s:%s\nAllowedIPs = %s\nPersistentKeepalive = 25\n\n", peer_id, bb_pub, endpoint, bb_port, allowed;
    }
  ' "$NODES_DB"
}

render_users_peers_for_node() {
  local node_id="$1"
  local peers_file="$SERVER_PEERS_DIR/$node_id.peers.conf"
  if [[ -f "$peers_file" ]]; then
    cat "$peers_file"
  fi
}

ensure_nft_include_line() {
  local include_line='include "/etc/nftables.d/*.nft"'
  mkdir -p /etc/nftables.d
  touch /etc/nftables.conf
  if ! grep -q '/etc/nftables.d/\*\.nft' /etc/nftables.conf; then
    printf '\n%s\n' "$include_line" >> /etc/nftables.conf
  fi
}

bootstrap_common_header() {
  cat <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C.UTF-8 LANG=C.UTF-8

log(){ printf '[bootstrap] %s\n' "$*"; }
die(){ printf '[bootstrap][error] %s\n' "$*" >&2; exit 1; }

[[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Требуется root."
OS_VER="$(. /etc/os-release && echo "${VERSION_ID:-}")"
[[ "$OS_VER" == "13" ]] || die "Поддерживается только Debian 13."

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y wireguard-tools nftables iproute2

install -d -m 700 /etc/wireguard
install -d -m 755 /etc/nftables.d
sysctl -w net.ipv4.ip_forward=1 >/dev/null
if [[ -f /etc/sysctl.conf ]]; then
  grep -q '^net.ipv4.ip_forward=1$' /etc/sysctl.conf || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
else
  install -d -m 755 /etc/sysctl.d
  printf '%s\n' 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-wg-hub-ipforward.conf
  chmod 644 /etc/sysctl.d/99-wg-hub-ipforward.conf
fi
EOF
}

render_policy_routing_for_node() {
  local node_id="$1"
  if [[ "$node_id" != "msk-1" ]]; then
    return
  fi
  cat <<'EOF'
ip route replace default via 10.77.0.11 dev wg-backbone table 101
ip route replace default via 10.77.0.12 dev wg-backbone table 102
ip rule add fwmark 0x65 table 101 2>/dev/null || true
ip rule add fwmark 0x66 table 102 2>/dev/null || true
EOF
}

render_bootstrap_entry_exit() {
  local node_id="$1" output="$2"
  local fqdn public_ip iface bb_ip bb_port bb_priv bb_pub users_ip_cidr users_subnet users_port users_priv
  fqdn="$(get_node_field "$node_id" 4)"
  public_ip="$(get_node_field "$node_id" 5)"
  iface="$(get_node_field "$node_id" 6)"
  bb_ip="$(get_node_field "$node_id" 7)"
  bb_port="$(get_node_field "$node_id" 8)"
  bb_priv="$(get_node_field "$node_id" 9)"
  bb_pub="$(get_node_field "$node_id" 10)"
  users_ip_cidr="$(get_node_field "$node_id" 11)"
  users_subnet="$(get_node_field "$node_id" 12)"
  users_port="$(get_node_field "$node_id" 13)"
  users_priv="$(<"$STATE_DIR/$node_id.users.priv")"

  local peers
  peers="$(render_backbone_peers_for_node "$node_id")"
  local users_peers
  users_peers="$(render_users_peers_for_node "$node_id")"
  local policy_routes
  policy_routes="$(render_policy_routing_for_node "$node_id")"

  {
    bootstrap_common_header
    cat <<EOF
cat >/etc/wireguard/wg-backbone.conf <<'WGEOF'
[Interface]
Address = ${bb_ip}/32
ListenPort = ${bb_port}
PrivateKey = ${bb_priv}

${peers}
WGEOF

cat >/etc/wireguard/wg-users.conf <<'WGUEOF'
[Interface]
Address = ${users_ip_cidr}
ListenPort = ${users_port}
PrivateKey = ${users_priv}

${users_peers}
WGUEOF

cat >/etc/nftables.d/90-wg-hub.nft <<'NFEOF'
table inet wg_hub {
  set fra_targets {
    type ipv4_addr
    flags interval
  }
  set ams_targets {
    type ipv4_addr
    flags interval
  }
  chain mangle_prerouting {
    type filter hook prerouting priority mangle; policy accept;
    iifname "wg-users" ip daddr @fra_targets meta mark set 0x65
    iifname "wg-users" ip daddr @ams_targets meta mark set 0x66
  }
  chain forward_filter {
    type filter hook forward priority filter; policy drop;
    ct state established,related accept
    iifname "wg-users" oifname "wg-users" drop
    iifname "wg-users" accept
    oifname "wg-users" ct state established,related accept
  }
  chain postrouting_nat {
    type nat hook postrouting priority srcnat; policy accept;
    oifname "${iface}" ip saddr ${users_subnet} masquerade
  }
}
NFEOF
EOF
    cat <<'EOF'
if [[ -f /opt/wg-hub/state/lists/fra_runtime.txt ]]; then
  while read -r ip; do
    [[ -z "$ip" ]] && continue
    nft add element inet wg_hub fra_targets "{ $ip }" 2>/dev/null || true
  done </opt/wg-hub/state/lists/fra_runtime.txt
fi
if [[ -f /opt/wg-hub/state/lists/ams_runtime.txt ]]; then
  while read -r ip; do
    [[ -z "$ip" ]] && continue
    nft add element inet wg_hub ams_targets "{ $ip }" 2>/dev/null || true
  done </opt/wg-hub/state/lists/ams_runtime.txt
fi
EOF
    cat <<'EOF'
grep -q '/etc/nftables.d/\*\.nft' /etc/nftables.conf 2>/dev/null || echo 'include "/etc/nftables.d/*.nft"' >> /etc/nftables.conf
systemctl enable nftables wg-quick@wg-backbone wg-quick@wg-users
systemctl restart nftables
systemctl restart wg-quick@wg-backbone
systemctl restart wg-quick@wg-users
EOF
    cat <<EOF
${policy_routes}
EOF
    cat <<EOF
wg show || true
log "Готово: ${node_id} (${fqdn:-$public_ip})"
EOF
  } >"$output"
  chmod +x "$output"
  printf '%s\n' "$bb_pub" >"$STATE_DIR/$node_id.backbone.pub"
}

render_bootstrap_exit_only() {
  local node_id="$1" output="$2"
  local fqdn iface bb_ip bb_port bb_priv
  fqdn="$(get_node_field "$node_id" 4)"
  iface="$(get_node_field "$node_id" 6)"
  bb_ip="$(get_node_field "$node_id" 7)"
  bb_port="$(get_node_field "$node_id" 8)"
  bb_priv="$(get_node_field "$node_id" 9)"

  local peers
  peers="$(render_backbone_peers_for_node "$node_id")"

  {
    bootstrap_common_header
    cat <<EOF
cat >/etc/wireguard/wg-backbone.conf <<'WGEOF'
[Interface]
Address = ${bb_ip}/32
ListenPort = ${bb_port}
PrivateKey = ${bb_priv}

${peers}
WGEOF

cat >/etc/nftables.d/90-wg-hub.nft <<'NFEOF'
table inet wg_hub {
  chain postrouting_nat {
    type nat hook postrouting priority srcnat; policy accept;
    oifname "${iface}" ip saddr 10.88.0.0/16 masquerade
  }
}
NFEOF

grep -q '/etc/nftables.d/\*\.nft' /etc/nftables.conf || echo 'include "/etc/nftables.d/*.nft"' >> /etc/nftables.conf
systemctl enable nftables wg-quick@wg-backbone
systemctl restart nftables
systemctl restart wg-quick@wg-backbone
wg show
log "Готово: ${node_id} (${fqdn})"
EOF
  } >"$output"
  chmod +x "$output"
}

create_or_update_node() {
  local role="$1"
  local node_id fqdn public_ip iface bb_ip bb_port reserve now keys bb_priv bb_pub users_ip_cidr users_subnet users_port ukeys users_priv users_pub vlan

  fqdn="$(input "Нода" "Домен новой VPS (FQDN) — остальное подставится само" "")"
  if ! valid_fqdn "$fqdn"; then
    msg "Некорректный домен (FQDN)."
    return
  fi
  if fqdn_registered "$fqdn"; then
    msg "Этот домен уже есть в базе нод."
    return
  fi
  node_id="$(derive_node_id_from_fqdn "$fqdn")"
  if [[ -z "$node_id" ]] || [[ "$node_id" == "msk-1" ]]; then
    msg "ID ноды не может быть пустым или msk-1 (это хаб). Выберите другой домен."
    return
  fi
  node_id="$(ensure_unique_node_id "$node_id")"
  public_ip=""
  iface="$(default_public_iface)"
  bb_port="51820"
  users_port="51821"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  keys="$(gen_keypair)"
  bb_priv="${keys%%|*}"
  bb_pub="${keys##*|}"

  if [[ "$role" == "entry-exit" ]]; then
    reserve="yes"
    bb_ip="$(allocate_bb_for_entry_exit)"
    vlan="$(next_users_vlan)"
    users_ip_cidr="10.88.${vlan}.1/24"
    users_subnet="10.88.${vlan}.0/24"
    ukeys="$(gen_keypair)"
    users_priv="${ukeys%%|*}"
    users_pub="${ukeys##*|}"
    printf '%s\n' "$users_priv" >"$STATE_DIR/$node_id.users.priv"
    printf '%s\n' "$users_pub" >"$STATE_DIR/$node_id.users.pub"
    upsert_node "$node_id|entry-exit|$reserve|$fqdn|$public_ip|$iface|$bb_ip|$bb_port|$bb_priv|$bb_pub|$users_ip_cidr|$users_subnet|$users_port|$now"
    render_bootstrap_entry_exit "$node_id" "$BOOTSTRAP_DIR/bootstrap-$node_id.sh"
    msg "Готово: $node_id → $BOOTSTRAP_DIR/bootstrap-$node_id.sh\nbackbone ${bb_ip}, users ${users_ip_cidr}, порт ${users_port}"
  else
    bb_ip="$(allocate_bb_for_exit_only)"
    upsert_node "$node_id|exit-only|no|$fqdn|$public_ip|$iface|$bb_ip|$bb_port|$bb_priv|$bb_pub|||0|$now"
    render_bootstrap_exit_only "$node_id" "$BOOTSTRAP_DIR/bootstrap-$node_id.sh"
    msg "Готово: $node_id → $BOOTSTRAP_DIR/bootstrap-$node_id.sh\nbackbone ${bb_ip}"
  fi

  sanitize_nodes_db
  # Пересобрать bootstrap для всех нод (хаб + спицы).
  awk -F'|' 'NR>1 {print $1 "|" $2}' "$NODES_DB" | while IFS='|' read -r id r; do
    if [[ "$r" == "entry-exit" ]]; then
      render_bootstrap_entry_exit "$id" "$BOOTSTRAP_DIR/bootstrap-$id.sh"
    else
      render_bootstrap_exit_only "$id" "$BOOTSTRAP_DIR/bootstrap-$id.sh"
    fi
  done
}

create_client() {
  local client_name count i octet now dev_name keys dev_priv dev_pub msk1_id msk2_id msk1_ep msk2_ep msk1_port msk2_port
  local dir ip1 ip2 msk1_pub msk2_pub msk2_net vlan2 dual_entry
  client_name="$(input "Клиент" "Имя клиента (латиницей)" "")"
  count="$(whiptail --title "Клиент" --menu "Сколько устройств?" 12 60 2 "1" "Одно устройство" "2" "Два устройства" 3>&1 1>&2 2>&3)"
  msk1_id="msk-1"
  msk2_id="$(awk -F'|' 'NR>1 && $2=="entry-exit" && $1!="msk-1" {print $1; exit}' "$NODES_DB")"
  if ! node_exists "$msk1_id"; then
    msg "Не найдена entry-нодa msk-1"
    return
  fi
  dual_entry=0
  if [[ -n "$msk2_id" ]] && node_exists "$msk2_id"; then
    dual_entry=1
  fi

  msk1_ep="$(get_node_field "$msk1_id" 4)"
  msk1_port="$(get_node_field "$msk1_id" 13)"
  msk1_pub="$(<"$STATE_DIR/$msk1_id.users.pub")"
  if [[ "$dual_entry" -eq 1 ]]; then
    msk2_ep="$(get_node_field "$msk2_id" 4)"
    msk2_port="$(get_node_field "$msk2_id" 13)"
    msk2_pub="$(<"$STATE_DIR/$msk2_id.users.pub")"
    msk2_net="$(get_node_field "$msk2_id" 12)"
    if [[ "$msk2_net" =~ ^10\.88\.([0-9]+)\.0/24$ ]]; then
      vlan2="${BASH_REMATCH[1]}"
    else
      vlan2="2"
    fi
  fi

  octet="$(next_client_octet)"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  for ((i=1; i<=count; i++)); do
    if [[ "$i" -eq 1 ]]; then
      dev_name="${client_name}-pc"
    else
      dev_name="${client_name}-mobile"
    fi
    keys="$(gen_keypair)"
    dev_priv="${keys%%|*}"
    dev_pub="${keys##*|}"

    dir="$CLIENTS_DIR/$client_name/$dev_name"
    mkdir -p "$dir"
    ip1="10.88.1.${octet}/32"

    cat >"$dir/${dev_name}-MSK1.conf" <<EOF
[Interface]
PrivateKey = ${dev_priv}
Address = ${ip1}
DNS = 1.1.1.1

[Peer]
PublicKey = ${msk1_pub}
Endpoint = ${msk1_ep}:${msk1_port}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

    cat >>"$SERVER_PEERS_DIR/$msk1_id.peers.conf" <<EOF
[Peer]
# ${dev_name}
PublicKey = ${dev_pub}
AllowedIPs = 10.88.1.${octet}/32

EOF

    if [[ "$dual_entry" -eq 1 ]]; then
      ip2="10.88.${vlan2}.${octet}/32"
      cat >"$dir/${dev_name}-MSKGAMING.conf" <<EOF
[Interface]
PrivateKey = ${dev_priv}
Address = ${ip2}
DNS = 1.1.1.1

[Peer]
PublicKey = ${msk2_pub}
Endpoint = ${msk2_ep}:${msk2_port}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

      cat >>"$SERVER_PEERS_DIR/$msk2_id.peers.conf" <<EOF
[Peer]
# ${dev_name}
PublicKey = ${dev_pub}
AllowedIPs = 10.88.${vlan2}.${octet}/32

EOF
      qrencode -t ANSIUTF8 <"$dir/${dev_name}-MSKGAMING.conf" || true
    fi

    printf '%s|%s|%s|%s|%s|%s|%s|%s\n' "$client_name" "$i" "$client_name" "$dev_name" "$dev_priv" "$dev_pub" "$octet" "$now" >>"$CLIENTS_DB"

    qrencode -t ANSIUTF8 <"$dir/${dev_name}-MSK1.conf" || true
    octet=$((octet + 1))
  done
  save_meta_octet "$octet"
  if [[ "$dual_entry" -eq 1 ]]; then
    msg "Клиент создан (MSK-1 + резерв MSK-GAMING). Файлы: $CLIENTS_DIR/$client_name"
  else
    msg "Клиент создан только для MSK-1. Второй конфиг появится после добавления второй entry-ноды (п.2) и п.7.\nФайлы: $CLIENTS_DIR/$client_name"
  fi
}

show_client_qr() {
  local client_name
  client_name="$(input "QR" "Имя клиента" "")"
  local dir
  dir="$CLIENTS_DIR/$client_name"
  if [[ ! -d "$dir" ]]; then
    msg "Не найдено: $dir"
    return
  fi
  while IFS= read -r conf; do
    qrencode -t ANSIUTF8 <"$conf" || true
  done < <(find "$dir" -type f -name "*.conf" | sort)
}

open_lists_hint() {
  msg "Редактируйте файлы:\n$LISTS_DIR/fra_domains.txt\n$LISTS_DIR/fra_ips.txt\n$LISTS_DIR/ams_domains.txt\n$LISTS_DIR/ams_ips.txt\n\nПосле редактирования запустите ваш deploy hook."
}

regenerate_bootstrap() {
  sanitize_nodes_db
  awk -F'|' 'NR>1 {print $1 "|" $2}' "$NODES_DB" | while IFS='|' read -r id r; do
    if [[ "$r" == "entry-exit" ]]; then
      render_bootstrap_entry_exit "$id" "$BOOTSTRAP_DIR/bootstrap-$id.sh"
    else
      render_bootstrap_exit_only "$id" "$BOOTSTRAP_DIR/bootstrap-$id.sh"
    fi
  done
  msg "Bootstrap-скрипты пересозданы: $BOOTSTRAP_DIR"
}

wg_iface_list() {
  wg show interfaces 2>/dev/null | tr -s '[:space:]' '\n' | awk 'NF'
}

pick_wg_iface_for_status() {
  local iface local_pub
  if wg show wg-backbone dump &>/dev/null; then
    printf '%s' "wg-backbone"
    return 0
  fi
  while read -r iface; do
    [[ -n "$iface" ]] || continue
    wg show "$iface" dump &>/dev/null || continue
    local_pub="$(wg show "$iface" dump 2>/dev/null | awk -F'\t' 'NR == 1 && NF == 4 { print $2; exit }')"
    [[ -n "$local_pub" ]] || continue
    if awk -F'|' -v p="$local_pub" 'NR > 1 && $10 == p { found = 1; exit } END { exit !found }' "$NODES_DB"; then
      printf '%s' "$iface"
      return 0
    fi
  done < <(wg_iface_list)
  return 1
}

show_nodes_status() {
  sanitize_nodes_db
  local rep hs now local_pub wg_ok wg_iface
  rep="$(mktemp)"
  hs="$(mktemp)"
  now="$(date +%s)"
  wg_ok=0
  wg_iface=""
  if wg_iface="$(pick_wg_iface_for_status)"; then
    wg_ok=1
    wg show "$wg_iface" dump 2>/dev/null | awk -F'\t' 'NF == 8 { print $1 "\t" ($5 + 0) }' >"$hs"
    local_pub="$(wg show "$wg_iface" dump 2>/dev/null | awk -F'\t' 'NR == 1 && NF == 4 { print $2; exit }')"
  else
    : >"$hs"
    local_pub=""
  fi

  {
    printf 'Сводка по нодам из %s\n' "$NODES_DB"
    if [[ "$wg_ok" -eq 1 ]]; then
      printf 'WireGuard: интерфейс «%s». Онлайн по туннелю: рукопожатие не старше 3 мин.\n' "$wg_iface"
    else
      printf 'WireGuard: интерфейс backbone не найден (нет wg-backbone и нет iface с ключом из nodes.db).\n'
      printf 'Запустите bootstrap на этой машине или поднимите wg-quick@wg-backbone — иначе виден только ping.\n'
    fi
    printf 'Ping: один ICMP; если ICMP запрещён — «офлайн» не значит, что WG мёртв.\n\n'

    printf '%-14s %-10s %-22s %-10s %s\n' "ID" "Роль" "Туннель (backbone)" "Ping" "Проверка (IP/домен)"
    printf '%s\n' "------------------------------------------------------------------------------"

    while IFS='|' read -r id role _ fqdn pip _ _ _ _ pub _ _ _ _; do
      [[ -n "$id" ]] || continue
      tun=""
      pingst=""
      lhs=""
      age=0

      if [[ "$wg_ok" -eq 1 && -n "$local_pub" && "$pub" == "$local_pub" ]]; then
        tun="локально"
      elif [[ "$wg_ok" -ne 1 ]]; then
        tun="—"
      else
        lhs="$(awk -F'\t' -v p="$pub" '$1 == p { print $2; exit }' "$hs")"
        if [[ -z "$lhs" ]]; then
          tun="нет peer"
        elif [[ "$lhs" -eq 0 ]]; then
          tun="офлайн"
        else
          age=$((now - lhs))
          if [[ "$age" -le 180 ]]; then
            tun="онлайн (${age}s)"
          else
            tun="офлайн (${age}s)"
          fi
        fi
      fi

      ping_target="${pip:-$fqdn}"
      if [[ -z "$ping_target" ]]; then
        pingst="—"
      elif command -v ping >/dev/null 2>&1; then
        if ping -c 1 -W 2 -q "$ping_target" &>/dev/null; then
          pingst="онлайн"
        else
          pingst="офлайн"
        fi
      else
        pingst="нет ping"
      fi

      printf '%-14s %-10s %-22s %-10s %s\n' "$id" "$role" "$tun" "$pingst" "$ping_target"
    done < <(tail -n +2 "$NODES_DB")
  } >"$rep"

  whiptail --title "Статус нод" --scrolltext --textbox "$rep" 26 100
  rm -f "$rep" "$hs"
}

healthcheck() {
  local report="$OUTPUT_DIR/health-$(date +%Y%m%d-%H%M%S).txt"
  {
    echo "== NODES =="
    cat "$NODES_DB"
    echo
    echo "== CLIENTS =="
    cat "$CLIENTS_DB"
    echo
    echo "== LOCAL WG =="
    wg show || true
    echo
    echo "== LOCAL NFT =="
    nft list ruleset || true
  } >"$report"
  msg "Health-check сохранен: $report"
}

backup_state() {
  local out="$BACKUP_DIR/wg-hub-$(date +%Y%m%d-%H%M%S).tar.gz"
  tar -czf "$out" -C "$WG_HUB_HOME" state output
  msg "Backup создан: $out"
}

init_hub() {
  install_dependencies
  init_layout
  sanitize_nodes_db
  local had_msk1=0 bs="$BOOTSTRAP_DIR/bootstrap-msk-1.sh"
  node_exists "msk-1" && had_msk1=1
  ensure_hub_seed_node
  if ! node_exists "msk-1"; then
    return
  fi
  render_bootstrap_entry_exit "msk-1" "$bs"
  chmod +x "$bs" 2>/dev/null || true
  if [[ "$had_msk1" -eq 0 ]]; then
    if ! bash "$bs"; then
      msg "База: $WG_HUB_HOME\nНе удалось поднять exit (WireGuard + NAT) автоматически. Запустите:\n  bash $bs"
      return
    fi
    msg "Хаб инициализирован и сразу работает как exit: NAT для клиентов wg-users, форвардинг.\nБаза: $WG_HUB_HOME"
  else
    msg "msk-1 уже в базе — обновлён $bs\nЧтобы применить заново: bash $bs\nБаза: $WG_HUB_HOME"
  fi
}

main() {
  require_root
  require_debian13
  ensure_minimal_menu_deps
  require_cmd awk
  init_layout
  sanitize_nodes_db

  while true; do
    local c
    c="$(menu_main)"
    case "$c" in
      1) init_hub ;;
      2) create_or_update_node "entry-exit" ;;
      3) create_or_update_node "exit-only" ;;
      4) create_client ;;
      5) show_client_qr ;;
      6) open_lists_hint ;;
      7) regenerate_bootstrap ;;
      8) healthcheck ;;
      9) backup_state ;;
      t) show_nodes_status ;;
      0) exit 0 ;;
      *) ;;
    esac
  done
}

main "$@"
