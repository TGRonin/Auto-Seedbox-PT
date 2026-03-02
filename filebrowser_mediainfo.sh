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

ASP_JS_PATH="/usr/local/bin/asp-mediainfo.js"
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
  mkdir -p "${FB_DATA_DIR}"
  mkdir -p "${FB_ROOT}"
  mkdir -p "/home/admin/qbittorrent/Downloads"
}

write_frontend_assets() {
  cat > "${ASP_JS_PATH}" <<'EOF_JS'
/**
 * Auto-Seedbox-PT (ASP) MediaInfo 极客前端扩展
 * 由 Nginx 底层动态注入
 */
(function() {
    console.log("🚀 [ASP] MediaInfo v1.1 已加载 (优化 PT 发种体验)！");
    
    // 兼容剪贴板复制逻辑
    const copyText = (text) => {
        if (navigator.clipboard && window.isSecureContext) {
            return navigator.clipboard.writeText(text);
        } else {
            let textArea = document.createElement("textarea");
            textArea.value = text;
            textArea.style.position = "fixed";
            textArea.style.opacity = "0";
            document.body.appendChild(textArea);
            textArea.focus();
            textArea.select();
            return new Promise((res, rej) => {
                document.execCommand('copy') ? res() : rej();
                textArea.remove();
            });
        }
    };

    // 动态引入弹窗 UI 库
    const script = document.createElement('script');
    script.src = "/sweetalert2.all.min.js";
    document.head.appendChild(script);

    function getCurrentPath() {
        let path = window.location.pathname.replace(/^\/files/, '');
        return decodeURIComponent(path) || '/';
    }

    let lastRightClickedFile = "";

    // 捕获右键选中目标
    document.addEventListener('contextmenu', function(e) {
        let row = e.target.closest('.item');
        if (row) {
            let nameEl = row.querySelector('.name');
            if (nameEl) lastRightClickedFile = nameEl.innerText.trim();
        } else {
            lastRightClickedFile = "";
        }
    }, true);

    // 左键点击任意非按钮区域，清空右键记忆，防止幽灵状态
    document.addEventListener('click', function(e) {
        if (!e.target.closest('.asp-mi-btn-class') && !e.target.closest('.item[aria-selected="true"]')) {
            lastRightClickedFile = "";
        }
    }, true);

    const openMediaInfo = (fileName) => {
        let fullPath = (getCurrentPath() + '/' + fileName).replace(/\/\//g, '/');
        if (typeof Swal === 'undefined') {
            alert('UI组件正在加载，请稍后再试...'); return;
        }
        Swal.fire({
            title: '解析中...',
            text: '正在读取底层媒体轨道信息',
            allowOutsideClick: false,
            didOpen: () => Swal.showLoading()
        });
        
        fetch(`/api/mi?file=${encodeURIComponent(fullPath)}`)
        .then(r => r.json())
        .then(data => {
            if(data.error) throw new Error(data.error);
            
            let rawText = "";
            let html = `<style>
                .mi-box { text-align:left; font-size:13px; background:#1e1e1e; color:#d4d4d4; padding:15px; border-radius:8px; max-height:550px; overflow-y:auto; font-family: 'Consolas', 'Courier New', monospace; user-select:text;}
                .mi-track { margin-bottom: 20px; }
                .mi-track-header { font-size: 15px; font-weight: bold; margin-bottom: 8px; padding-bottom: 4px; border-bottom: 1px solid #444; }
                .mi-Video .mi-track-header { color: #569cd6; border-bottom-color: #569cd6; }
                .mi-Audio .mi-track-header { color: #4ec9b0; border-bottom-color: #4ec9b0; }
                .mi-Text .mi-track-header { color: #ce9178; border-bottom-color: #ce9178; }
                .mi-General .mi-track-header { color: #dcdcaa; border-bottom-color: #dcdcaa; }
                .mi-Menu .mi-track-header { color: #c586c0; border-bottom-color: #c586c0; }
                .mi-item { display: flex; padding: 3px 0; line-height: 1.5; border-bottom: 1px dashed #333;}
                .mi-key { width: 180px; flex-shrink: 0; color: #9cdcfe; }
                .mi-val { flex-grow: 1; color: #cecece; word-wrap: break-word; }
            </style><div class="mi-box">`;

            if (data.media && data.media.track) {
                data.media.track.forEach(t => {
                    let type = t['@type'] || 'Unknown';
                    // 头部空行，更符合原生 CLI 观感
                    rawText += `${type}\n`;
                    html += `<div class="mi-track mi-${type}"><div class="mi-track-header">${type}</div>`;

                    for (let k in t) { 
                        if (k === '@type') continue;
                        let val = t[k];
                        if (typeof val === 'object') val = JSON.stringify(val);
                        
                        // 优化对齐逻辑：原生格式通常是 Key 占一定宽度，然后跟 ' : '
                        let paddedKey = String(k).padEnd(32, ' ');
                        rawText += `${paddedKey}: ${val}\n`;

                        html += `<div class="mi-item"><div class="mi-key">${k}</div><div class="mi-val">${val}</div></div>`;
                    }
                    rawText += `\n`;
                    html += `</div>`;
                });
            } else { 
                rawText = JSON.stringify(data, null, 2); 
                html += `<pre>${rawText}</pre>`;
            }
            html += `</div>`;
            
            // 优化：提供纯文本与 BBCode 两种复制选项
            Swal.fire({ 
                title: fileName, 
                html: html, 
                width: '850px',
                showCancelButton: true,
                showDenyButton: true, // 开启第三个按钮
                confirmButtonColor: '#3085d6',
                denyButtonColor: '#28a745', // 绿色
                cancelButtonColor: '#555',
                confirmButtonText: '📋 纯文本',
                denyButtonText: '🏷️ 复制 BBCode',
                cancelButtonText: '关闭'
            }).then((result) => {
                let textToCopy = rawText.trim();
                let successMsg = '纯文本复制成功！';

                if (result.isConfirmed) {
                    // 纯文本
                    textToCopy = rawText.trim();
                } else if (result.isDenied) {
                    // BBCode 格式
                    textToCopy = `[quote]\n${rawText.trim()}\n[/quote]`;
                    successMsg = 'BBCode 复制成功，快去发种吧！';
                } else {
                    return; // 点击关闭或背景
                }

                copyText(textToCopy).then(() => {
                    Swal.fire({toast: true, position: 'top-end', icon: 'success', title: successMsg, showConfirmButton: false, timer: 2000});
                }).catch(() => {
                    Swal.fire('复制失败', '请手动选中上方文本进行复制', 'error');
                });
            });
        }).catch(e => Swal.fire('解析失败', e.toString(), 'error'));
    };

    // 性能优化：加入防抖 (Debounce) 机制
    let observerTimer = null;
    const observer = new MutationObserver(() => {
        if (observerTimer) clearTimeout(observerTimer);
        
        observerTimer = setTimeout(() => {
            let targetFile = "";
            if (lastRightClickedFile) {
                targetFile = lastRightClickedFile;
            } else {
                let selectedRows = document.querySelectorAll('.item[aria-selected="true"], .item.selected');
                if (selectedRows.length === 1) {
                    let nameEl = selectedRows[0].querySelector('.name');
                    if (nameEl) targetFile = nameEl.innerText.trim();
                }
            }

            // 扩展支持：添加原盘 index.bdmv 及无损音频格式
            let isMedia = targetFile && targetFile.match(/\.(mp4|mkv|avi|ts|iso|rmvb|wmv|flv|mov|webm|vob|m2ts|bdmv|flac|wav|ape|alac)$/i);

            let menus = new Set();
            document.querySelectorAll('button[aria-label="Info"]').forEach(btn => {
                if (btn.parentElement) menus.add(btn.parentElement);
            });

            menus.forEach(menu => {
                let existingBtn = menu.querySelector('.asp-mi-btn-class');
                if (isMedia) {
                    if (!existingBtn) {
                        let btn = document.createElement('button');
                        btn.className = 'action asp-mi-btn-class';
                        btn.setAttribute('title', 'MediaInfo');
                        btn.setAttribute('aria-label', 'MediaInfo');
                        btn.innerHTML = '<i class="material-icons">movie</i><span>MediaInfo</span>';
                        
                        btn.onclick = function(ev) {
                            ev.preventDefault();
                            ev.stopPropagation();
                            document.body.click(); 
                            openMediaInfo(targetFile);
                        };
                        
                        let infoBtn = menu.querySelector('button[aria-label="Info"]');
                        if (infoBtn) {
                            infoBtn.insertAdjacentElement('afterend', btn);
                        } else {
                            menu.appendChild(btn);
                        }
                    }
                } else {
                    if (existingBtn) existingBtn.remove();
                }
            });
        }, 100); // 100ms 延迟，极大降低浏览器性能开销
    });

    observer.observe(document.body, { childList: true, subtree: true });
})();
EOF_JS

  curl -fsSL "https://cdn.jsdelivr.net/npm/sweetalert2@11/dist/sweetalert2.all.min.js" -o "${SWAL_JS_PATH}"
  chmod 644 "${ASP_JS_PATH}" "${SWAL_JS_PATH}"
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
        sub_filter '</body>' '<script src="/asp-mediainfo.js"></script></body>';
        sub_filter_once on;
    }

    location = /asp-mediainfo.js {
        alias ${ASP_JS_PATH};
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

已将 /home/admin/qbittorrent/Downloads 挂载到容器内 /srv/dl。

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
