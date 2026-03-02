#!/usr/bin/env bash
set -euo pipefail

# FileBrowser + MediaInfo (Docker) installer for Debian/Ubuntu
# - Installs Docker if missing
# - Installs Nginx + Python3 + MediaInfo on host
# - Runs FileBrowser in Docker and injects a custom frontend popup for MediaInfo
# - Exposes /api/mi for frontend calls

FB_PORT="${FB_PORT:-8080}"
FB_INTERNAL_PORT="${FB_INTERNAL_PORT:-18081}"
FB_ROOT="${FB_ROOT:-/srv}"
FB_DATA_DIR="${FB_DATA_DIR:-/opt/filebrowser}"
FB_IMAGE="${FB_IMAGE:-filebrowser/filebrowser:s6}"
FB_CONTAINER="${FB_CONTAINER:-filebrowser}"
MI_PORT="${MI_PORT:-19090}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASP_JS_PATH="/usr/local/bin/asp-mediainfo.js"
ASP_SS_PATH="/usr/local/bin/asp-screenshot.js"
SWAL_JS_PATH="/usr/local/bin/sweetalert2.all.min.js"
MI_API_PATH="/usr/local/bin/asp-mediainfo.py"
NGINX_CONF="/etc/nginx/conf.d/asp-filebrowser.conf"

is_valid_port() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge 1 ] && [ "$p" -le 65535 ]
}

prompt_var() {
  local var_name="$1"
  local default_val="$2"
  local prompt="$3"
  local input=""

  if [ "${INTERACTIVE:-1}" = "0" ]; then
    return 0
  fi

  if [ -r /dev/tty ]; then
    read -r -p "${prompt}（默认为${default_val}）: " input < /dev/tty || true
  elif [ -t 0 ]; then
    read -r -p "${prompt}（默认为${default_val}）: " input || true
  fi

  if [ -n "${input}" ]; then
    printf -v "${var_name}" '%s' "${input}"
  fi
}

configure_ports() {
  local default_fb_port="${FB_PORT}"
  local default_internal_port="${FB_INTERNAL_PORT}"
  local default_mi_port="${MI_PORT}"

  prompt_var FB_PORT "${default_fb_port}" "请输入访问端口"
  if ! is_valid_port "${FB_PORT}"; then
    echo "端口 ${FB_PORT} 非法，回退为默认值 ${default_fb_port}" >&2
    FB_PORT="${default_fb_port}"
  fi

  prompt_var FB_INTERNAL_PORT "${default_internal_port}" "请输入 FileBrowser 内部转发端口"
  if ! is_valid_port "${FB_INTERNAL_PORT}"; then
    echo "端口 ${FB_INTERNAL_PORT} 非法，回退为默认值 ${default_internal_port}" >&2
    FB_INTERNAL_PORT="${default_internal_port}"
  fi

  prompt_var MI_PORT "${default_mi_port}" "请输入 MediaInfo API 端口"
  if ! is_valid_port "${MI_PORT}"; then
    echo "端口 ${MI_PORT} 非法，回退为默认值 ${default_mi_port}" >&2
    MI_PORT="${default_mi_port}"
  fi
}

ensure_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "请使用 root 或 sudo 运行该脚本。" >&2
    exit 1
  fi
}

