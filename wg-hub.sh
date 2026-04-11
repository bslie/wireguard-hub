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
JOIN_BUNDLE_DIR="$OUTPUT_DIR/join-bundles"

log() { printf '[wg-hub] %s\n' "$*"; }
err() { printf '[wg-hub][error] %s\n' "$*" >&2; }

# ANSI: только на TTY (подсветка меню и фрагментов конфигов).
if [[ -t 2 ]]; then
  C_HEAD=$'\033[1;36m'
  C_OK=$'\033[1;32m'
  C_WARN=$'\033[1;33m'
  C_ERR=$'\033[1;31m'
  C_KEY=$'\033[33m'
  C_SEC=$'\033[35m'
  C_DIM=$'\033[0;90m'
  C_RESET=$'\033[0m'
else
  C_HEAD='' C_OK='' C_WARN='' C_ERR='' C_KEY='' C_SEC='' C_DIM='' C_RESET=''
fi

ui_tty() {
  if [[ -r /dev/tty && -w /dev/tty ]]; then
    printf '%s' /dev/tty
  else
    printf '%s' /dev/stderr
  fi
}

ui_print() {
  # печать в интерактивный терминал (меню не попадает в stdout при $(capture))
  printf '%b\n' "$*" >"$(ui_tty)"
}

ui_pause() {
  local tty
  tty="$(ui_tty)"
  [[ -r "$tty" && -w "$tty" ]] || return 0
  read -r -p "$(printf '%b' "${C_DIM}[Enter] — дальше…${C_RESET} ")" _ <"$tty" 2>/dev/null || true
}

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
  apt-get install -y wireguard-tools nftables iproute2 qrencode git curl iputils-ping
}

ensure_minimal_menu_deps() {
  :
}

init_layout() {
  mkdir -p "$STATE_DIR" "$LISTS_DIR" "$BOOTSTRAP_DIR" "$JOIN_BUNDLE_DIR" "$CLIENTS_DIR" "$SERVER_PEERS_DIR" "$BACKUP_DIR"
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
  ui_print "${C_OK}${1}${C_RESET}"
  ui_pause
}

confirm_yes() {
  local prompt="$1" tty ans
  tty="$(ui_tty)"
  [[ -r "$tty" && -w "$tty" ]] || return 1
  printf '%b\n' "${C_WARN}${prompt}${C_RESET}"
  printf '%s' "[y/N]: " >"$tty"
  read -r ans <"$tty" 2>/dev/null || return 1
  [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
}

# Простая подсветка строк WireGuard-конфига (секции / ключи).
hl_wg_cat() {
  local out="$1"
  local line sec key rest
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == \[*] ]]; then
      printf '%b\n' "${C_HEAD}${line}${C_RESET}" >"$out"
    elif [[ "$line" =~ ^(PrivateKey|PreSharedKey)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      rest="${BASH_REMATCH[2]}"
      printf '%b\n' "${C_SEC}${key}${C_RESET} = ${C_KEY}${rest}${C_RESET}" >"$out"
    elif [[ "$line" =~ ^(PublicKey)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      rest="${BASH_REMATCH[2]}"
      printf '%b\n' "${C_SEC}${key}${C_RESET} = ${C_KEY}${rest}${C_RESET}" >"$out"
    else
      printf '%s\n' "$line" >"$out"
    fi
  done
}

# Текст конфига в SSH-терминал: копирование без полноэкранных окон.
dump_text_to_console() {
  local title="$1" file="$2" out
  out="$(ui_tty)"
  {
    printf '\n========== %s ==========\n\n' "$title"
    if [[ -t 2 ]] || [[ "$out" == /dev/tty ]]; then
      hl_wg_cat "$out" <"$file"
    else
      cat "$file"
    fi
    printf '\n\n========== конец ==========\n\n'
  } >"$out"
  ui_pause
}

input() {
  local title="$1" prompt="$2" default="${3:-}"
  local value tty
  tty="$(ui_tty)"
  ui_print "${C_HEAD}[$title]${C_RESET} $prompt"
  if [[ -n "$default" ]]; then
    ui_print "${C_DIM}По умолчанию:${C_RESET} $default ${C_DIM}(Enter — принять)${C_RESET}"
  fi
  printf '%b' "${C_DIM}> ${C_RESET}" >"$tty"
  read -r value <"$tty" || true
  if [[ -z "$value" && -n "$default" ]]; then
    value="$default"
  fi
  # Убираем CR/управляющие символы: они ломают nodes.db и bootstrap.
  printf '%s' "$value" \
    | tr -d '\r' \
    | sed -e 's/[^[:print:]\t]//g' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

menu_main() {
  local c tty
  tty="$(ui_tty)"
  {
    printf '%b\n' "${C_HEAD}=== WG HUB — главное меню ===${C_RESET}"
    printf '%s\n' "Root, Debian 13. Каталог: $WG_HUB_HOME"
    printf '%s\n' ""
    printf '%s\n' "  1) Хаб — первичная инициализация (MSK-1)"
    printf '%s\n' "  2) Ноды — добавить, удалить, join с Git, статус"
    printf '%s\n' "  3) Клиенты WireGuard"
    printf '%s\n' "  4) Списки FRA / AMS (куда править файлы)"
    printf '%s\n' "  5) Служебное — пересборка, wg-users, health, backup, URL join"
    printf '%s\n' "  0) Выход"
    printf '%b' "${C_DIM}Пункт: ${C_RESET}"
  } >"$tty"
  read -r c <"$tty" || c=""
  printf '%s' "$c"
}

menu_nodes() {
  local mc tty
  tty="$(ui_tty)"
  while true; do
    {
      printf '%b\n' "${C_HEAD}=== Ноды ===${C_RESET}"
      printf '%s\n' "  1) Добавить entry-exit (FQDN новой VPS)"
      printf '%s\n' "  2) Добавить exit-only"
      printf '%s\n' "  3) Статус нод (WireGuard + ICMP)"
      printf '%s\n' "  4) Удалить ноду"
      printf '%s\n' "  5) Повторить команды join (scp + curl из Git)"
      printf '%s\n' "  6) Задать URL raw scripts/node-join.sh (GitHub)"
      printf '%s\n' "  0) Назад"
      printf '%b' "${C_DIM}Пункт: ${C_RESET}"
    } >"$tty"
    read -r mc <"$tty" || break
    case "$mc" in
      1) create_or_update_node "entry-exit" ;;
      2) create_or_update_node "exit-only" ;;
      3) show_nodes_status ;;
      4) delete_node_interactive ;;
      5) menu_reprint_join_commands ;;
      6) configure_join_script_url ;;
      0|"") break ;;
    esac
  done
}

