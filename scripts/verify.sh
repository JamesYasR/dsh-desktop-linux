#!/usr/bin/env bash
# 验证矩阵。逐项检查，失败不中断，最后汇总。
#
#   ./scripts/verify.sh             静态部分：只看产物与打包元数据，不启动应用（CI 跑这个）
#   ./scripts/verify.sh --runtime   额外跑活体矩阵：真的拉起 linux-unpacked，用 DevTools
#                                   协议读渲染文档，结束时自动收掉
#
# 活体部分需要显示器，且刻意只碰临时 DSH_HOME；同时断言真实的 ~/.dsh 未被触碰。
# 每项检查为什么这么判，都写在它自己的注释里。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM="$ROOT/upstream"
# 刻意不继承环境里的 DSH_HOME：DSH 会话自身把 DSH_HOME 指向用户真实的 ~/.dsh，直接继承会让
# 构建往正在使用的数据目录里写东西。要换路径请用 DSH_DESKTOP_LINUX_HOME。
export DSH_HOME="${DSH_DESKTOP_LINUX_HOME:-/tmp/dsh-desktop-test}"
if [[ "$DSH_HOME" == "$HOME/.dsh" ]]; then
  echo "错误：DSH_HOME 不能指向 $HOME/.dsh（正在使用的 dsh 数据目录）" >&2
  exit 1
fi

RUNTIME=0
for arg in "$@"; do
  case "$arg" in
    --runtime) RUNTIME=1 ;;
    *) echo "未知参数：$arg" >&2; exit 2 ;;
  esac
done

pass=0; fail=0; skipped=0
ok()   { echo "  [PASS] $1"; pass=$((pass+1)); }
bad()  { echo "  [FAIL] $1"; fail=$((fail+1)); }
skip() { echo "  [SKIP] $1"; skipped=$((skipped+1)); }
# 断言一个字符串包含另一段文本；$3 是给人看的说明。
has()  { if [[ "$1" == *"$2"* ]]; then ok "$3"; else bad "$3（期望包含：$2）"; fi; }

# unsigned 构建的输出目录（见 electron-builder-config.mjs 的 directories.output）
OUT="$UPSTREAM/apps/desktop/.desktop-build/targets/linux-x64/unsigned-artifacts"
UNPACKED="$OUT/linux-unpacked"
APPDSH="$UNPACKED/resources/app/dsh"
PRIMARY_NODE="$UNPACKED/resources/runtime/primary-runtime/dependencies/node/bin/node"
CLI="$APPDSH/node_modules/@deepseek-ai/dsh/lib/bin.js"

# 探测用的 node：用系统 node 读 built lib，不依赖产物里那份运行时。
NODE="$(command -v node || true)"

echo "== 1. 产物存在 =="
mapfile -t artifacts < <(find "$OUT" -maxdepth 1 \
  \( -name '*.AppImage' -o -name '*.deb' -o -name '*.rpm' \) 2>/dev/null)
