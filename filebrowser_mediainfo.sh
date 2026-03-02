#!/usr/bin/env bash
set -euo pipefail

# FileBrowser + MediaInfo (Docker) installer for Debian/Ubuntu
# - Installs Docker if missing
# - Installs Nginx + Python3 + MediaInfo on host
# - Runs FileBrowser in Docker and injects a custom frontend popup for MediaInfo
# - Exposes /api/mi for frontend calls

FB_PORT="${FB_PORT:-9091}"
FB_INTERNAL_PORT="${FB_INTERNAL_PORT:-18081}"
FB_ROOT="${FB_ROOT:-/srv}"
FB_DATA_DIR="${FB_DATA_DIR:-/opt/filebrowser}"
FB_IMAGE="${FB_IMAGE:-filebrowser/filebrowser:s6}"
FB_CONTAINER="${FB_CONTAINER:-filebrowser}"
MI_PORT="${MI_PORT:-19090}"
SS_PORT="${SS_PORT:-19190}"
HOST_DL="${HOST_DL:-/home/admin/qbittorrent/Downloads}"
SRV_DL="${SRV_DL:-/srv/dl}"

ASP_MEDIAINFO_URL="https://raw.githubusercontent.com/TGRonin/Auto-Seedbox-PT/main/asp-mediainfo.js"
ASP_SCREENSHOT_URL="https://raw.githubusercontent.com/TGRonin/Auto-Seedbox-PT/main/asp-screenshot.js"
ASP_JS_PATH="/usr/local/bin/asp-mediainfo.js"
ASP_SS_PATH="/usr/local/bin/asp-screenshot.js"
SWAL_JS_PATH="/usr/local/bin/sweetalert2.all.min.js"
MI_API_PATH="/usr/local/bin/asp-mediainfo.py"
SS_API_PATH="/usr/local/bin/asp-screenshot.py"
SS_OUT_DIR="/usr/local/asp-ss"
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
  echo "安装宿主依赖 (nginx, python3, mediainfo, ffmpeg)..."
  apt-get update -y
  apt-get install -y nginx python3 mediainfo ffmpeg curl
}

prepare_dirs() {
  mkdir -p "${FB_DATA_DIR}"
  mkdir -p "${FB_ROOT}"
  mkdir -p "${HOST_DL}"
  mkdir -p "${SRV_DL}"
  mkdir -p "${SS_OUT_DIR}"

  if ! mountpoint -q "${SRV_DL}"; then
    mount --bind "${HOST_DL}" "${SRV_DL}"
  fi

  if ! grep -qs "^${HOST_DL} ${SRV_DL} " /etc/fstab; then
    echo "${HOST_DL} ${SRV_DL} none bind 0 0" >> /etc/fstab
  fi
}

write_frontend_assets() {
  curl -fsSL "${ASP_MEDIAINFO_URL}" -o "${ASP_JS_PATH}"
  curl -fsSL "${ASP_SCREENSHOT_URL}" -o "${ASP_SS_PATH}"
  curl -fsSL "https://cdn.jsdelivr.net/npm/sweetalert2@11/dist/sweetalert2.all.min.js" -o "${SWAL_JS_PATH}"

  chmod 644 "${ASP_JS_PATH}" "${ASP_SS_PATH}" "${SWAL_JS_PATH}"
}