menu_service() {
  local mc tty
  tty="$(ui_tty)"
  while true; do
    {
      printf '%b\n' "${C_HEAD}=== Служебное ===${C_RESET}"
      printf '%s\n' "  1) Пересобрать все bootstrap + join-bundle"
      printf '%s\n' "  2) Обновить wg-users на этом сервере из базы"
      printf '%s\n' "  3) Health-check (файл в output/)"
      printf '%s\n' "  4) Backup state + output"
      printf '%s\n' "  5) URL raw node-join.sh (Git)"
      printf '%s\n' "  0) Назад"
      printf '%b' "${C_DIM}Пункт: ${C_RESET}"
    } >"$tty"
    read -r mc <"$tty" || break
    case "$mc" in
      1) regenerate_bootstrap ;;
      2) resync_wg_users_local ;;
      3) healthcheck ;;
      4) backup_state ;;
      5) configure_join_script_url ;;
      0|"") break ;;
    esac
  done
}

menu_clients() {
  local mc tty
  tty="$(ui_tty)"
  while true; do
    {
      printf '%b\n' "${C_HEAD}=== Клиенты WireGuard ===${C_RESET}"
      printf '%s\n' "На другой entry-VPS после изменений скопируйте state/ или повторите синхронизацию там."
      printf '%s\n' ""
      printf '%s\n' "  1) Создать клиента (1–2 устройства)"
      printf '%s\n' "  2) Просмотр конфига (текст) + QR PNG"
      printf '%s\n' "  3) Список клиентов и устройств"
      printf '%s\n' "  4) Удалить клиента"
      printf '%s\n' "  5) Пересобрать пиры из базы + wg-users"
      printf '%s\n' "  6) Экспорт клиента в .tar.gz"
      printf '%s\n' "  0) Назад"
      printf '%b' "${C_DIM}Пункт: ${C_RESET}"
    } >"$tty"
    read -r mc <"$tty" || break
    case "$mc" in
      1) create_client ;;
      2) browse_client_config_ui ;;
      3) list_clients_menu ;;
      4) delete_client_ui ;;
      5) menu_clients_repair_from_db ;;
      6) export_client_archive_ui ;;
      0|"") break ;;
    esac
  done
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

get_join_script_url() {
  if [[ -n "${WG_HUB_JOIN_SCRIPT_URL:-}" ]]; then
    printf '%s' "$WG_HUB_JOIN_SCRIPT_URL"
    return 0
  fi
  if [[ -f "$STATE_DIR/join-script-url.txt" ]]; then
    head -1 "$STATE_DIR/join-script-url.txt" | tr -d '\r'
    return 0
  fi
  printf '%s' "https://raw.githubusercontent.com/YOUR_ORG/wireguard-hub/main/scripts/node-join.sh"
}

configure_join_script_url() {
  local cur v
  cur="$(get_join_script_url)"
  v="$(input "Git raw URL" "Полный URL к scripts/node-join.sh (страница raw на GitHub)" "$cur")"
  [[ -n "$v" ]] || return
  printf '%s\n' "$v" >"$STATE_DIR/join-script-url.txt"
  msg "Сохранено: $STATE_DIR/join-script-url.txt"
}