if (( ${#artifacts[@]} > 0 )); then
  for a in "${artifacts[@]}"; do ok "$(basename "$a") ($(du -h "$a" | cut -f1))"; done
else
  bad "没找到 AppImage/deb/rpm 产物（$OUT）"
fi

echo "== 2. 未打包目录可执行 =="
if [[ -x "$UNPACKED/deepseek-harness" ]]; then
  ok "linux-unpacked/deepseek-harness"
  # 真 Node 读不了 asar，Linux 上 dsh 必须是一棵真目录树。
  if [[ -d "$APPDSH/node_modules" ]]; then
    ok "resources/app/dsh 是解包目录树（asar 已关闭）"
  else
    bad "resources/app/dsh 不是解包目录树——真 Node 读不了 asar"
  fi
else
  skip "linux-unpacked 不存在（还没跑 package:linux:x64:dir）"
fi

echo "== 3. 原生模块 =="
for mod in pty.node; do
  if find "$UPSTREAM/node_modules" -name "$mod" -print -quit 2>/dev/null | grep -q .; then
    ok "$mod 已构建"
  else
    bad "$mod 缺失（node-pty 在 Linux 上无 prebuild）"
  fi
done
if find "$UPSTREAM/node_modules" -path '*sharp*' -name '*.node' -print -quit 2>/dev/null | grep -q .; then
  ok "sharp 原生模块已构建"
else
  bad "sharp 原生模块缺失"
fi

echo "== 4. 打包元数据 =="
# .desktop 决定三件事：菜单项、窗口与任务的关联（StartupWMClass）、以及 dsh:// 的处理者（MimeType）。
# AppImage 的那份在 squashfs 里，用运行时自带的解包开关取，不需要 FUSE。
appimage="$(find "$OUT" -maxdepth 1 -name '*.AppImage' -print -quit 2>/dev/null)"
if [[ -n "$appimage" ]]; then
  extract="$(mktemp -d)"
  ( cd "$extract" && "$appimage" --appimage-extract '*.desktop' >/dev/null 2>&1 )
  desktop="$(find "$extract" -name '*.desktop' -print -quit 2>/dev/null)"
  if [[ -n "$desktop" ]]; then
    body="$(cat "$desktop")"
    has "$body" 'MimeType=x-scheme-handler/dsh;' 'AppImage 的 .desktop 注册了 dsh:// 处理者'
    has "$body" 'StartupWMClass=deepseek-harness' 'AppImage 的 .desktop 声明了 StartupWMClass'
    # AppRun 自己会探测 user namespace；写死 --no-sandbox 会让菜单启动的每一次都没有沙箱。
    exec_line="$(grep -m1 '^Exec=' "$desktop" || true)"
    if [[ "$exec_line" == *'--no-sandbox'* ]]; then
      bad "AppImage 的 Exec 写死了 --no-sandbox：$exec_line"
    else
      ok "AppImage 的 Exec 没有写死 --no-sandbox（$exec_line）"
    fi
  else
    skip "没能从 AppImage 里取出 .desktop"
  fi
  rm -rf "$extract"
else
  skip "没有 AppImage，跳过 .desktop 检查"
fi

# PKGBUILD 手写一份 .desktop（Arch 包不走 fpm），内容取自上游 deb 里 electron-builder 生成的那份。
pkg_desktop="$(awk '/applications\/deepseek-harness\.desktop/{f=1;next} f&&/^EOF$/{exit} f' "$ROOT/PKGBUILD" 2>/dev/null)"
if [[ -n "$pkg_desktop" ]]; then
  has "$pkg_desktop" 'MimeType=x-scheme-handler/dsh;' 'PKGBUILD 的 .desktop 注册了 dsh:// 处理者'
  has "$pkg_desktop" 'StartupWMClass=deepseek-harness' 'PKGBUILD 的 .desktop 声明了 StartupWMClass'
  has "$pkg_desktop" 'Exec="/opt/deepseek-harness-desktop/deepseek-harness" %U' 'PKGBUILD 的 Exec 用了安装前缀'
else
  skip "没能从 PKGBUILD 里取出 .desktop"
fi

# 策略通道是 Windows/macOS 专有的，Linux 产物里不该出现这个字段（补丁 0010）。
if [[ -f "$APPDSH/package.json" ]]; then
  if grep -q 'dshMandatoryUpdatePolicy' "$APPDSH/package.json"; then
    bad "Linux 产物的 manifest 里出现了 dshMandatoryUpdatePolicy"
  else
    ok "Linux 产物的 manifest 里没有策略字段"
  fi
else
  skip "没有打包后的 manifest，跳过策略字段检查"
fi

echo "== 5. 共享根与 profile 独占（不需要 GUI）=="
if [[ -n "$NODE" && -f "$APPDSH/node_modules/@deepseek-ai/dsh-home-paths/lib/index.js" ]]; then
  read -r home_precedence home_blank <<<"$("$NODE" --input-type=module -e "
    const { resolveDshHome, defaultDshHome } = await import('$APPDSH/node_modules/@deepseek-ai/dsh-home-paths/lib/index.js')
    process.stdout.write([
      resolveDshHome(undefined, { DSH_HOME: '/tmp/x' }) === '/tmp/x',
      resolveDshHome(undefined, { DSH_HOME: '   ' }) === defaultDshHome(),
    ].join(' '))
  " 2>/dev/null)"
  [[ "$home_precedence" == true ]] && ok 'DSH_HOME 覆盖默认根' || bad 'DSH_HOME 没有覆盖默认根'
  [[ "$home_blank" == true ]] && ok '空白的 DSH_HOME 回落到 ~/.dsh' || bad '空白 DSH_HOME 的处理与预期不符'
else
  skip "缺少 dsh-home-paths 的 built lib，跳过根解析检查"
fi

# Linux 上客户端把 x-client-platform 报成 desktop-mac：platform === 'win32' ? 'desktop-win' : 'desktop-mac'。
# 这是记录在案的行为（不是缺陷），但它意味着 Platform 侧看到的是一台 macOS 客户端。
if [[ -n "$NODE" && -f "$APPDSH/node_modules/@deepseek-ai/dsh-deepseek-account/lib/index.js" ]]; then
  platform_header="$("$NODE" --input-type=module -e "
    const { platformClientHeaders } = await import('$APPDSH/node_modules/@deepseek-ai/dsh-deepseek-account/lib/index.js')
    const c = { version: '0', locale: 'en-US', timezoneOffsetSeconds: 0 }
    process.stdout.write(['linux', 'darwin', 'null'].map(p =>
      p === 'null' ? platformClientHeaders(null, c)['x-client-platform']
                   : platformClientHeaders(p, c)['x-client-platform']).join(' '))
  " 2>/dev/null)"
  if [[ "$platform_header" == 'desktop-mac desktop-mac web' ]]; then
    ok "客户端身份：linux→desktop-mac（已记录）、darwin→desktop-mac、null→web"
  else
    bad "客户端身份与记录不符：$platform_header"
  fi
else
  skip "缺少 deepseek-account 的 built lib，跳过客户端身份检查"
fi

# desktop profile 由 Electron 独占：CLI 连参数层面都拒绝它，所以两者不可能写同一个 profile。
if [[ -x "$PRIMARY_NODE" && -f "$CLI" ]]; then
  cli_out="$("$PRIMARY_NODE" "$CLI" --profile desktop --dump-config 2>&1)"; cli_rc=$?
  if (( cli_rc != 0 )) && [[ "$cli_out" == *'managed exclusively by the Electron application'* ]]; then
    ok "CLI 拒绝 desktop profile（exit $cli_rc）"
  else
    bad "CLI 没有拒绝 desktop profile：exit=$cli_rc $cli_out"
  fi
else
  skip "缺少产物里的 CLI，跳过 desktop profile 独占检查"
fi

if (( RUNTIME )); then
  echo "== 6. 活体矩阵（--runtime）=="
  if [[ -z "${WAYLAND_DISPLAY:-}${DISPLAY:-}" ]]; then
    skip "没有显示器（WAYLAND_DISPLAY 与 DISPLAY 都为空）"
  elif ss -ltn 2>/dev/null | grep -q ':19387'; then
    skip "19387 已被占用（可能已经有一个桌面端在跑）"
  else
    APP="$UNPACKED/deepseek-harness"
    LIVE="$(mktemp -d /tmp/dsh-verify-live-XXXXXX)"
    CDP_PORT=9223
    APP_PID=""
    cleanup() {
      [[ -n "$APP_PID" ]] && kill "$APP_PID" 2>/dev/null
      rm -rf "$LIVE"
    }
    trap cleanup EXIT

    # 纪律判据：整个活体过程不许改真实的 ~/.dsh。
    # 比的是「跑前跑后是否一致」，不是「目录是否存在」—— 只要这台机器上装过并用过桌面端，
    # ~/.dsh/profiles/desktop 就必然存在（已装版用的就是真实的 DSH_HOME），断言不存在的话
    # 每次都会误报。指纹取文件名/类型/大小/mtime，改动或新增都会被看出来。
    real_desktop_fingerprint() {
      local d="$HOME/.dsh/profiles/desktop"
      [[ -e "$d" ]] || { printf 'absent\n'; return 0; }
      find "$d" -mindepth 1 -printf '%P\t%y\t%s\t%T@\n' 2>/dev/null | sort
    }
    real_desktop_before="$(real_desktop_fingerprint)"

    # 哨兵：桌面端只许动 profiles/desktop 与共享根，不许碰别的 profile。
    mkdir -p "$LIVE/profiles/web"
    echo "sentinel" >"$LIVE/profiles/web/SENTINEL"
    sentinel_before="$(sha256sum "$LIVE/profiles/web/SENTINEL" | cut -d' ' -f1)"

    DSH_HOME="$LIVE" "$APP" --remote-debugging-port="$CDP_PORT" >"$LIVE/app.log" 2>&1 &
    APP_PID=$!
    ready=0
    for _ in $(seq 1 60); do
      ss -ltn 2>/dev/null | grep -q ':19387' && { ready=1; break; }
      kill -0 "$APP_PID" 2>/dev/null || break
      sleep 1
    done

    if (( ready )); then
      ok "应用起来了，19387 在监听"

      # 用 DevTools 协议问渲染文档本身，而不是只看进程在不在。
      cat >"$LIVE/cdp.mjs" <<'CDP'
const port = process.argv[2]
const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json()
for (const t of list.filter(t => t.type === 'page')) {
  const ws = new WebSocket(t.webSocketDebuggerUrl)
  await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej })
  const value = await new Promise(res => {
    ws.addEventListener('message', ev => {
      const m = JSON.parse(ev.data)
      if (m.id === 1) res(m.result?.result?.value ?? '')
    })
    ws.send(JSON.stringify({ id: 1, method: 'Runtime.evaluate', params: {
      expression: `location.href + ' ' + document.querySelectorAll('*').length`, returnByValue: true } }))
  })
  console.log(value)
  ws.close()
}
CDP
      # 19387 一开始监听时 renderer 往往还在加载，所以要等到节点数连续两次一样（渲染稳定）为止。
      cdp_out=""; app_nodes=""; prev_nodes=""
      for _ in $(seq 1 60); do
        cdp_out="$(env -u NODE_OPTIONS -u NODE_USE_ENV_PROXY -u http_proxy -u https_proxy \
          -u HTTP_PROXY -u HTTPS_PROXY "$NODE" "$LIVE/cdp.mjs" "$CDP_PORT" 2>/dev/null)"
        app_page="$(grep -m1 '^dsh-app://' <<<"$cdp_out" || true)"
        cur_nodes="${app_page##* }"
        if [[ "$cur_nodes" =~ ^[0-9]+$ ]] && (( cur_nodes > 100 )) && [[ "$cur_nodes" == "$prev_nodes" ]]; then
          app_nodes="$cur_nodes"; break
        fi
        prev_nodes="$cur_nodes"
        sleep 1
      done
      if [[ -n "$app_nodes" ]]; then
        ok "dsh-app:// 加载出了 UI（$app_nodes 个 DOM 节点，已稳定）"
      else
        bad "dsh-app:// 没有渲染出 UI（最后一次探测：${cdp_out:-无输出}）"
      fi

      # Host 必须跑在 primary-runtime 自带的真 Node 上（Electron 的 node 模式下 sharp 会段错误）。
      host_pid=""
      for p in $(pgrep -f 'dsh-desktop-host' 2>/dev/null); do
        if [[ "$(readlink -f "/proc/$p/exe" 2>/dev/null)" == "$(readlink -f "$PRIMARY_NODE")" ]]; then
          host_pid="$p"; break
        fi
      done
      if [[ -n "$host_pid" ]]; then
        ok "Host 进程跑在 primary-runtime 的真 Node 上（pid $host_pid）"
      else
        bad "没有找到跑在 primary-runtime Node 上的 Host 进程"
      fi

      # 沙箱：渲染进程在独立 user namespace 里且 seccomp 生效，主进程不在。
      main_ns="$(readlink "/proc/$APP_PID/ns/pid" 2>/dev/null)"
      sandboxed=0; renderers=0
      for p in $(pgrep -f -- '--type=renderer' 2>/dev/null); do
        [[ "$(readlink -f "/proc/$p/exe" 2>/dev/null)" == "$(readlink -f "$APP")" ]] || continue
        renderers=$((renderers+1))
        [[ "$(readlink "/proc/$p/ns/pid" 2>/dev/null)" != "$main_ns" ]] || continue
        grep -q '^Seccomp:\s*2' "/proc/$p/status" 2>/dev/null && sandboxed=$((sandboxed+1))
      done
      if (( renderers > 0 && sandboxed == renderers )); then
        ok "全部 $renderers 个渲染进程都在独立 user namespace 里且 seccomp 生效"
      else
        bad "渲染进程沙箱不完整（$sandboxed/$renderers）"
      fi

      # 共享根：会话与凭据落在根上，而不是某个 profile 里。会话由 Host 在启动后异步建立。
      [[ -d "$LIVE/profiles/desktop" ]] && ok 'profiles/desktop 已建立' || bad 'profiles/desktop 没有建立'
      session_seen=0
      for _ in $(seq 1 30); do
        if find "$LIVE/sessions" -name 'session.v*.jsonl*' -print -quit 2>/dev/null | grep -q .; then
          session_seen=1; break
        fi
        sleep 1
      done
      (( session_seen )) && ok '共享根里出现了会话记录' || bad '共享根里没有会话记录'
      [[ -f "$LIVE/.credentials.yaml" ]] && ok '共享根里出现了凭据文件' || bad '共享根里没有凭据文件'
      if [[ "$(sha256sum "$LIVE/profiles/web/SENTINEL" | cut -d' ' -f1)" == "$sentinel_before" ]]; then
        ok 'profiles/web 的哨兵未被触碰'
      else
        bad 'profiles/web 被改动了'
      fi

      # 交叉验证：CLI 在同一个根上跑，profiles/desktop 必须逐字节不变。
      if [[ -x "$PRIMARY_NODE" && -f "$CLI" ]]; then
        desktop_before="$(find "$LIVE/profiles/desktop" -type f -exec sha256sum {} \; 2>/dev/null | sort)"
        DSH_HOME="$LIVE" "$PRIMARY_NODE" "$CLI" --profile web --dump-config >/dev/null 2>&1
        desktop_after="$(find "$LIVE/profiles/desktop" -type f -exec sha256sum {} \; 2>/dev/null | sort)"
        if [[ -n "$desktop_before" && "$desktop_before" == "$desktop_after" ]]; then
          ok 'CLI 在同一根上跑完，profiles/desktop 逐字节未变'
        else
          bad 'CLI 动了 profiles/desktop'
        fi
      fi
    else
      bad "应用没能在 60 秒内监听 19387（日志见下）"
      sed 's/^/         /' "$LIVE/app.log" | tail -10
    fi

    # 纪律：整个活体过程不许碰真实的 ~/.dsh。
    if [[ "$(real_desktop_fingerprint)" == "$real_desktop_before" ]]; then
      if [[ "$real_desktop_before" == absent ]]; then
        ok '真实的 ~/.dsh 未被触碰（没有 profiles/desktop）'
      else
        ok '真实的 ~/.dsh/profiles/desktop 存在，但本次活体过程未改动它'
      fi
    else
      bad '真实的 ~/.dsh/profiles/desktop 被改动了——桌面端泄漏到了正在使用的数据目录'
    fi

    kill "$APP_PID" 2>/dev/null
    wait "$APP_PID" 2>/dev/null
    APP_PID=""
  fi
else
  echo "== 6. 活体矩阵（--runtime）=="
  skip "没给 --runtime"
fi

echo "== 7. 端口不冲突 =="
if ss -ltnp 2>/dev/null | grep -q ':3080'; then
  ok "3080 上的 web GUI 未受影响"
else
  skip "3080 没在监听"
fi

echo
echo "== 汇总：$pass 通过 / $fail 失败 / $skipped 跳过 =="
(( fail == 0 ))