install_docker() {
  if command -v docker >/dev/null 2>&1; then
    return 0
  fi

  echo "未检测到 Docker，开始安装..."
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg lsb-release
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo \"$VERSION_CODENAME\") stable" \
    | tee /etc/apt/sources.list.d/docker.list >/dev/null
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

install_host_deps() {
  echo "安装宿主依赖 (nginx, python3, mediainfo)..."
  apt-get update -y
  apt-get install -y nginx python3 mediainfo curl
}

prepare_dirs() {
  local host_dl="/home/admin/qbittorrent/Downloads"
  local srv_dl="/srv/dl"

  mkdir -p "${FB_DATA_DIR}"
  mkdir -p "${FB_ROOT}"
  mkdir -p "${host_dl}"
  mkdir -p "${srv_dl}"

  if ! mountpoint -q "${srv_dl}"; then
    mount --bind "${host_dl}" "${srv_dl}"
  fi

  if ! grep -qs "^${host_dl} ${srv_dl} " /etc/fstab; then
    echo "${host_dl} ${srv_dl} none bind 0 0" >> /etc/fstab
  fi
}

write_frontend_assets() {
  if [ ! -f "${SCRIPT_DIR}/asp-mediainfo.js" ] || [ ! -f "${SCRIPT_DIR}/asp-screenshot.js" ]; then
    echo "未找到 ${SCRIPT_DIR}/asp-mediainfo.js 或 ${SCRIPT_DIR}/asp-screenshot.js" >&2
    exit 1
  fi

  install -m 644 "${SCRIPT_DIR}/asp-mediainfo.js" "${ASP_JS_PATH}"
  install -m 644 "${SCRIPT_DIR}/asp-screenshot.js" "${ASP_SS_PATH}"

  curl -fsSL "https://cdn.jsdelivr.net/npm/sweetalert2@11/dist/sweetalert2.all.min.js" -o "${SWAL_JS_PATH}"
  chmod 644 "${SWAL_JS_PATH}"
}

setup_mediainfo_api() {
  cat > "${MI_API_PATH}" <<'EOF_PY'
import http.server, socketserver, urllib.parse, subprocess, json, os, sys

PORT = int(sys.argv[2])
BASE_DIR = sys.argv[1]

class Handler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == '/api/mi':
            query = urllib.parse.parse_qs(parsed.query)
            file_path = query.get('file', [''])[0].lstrip('/')
            full_path = os.path.abspath(os.path.join(BASE_DIR, file_path))

            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()

            if not full_path.startswith(os.path.abspath(BASE_DIR)) or not os.path.isfile(full_path):
                self.wfile.write(json.dumps({"error": "非法路径或文件不存在"}).encode('utf-8'))
                return

            try:
                res = subprocess.run(['mediainfo', '--Output=JSON', full_path], capture_output=True, text=True)
                try:
                    json.loads(res.stdout)
                    self.wfile.write(res.stdout.encode('utf-8'))
                    return
                except Exception:
                    pass

                res_text = subprocess.run(['mediainfo', full_path], capture_output=True, text=True)
                lines = res_text.stdout.split('\n')
                tracks = []
                current_track = {}
                for line in lines:
                    line = line.strip()
                    if not line:
                        if current_track:
                            tracks.append(current_track)
                            current_track = {}
                        continue
                    if ':' not in line and '@type' not in current_track:
                        current_track['@type'] = line
                    elif ':' in line:
                        k, v = line.split(':', 1)
                        current_track[k.strip()] = v.strip()
                if current_track:
                    tracks.append(current_track)

                self.wfile.write(json.dumps({"media": {"track": tracks}}).encode('utf-8'))

            except Exception as e:
                self.wfile.write(json.dumps({"error": str(e)}).encode('utf-8'))
        else:
            self.send_response(404)
            self.end_headers()

socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("127.0.0.1", PORT), Handler) as httpd:
    httpd.serve_forever()
EOF_PY

  chmod +x "${MI_API_PATH}"

  cat > /etc/systemd/system/asp-mediainfo.service <<EOF
[Unit]
Description=ASP MediaInfo API Service
After=network.target
[Service]
Type=simple
User=root
ExecStart=/usr/bin/python3 ${MI_API_PATH} "${FB_ROOT}" ${MI_PORT}
Restart=always
[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable asp-mediainfo.service >/dev/null 2>&1
  systemctl restart asp-mediainfo.service
}

setup_nginx() {
  if [ -f /etc/nginx/sites-enabled/default ]; then
    rm -f /etc/nginx/sites-enabled/default
  fi

  cat > "${NGINX_CONF}" <<EOF
server {
    listen ${FB_PORT};
    server_name _;
    client_max_body_size 0;

    location / {
        proxy_pass http://127.0.0.1:${FB_INTERNAL_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Accept-Encoding "";
        sub_filter '</body>' '<script src="/asp-mediainfo.js"></script><script src="/asp-screenshot.js"></script></body>';
        sub_filter_once on;
    }

    location = /asp-mediainfo.js {
        alias ${ASP_JS_PATH};
        add_header Content-Type "application/javascript; charset=utf-8";
    }
    location = /asp-screenshot.js {
        alias ${ASP_SS_PATH};
        add_header Content-Type "application/javascript; charset=utf-8";
    }
    location = /sweetalert2.all.min.js {
        alias ${SWAL_JS_PATH};
        add_header Content-Type "application/javascript; charset=utf-8";
    }

    location /api/mi {
        proxy_pass http://127.0.0.1:${MI_PORT};
    }
}
EOF

  systemctl restart nginx
}

run_container() {
  if docker ps -a --format '{{.Names}}' | grep -q "^${FB_CONTAINER}$"; then
    echo "发现已存在容器 ${FB_CONTAINER}，将先停止并删除..."
    docker rm -f "${FB_CONTAINER}"
  fi

  docker run -d \
    --name "${FB_CONTAINER}" \
    -p "127.0.0.1:${FB_INTERNAL_PORT}:80" \
    -v "${FB_ROOT}:/srv" \
    -v "/home/admin/qbittorrent/Downloads:/srv/dl" \
    -v "${FB_DATA_DIR}/filebrowser.db:/database.db" \
    -v "${FB_DATA_DIR}/settings.json:/settings.json" \
    --restart unless-stopped \
    "${FB_IMAGE}"
}

print_info() {
  cat <<EOF
安装完成。
访问地址: http://<服务器IP>:${FB_PORT}
默认账号: admin
默认密码: admin

已在 FileBrowser 页面注入 MediaInfo 弹窗按钮（右键或选中文件菜单）。
API: /api/mi 由宿主机 Python 服务提供。

已将 /home/admin/qbittorrent/Downloads 绑定挂载到宿主 /srv/dl，并映射到容器内 /srv/dl。

可选环境变量:
  FB_PORT          - 访问端口 (默认 8080)
  FB_INTERNAL_PORT - FileBrowser 容器内部转发端口 (默认 18081)
  FB_ROOT          - 文件根目录 (默认 /srv)
  FB_DATA_DIR      - 持久化数据目录 (默认 /opt/filebrowser)
  FB_IMAGE         - 镜像名 (默认 filebrowser/filebrowser:s6)
  FB_CONTAINER     - 容器名 (默认 filebrowser)
  MI_PORT          - MediaInfo API 端口 (默认 19090)
  INTERACTIVE      - 设为 0 可禁用交互提示
EOF
}

main() {
  ensure_root
  configure_ports
  install_docker
  install_host_deps
  prepare_dirs
  write_frontend_assets
  setup_mediainfo_api
  run_container
  setup_nginx
  print_info
}

main "$@"
