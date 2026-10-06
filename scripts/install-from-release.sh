#!/usr/bin/env bash
# 从 GitHub Release 下载最新的 Linux 产物并安装，不需要本地构建。
#
#   ./scripts/install-from-release.sh
#   REPO=someone/other-fork ./scripts/install-from-release.sh
#   TAG=linux-latest ./scripts/install-from-release.sh
#
# 这是「全自动」那条路的消费端：CI 在 update-feed.yml 里构建并发布，这里把产物取下来装好。
# 装出来的 AppImage 内嵌的更新源指向同一个 release，所以应用内「检查更新」是通的。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="${REPO:-JamesYasR/dsh-desktop-linux}"
TAG="${TAG:-linux-latest}"
WORK="${WORK:-$ROOT/.release-download}"

command -v curl >/dev/null || { echo "需要 curl" >&2; exit 1; }

api="https://api.github.com/repos/$REPO/releases/tags/$TAG"
echo "==> 读取 release：$REPO @ $TAG"
listing="$(curl -fsSL "$api")" || {
  echo "拿不到 release（私有仓库、tag 不存在或没网？）：$api" >&2
  exit 1
}

appimage_url="$(printf '%s' "$listing" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assets = [a for a in d.get("assets", []) if a["name"].endswith(".AppImage")]
if not assets:
    raise SystemExit("release 里没有 .AppImage")
print(assets[0]["browser_download_url"])
')" || { echo "release 里没有 AppImage" >&2; exit 1; }

mkdir -p "$WORK"
name="$(basename "$appimage_url")"
echo "==> 下载 $name"
curl -fL --progress-bar -o "$WORK/$name" "$appimage_url"
chmod +x "$WORK/$name"

# 通道元数据一并取下，方便核对 feed 公布的版本与校验和。
if curl -fsSL -o "$WORK/nightly-linux.yml" \
    "https://github.com/$REPO/releases/download/$TAG/nightly-linux.yml" 2>/dev/null; then
  echo "==> 通道元数据"
  grep -E '^(version|path|sha512):' "$WORK/nightly-linux.yml" | sed 's/^/    /'
fi

# 校验下载到的字节与 feed 公布的 sha512 一致——CI 产物也要过这一关再用。
if [[ -f "$WORK/nightly-linux.yml" ]]; then
  expected="$(python3 - "$WORK/nightly-linux.yml" <<'PY'
import base64, hashlib, re, sys
text = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"^sha512:\s*(\S+)$", text, re.M)
print(m.group(1) if m else "")
PY
)"
  if [[ -n "$expected" ]]; then
    actual="$(python3 - "$WORK/$name" <<'PY'
import base64, hashlib, sys
print(base64.b64encode(hashlib.sha512(open(sys.argv[1], "rb").read()).digest()).decode())
PY
)"
    if [[ "$expected" == "$actual" ]]; then
      echo "==> [PASS] sha512 与 feed 一致"
    else
      echo "==> [FAIL] sha512 不一致，拒绝安装" >&2
      exit 1
    fi
  fi
fi

echo "==> 安装"
ARTIFACTS="$WORK" "$ROOT/scripts/install-user.sh"
