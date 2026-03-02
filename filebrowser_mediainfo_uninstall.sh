#!/usr/bin/env bash
set -euo pipefail

# Uninstall script for filebrowser_mediainfo.sh
# - Stops/removes FileBrowser container and image
# - Removes ASP frontend assets and MediaInfo API service
# - Removes Nginx config injected by installer
# - Cleans bind mount and data directories
# - Optionally purges system packages installed by installer

FB_PORT="${FB_PORT:-8080}"
FB_INTERNAL_PORT="${FB_INTERNAL_PORT:-18081}"
FB_ROOT="${FB_ROOT:-/srv}"
FB_DATA_DIR="${FB_DATA_DIR:-/opt/filebrowser}"
FB_IMAGE="${FB_IMAGE:-filebrowser/filebrowser:s6}"
FB_CONTAINER="${FB_CONTAINER:-filebrowser}"
MI_PORT="${MI_PORT:-19090}"

ASP_JS_PATH="/usr/local/bin/asp-mediainfo.js"
ASP_SS_PATH="/usr/local/bin/asp-screenshot.js"
SWAL_JS_PATH="/usr/local/bin/sweetalert2.all.min.js"
MI_API_PATH="/usr/local/bin/asp-mediainfo.py"
NGINX_CONF="/etc/nginx/conf.d/asp-filebrowser.conf"
MI_SERVICE="asp-mediainfo.service"

HOST_DL="/home/admin/qbittorrent/Downloads"
SRV_DL="/srv/dl"

ensure_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "请使用 root 或 sudo 运行该脚本。" >&2
    exit 1
  fi
}

confirm() {
  local prompt="$1"
  local default_yes="$2"
  local reply=""

  if [ "${INTERACTIVE:-1}" = "0" ]; then
    return 0
  fi

  if [ -r /dev/tty ]; then
    read -r -p "${prompt} [${default_yes}] " reply < /dev/tty || true
  elif [ -t 0 ]; then
    read -r -p "${prompt} [${default_yes}] " reply || true
  fi

  if [ -z "${reply}" ]; then
    reply="${default_yes}"
  fi

  case "${reply}" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

stop_remove_container() {
  if command -v docker >/dev/null 2>&1; then
    if docker ps -a --format '{{.Names}}' | grep -q "^${FB_CONTAINER}$"; then
      docker rm -f "${FB_CONTAINER}" || true
    fi

    if docker image inspect "${FB_IMAGE}" >/dev/null 2>&1; then
      docker image rm -f "${FB_IMAGE}" || true
    fi
  fi
}

remove_services() {
  if systemctl list-unit-files | grep -q "^${MI_SERVICE}"; then
    systemctl stop "${MI_SERVICE}" || true
    systemctl disable "${MI_SERVICE}" >/dev/null 2>&1 || true
  fi
  rm -f "/etc/systemd/system/${MI_SERVICE}"
  systemctl daemon-reload || true
}

remove_nginx_conf() {
  rm -f "${NGINX_CONF}"
  if systemctl is-active --quiet nginx; then
    systemctl reload nginx || systemctl restart nginx || true
  fi
}

remove_assets() {
  rm -f "${ASP_JS_PATH}" "${ASP_SS_PATH}" "${SWAL_JS_PATH}" "${MI_API_PATH}"
}

remove_mounts_and_data() {
  if mountpoint -q "${SRV_DL}"; then
    umount "${SRV_DL}" || true
  fi

  if [ -f /etc/fstab ]; then
    tmp_file="$(mktemp)"
    grep -v -F "${HOST_DL} ${SRV_DL} " /etc/fstab > "${tmp_file}" || true
    cat "${tmp_file}" > /etc/fstab
    rm -f "${tmp_file}"
  fi

  rm -rf "${SRV_DL}"
  rm -rf "${FB_DATA_DIR}"

  rmdir "${FB_ROOT}" 2>/dev/null || true
}

purge_packages() {
  apt-get update -y
  apt-get purge -y nginx python3 mediainfo curl \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || true
  apt-get autoremove -y || true

  rm -f /etc/apt/sources.list.d/docker.list
  rm -f /etc/apt/keyrings/docker.gpg
}

main() {
  ensure_root

  if ! confirm "将删除 FileBrowser/MediaInfo 相关配置与数据，继续吗？" "Y/n"; then
    echo "已取消。"
    exit 0
  fi

  stop_remove_container
  remove_services
  remove_nginx_conf
  remove_assets
  remove_mounts_and_data

  if confirm "是否卸载系统软件包 (Docker/Nginx/Python3/MediaInfo/Curl)？" "Y/n"; then
    purge_packages
  fi

  echo "卸载完成。"
}

main "$@"
