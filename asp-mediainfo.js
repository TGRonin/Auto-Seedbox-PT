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
        .then(r => r.text().then(t => ({ ok: r.ok, status: r.status, text: t })))
        .then(({ ok, status, text }) => {
            if (!ok) throw new Error(text || `HTTP ${status}`);
            
            let rawText = text || '';
            let html = `<style>
                .mi-box { text-align:left; font-size:13px; background:#1e1e1e; color:#d4d4d4; padding:15px; border-radius:8px; max-height:550px; overflow-y:auto; font-family: 'Consolas', 'Courier New', monospace; user-select:text; white-space: pre-wrap;}
            </style><div class="mi-box"><pre>${rawText.replace(/[&<>]/g, c => ({'&':'&','<':'<','>':'>'}[c]))}</pre></div>`;
            
            // 优化：提供纯文本与 BBCode 两种复制选项
            Swal.fire({
                title: fileName,
                html: html,
                width: '850px',
                showCancelButton: true,
                showDenyButton: true,
                confirmButtonColor: '#3085d6',
                denyButtonColor: '#28a745', // 绿色
                cancelButtonColor: '#555',
                confirmButtonText: '📋 纯文本',
                denyButtonText: '🏷️ 复制 BBCode',
                cancelButtonText: '关闭',
                // 拦截“纯文本”按钮点击
                preConfirm: () => {
                    let textToCopy = rawText.trim();
                    copyText(textToCopy).then(() => {
                        // 修改按钮文字作为反馈，不触发新的 Swal 弹窗
                        let btn = Swal.getConfirmButton();
                        let originalText = btn.innerHTML;
                        btn.innerHTML = '✅ 纯文本复制成功！';
                        setTimeout(() => { btn.innerHTML = originalText; }, 2000);
                    }).catch(() => {
                        alert('复制失败，请手动选中上方文本进行复制');
                    });
                    return false; // 返回 false 阻止弹窗关闭
                },
                // 拦截“复制 BBCode”按钮点击
                preDeny: () => {
                    let textToCopy = `[quote]\n${rawText.trim()}\n[/quote]`;
                    copyText(textToCopy).then(() => {
                        // 修改按钮文字作为反馈
                        let btn = Swal.getDenyButton();
                        let originalText = btn.innerHTML;
                        btn.innerHTML = '✅ BBCode 复制成功！';
                        setTimeout(() => { btn.innerHTML = originalText; }, 2000);
                    }).catch(() => {
                        alert('复制失败，请手动选中上方文本进行复制');
                    });
                    return false; // 返回 false 阻止弹窗关闭
                }
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

                btn.classList.add('asp-mi-btn-class');
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

            collectActionContainers().forEach(menu => {
                let existingBtn = menu.querySelector('.asp-mi-btn-class');
                if (isMedia) {
                    if (!existingBtn) {
                        let btn = buildMenuButton(menu, 'MediaInfo', 'movie');
                        btn.onclick = function(ev) {
                            ev.preventDefault();
                            ev.stopPropagation();
                            document.body.click();
                            openMediaInfo(targetFile);
                        };
                        
                        let infoBtn = findInfoButton(menu);
                        if (infoBtn && infoBtn.insertAdjacentElement) {
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