write_join_bundle_for_node() {
  local node_id="$1"
  local out="$JOIN_BUNDLE_DIR/join-${node_id}.bash"
  local role fqdn public_ip iface bb_ip bb_port bb_priv bb_pub users_ip_cidr users_subnet users_port
  local peers peers_b64 users_peers users_peers_b64 policy policy_b64 users_priv

  role="$(get_node_field "$node_id" 2)"
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

  peers="$(render_backbone_peers_for_node "$node_id")"
  peers_b64="$(printf '%s' "$peers" | base64 -w0)"
  users_peers_b64=""
  policy_b64=""
  users_priv=""
  if [[ "$role" == "entry-exit" ]]; then
    [[ -f "$STATE_DIR/$node_id.users.priv" ]] && users_priv="$(<"$STATE_DIR/$node_id.users.priv")"
    users_peers="$(render_users_peers_for_node "$node_id")"
    users_peers_b64="$(printf '%s' "$users_peers" | base64 -w0)"
    policy="$(render_policy_routing_for_node "$node_id")"
    policy_b64="$(printf '%s' "$policy" | base64 -w0)"
  fi

  cat >"$out" <<EOF
# Автогенерация wg-hub — не править вручную. Источник: node ${node_id}
WG_JOIN_SCHEMA=1
WG_JOIN_ROLE='${role}'
WG_JOIN_NODE_ID='${node_id}'
WG_JOIN_FQDN='${fqdn}'
WG_JOIN_PUBLIC_IP='${public_ip}'
WG_JOIN_IFACE='${iface}'
WG_JOIN_BB_IP='${bb_ip}'
WG_JOIN_BB_PORT='${bb_port}'
WG_JOIN_BB_PRIV='${bb_priv}'
WG_JOIN_BB_PUB='${bb_pub}'
WG_JOIN_USERS_IP_CIDR='${users_ip_cidr}'
WG_JOIN_USERS_SUBNET='${users_subnet}'
WG_JOIN_USERS_PORT='${users_port}'
WG_JOIN_USERS_PRIV='${users_priv}'
WG_JOIN_BACKBONE_PEERS_B64='${peers_b64}'
WG_JOIN_USERS_PEERS_B64='${users_peers_b64}'
WG_JOIN_POLICY_ROUTES_B64='${policy_b64}'
EOF
  chmod 600 "$out"
}

write_all_join_bundles() {
  local id
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    write_join_bundle_for_node "$id"
  done < <(awk -F'|' 'NR>1 {print $1}' "$NODES_DB")
}

regenerate_all_bootstraps_and_bundles() {
  sanitize_nodes_db
  awk -F'|' 'NR>1 {print $1 "|" $2}' "$NODES_DB" | while IFS='|' read -r id r; do
    if [[ "$r" == "entry-exit" ]]; then
      render_bootstrap_entry_exit "$id" "$BOOTSTRAP_DIR/bootstrap-$id.sh"
    else
      render_bootstrap_exit_only "$id" "$BOOTSTRAP_DIR/bootstrap-$id.sh"
    fi
  done
  write_all_join_bundles
}

print_join_instructions_tty() {
  local node_id="$1" url bundle fqdn
  url="$(get_join_script_url)"
  bundle="$JOIN_BUNDLE_DIR/join-${node_id}.bash"
  fqdn="$(get_node_field "$node_id" 4)"
  [[ -f "$bundle" ]] || {
    err "Нет join-bundle: $bundle"
    return 1
  }
  ui_print ""
  ui_print "${C_HEAD}── Команды на новой VPS (${node_id}, ${fqdn}) ──${C_RESET}"
  ui_print ""
  ui_print "${C_DIM}1) Скопируйте bundle с этой машины (хаба):${C_RESET}"
  ui_print "   ${C_KEY}scp ${bundle} root@${fqdn}:/root/join-${node_id}.bash${C_RESET}"
  ui_print ""
  ui_print "${C_DIM}2) На VPS скачайте node-join.sh из Git и выполните:${C_RESET}"
  ui_print "   ${C_KEY}curl -fsSL '${url}' -o /root/node-join.sh && chmod +x /root/node-join.sh${C_RESET}"
  ui_print "   ${C_KEY}bash /root/node-join.sh /root/join-${node_id}.bash${C_RESET}"
  ui_print ""
}

resolve_local_node_id_from_wg() {
  local wg_iface pub
  wg_iface="$(pick_wg_iface_for_status 2>/dev/null)" || return 1
  pub="$(wg show "$wg_iface" dump 2>/dev/null | awk -F'\t' 'NR == 1 && NF == 4 { print $2; exit }')"
  [[ -n "$pub" ]] || return 1
  awk -F'|' -v p="$pub" 'NR>1 && $10==p {print $1; exit}' "$NODES_DB"
}

prompt_apply_local_bootstrap_if_needed() {
  local nid
  nid="$(resolve_local_node_id_from_wg 2>/dev/null)" || return 0
  node_exists "$nid" || return 0
  if confirm_yes "Сервер совпадает с нодой «$nid» в базе. Применить сейчас $BOOTSTRAP_DIR/bootstrap-${nid}.sh (обновить живой WireGuard и пиров)?"; then
    bash "$BOOTSTRAP_DIR/bootstrap-$nid.sh" || msg "Ошибка bootstrap — запустите вручную на этом хосте."
  fi
}

