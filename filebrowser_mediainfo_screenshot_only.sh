#!/usr/bin/env bash
set -euo pipefail

# Deploy MediaInfo + Screenshot services only (no FileBrowser container)
# - Installs deps: nginx, python3, mediainfo, ffmpeg
# - Creates /api/mi and /api/ss Python services
# - Optionally patches existing Nginx config to add /api/mi /api/ss /asp-ss

FB_ROOT="${FB_ROOT:-/srv}"
HOST_DL="${HOST_DL:-/home/admin/qbittorrent/Downloads}"
SRV_DL="${SRV_DL:-/srv/dl}"
MI_PORT="${MI_PORT:-19090}"
SS_PORT="${SS_PORT:-19190}"
SS_OUT_DIR="${SS_OUT_DIR:-/usr/local/asp-ss}"
MI_API_PATH="${MI_API_PATH:-/usr/local/bin/asp-mediainfo.py}"
SS_API_PATH="${SS_API_PATH:-/usr/local/bin/asp-screenshot.py}"
NGINX_CONF="${NGINX_CONF:-/etc/nginx/conf.d/asp-filebrowser.conf}"

ensure_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "请使用 root 或 sudo 运行该脚本。" >&2
    exit 1
  fi
}

install_deps() {
  echo "安装宿主依赖 (nginx, python3, mediainfo, ffmpeg)..."
  apt-get update -y
  apt-get install -y nginx python3 mediainfo ffmpeg curl
}

prepare_dirs() {
  mkdir -p "${FB_ROOT}" "${HOST_DL}" "${SRV_DL}" "${SS_OUT_DIR}"

  if ! mountpoint -q "${SRV_DL}"; then
    mount --bind "${HOST_DL}" "${SRV_DL}"
  fi

  if ! grep -qs "^${HOST_DL} ${SRV_DL} " /etc/fstab; then
    echo "${HOST_DL} ${SRV_DL} none bind 0 0" >> /etc/fstab
  fi
}

write_mediainfo_api() {
  cat > "${MI_API_PATH}" <<'EOF_PY'
import http.server, socketserver, urllib.parse, subprocess, os, sys

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
}

write_screenshot_api() {
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
}

setup_services() {
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
  systemctl enable asp-mediainfo.service >/dev/null 2>&1
  systemctl enable asp-screenshot.service >/dev/null 2>&1
  systemctl restart asp-mediainfo.service
  systemctl restart asp-screenshot.service
}

patch_nginx() {
  if [ -z "${NGINX_CONF}" ] || [ ! -f "${NGINX_CONF}" ]; then
    echo "未找到 Nginx 配置文件: ${NGINX_CONF:-<空>}，跳过路由注入。"
    return 0
  fi

  NGINX_CONF="${NGINX_CONF}" MI_PORT="${MI_PORT}" SS_PORT="${SS_PORT}" SS_OUT_DIR="${SS_OUT_DIR}" \
  python3 - <<'PY'
import io
import os
import sys

conf = os.environ.get('NGINX_CONF')
mi_port = os.environ.get('MI_PORT')
ss_port = os.environ.get('SS_PORT')
ss_out = os.environ.get('SS_OUT_DIR')

if not conf:
    print('NGINX_CONF 为空，跳过修改。')
    sys.exit(0)

with open(conf, 'r', encoding='utf-8') as f:
    data = f.read()

need_mi = 'location /api/mi' not in data
need_ss = 'location /api/ss' not in data
need_out = 'location /asp-ss/' not in data

if not (need_mi or need_ss or need_out):
    print('Nginx 已包含 /api/mi、/api/ss、/asp-ss 配置，无需修改。')
    sys.exit(0)

snippet = '\n'
if need_mi:
    snippet += f"    location /api/mi {{\n        proxy_pass http://127.0.0.1:{mi_port};\n    }}\n\n"
if need_ss:
    snippet += f"    location /api/ss {{\n        proxy_pass http://127.0.0.1:{ss_port};\n    }}\n\n"
if need_out:
    snippet += f"    location /asp-ss/ {{\n        alias {ss_out}/;\n        add_header Cache-Control \"no-store\";\n    }}\n\n"

idx = data.rfind('}')
if idx == -1:
    print('Nginx 配置格式异常，未找到结尾 }，跳过修改。')
    sys.exit(1)

new_data = data[:idx] + snippet + data[idx:]
with open(conf, 'w', encoding='utf-8') as f:
    f.write(new_data)

print('已更新 Nginx 配置，注入 /api/mi /api/ss /asp-ss。')
PY

  nginx -t
  systemctl reload nginx
}

print_info() {
  cat <<EOF
部署完成。
MediaInfo API: http://127.0.0.1:${MI_PORT}/api/mi
Screenshot API: http://127.0.0.1:${SS_PORT}/api/ss
截图输出目录: ${SS_OUT_DIR}

可选环境变量:
  FB_ROOT     - 文件根目录 (默认 /srv)
  HOST_DL     - 原始下载目录 (默认 /home/admin/qbittorrent/Downloads)
  SRV_DL      - 绑定挂载目录 (默认 /srv/dl)
  MI_PORT     - MediaInfo API 端口 (默认 19090)
  SS_PORT     - Screenshot API 端口 (默认 19190)
  SS_OUT_DIR  - 截图输出目录 (默认 /usr/local/asp-ss)
  NGINX_CONF  - Nginx 配置路径 (默认 /etc/nginx/conf.d/asp-filebrowser.conf)
EOF
}

main() {
  ensure_root
  install_deps
  prepare_dirs
  write_mediainfo_api
  write_screenshot_api
  setup_services
  patch_nginx
  print_info
}

main "$@"
