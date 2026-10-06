#!/usr/bin/env bash
# 端到端验证 Linux 应用内更新：在本地起一条 electron-updater generic feed，跑真正的 AppImage，
# 断言它启动后确实去查了这条 feed、并把 feed 里的版本识别成可更新版本。
#
#   ./scripts/verify-update.sh
#
# 需要图形显示（AppImage 要有真实会话才能起窗口）。证据留在 .verify/ 下：
#   .verify/feed/          本地 feed（修改过 version 的通道元数据 + 同一份 AppImage 作为载荷）
#   .verify/http.log       feed 的访问日志：能直接看到应用请求了 nightly-linux.yml
#   .verify/journal/*.jsonl 应用自己写的更新状态流水（需要 DSH_DESKTOP_UPDATE_JOURNAL_DIR）
#   .verify/app.log        应用 stdout/stderr
#   .verify/screenshot.png 窗口截图（有截图工具时）
#
# 退出码 0 表示「应用启动 + 更新检查命中 feed + 识别到更高版本」三件都成立。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFY="$ROOT/.verify"
ART="${ARTIFACTS:-$ROOT/upstream/apps/desktop/.desktop-build/targets/linux-x64/unsigned-artifacts}"
PORT="${PORT:-8899}"
# feed 里公布的版本必须高于产物自身版本，否则应用只会报「已是最新」，验证不到 available。
FEED_VERSION="${FEED_VERSION:-9.9.9}"
WAIT_SECONDS="${WAIT_SECONDS:-120}"

command -v python3 >/dev/null || { echo "需要 python3 起 feed" >&2; exit 1; }

appimage="$(find "$ART" -maxdepth 1 -name '*.AppImage' -print -quit 2>/dev/null)"
metadata="$(find "$ART" -maxdepth 1 -name '*-linux.yml' -print -quit 2>/dev/null)"
[[ -n "$appimage" ]] || { echo "找不到 AppImage（$ART）；先跑 scripts/build.sh --appimage" >&2; exit 1; }
[[ -n "$metadata" ]] || { echo "找不到通道元数据（$ART）；产物没有嵌入更新 feed，检查 .env.linux 的 DSH_DESKTOP_LINUX_UPDATE_ORIGIN" >&2; exit 1; }

rm -rf "$VERIFY"
mkdir -p "$VERIFY/feed" "$VERIFY/journal" "$VERIFY/home"
cp "$appimage" "$VERIFY/feed/"
cp "$metadata" "$VERIFY/feed/"
yml="$VERIFY/feed/$(basename "$metadata")"
sed -i "s/^version: .*/version: $FEED_VERSION/" "$yml"

# 被测应用默认就是构建产物；装进系统后可以用 APPIMAGE_PATH 指向装好的那份，
# feed 里的载荷仍然用构建产物（两者字节相同）。
under_test="${APPIMAGE_PATH:-$appimage}"
[[ -x "$under_test" ]] || { echo "被测 AppImage 不可执行：$under_test" >&2; exit 1; }

echo "==> 被测应用：$under_test"
echo "==> 通道元数据：$(basename "$metadata")，feed 公布版本 $FEED_VERSION"
grep -E '^(version|path|sha512):' "$yml" | sed 's/^/    /'

python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$VERIFY/feed" > "$VERIFY/http.log" 2>&1 &
feed_pid=$!
trap 'kill "$feed_pid" "${app_pid:-}" 2>/dev/null' EXIT
sleep 1

export DSH_DESKTOP_LINUX_UPDATE_ORIGIN="http://127.0.0.1:$PORT"
export DSH_DESKTOP_UPDATE_JOURNAL_DIR="$VERIFY/journal"
export DSH_DESKTOP_UPDATE_CHECK_INTERVAL_MS=15000
export DSH_HOME="$VERIFY/home"

echo "==> 启动 AppImage（feed=$DSH_DESKTOP_LINUX_UPDATE_ORIGIN）"
"$under_test" > "$VERIFY/app.log" 2>&1 &
app_pid=$!

deadline=$((SECONDS + WAIT_SECONDS))
phase=""
while (( SECONDS < deadline )); do
  if ! kill -0 "$app_pid" 2>/dev/null; then
    echo "!! 应用在验证窗口内退出（见 .verify/app.log）" >&2
    break
  fi
  phase="$(cat "$VERIFY"/journal/*.jsonl 2>/dev/null \
    | grep -o '"phase":"[a-z]*"' | sed 's/.*:"//;s/"//' | tail -1)"
  case "$phase" in
    available|ready|downloading) break ;;
  esac
  sleep 3
done

# 截图是给人看的附加证据，拿不到不算失败。
if command -v import >/dev/null 2>&1; then
  import -window root "$VERIFY/screenshot.png" 2>/dev/null || rm -f "$VERIFY/screenshot.png"
fi

kill "$app_pid" 2>/dev/null
sleep 2
kill -9 "$app_pid" 2>/dev/null
kill "$feed_pid" 2>/dev/null

echo
echo "==> feed 访问日志"
sed 's/^/    /' "$VERIFY/http.log"
echo "==> 更新状态流水"
cat "$VERIFY"/journal/*.jsonl 2>/dev/null | sed 's/^/    /' || echo "    （没有 journal，说明应用没起来）"

fail=0
if [[ -f "$VERIFY/app.log" ]]; then
  grep -q 'dsh web: http://127.0.0.1:' "$VERIFY/app.log" \
    && echo "==> [PASS] Harness Host 已监听" \
    || { echo "==> [FAIL] 没看到 Host 监听日志"; fail=1; }
else
  echo "==> [FAIL] 没有应用日志"; fail=1
fi
grep -q 'nightly-linux.yml' "$VERIFY/http.log" \
  && echo "==> [PASS] 应用请求了 feed 的 nightly-linux.yml" \
  || { echo "==> [FAIL] 应用没有请求 feed（更新器没启用或地址不对）"; fail=1; }
case "$phase" in
  available|ready|downloading)
    echo "==> [PASS] 应用识别到 feed 上的更高版本（phase=$phase）" ;;
  *)
    echo "==> [FAIL] 应用没有识别到更高版本（最后 phase='${phase:-无}'）"; fail=1 ;;
esac

echo
[[ $fail == 0 ]] && echo "结果：全部通过" || echo "结果：有失败项"
exit $fail
