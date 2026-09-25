#!/usr/bin/env bash
# 验证矩阵（阶段 5）。逐项检查，失败不中断，最后汇总。
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

pass=0; fail=0
ok()   { echo "  [PASS] $1"; pass=$((pass+1)); }
bad()  { echo "  [FAIL] $1"; fail=$((fail+1)); }
skip() { echo "  [SKIP] $1"; }

# unsigned 构建的输出目录（见 electron-builder-config.mjs 的 directories.output）
OUT="$UPSTREAM/apps/desktop/.desktop-build/targets/linux-x64/unsigned-artifacts"

echo "== 1. 产物存在 =="
mapfile -t artifacts < <(find "$OUT" -maxdepth 1 \
  \( -name '*.AppImage' -o -name '*.deb' -o -name '*.rpm' \) 2>/dev/null)
if (( ${#artifacts[@]} > 0 )); then
  for a in "${artifacts[@]}"; do ok "$(basename "$a") ($(du -h "$a" | cut -f1))"; done
else
  bad "没找到 AppImage/deb/rpm 产物（$OUT）"
fi

echo "== 2. 未打包目录可执行 =="
if [[ -x "$OUT/linux-unpacked/deepseek-harness" ]]; then
  ok "linux-unpacked/deepseek-harness"
  # 真 Node 读不了 asar，Linux 上 dsh 必须是一棵真目录树。
  if [[ -d "$OUT/linux-unpacked/resources/app/dsh/node_modules" ]]; then
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

echo "== 4. profile 隔离（不污染 web） =="
if [[ -d "$DSH_HOME/profiles/desktop" ]]; then
  ok "$DSH_HOME/profiles/desktop 存在"
else
  skip "$DSH_HOME/profiles/desktop 不存在（桌面端还没跑过）"
fi
if [[ "$DSH_HOME" == "$HOME/.dsh" ]]; then
  bad "DSH_HOME 指向了正在使用的 ~/.dsh！"
else
  ok "DSH_HOME 已隔离：$DSH_HOME"
fi

echo "== 5. 端口不冲突 =="
if ss -ltnp 2>/dev/null | grep -q ':19387'; then
  ok "19387 被占用（桌面端在跑）"
else
  skip "19387 空闲（桌面端没在跑）"
fi
if ss -ltnp 2>/dev/null | grep -q ':3080'; then
  ok "3080 上的 web GUI 未受影响"
else
  skip "3080 没在监听"
fi

echo
echo "== 汇总：$pass 通过 / $fail 失败 =="
(( fail == 0 ))