wait_for_node_peer_connected() {
  local node_id="$1"
  local max_sec="${2:-900}"
  local pub wg_iface hs_ts now start age
  pub="$(get_node_field "$node_id" 10)"
  [[ -n "$pub" ]] || return 0
  if ! wg_iface="$(pick_wg_iface_for_status 2>/dev/null)"; then
    ui_print "${C_WARN}На этом хосте не найден wg-backbone из базы — авто-ожидание пропущено. Проверьте статус нод с машины-хаба с поднятым туннелем.${C_RESET}"
    ui_pause
    return 0
  fi
  start="$(date +%s)"
  ui_print "${C_WARN}Ожидание подключения ноды «${node_id}»…${C_RESET}"
  ui_print "${C_DIM}После запуска node-join на новой VPS здесь появится успех (рукопожатие WireGuard ≤3 мин). Ctrl+C — выйти из ожидания.${C_RESET}"
  while true; do
    hs_ts="$(wg show "$wg_iface" dump 2>/dev/null | awk -F'\t' -v p="$pub" '$1 == p && NF == 8 { print ($5 + 0); exit }')"
    now="$(date +%s)"
    if [[ -n "$hs_ts" && "$hs_ts" -ne 0 ]]; then
      age=$((now - hs_ts))
      if [[ "$age" -le 180 ]]; then
        printf '\r%*s\r' 80 '' >"$(ui_tty)"
        ui_print "${C_OK}Подключение выполнено успешно: «${node_id}», рукопожатие ${age} с назад.${C_RESET}"
        ui_pause
        return 0
      fi
    fi
    if [[ $((now - start)) -ge "$max_sec" ]]; then
      printf '\r%*s\r' 80 '' >"$(ui_tty)"
      ui_print "${C_ERR}Таймаут ожидания (${max_sec} с). Проверьте node-join на ноде, UDP-порт, фаервол и что на хабе применён актуальный bootstrap.${C_RESET}"
      ui_pause
      return 1
    fi
    printf '\r  %s… %s с ' "${node_id}" "$((now - start))" >"$(ui_tty)"
    sleep 3
  done
}

pick_node_id_interactive() {
  local title="$1" lines tty sel i id role fqdn
  tty="$(ui_tty)"
  sanitize_nodes_db
  mapfile -t lines < <(awk -F'|' 'NR>1 { printf "%s|%s|%s\n", $1, $2, $4 }' "$NODES_DB")
  if [[ "${#lines[@]}" -eq 0 ]]; then
    msg "В базе нет нод."
    return 1
  fi
  {
    printf '%b\n' "${C_HEAD}$title${C_RESET}"
    for i in "${!lines[@]}"; do
      IFS='|' read -r id role fqdn <<<"${lines[$i]}"
      printf '%3s) %-16s %-12s %s\n' "$i" "$id" "$role" "$fqdn"
    done
    printf '%b' "${C_DIM}Номер или id: ${C_RESET}"
  } >"$tty"
  read -r sel <"$tty" || return 1
  if [[ "$sel" =~ ^[0-9]+$ ]] && [[ "$sel" -ge 0 && "$sel" -lt "${#lines[@]}" ]]; then
    IFS='|' read -r id _ _ <<<"${lines[$sel]}"
    printf '%s' "$id"
    return 0
  fi
  printf '%s' "$sel"
}

delete_node_by_id() {
  local node_id="$1"
  local tmp
  tmp="$(mktemp)"
  awk -F'|' -v id="$node_id" 'NR==1 || $1!=id' "$NODES_DB" >"$tmp"
  mv "$tmp" "$NODES_DB"
  rm -f \
    "$STATE_DIR/${node_id}.users.priv" \
    "$STATE_DIR/${node_id}.users.pub" \
    "$STATE_DIR/${node_id}.backbone.pub" \
    "$BOOTSTRAP_DIR/bootstrap-${node_id}.sh" \
    "$JOIN_BUNDLE_DIR/join-${node_id}.bash" \
    "$SERVER_PEERS_DIR/${node_id}.peers.conf"
  sanitize_nodes_db
  regenerate_all_bootstraps_and_bundles
  repair_peers_and_wg_users_from_db
}

delete_node_interactive() {
  local nid
  nid="$(pick_node_id_interactive "Удалить ноду")" || return
  [[ -n "$nid" ]] || return
  if [[ "$nid" == "msk-1" ]]; then
    msg "Ноду msk-1 (корневой хаб) нельзя удалить из этого меню."
    return
  fi
  if ! node_exists "$nid"; then
    msg "Ноды «$nid» нет в базе."
    return
  fi
  if ! confirm_yes "Удалить «$nid» из nodes.db и с диска (ключи, bootstrap, join-bundle, server-peers)? Остальные ноды будут пересобраны."; then
    return
  fi
  delete_node_by_id "$nid"
  msg "Нода «$nid» удалена, артефакты пересобраны."
}