setup_mediainfo_api() {
  cat > "${MI_API_PATH}" <<'EOF_PY'
import http.server, socketserver, urllib.parse, subprocess, json, os, sys

PORT = int(sys.argv[2])
BASE_DIR = sys.argv[1]
HOST_DL = sys.argv[3]
SRV_DL = sys.argv[4]

class Handler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == '/api/mi':
            query = urllib.parse.parse_qs(parsed.query)
            file_path = query.get('file', [''])[0].lstrip('/')
            full_path = os.path.abspath(os.path.join(BASE_DIR, file_path))

            if full_path.startswith(os.path.abspath(SRV_DL)):
                full_path = os.path.abspath(os.path.join(HOST_DL, os.path.relpath(full_path, SRV_DL)))

            if not full_path.startswith(os.path.abspath(BASE_DIR)) and not full_path.startswith(os.path.abspath(HOST_DL)):
                self.send_response(400)
                self.send_header('Content-Type', 'text/plain; charset=utf-8')
                self.end_headers()
                self.wfile.write('非法路径'.encode('utf-8'))
                return

            if not os.path.isfile(full_path):
                self.send_response(400)
                self.send_header('Content-Type', 'text/plain; charset=utf-8')
                self.end_headers()
                self.wfile.write('非法路径或文件不存在'.encode('utf-8'))
                return

            try:
                res = subprocess.run(['mediainfo', full_path], capture_output=True, text=True)
                output = res.stdout if res.stdout else res.stderr
                self.send_response(200)
                self.send_header('Content-Type', 'text/plain; charset=utf-8')
                self.end_headers()
                self.wfile.write(output.encode('utf-8', errors='ignore'))
            except Exception as e:
                self.send_response(500)
                self.send_header('Content-Type', 'text/plain; charset=utf-8')
                self.end_headers()
                self.wfile.write(str(e).encode('utf-8', errors='ignore'))
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
ExecStart=/usr/bin/python3 ${MI_API_PATH} "${FB_ROOT}" ${MI_PORT} "${HOST_DL}" "${SRV_DL}"
Restart=always
[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable asp-mediainfo.service >/dev/null 2>&1
  systemctl restart asp-mediainfo.service
}

setup_screenshot_api() {
  cat > "${SS_API_PATH}" <<'EOF_PY'
import http.server, socketserver, urllib.parse, subprocess, json, os, sys, time, hashlib, zipfile

PORT = int(sys.argv[2])
BASE_DIR = sys.argv[1]
HOST_DL = sys.argv[3]
SRV_DL = sys.argv[4]
OUT_DIR = sys.argv[5]


def json_response(handler, code, payload):
    data = json.dumps(payload, ensure_ascii=False)
    handler.send_response(code)
    handler.send_header('Content-Type', 'application/json; charset=utf-8')
    handler.end_headers()
    handler.wfile.write(data.encode('utf-8'))


def resolve_path(file_param):
    file_path = file_param.lstrip('/')
    full_path = os.path.abspath(os.path.join(BASE_DIR, file_path))

    if full_path.startswith(os.path.abspath(SRV_DL)):
        full_path = os.path.abspath(os.path.join(HOST_DL, os.path.relpath(full_path, SRV_DL)))

    if not full_path.startswith(os.path.abspath(BASE_DIR)) and not full_path.startswith(os.path.abspath(HOST_DL)):
        return None
    if not os.path.isfile(full_path):
        return None
    return full_path


def ffprobe_meta(full_path):
    try:
        cmd = [
            'ffprobe', '-v', 'error', '-print_format', 'json',
            '-show_entries', 'stream=width,height', '-show_entries', 'format=duration',
            '-select_streams', 'v:0', full_path
        ]
        res = subprocess.run(cmd, capture_output=True, text=True)
        if res.returncode != 0:
            return {'width': None, 'height': None, 'duration': None}
        data = json.loads(res.stdout or '{}')
        stream = (data.get('streams') or [{}])[0]
        duration = None
        fmt = data.get('format') or {}
        if 'duration' in fmt:
            try:
                duration = float(fmt.get('duration'))
            except Exception:
                duration = None
        return {
            'width': stream.get('width'),
            'height': stream.get('height'),
            'duration': duration
        }
    except Exception:
        return {'width': None, 'height': None, 'duration': None}


def safe_dir(full_path):
    h = hashlib.md5((full_path + str(time.time())).encode('utf-8')).hexdigest()[:10]
    return f"ss_{h}"


def take_screens(full_path, n, width, head, tail, fmt, need_zip):
    meta = ffprobe_meta(full_path)
    duration = meta.get('duration') or 0

    if duration <= 0:
        raise RuntimeError('无法读取视频时长')

    start = duration * (head / 100.0)
    end = duration * (1 - tail / 100.0)
    if end <= start:
        start = 0
        end = duration

    out_sub = safe_dir(full_path)
    out_path = os.path.join(OUT_DIR, out_sub)
    os.makedirs(out_path, exist_ok=True)

    files = []
    for i in range(n):
        ts = start + (end - start) * (i + 1) / (n + 1)
        name = f"{i + 1:02d}.{fmt}"
        out_file = os.path.join(out_path, name)
        cmd = [
            'ffmpeg', '-y', '-ss', str(ts), '-i', full_path,
            '-frames:v', '1', '-vf', f"scale={width}:-1", '-q:v', '2', out_file
        ]
        res = subprocess.run(cmd, capture_output=True, text=True)
        if res.returncode != 0:
            raise RuntimeError(res.stderr.strip() or 'ffmpeg 截图失败')
        files.append(name)

    zip_name = None
    if need_zip:
        zip_name = 'screenshots.zip'
        zip_path = os.path.join(out_path, zip_name)
        with zipfile.ZipFile(zip_path, 'w', compression=zipfile.ZIP_DEFLATED) as zf:
            for f in files:
                zf.write(os.path.join(out_path, f), arcname=f)

    return out_sub, files, zip_name, meta


class Handler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path != '/api/ss':
            self.send_response(404)
            self.end_headers()
            return

        query = urllib.parse.parse_qs(parsed.query)
        file_param = query.get('file', [''])[0]
        if not file_param:
            json_response(self, 400, {'error': '缺少 file 参数'})
            return

        full_path = resolve_path(file_param)
        if not full_path:
            json_response(self, 400, {'error': '非法路径或文件不存在'})
            return

        if query.get('probe', [''])[0] == '1':
            meta = ffprobe_meta(full_path)
            json_response(self, 200, {'meta': meta})
            return

        try:
            n = int(query.get('n', ['6'])[0])
        except Exception:
            n = 6
        try:
            width = int(query.get('width', ['1280'])[0])
        except Exception:
            width = 1280
        try:
            head = int(query.get('head', ['5'])[0])
        except Exception:
            head = 5
        try:
            tail = int(query.get('tail', ['5'])[0])
        except Exception:
            tail = 5
        fmt = (query.get('fmt', ['jpg'])[0] or 'jpg').lower()
        if fmt not in ('jpg', 'jpeg', 'png'):
            fmt = 'jpg'
        need_zip = query.get('zip', ['0'])[0] == '1'

        try:
            out_sub, files, zip_name, meta = take_screens(full_path, n, width, head, tail, fmt, need_zip)
            base = f"/asp-ss/{out_sub}/"
            payload = {"base": base, "files": files, "zip": zip_name, "meta": meta}
            json_response(self, 200, payload)
        except Exception as e:
            json_response(self, 500, {'error': str(e)})


socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("127.0.0.1", PORT), Handler) as httpd:
    httpd.serve_forever()
EOF_PY

  chmod +x "${SS_API_PATH}"

  cat > /etc/systemd/system/asp-screenshot.service <<EOF
[Unit]
Description=ASP Screenshot API Service
After=network.target
[Service]
Type=simple
User=root
ExecStart=/usr/bin/python3 ${SS_API_PATH} "${FB_ROOT}" ${SS_PORT} "${HOST_DL}" "${SRV_DL}" "${SS_OUT_DIR}"
Restart=always
[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable asp-screenshot.service >/dev/null 2>&1
  systemctl restart asp-screenshot.service
}

patch_nginx() {
  if [ -z "${NGINX_CONF}" ] || [ ! -f "${NGINX_CONF}" ]; then
    echo "未找到 Nginx 配置文件: ${NGINX_CONF:-<空>}，跳过路由注入。"
    return 0
  fi

  python3 - "${NGINX_CONF}" "${MI_PORT}" "${SS_PORT}" "${SS_OUT_DIR}" "${ASP_JS_PATH}" "${ASP_SS_PATH}" "${SWAL_JS_PATH}" <<'PY'
import io
import os
import sys

conf = sys.argv[1] if len(sys.argv) > 1 and sys.argv[1] else '/etc/nginx/conf.d/asp-filebrowser.conf'
mi_port = sys.argv[2] if len(sys.argv) > 2 and sys.argv[2] else '19090'
ss_port = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] else '19190'
ss_out = sys.argv[4] if len(sys.argv) > 4 and sys.argv[4] else '/usr/local/asp-ss'
mi_js_path = sys.argv[5] if len(sys.argv) > 5 and sys.argv[5] else '/usr/local/bin/asp-mediainfo.js'
ss_js_path = sys.argv[6] if len(sys.argv) > 6 and sys.argv[6] else '/usr/local/bin/asp-screenshot.js'
swal_js_path = sys.argv[7] if len(sys.argv) > 7 and sys.argv[7] else '/usr/local/bin/sweetalert2.all.min.js'

if not conf:
    print('NGINX_CONF 为空，跳过修改。')
    sys.exit(0)

with open(conf, 'r', encoding='utf-8') as f:
    data = f.read()

need_mi = 'location /api/mi' not in data
need_ss = 'location /api/ss' not in data
need_out = 'location /asp-ss/' not in data
need_mi_js = 'location = /asp-mediainfo.js' not in data
need_ss_js = 'location = /asp-screenshot.js' not in data
need_swal_js = 'location = /sweetalert2.all.min.js' not in data
need_pixhost = 'location /api/pixhost' not in data

if not (need_mi or need_ss or need_out or need_mi_js or need_ss_js or need_swal_js or need_pixhost):
    print('Nginx 已包含 /api/mi、/api/ss、/asp-ss、/asp-mediainfo.js、/asp-screenshot.js、/sweetalert2.all.min.js、/api/pixhost 配置，无需修改。')
    sys.exit(0)

snippet = '\n'
if need_mi:
    snippet += f"    location /api/mi {{\n        proxy_pass http://127.0.0.1:{mi_port};\n    }}\n\n"
if need_ss:
    snippet += f"    location /api/ss {{\n        proxy_pass http://127.0.0.1:{ss_port};\n    }}\n\n"
if need_out:
    snippet += f"    location /asp-ss/ {{\n        alias {ss_out}/;\n        add_header Cache-Control \"no-store\";\n    }}\n\n"
if need_mi_js:
    snippet += f"    location = /asp-mediainfo.js {{\n        alias {mi_js_path};\n        add_header Content-Type \"application/javascript; charset=utf-8\";\n    }}\n\n"
if need_ss_js:
    snippet += f"    location = /asp-screenshot.js {{\n        alias {ss_js_path};\n        add_header Content-Type \"application/javascript; charset=utf-8\";\n    }}\n\n"
if need_swal_js:
    snippet += f"    location = /sweetalert2.all.min.js {{\n        alias {swal_js_path};\n        add_header Content-Type \"application/javascript; charset=utf-8\";\n    }}\n\n"
if need_pixhost:
    snippet += "    location /api/pixhost {\n        proxy_pass https://pixhost.to/remote/;\n        proxy_set_header Host pixhost.to;\n        proxy_set_header Referer https://pixhost.to/;\n        proxy_set_header Origin https://pixhost.to;\n    }\n\n"

idx = data.rfind('}')
if idx == -1:
    print('Nginx 配置格式异常，未找到结尾 }，跳过修改。')
    sys.exit(1)

new_data = data[:idx] + snippet + data[idx:]
with open(conf, 'w', encoding='utf-8') as f:
    f.write(new_data)

print('已更新 Nginx 配置，注入 /api/mi /api/ss /asp-ss /asp-mediainfo.js /asp-screenshot.js /sweetalert2.all.min.js /api/pixhost。')
PY

  nginx -t
  systemctl reload nginx
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

    location /api/ss {
        proxy_pass http://127.0.0.1:${SS_PORT};
    }

    location /api/pixhost {
        proxy_pass https://pixhost.to/remote/;
        proxy_set_header Host pixhost.to;
        proxy_set_header Referer https://pixhost.to/;
        proxy_set_header Origin https://pixhost.to;
    }

    location /asp-ss/ {
        alias ${SS_OUT_DIR}/;
        add_header Cache-Control "no-store";
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

已在 FileBrowser 页面注入 MediaInfo / Screenshot 弹窗按钮（右键或选中文件菜单）。
API: /api/mi 与 /api/ss 由宿主机 Python 服务提供。
说明: 已内置 /api/pixhost 反向代理用于绕过 CORS。

已将 /home/admin/qbittorrent/Downloads 绑定挂载到宿主 /srv/dl，并映射到容器内 /srv/dl。

可选环境变量:
  FB_PORT          - 访问端口 (默认 8080)
  FB_INTERNAL_PORT - FileBrowser 容器内部转发端口 (默认 18081)
  FB_ROOT          - 文件根目录 (默认 /srv)
  FB_DATA_DIR      - 持久化数据目录 (默认 /opt/filebrowser)
  FB_IMAGE         - 镜像名 (默认 filebrowser/filebrowser:s6)
  FB_CONTAINER     - 容器名 (默认 filebrowser)
  MI_PORT          - MediaInfo API 端口 (默认 19090)
  SS_PORT          - Screenshot API 端口 (默认 19190)
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
  setup_screenshot_api
  run_container
  setup_nginx
  patch_nginx
  print_info
}

main "$@"
