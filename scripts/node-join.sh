#!/usr/bin/env bash
# Универсальная настройка ноды из репозитория wg-hub.
# На VPS: скопируйте join-*.bash с хаба, затем:
#   curl -fsSL '<RAW_URL>/scripts/node-join.sh' -o /tmp/node-join.sh && chmod +x /tmp/node-join.sh
#   sudo bash /tmp/node-join.sh /root/join-<id>.bash
set -euo pipefail
export LC_ALL=C.UTF-8 LANG=C.UTF-8

log() { printf '[node-join] %s\n' "$*"; }
die() { printf '[node-join][error] %s\n' "$*" >&2; exit 1; }

usage() {
  printf '%s\n' "Использование: $0 /path/to/join-<node>.bash" >&2
  printf '%s\n' "Файл bundle генерируется на хабе (wg-hub) и содержит ключи и параметры ноды." >&2
  exit 1
}

[[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Требуется root."
[[ "${#}" -eq 1 ]] || usage
bundle_path="$1"
[[ -f "$bundle_path" ]] || die "Нет файла: $bundle_path"

# shellcheck disable=SC1090
source "$bundle_path"

[[ "${WG_JOIN_SCHEMA:-0}" == "1" ]] || die "Устаревший или битый bundle (нет WG_JOIN_SCHEMA=1)."
[[ -n "${WG_JOIN_ROLE:-}" ]] || die "В bundle нет WG_JOIN_ROLE."
[[ -n "${WG_JOIN_NODE_ID:-}" ]] || die "В bundle нет WG_JOIN_NODE_ID."

OS_VER="$(. /etc/os-release && echo "${VERSION_ID:-}")"
[[ "$OS_VER" == "13" ]] || die "Поддерживается только Debian 13 (сейчас: ${OS_VER:-unknown})."

decode64() {
  local s="$1"
  [[ -n "$s" ]] || { printf '%s' ''; return 0; }
  printf '%s' "$s" | base64 -d
}

WG_JOIN_BACKBONE_PEERS="$(decode64 "$WG_JOIN_BACKBONE_PEERS_B64")"
if [[ "${WG_JOIN_ROLE}" == "entry-exit" ]]; then
  WG_JOIN_USERS_PEERS="$(decode64 "${WG_JOIN_USERS_PEERS_B64:-}")"
  WG_JOIN_POLICY_ROUTES="$(decode64 "${WG_JOIN_POLICY_ROUTES_B64:-}")"
fi

export DEBIAN_FRONTEND=noninteractive

# Облачные VPS: незавершённый grub-pc ломает любой apt (нет диска для grub-install).
pre_apt_unstick_dpkg() {
  local fix=0
  dpkg --audit 2>/dev/null | grep -q . && fix=1
  if dpkg -l grub-pc 2>/dev/null | grep -qE '^.. +(iF|iU)'; then
    fix=1
  fi
  [[ "$fix" -eq 1 ]] || return 0
  log "Зависший dpkg (часто grub-pc на VPS) — пробуем безопасное завершение настройки…"
  if command -v debconf-set-selections >/dev/null 2>&1; then
    printf '%s\n' 'grub-pc grub-pc/install_devices_empty boolean true' | debconf-set-selections || true
  fi
  DEBIAN_FRONTEND=noninteractive dpkg --configure -a || true
  apt-get install -y -f || true
}

pre_apt_unstick_dpkg
apt-get update -y
pre_apt_unstick_dpkg
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

cat >/etc/wireguard/wg-backbone.conf <<WGEOF
[Interface]
Address = ${WG_JOIN_BB_IP}/32
ListenPort = ${WG_JOIN_BB_PORT}
PrivateKey = ${WG_JOIN_BB_PRIV}

${WG_JOIN_BACKBONE_PEERS}
WGEOF

if [[ "${WG_JOIN_ROLE}" == "entry-exit" ]]; then
  cat >/etc/wireguard/wg-users.conf <<WGUEOF
[Interface]
Address = ${WG_JOIN_USERS_IP_CIDR}
ListenPort = ${WG_JOIN_USERS_PORT}
PrivateKey = ${WG_JOIN_USERS_PRIV}

${WG_JOIN_USERS_PEERS}
WGUEOF

  cat >/etc/nftables.d/90-wg-hub.nft <<NFEOF
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
    oifname "${WG_JOIN_IFACE}" ip saddr ${WG_JOIN_USERS_SUBNET} masquerade
  }
}
NFEOF
else
  cat >/etc/nftables.d/90-wg-hub.nft <<NFEOF
table inet wg_hub {
  chain postrouting_nat {
    type nat hook postrouting priority srcnat; policy accept;
    oifname "${WG_JOIN_IFACE}" ip saddr 10.88.0.0/16 masquerade
  }
}
NFEOF
fi

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

grep -q '/etc/nftables.d/\*\.nft' /etc/nftables.conf 2>/dev/null || echo 'include "/etc/nftables.d/*.nft"' >> /etc/nftables.conf
systemctl enable nftables

if [[ "${WG_JOIN_ROLE}" == "entry-exit" ]]; then
  systemctl enable wg-quick@wg-backbone wg-quick@wg-users
else
  systemctl enable wg-quick@wg-backbone
fi

systemctl restart nftables
systemctl restart wg-quick@wg-backbone
if [[ "${WG_JOIN_ROLE}" == "entry-exit" ]]; then
  systemctl restart wg-quick@wg-users
  if [[ -n "${WG_JOIN_POLICY_ROUTES}" ]]; then
    printf '%s\n' "$WG_JOIN_POLICY_ROUTES" | bash || true
  fi
fi

wg show || true
log "Готово: ${WG_JOIN_NODE_ID} (${WG_JOIN_FQDN})"