menu_reprint_join_commands() {
  local nid
  nid="$(pick_node_id_interactive "Повторить инструкции join")" || return
  [[ -n "$nid" ]] || return
  if [[ ! -f "$JOIN_BUNDLE_DIR/join-${nid}.bash" ]]; then
    msg "Нет join-${nid}.bash — выполните «Пересобрать bootstrap + join-bundle» в служебном меню."
    return
  fi
  print_join_instructions_tty "$nid"
  ui_pause
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

apply_wg_users_live_for_node() {
  local node_id="$1"
  local users_ip_cidr users_port users_priv users_peers stored_pub live_pub
  [[ -f "$STATE_DIR/$node_id.users.priv" ]] || return 0
  [[ "$(get_node_field "$node_id" 2)" == "entry-exit" ]] || return 0
  stored_pub="$(<"$STATE_DIR/$node_id.users.pub")"
  live_pub="$(wg show wg-users public-key 2>/dev/null || true)"
  if [[ -n "$live_pub" && "$live_pub" != "$stored_pub" ]]; then
    return 0
  fi
  if [[ -z "$live_pub" && ! -f /etc/wireguard/wg-users.conf ]]; then
    return 0
  fi
  users_ip_cidr="$(get_node_field "$node_id" 11)"
  [[ -n "$users_ip_cidr" ]] || return 0
  users_port="$(get_node_field "$node_id" 13)"
  users_priv="$(<"$STATE_DIR/$node_id.users.priv")"
  users_peers="$(render_users_peers_for_node "$node_id")"
  install -d -m 700 /etc/wireguard
  cat >/etc/wireguard/wg-users.conf <<EOF
[Interface]
Address = ${users_ip_cidr}
ListenPort = ${users_port}
PrivateKey = ${users_priv}

${users_peers}
EOF
  if systemctl is-enabled wg-quick@wg-users &>/dev/null; then
    systemctl restart wg-quick@wg-users || true
  elif command -v wg-quick >/dev/null 2>&1; then
    wg-quick down wg-users 2>/dev/null || true
    wg-quick up wg-users 2>/dev/null || true
  fi
}

apply_wg_users_all_entry_nodes() {
  local id
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    apply_wg_users_live_for_node "$id"
  done < <(awk -F'|' 'NR>1 && $2=="entry-exit" {print $1}' "$NODES_DB")
}

resync_wg_users_local() {
  sanitize_nodes_db
  apply_wg_users_all_entry_nodes
  msg "Для каждой entry-ноды проверено: если это текущий сервер (ключ wg-users), /etc/wireguard/wg-users.conf перезаписан из $SERVER_PEERS_DIR и wg-quick перезапущен."
}

rebuild_all_server_peers_from_clients_db() {
  local id role usub vlan c1 di c3 dev_name priv pub octet cr
  mkdir -p "$SERVER_PEERS_DIR"
  while IFS='|' read -r id role _; do
    [[ "$role" == "entry-exit" ]] || continue
    : >"$SERVER_PEERS_DIR/$id.peers.conf"
  done < <(awk -F'|' 'NR>1 {print $1"|"$2}' "$NODES_DB")

  [[ -f "$CLIENTS_DB" ]] || return 0
  [[ "$(wc -l <"$CLIENTS_DB")" -ge 2 ]] || return 0

  while IFS='|' read -r c1 di c3 dev_name priv pub octet cr; do
    [[ -n "$pub" ]] || continue
    [[ "$octet" =~ ^[0-9]+$ ]] || continue
    while IFS='|' read -r id role; do
      [[ "$role" == "entry-exit" ]] || continue
      usub="$(get_node_field "$id" 12)"
      if [[ "$usub" =~ ^10\.88\.([0-9]+)\.0/24$ ]]; then
        vlan="${BASH_REMATCH[1]}"
        cat >>"$SERVER_PEERS_DIR/$id.peers.conf" <<EOF
[Peer]
# ${dev_name}
PublicKey = ${pub}
AllowedIPs = 10.88.${vlan}.${octet}/32

EOF
      fi
    done < <(awk -F'|' 'NR>1 {print $1"|"$2}' "$NODES_DB")
  done < <(tail -n +2 "$CLIENTS_DB")
}

repair_peers_and_wg_users_from_db() {
  sanitize_nodes_db
  rebuild_all_server_peers_from_clients_db
  apply_wg_users_all_entry_nodes
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

cloud_prep_apt() {
  log "Подготовка apt: grub-pc без установки в недоступный диск (типично QEMU/VPS)…"
  if command -v debconf-set-selections >/dev/null 2>&1; then
    printf '%s\n' 'grub-pc grub-pc/install_devices_empty boolean true' | debconf-set-selections || true
  fi
  if command -v debconf-communicate >/dev/null 2>&1; then
    debconf-communicate grub-pc >/dev/null 2>&1 <<'DCF' || true
SET grub-pc/install_devices_empty true
DCF
  fi
  if dpkg -s grub-pc &>/dev/null; then
    DEBIAN_FRONTEND=noninteractive dpkg --configure grub-pc 2>/dev/null || true
  fi
  DEBIAN_FRONTEND=noninteractive dpkg --configure -a 2>/dev/null || true
  apt-get install -y -f 2>/dev/null || true
}

[[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Требуется root."
OS_VER="$(. /etc/os-release && echo "${VERSION_ID:-}")"
[[ "$OS_VER" == "13" ]] || die "Поддерживается только Debian 13."

export DEBIAN_FRONTEND=noninteractive
cloud_prep_apt
apt-get update -y
cloud_prep_apt
if ! apt-get install -y wireguard-tools nftables iproute2; then
  log "Повтор apt после доп. попытки grub-pc…"
  cloud_prep_apt
  apt-get install -y wireguard-tools nftables iproute2
fi

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
# onlink: шлюз в /32-туннеле иначе ядро даёт «Nexthop has invalid gateway»
ip route replace default via 10.77.0.11 dev wg-backbone onlink table 101
ip route replace default via 10.77.0.12 dev wg-backbone onlink table 102
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

  ui_print "${C_DIM}Ключи генерируются на хабе: локальный bootstrap-*.sh и файл join-*.bash (для scripts/node-join.sh из Git). На VPS удобнее curl+join; bootstrap остаётся как один самодостаточный .sh.${C_RESET}"
  ui_pause
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
  else
    bb_ip="$(allocate_bb_for_exit_only)"
    upsert_node "$node_id|exit-only|no|$fqdn|$public_ip|$iface|$bb_ip|$bb_port|$bb_priv|$bb_pub|||0|$now"
  fi

  regenerate_all_bootstraps_and_bundles
  ui_print "${C_OK}Нода ${node_id} добавлена.${C_RESET}"
  if [[ "$role" == "entry-exit" ]]; then
    ui_print "entry-exit · backbone ${bb_ip} · users ${users_ip_cidr} · wg-users UDP ${users_port}"
  else
    ui_print "exit-only · backbone ${bb_ip} · backbone UDP ${bb_port}"
  fi
  ui_print "Публичный ключ backbone: ${bb_pub}"
  ui_print "Артефакты: ${BOOTSTRAP_DIR}/bootstrap-${node_id}.sh · ${JOIN_BUNDLE_DIR}/join-${node_id}.bash"
  print_join_instructions_tty "$node_id"
  prompt_apply_local_bootstrap_if_needed
  wait_for_node_peer_connected "$node_id"
}

create_client() {
  local client_name count i octet now dev_name keys dev_priv dev_pub msk1_id msk2_id msk1_ep msk2_ep msk1_port msk2_port
  local dir ip1 ip2 msk1_pub msk2_pub msk2_net vlan2 dual_entry tty
  tty="$(ui_tty)"
  client_name="$(input "Клиент" "Имя клиента (латиницей)" "")"
  {
    printf '%b\n' "${C_HEAD}Сколько устройств?${C_RESET}"
    printf '%s\n' "  1) Одно устройство"
    printf '%s\n' "  2) Два устройства"
    printf '%b' "${C_DIM}Пункт: ${C_RESET}"
  } >"$tty"
  read -r count <"$tty" || count="1"
  [[ "$count" =~ ^[12]$ ]] || count="1"
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
    fi

    printf '%s|%s|%s|%s|%s|%s|%s|%s\n' "$client_name" "$i" "$client_name" "$dev_name" "$dev_priv" "$dev_pub" "$octet" "$now" >>"$CLIENTS_DB"

    octet=$((octet + 1))
  done
  save_meta_octet "$octet"
  repair_peers_and_wg_users_from_db
  present_client_artifacts "$client_name"
  if [[ "$dual_entry" -eq 1 ]]; then
    msg "MSK-1 + резерв MSK-GAMING. wg-users обновлён на подходящих нодах.\nUDP wg-users откройте в фаерволе облака."
  else
    msg "Только MSK-1. Если трафик не идёт: UDP $(get_node_field "$msk1_id" 13) у провайдера, nftables, bootstrap msk-1."
  fi
}

present_client_artifacts() {
  local name="$1" tmp f list_png
  tmp="$(mktemp)"
  : >"$tmp"
  while IFS= read -r f; do
    printf '\n# ----- %s -----\n\n' "$(basename "$f")" >>"$tmp"
    cat "$f" >>"$tmp"
    printf '\n' >>"$tmp"
    if command -v qrencode >/dev/null 2>&1; then
      qrencode -t PNG -o "${f%.conf}.png" <"$f" 2>/dev/null || true
    fi
  done < <(find "$CLIENTS_DIR/$name" -name '*.conf' -type f 2>/dev/null | sort)

  if [[ ! -s "$tmp" ]]; then
    rm -f "$tmp"
    msg "Нет .conf для клиента $name"
    return
  fi
  dump_text_to_console "Клиент $name — WireGuard .conf" "$tmp"
  rm -f "$tmp"

  list_png="$(find "$CLIENTS_DIR/$name" -maxdepth 3 -name '*.png' -type f 2>/dev/null | sort | tr '\n' ' ')"
  msg "Файлы:\n$CLIENTS_DIR/$name/\n\nQR (PNG), откройте на сервере или scp:\n${list_png:-—}"
}

browse_client_config_ui() {
  local name i sel f tmp tty
  tty="$(ui_tty)"
  name="$(pick_client_name_interactive "Просмотр конфига" "Выберите клиента")" || return
  [[ -n "$name" ]] || return
  if [[ ! -d "$CLIENTS_DIR/$name" ]]; then
    msg "Нет каталога: $CLIENTS_DIR/$name"
    return
  fi

  mapfile -t _client_confs < <(find "$CLIENTS_DIR/$name" -name '*.conf' -type f | sort)
  if [[ "${#_client_confs[@]}" -eq 0 ]]; then
    msg "В каталоге нет .conf"
    return
  fi

  if [[ "${#_client_confs[@]}" -eq 1 ]]; then
    f="${_client_confs[0]}"
  else
    {
      printf '%b\n' "${C_HEAD}Выберите файл конфига${C_RESET}"
      for i in "${!_client_confs[@]}"; do
        printf '%3s) %s\n' "$i" "$(basename "${_client_confs[$i]}")"
      done
      printf '%b' "${C_DIM}Номер: ${C_RESET}"
    } >"$tty"
    read -r sel <"$tty" || return
    [[ "$sel" =~ ^[0-9]+$ ]] && [[ "$sel" -ge 0 && "$sel" -lt "${#_client_confs[@]}" ]] || return
    f="${_client_confs[$sel]}"
  fi

  if command -v qrencode >/dev/null 2>&1; then
    qrencode -t PNG -o "${f%.conf}.png" <"$f" 2>/dev/null || true
  fi
  tmp="$(mktemp)"
  cat "$f" >"$tmp"
  dump_text_to_console "$(basename "$f")" "$tmp"
  rm -f "$tmp"
  msg "Полный путь конфига:\n$f\n\nQR PNG:\n${f%.conf}.png"
}

list_clients_menu() {
  local tmp nlines
  tmp="$(mktemp)"
  nlines="$(awk -F'|' 'NR>1' "$CLIENTS_DB" 2>/dev/null | wc -l)"
  nlines="${nlines//[[:space:]]/}"
  {
    echo "Всего записей устройств в базе: ${nlines:-0}"
    echo "Файл: $CLIENTS_DB"
    echo "Каталог конфигов: $CLIENTS_DIR"
    echo
    echo "имя_клиента | устройство | октет | создано"
    echo "----------------------------------------------------------------"
    awk -F'|' 'NR>1 { printf "%-18s %-22s %-6s %s\n", $1, $4, $7, $8 }' "$CLIENTS_DB" 2>/dev/null || true
    echo
    echo "Каталоги (по одному на клиента):"
    ls -1 "$CLIENTS_DIR" 2>/dev/null || echo "(пусто)"
  } >"$tmp"
  if command -v less >/dev/null 2>&1; then
    LESS="${LESS:-} -R" less -FX "$tmp"
  else
    cat "$tmp"
    ui_pause
  fi
  rm -f "$tmp"
}

pick_client_name_interactive() {
  local title="$1" subtitle="$2" dirs d nconf sel i tty
  tty="$(ui_tty)"
  mapfile -t dirs < <(ls -1 "$CLIENTS_DIR" 2>/dev/null | sort)
  if [[ "${#dirs[@]}" -eq 0 ]]; then
    ui_print "${C_WARN}Пока нет клиентов.${C_RESET}
${CLIENTS_DIR} пуст.

Создайте клиента: п.1 в этом меню."
    ui_pause
    return 1
  fi
  {
    printf '%b\n' "${C_HEAD}$title${C_RESET}"
    printf '%s\n' "$subtitle"
    printf '%s\n' ""
    i=0
    for d in "${dirs[@]}"; do
      nconf="$(find "$CLIENTS_DIR/$d" -name '*.conf' -type f 2>/dev/null | wc -l)"
      nconf="${nconf//[[:space:]]/}"
      printf '%3s) %s  (%s .conf)\n' "$i" "$d" "$nconf"
      i=$((i + 1))
    done
    printf '%3s) %s\n' "m" "Ввести имя каталога вручную…"
    printf '%b' "${C_DIM}Номер, имя каталога или m: ${C_RESET}"
  } >"$tty"
  read -r sel <"$tty" || return 1
  if [[ "${sel,,}" == "m" ]]; then
    input "Клиент" "Имя каталога (латиницей)" ""
    return 0
  fi
  if [[ "$sel" =~ ^[0-9]+$ ]] && [[ "$sel" -ge 0 && "$sel" -lt "${#dirs[@]}" ]]; then
    printf '%s' "${dirs[$sel]}"
    return 0
  fi
  printf '%s' "$sel"
}

delete_client_ui() {
  sanitize_nodes_db
  local name tmp
  name="$(pick_client_name_interactive "Удалить клиента" "Все устройства этого клиента исчезнут из базы и с диска.")" || return
  [[ -n "$name" ]] || return
  if ! confirm_yes "Удалить клиента «$name»?

Из clients.db, каталога и пиров (пересборка из оставшихся записей).
На другой entry-VPS: скопируйте state/ или повторите удаление/синхронизацию там."; then
    return
  fi
  tmp="$(mktemp)"
  awk -F'|' -v n="$name" 'NR==1 || $1!=n' "$CLIENTS_DB" >"$tmp"
  mv "$tmp" "$CLIENTS_DB"
  rm -rf "${CLIENTS_DIR:?}/$name"
  repair_peers_and_wg_users_from_db
  msg "Клиент «$name» удалён.\nПиры пересобраны из clients.db; wg-users на этой машине обновлён (если ключ совпадает с entry-нодой)."
}

export_client_archive_ui() {
  local name out
  name="$(pick_client_name_interactive "Экспорт" "Будет создан архив в output/")" || return
  [[ -n "$name" ]] || return
  out="$OUTPUT_DIR/client-${name}-$(date +%Y%m%d-%H%M%S).tar.gz"
  tar -czf "$out" -C "$CLIENTS_DIR" "$name"
  msg "Готово:\n$out\n\nСкопировать: scp root@VPS:$out ."
}

menu_clients_repair_from_db() {
  if ! confirm_yes "Пересобрать $SERVER_PEERS_DIR/*.conf из clients.db и перезаписать wg-users на этом сервере (для entry-нод с совпадающим ключом)?"; then
    return
  fi
  repair_peers_and_wg_users_from_db
  msg "Пиры заново собраны из clients.db, wg-users перезапущен где применимо."
}

open_lists_hint() {
  msg "Редактируйте файлы:\n$LISTS_DIR/fra_domains.txt\n$LISTS_DIR/fra_ips.txt\n$LISTS_DIR/ams_domains.txt\n$LISTS_DIR/ams_ips.txt\n\nПосле редактирования запустите ваш deploy hook."
}

regenerate_bootstrap() {
  regenerate_all_bootstraps_and_bundles
  msg "Пересозданы: $BOOTSTRAP_DIR и $JOIN_BUNDLE_DIR"
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
  local rep hs now local_pub wg_ok wg_iface ts ep tun pingst lhs age ping_target
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

  ts="$(date -u '+%Y-%m-%d %H:%M UTC')"

  {
    printf '\n'
    printf '  +============================================================================================+\n'
    printf '  |  %-88s  |\n' "СТАТУС НОД  ·  $ts"
    printf '  +--------------------------------------------------------------------------------------------+\n'
    if [[ "$wg_ok" -eq 1 ]]; then
      printf '  |  %-88s  |\n' "WireGuard: $wg_iface  ·  онлайн по туннелю = рукопожатие не старше 3 мин"
    else
      printf '  |  %-88s  |\n' "WireGuard не найден на этой машине — колонка «Туннель» пустая; смотрите ICMP."
    fi
    printf '  |  %-88s  |\n' "ICMP: один ping; если ICMP режут, «нет» здесь не значит, что WG мёртв."
    printf '  +============================================================================================+\n'
    printf '\n'
    printf '  Ноды:\n\n'
    printf '  +--------------+-------------+--------------------+---------+------------------------------------+\n'
    printf '  | %-12s | %-11s | %-18s | %-7s | %-34s |\n' "Нода" "Роль" "Туннель" "ICMP" "Endpoint"
    printf '  +--------------+-------------+--------------------+---------+------------------------------------+\n'
    while IFS='|' read -r id role _ fqdn pip _ _ _ _ pub _ _ _ _; do
      [[ -n "$id" ]] || continue
      tun=""
      pingst=""
      lhs=""
      age=0

      if [[ "$wg_ok" -eq 1 && -n "$local_pub" && "$pub" == "$local_pub" ]]; then
        tun="эта машина"
      elif [[ "$wg_ok" -ne 1 ]]; then
        tun="—"
      else
        lhs="$(awk -F'\t' -v p="$pub" '$1 == p { print $2; exit }' "$hs")"
        if [[ -z "$lhs" ]]; then
          tun="нет peer"
        elif [[ "$lhs" -eq 0 ]]; then
          tun="нет HS"
        else
          age=$((now - lhs))
          if [[ "$age" -le 180 ]]; then
            tun="онлайн ${age}с"
          else
            tun="давно ${age}с"
          fi
        fi
      fi

      ping_target="${pip:-$fqdn}"
      if [[ -z "$ping_target" ]]; then
        pingst="—"
      elif command -v ping >/dev/null 2>&1; then
        if ping -c 1 -W 2 -q "$ping_target" &>/dev/null; then
          pingst="есть"
        else
          pingst="нет"
        fi
      else
        pingst="n/a"
      fi

      ep="$ping_target"
      [[ ${#ep} -gt 34 ]] && ep="${ep:0:33}…"
      [[ ${#id} -gt 12 ]] && id="${id:0:11}…"
      [[ ${#role} -gt 11 ]] && role="${role:0:10}…"
      [[ ${#tun} -gt 18 ]] && tun="${tun:0:17}…"

      printf '  | %-12s | %-11s | %-18s | %-7s | %-34s |\n' "$id" "$role" "$tun" "$pingst" "$ep"
    done < <(tail -n +2 "$NODES_DB")

    printf '  +--------------+-------------+--------------------+---------+------------------------------------+\n'
    printf '\n  Источник: %s\n\n' "$NODES_DB"
  } >"$rep"

  if command -v less >/dev/null 2>&1; then
    LESS="${LESS:-} -R" less -FX "$rep"
  else
    cat "$rep"
    ui_pause
  fi
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
  write_join_bundle_for_node "msk-1"
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
      2) menu_nodes ;;
      3) menu_clients ;;
      4) open_lists_hint ;;
      5) menu_service ;;
      0) exit 0 ;;
      *) ;;
    esac
  done
}

main "$@"
