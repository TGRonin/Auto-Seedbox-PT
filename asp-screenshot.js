/**
 * Auto-Seedbox-PT (ASP) Screenshot 前端扩展
 * 由 Nginx 动态注入：/asp-screenshot.js
 */
(function () {
    console.log("📸 [ASP] Screenshot 已加载 (极客UI优化版)");

    const SS_API = "/api/ss";

    const script = document.createElement("script");
    script.src = "/sweetalert2.all.min.js";
    document.head.appendChild(script);

    function getCurrentDir() {
        const path = window.location.pathname.replace(/^\/files/, "");
        return decodeURIComponent(path) || "/";
    }

    function escapeHtml(s) {
        return String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
    }

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

    async function uploadToPixhostRemote(urls) {
        const body = encodeURI(`imgs=${urls.join('\r\n')}&content_type=0&max_th_size=350`);
        const res = await fetch("https://pixhost.to/remote/", {
            method: "POST",
            headers: {
                "Content-Type": "application/x-www-form-urlencoded",
                "Accept": "application/json"
            },
            body
        });
        const text = await res.text();
        if (!res.ok) {
            throw new Error(`Pixhost 上传失败 (HTTP ${res.status})`);
        }
        const match = text.match(/upload_results\s*=\s*({.*});/);
        if (!match || !match[1]) {
            throw new Error("Pixhost 返回解析失败");
        }
        const payload = JSON.parse(match[1]);
        const images = Array.isArray(payload.images) ? payload.images : [];
        return images.map((item) => {
            const thUrl = item.th_url;
            const fullUrl = thUrl.replace("//t", "//img").replace("thumbs", "images");
            return { show_url: item.show_url, th_url: thUrl, full_url: fullUrl };
        });
    }

    const isMedia = (file) => file && file.match(/\.(mp4|mkv|avi|ts|m2ts|mov|webm|mpg|mpeg|wmv|flv|vob|iso)$/i);

    function clamp(v, lo, hi, fallback) {
        v = parseInt(v, 10);
        if (!Number.isFinite(v)) return fallback;
        return Math.max(lo, Math.min(hi, v));
    }

    async function probeVideo(fullPath) {
        try {
            const r = await fetch(`${SS_API}?file=${encodeURIComponent(fullPath)}&probe=1`, { cache: "no-store" });
            const j = await r.json().catch(() => ({}));
            if (r.ok && j && j.meta) return j.meta;
        } catch (e) { }
        return { width: null, height: null, duration: null };
    }

    let lastRightClickedFile = "";
    document.addEventListener("contextmenu", function (e) {
        const row = e.target.closest(".item");
        if (row) {
            const nameEl = row.querySelector(".name");
            if (nameEl) lastRightClickedFile = nameEl.innerText.trim();
        } else {
            lastRightClickedFile = "";
        }
    }, true);

    document.addEventListener("click", function (e) {
        if (!e.target.closest(".asp-ss-btn-class") && !e.target.closest('.item[aria-selected="true"]')) {
            lastRightClickedFile = "";
        }
    }, true);

   // ==========================================
    // 弹窗1：参数设置面板 (现代极简浅色版)
    // ==========================================
    async function promptSettings(fileName) {
        if (typeof Swal === "undefined") {
            alert("界面组件加载中，请稍后重试。");
            return null;
        }

        const fullPath = (getCurrentDir() + "/" + fileName).replace(/\/\//g, "/");

        Swal.fire({
            title: "读取视频信息中...",
            text: "正在探测原始分辨率",
            allowOutsideClick: false,
            allowEscapeKey: false,
            didOpen: () => Swal.showLoading()
        });

        const meta = await probeVideo(fullPath);
        const origW = clamp(meta.width, 320, 3840, 1280);
        const origH = meta.height ? clamp(meta.height, 240, 2160, null) : null;

        const presetWs = [origW, 3840, 2560, 1920, 1280, 960, 720]
            .filter((v, i, a) => a.indexOf(v) === i)
            .filter((v) => v >= 320 && v <= 3840);
        const presetNs = [6, 8, 10, 12, 16];

        const html = `
            <style>
                /* 全局与排版 (浅色) */
                .ss-wrap { text-align: left; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif; color: #1f2937; }
                .ss-head { margin-bottom: 20px; padding-bottom: 16px; border-bottom: 1px dashed #e5e7eb; }
                .ss-title { font-size: 18px; font-weight: 600; color: #111827; margin-bottom: 8px; display: flex; align-items: center; gap: 8px; }
                .ss-sub { font-size: 13px; color: #6b7280; margin-bottom: 12px; display: flex; align-items: center; }
                .ss-sub code { font-family: 'Consolas', monospace; background: #f3f4f6; border: 1px solid #e5e7eb; border-radius: 4px; padding: 2px 6px; color: #ec4899; margin-left: 8px; word-break: break-all; }
                
                /* 彩色信息徽章 */
                .ss-meta { display: flex; gap: 10px; flex-wrap: wrap; }
                .ss-pill { font-size: 12px; font-family: 'Consolas', monospace; background: #eff6ff; border: 1px solid #bfdbfe; border-radius: 6px; padding: 4px 10px; color: #1d4ed8; display: inline-flex; align-items: center; }
                .ss-pill.fmt { background: #f0fdf4; color: #15803d; border-color: #bbf7d0; } /* 清爽绿 */

                /* 表单网格 */
                .ss-form { display: grid; grid-template-columns: 130px 1fr; gap: 20px 16px; align-items: start; }
                .ss-form label { font-size: 14px; font-weight: 600; color: #374151; padding-top: 6px; }
                .ss-control { display: flex; flex-direction: column; gap: 10px; }

                /* 现代输入框 */
                .ss-input-box { display: flex; align-items: center; position: relative; }
                .ss-form input[type='number'] { width: 100%; padding: 8px 12px; border-radius: 6px; border: 1px solid #d1d5db; background: #fff; color: #111827; outline: none; font-family: 'Consolas', monospace; font-size: 14px; transition: all 0.2s ease; box-shadow: inset 0 1px 2px rgba(0,0,0,0.02); }
                .ss-form input[type='number']:focus { border-color: #3b82f6; box-shadow: 0 0 0 3px rgba(59, 130, 246, 0.15), inset 0 1px 2px rgba(0,0,0,0.02); }
                
                /* 药丸快捷标签 (悬浮变色) */
                .ss-chip-row { display: flex; gap: 8px; flex-wrap: wrap; }
                .ss-chip { cursor: pointer; padding: 5px 12px; border-radius: 20px; border: 1px solid #d1d5db; background: #fff; color: #4b5563; font-size: 12px; font-family: 'Consolas', monospace; user-select: none; transition: all 0.2s cubic-bezier(0.4, 0, 0.2, 1); }
                .ss-chip:hover { border-color: #9ca3af; background: #f9fafb; }
                .ss-chip.active { background: #eff6ff; border-color: #60a5fa; color: #1d4ed8; font-weight: 600; box-shadow: 0 1px 2px rgba(0,0,0,0.05); }

                /* 浅色精致滑动条 */
                .ss-range-wrap { display: flex; align-items: center; gap: 12px; }
                .ss-form input[type='range'] { -webkit-appearance: none; width: 100%; background: transparent; height: 24px; margin: 0; outline: none; }
                .ss-form input[type='range']::-webkit-slider-runnable-track { width: 100%; height: 6px; background: #e5e7eb; border-radius: 3px; }
                .ss-form input[type='range']::-webkit-slider-thumb { -webkit-appearance: none; height: 16px; width: 16px; border-radius: 50%; background: #3b82f6; cursor: pointer; margin-top: -5px; box-shadow: 0 2px 4px rgba(0,0,0,0.15); transition: transform 0.1s; }
                .ss-form input[type='range']::-webkit-slider-thumb:hover { transform: scale(1.15); background: #2563eb; }
                
                /* 动态数值显示 */
                .ss-val { display: inline-flex; justify-content: center; align-items: center; min-width: 44px; background: #f3f4f6; border: 1px solid #e5e7eb; border-radius: 6px; padding: 4px 6px; color: #374151; font-family: 'Consolas', monospace; font-size: 12px; font-weight: bold; }

                @media (max-width:760px) { .ss-form { grid-template-columns: 1fr; gap: 12px; } }
            </style>

            <div class='ss-wrap'>
                <div class='ss-head'>
                    <div class='ss-title'>
                        <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="#3b82f6" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="3" width="18" height="18" rx="2" ry="2"></rect><circle cx="8.5" cy="8.5" r="1.5"></circle><polyline points="21 15 16 10 5 21"></polyline></svg>
                        截图参数配置
                    </div>
                    <div class='ss-sub'>目标文件 <code>${escapeHtml(fileName)}</code></div>
                    <div class='ss-meta'>
                        <span class='ss-pill'>⚡ ${origW}${origH ? "x" + origH : "p"} 源解析度</span>
                        <span class='ss-pill fmt'>📦 JPG + ZIP 归档</span>
                    </div>
                </div>

                <div class='ss-form'>
                    <label>截图数量 (张)</label>
                    <div class='ss-control'>
                        <div class='ss-input-box'><input id='ss_n' type='number' min='1' max='20' value='6'/></div>
                        <div class='ss-chip-row' id='ss_n_chips'>
                            ${presetNs.map((n) => `<span class='ss-chip' data-n='${n}'>${n}</span>`).join("")}
                        </div>
                    </div>

                    <label>横向宽度 (px)</label>
                    <div class='ss-control'>
                        <div class='ss-input-box'><input id='ss_w' type='number' min='320' max='3840' value='${origW}'/></div>
                        <div class='ss-chip-row' id='ss_w_chips'>
                            ${presetWs.map((w) => `<span class='ss-chip' data-w='${w}'>${w}${w === origW ? "(原)" : ""}</span>`).join("")}
                        </div>
                    </div>

                    <label>智能跳过片头</label>
                    <div class='ss-control'>
                        <div class='ss-range-wrap'>
                            <input id='ss_head' type='range' min='0' max='20' value='5'/>
                            <div class='ss-val'><span id='ss_head_v'>5</span>%</div>
                        </div>
                    </div>

                    <label>智能跳过片尾</label>
                    <div class='ss-control'>
                        <div class='ss-range-wrap'>
                            <input id='ss_tail' type='range' min='0' max='20' value='5'/>
                            <div class='ss-val'><span id='ss_tail_v'>5</span>%</div>
                        </div>
                    </div>
                </div>
            </div>
        `;

        const result = await Swal.fire({
            html: html,
            width: '680px', 
            background: '#ffffff', // 回归干净的纯白背景
            showCancelButton: true,
            confirmButtonText: "🚀 开始执行截图",
            cancelButtonText: "取消",
            confirmButtonColor: "#3b82f6", // 明快的蓝色按钮
            cancelButtonColor: "#9ca3af",  // 柔和的灰色取消按钮
            allowOutsideClick: true,
            allowEscapeKey: true,
            didOpen: () => {
                const head = document.getElementById("ss_head");
                const tail = document.getElementById("ss_tail");
                const hv = document.getElementById("ss_head_v");
                const tv = document.getElementById("ss_tail_v");

                head.addEventListener("input", () => (hv.textContent = head.value));
                tail.addEventListener("input", () => (tv.textContent = tail.value));

                const nInput = document.getElementById("ss_n");
                const wInput = document.getElementById("ss_w");

                // 点击标签高亮并同步 Input
                const bindChips = (containerId, inputEl, dataAttr) => {
                    const container = document.getElementById(containerId);
                    container.addEventListener("click", (e) => {
                        const t = e.target.closest(".ss-chip");
                        if (!t) return;
                        container.querySelectorAll('.ss-chip').forEach(c => c.classList.remove('active'));
                        t.classList.add('active');
                        inputEl.value = t.getAttribute(dataAttr);
                    });
                };

                bindChips("ss_n_chips", nInput, "data-n");
                bindChips("ss_w_chips", wInput, "data-w");
                
                // 默认点亮当前值的 chip
                document.querySelector(`.ss-chip[data-n="6"]`)?.classList.add('active');
                document.querySelector(`.ss-chip[data-w="${origW}"]`)?.classList.add('active');
            },
            preConfirm: () => {
                return {
                    n: clamp(document.getElementById("ss_n").value, 1, 20, 6),
                    width: clamp(document.getElementById("ss_w").value, 320, 3840, origW),
                    head: clamp(document.getElementById("ss_head").value, 0, 20, 5),
                    tail: clamp(document.getElementById("ss_tail").value, 0, 20, 5),
                    fullPath, meta
                };
            }
        });

        return result.isConfirmed ? result.value : null;
    }

    // ==========================================
    // 弹窗2：结果展示面板 (深色极客UI + 按钮交互)
    // ==========================================
    function openScreenshot(fileName) {
        promptSettings(fileName).then((opt) => {
            if (!opt) return;

            Swal.fire({
                title: "截图生成中...",
                html: `正在处理...<br><br><span style="font-size:13px;color:#aaa;">数量 <b>${opt.n}</b> | 宽度 <b>${opt.width}</b> | 掐头去尾 <b>${opt.head}% / ${opt.tail}%</b></span>`,
                allowOutsideClick: false,
                allowEscapeKey: false,
                didOpen: () => Swal.showLoading()
            });

            const url = `${SS_API}?file=${encodeURIComponent(opt.fullPath)}&n=${opt.n}&width=${opt.width}&head=${opt.head}&tail=${opt.tail}&fmt=jpg&zip=1`;

            fetch(url, { cache: "no-store" })
                .then(async (r) => {
                    const contentType = (r.headers.get("content-type") || "").toLowerCase();
                    const text = await r.text();
                    let json = null;
                    if (text && (contentType.includes("application/json") || contentType.includes("text/json"))) {
                        try { json = JSON.parse(text); } catch (e) { json = null; }
                    } else {
                        try { json = JSON.parse(text); } catch (e) { json = null; }
                    }
                    return { ok: r.ok, status: r.status, json, raw: text, contentType };
                })
                .then(({ ok, status, json, raw, contentType }) => {
                    if (!ok || !json || !json.base || !Array.isArray(json.files) || json.files.length === 0) {
                        const isHtml = (contentType && contentType.includes("text/html")) || /^\s*<!doctype|^\s*<html/i.test(raw || "");
                        const hint = isHtml ? "接口返回了 HTML（疑似被重定向到登录页或前端页面），请检查 /api/ss 服务端路由是否可用或鉴权是否正确。" : "";
                        const err = json && json.error ? json.error : `请求失败 (HTTP ${status})`;
                        throw new Error(`${err}${hint ? "\n" + hint : ""}`);
                    }

                    const base = json.base;
                    const imgs = json.files.map((f) => `${base}${f}`);
                    const absoluteImgs = imgs.map((u) => new URL(u, window.location.origin).href);
                    const zipUrl = json.zip ? `${base}${json.zip}` : null;

                    Swal.fire({
                        title: "上传至 Pixhost...",
                        html: "正在上传截图，请稍候...",
                        allowOutsideClick: false,
                        allowEscapeKey: false,
                        didOpen: () => Swal.showLoading()
                    });

                    let pixItems = [];
                    try {
                        pixItems = await uploadToPixhostRemote(absoluteImgs);
                    } catch (err) {
                        Swal.fire("上传失败", err && err.message ? err.message : String(err), "error");
                        return;
                    }

                    const pixFullUrls = pixItems.map((i) => i.full_url);
                    const allLinksText = pixFullUrls.join("\n");

                    let html = `
                        <style>
                            .ss-panel { background:#1e1e1e; color:#d4d4d4; font-family:'Consolas', monospace; font-size:13px; text-align:left; border-radius:8px; padding:15px; }
                            .ss-top { margin-bottom:12px; line-height:1.6; }
                            .ss-top code { background:#2d2d2d; border:1px solid #444; border-radius:4px; padding:2px 6px; color:#ce9178; word-break:break-all; }
                            .ss-grid-wrap { max-height:500px; overflow-y:auto; padding-right:5px; margin-bottom:15px; }
                            .ss-grid { display:grid; grid-template-columns:repeat(2, minmax(0, 1fr)); gap:12px; }
                            .ss-card { border:1px solid #3c3c3c; border-radius:6px; overflow:hidden; background:#252526; transition: 0.2s; }
                            .ss-card:hover { border-color: #569cd6; }
                            .ss-bar { padding:6px 10px; display:flex; justify-content:space-between; align-items:center; font-size:12px; background:#2d2d2d; color:#9cdcfe; border-bottom:1px solid #3c3c3c; }
                            .ss-idx { font-weight:bold; color:#dcdcaa; }
                            .ss-img { display:block; width:100%; max-height:220px; object-fit:cover; background:#111; }
                            @media (max-width:760px) { .ss-grid { grid-template-columns:1fr; } }
                        </style>
                        <div class='ss-panel'>
                            <div class='ss-top'>
                                文件：<code>${escapeHtml(fileName)}</code><br>
                                参数：<span style="color:#4ec9b0;">${pixItems.length}张 / ${opt.width}px</span>
                            </div>
                            <div class='ss-grid-wrap'>
                                <div class='ss-grid'>
                                    ${pixItems.map((item, i) => `
                                    <a href='${item.full_url}' target='_blank' style='text-decoration:none'>
                                        <div class='ss-card'>
                                            <div class='ss-bar'><span class='ss-idx'>#${i + 1}</span><span>点击查看全图</span></div>
                                            <img class='ss-img' src='${item.th_url}' loading='lazy' />
                                        </div>
                                    </a>`).join("")}
                                </div>
                            </div>
                        </div>
                    `;

                    // 使用 Swal 的原生多按钮生态替代手动注入 DOM
                    Swal.fire({
                        title: "截图已生成",
                        html: html,
                        width: "850px",
                        allowOutsideClick: true,
                        allowEscapeKey: true,
                        showCancelButton: true,
                        showDenyButton: !!zipUrl, // 如果有 ZIP 才显示下载按钮
                        confirmButtonText: "📋 复制全部链接",
                        denyButtonText: "📦 下载 ZIP 压缩包",
                        cancelButtonText: "关闭",
                        confirmButtonColor: "#28a745", // 绿色
                        denyButtonColor: "#3085d6",    // 蓝色
                        cancelButtonColor: "#555",
                        
                        // 拦截“复制链接”点击
                        preConfirm: () => {
                            copyText(allLinksText).then(() => {
                                let btn = Swal.getConfirmButton();
                                let origText = btn.innerHTML;
                                btn.innerHTML = '✅ 复制成功，快去发种！';
                                setTimeout(() => { btn.innerHTML = origText; }, 2000);
                            }).catch(() => {
                                alert("复制失败，请手动处理。");
                            });
                            return false; // 阻断窗口关闭
                        },
                        
                        // 拦截“下载 ZIP”点击
                        preDeny: () => {
                            if (zipUrl) window.open(zipUrl, "_blank");
                            let btn = Swal.getDenyButton();
                            let origText = btn.innerHTML;
                            btn.innerHTML = '✅ 已在新标签页打开下载';
                            setTimeout(() => { btn.innerHTML = origText; }, 2000);
                            return false; // 阻断窗口关闭
                        }
                    });
                })
                .catch((e) => Swal.fire("截图失败", e.toString(), "error"));
        });
    }

    // ==========================================
    // 注入按钮逻辑 (仿 MediaInfo)
    // ==========================================
    let observerTimer = null;
    const observer = new MutationObserver(() => {
        if (observerTimer) clearTimeout(observerTimer);

        observerTimer = setTimeout(() => {
            let targetFile = "";
            if (lastRightClickedFile) {
                targetFile = lastRightClickedFile;
            } else {
                const selectedRows = document.querySelectorAll('.item[aria-selected="true"], .item.selected');
                if (selectedRows.length === 1) {
                    const nameEl = selectedRows[0].querySelector(".name");
                    if (nameEl) targetFile = nameEl.innerText.trim();
                }
            }

            const ok = isMedia(targetFile);

            const collectActionContainers = () => {
                const containers = new Set();
                const menuLabels = new Set(['Info', '信息', 'Delete', '删除', 'Download', '下载']);

                document.querySelectorAll('button[aria-label], a[aria-label], div[aria-label], li[aria-label]').forEach(btn => {
                    const label = btn.getAttribute('aria-label');
                    if (label && menuLabels.has(label)) {
                        if (btn.parentElement) containers.add(btn.parentElement);
                    }
                });

                document.querySelectorAll('button, a, div, li, span').forEach(el => {
                    const text = (el.textContent || '').trim();
                    if (menuLabels.has(text)) {
                        const menu = el.closest('[role="menu"], .context-menu, .contextMenu, .contextmenu, .dropdown-menu, .menu, [class*="context"], [class*="menu"], [data-testid*="menu"], [data-testid*="context"]');
                        if (menu) containers.add(menu);
                    }
                });

                document.querySelectorAll('.context-menu, .contextmenu, .dropdown-menu, .menu, [role="menu"], .contextMenu, [data-testid*="menu"], [data-testid*="context"]').forEach(menu => {
                    containers.add(menu);
                });
                return containers;
            };

            const buildMenuButton = (menu, label, icon) => {
                const sample = menu.querySelector('button, a, div[role="menuitem"], li, .menu-item, .item, [role="menuitem"]');
                let btn;
                if (sample) {
                    btn = document.createElement(sample.tagName.toLowerCase());
                    btn.className = sample.className || '';
                    const role = sample.getAttribute && sample.getAttribute('role');
                    if (role) btn.setAttribute('role', role);
                    const tabindex = sample.getAttribute && sample.getAttribute('tabindex');
                    if (tabindex) btn.setAttribute('tabindex', tabindex);
                } else {
                    btn = document.createElement('button');
                    btn.className = 'action';
                }

                btn.classList.add('asp-ss-btn-class');
                btn.setAttribute('title', label);
                btn.setAttribute('aria-label', label);
                if (btn.tagName === 'BUTTON' && !btn.getAttribute('type')) btn.setAttribute('type', 'button');

                const useMaterialIcons = !!menu.querySelector('i.material-icons');
                if (useMaterialIcons) {
                    btn.innerHTML = `<i class="material-icons">${icon}</i><span>${label}</span>`;
                } else {
                    btn.textContent = label;
                }
                return btn;
            };

            const findInfoButton = (menu) => {
                const ariaBtn = menu.querySelector('button[aria-label="Info"], button[aria-label="信息"], a[aria-label="Info"], a[aria-label="信息"], div[aria-label="Info"], div[aria-label="信息"]');
                if (ariaBtn) return ariaBtn;
                const candidates = menu.querySelectorAll('button, a, div, li, span');
                for (const el of candidates) {
                    const text = (el.textContent || '').trim();
                    if (text === 'Info' || text === '信息') return el;
                }
                return null;
            };

            collectActionContainers().forEach((menu) => {
                const existingBtn = menu.querySelector(".asp-ss-btn-class");
                if (ok) {
                    if (!existingBtn) {
                        const btn = buildMenuButton(menu, 'Screenshot', 'photo_camera');
                        btn.onclick = function (ev) {
                            ev.preventDefault();
                            ev.stopPropagation();
                            document.body.click();
                            openScreenshot(targetFile);
                        };

                        const miBtn = menu.querySelector(".asp-mi-btn-class");
                        if (miBtn) {
                            miBtn.insertAdjacentElement("afterend", btn);
                        } else {
                            const infoBtn = findInfoButton(menu);
                            if (infoBtn && infoBtn.insertAdjacentElement) infoBtn.insertAdjacentElement("afterend", btn);
                            else menu.appendChild(btn);
                        }
                    } else {
                        const miBtn = menu.querySelector(".asp-mi-btn-class");
                        if (miBtn && existingBtn.previousElementSibling !== miBtn) {
                            miBtn.insertAdjacentElement("afterend", existingBtn);
                        }
                    }
                } else if (existingBtn) {
                    existingBtn.remove();
                }
            });
        }, 100);
    });

    observer.observe(document.body, { childList: true, subtree: true });
})();