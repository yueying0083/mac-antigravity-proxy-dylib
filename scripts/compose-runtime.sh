#!/usr/bin/env bash
# Apply a version-matched Chinese localization pack, then inject the context
# viewer, only inside the runtime copy. Never touch /Applications/Antigravity.app.
set -euo pipefail

VIEWER_VERSION="${VIEWER_VERSION:-0.9.3}"
NODE_VERSION="${NODE_VERSION:-v22.21.1}"
LOCALIZATION_REPO="antigravity-cn-community/Antigravity-Chinese-Localization"
VIEWER_REPO="elviscjn-cjn/antigravity-context-viewer"

INNER_APP=""
CACHE_DIR=""
PROXY_URL=""

usage() {
  cat <<'EOF'
Usage: compose-runtime.sh --app PATH --cache PATH [--proxy URL]

--app    Runtime inner Antigravity.app. Must not be /Applications/Antigravity.app.
--cache  Download cache for the localization pack and context viewer.
--proxy  Optional proxy URL used for GitHub and nodejs.org downloads.
EOF
}

while (($#)); do
  case "$1" in
    --app)
      INNER_APP="${2:-}"
      shift 2
      ;;
    --cache)
      CACHE_DIR="${2:-}"
      shift 2
      ;;
    --proxy)
      PROXY_URL="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ -n "$INNER_APP" && -n "$CACHE_DIR" ]] || { usage >&2; exit 2; }
[[ -d "$INNER_APP" ]] || { echo "Runtime app not found: $INNER_APP" >&2; exit 1; }

case "$INNER_APP" in
  /Applications/Antigravity.app|/Applications/Antigravity.app/*)
    echo "Refusing to modify the original /Applications/Antigravity.app" >&2
    exit 1
    ;;
esac

ASAR="$INNER_APP/Contents/Resources/app.asar"
PLIST="$INNER_APP/Contents/Info.plist"
[[ -f "$ASAR" && -f "$PLIST" ]] || { echo "Runtime app is missing app.asar or Info.plist" >&2; exit 1; }

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "只支持 Apple Silicon (arm64)。" >&2
  exit 1
fi

mkdir -p "$CACHE_DIR"
CURL_PROXY="$PROXY_URL"
CURL_PROXY="${CURL_PROXY/socks5:\/\//socks5h:\/\/}"
CURL=(curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20)
if [[ -n "$CURL_PROXY" ]]; then
  CURL+=(--proxy "$CURL_PROXY")
fi

progress() {
  printf 'PROGRESS %s\n' "$*" >&2
}

human_bytes() {
  local n="${1:-0}"
  if [[ "$n" -ge 1048576 ]]; then
    awk -v n="$n" 'BEGIN { printf "%.1f MB", n / 1048576 }'
  elif [[ "$n" -ge 1024 ]]; then
    awk -v n="$n" 'BEGIN { printf "%.0f KB", n / 1024 }'
  else
    printf '%s B' "$n"
  fi
}

check_proxy() {
  [[ -n "$PROXY_URL" ]] || { echo "未配置下载代理。" >&2; exit 1; }
  local rest host port
  rest="${PROXY_URL#*://}"
  rest="${rest%%/*}"
  host="${rest%%:*}"
  port="${rest##*:}"
  if [[ -z "$host" || -z "$port" || "$host" == "$port" ]]; then
    echo "代理地址无法解析: $PROXY_URL" >&2
    exit 1
  fi
  progress "检查代理 ${host}:${port}"
  if ! nc -z -G 3 "$host" "$port"; then
    echo "代理不可用: $PROXY_URL。请先启动 Clash 或代理软件。" >&2
    exit 1
  fi
  progress "代理可用，下载将通过 ${PROXY_URL}"
}

content_length() {
  local url="$1"
  local headers size
  headers="$("${CURL[@]}" -I -L -D - -o /dev/null "$url" 2>/dev/null || true)"
  size="$(printf '%s\n' "$headers" | awk 'tolower($1) == "content-length:" { value = $2 } END { gsub("\r", "", value); print value + 0 }')"
  printf '%s' "${size:-0}"
}

download_file() {
  local url="$1"
  local dest="$2"
  local label="$3"
  local tmp pid total got pct last_pct
  mkdir -p "$(dirname "$dest")"
  tmp="$(mktemp "${TMPDIR:-/tmp}/antigravity-compose.XXXXXX")"
  total="$(content_length "$url")"
  progress "开始下载 ${label}"
  "${CURL[@]}" -L --fail -o "$tmp" "$url" &
  pid=$!
  last_pct=-1
  while kill -0 "$pid" 2>/dev/null; do
    got=0
    [[ -f "$tmp" ]] && got="$(stat -f %z "$tmp")"
    if [[ "$total" -gt 0 ]]; then
      pct="$(( got * 100 / total ))"
      if [[ "$pct" != "$last_pct" ]]; then
        progress "下载 ${label}  ${pct}%  ($(human_bytes "$got")/$(human_bytes "$total"))"
        last_pct="$pct"
      fi
    else
      progress "下载 ${label}  $(human_bytes "$got")"
    fi
    sleep 0.4
  done
  if ! wait "$pid"; then
    rm -f "$tmp"
    echo "下载失败: ${label}" >&2
    echo "$url" >&2
    return 1
  fi
  mv "$tmp" "$dest"
  got="$(stat -f %z "$dest")"
  progress "已完成 ${label}  ($(human_bytes "$got"))"
}

node_version_of() {
  local bin="$1"
  [[ -x "$bin" ]] || return 1
  "$bin" -p 'process.version'
}

ensure_node() {
  local candidate version login_node
  local -a candidates=()
  candidates+=("${NODE_BIN:-}")
  candidates+=("$HOME/.nvm/versions/node/${NODE_VERSION}/bin/node")
  candidates+=("$HOME/.local/share/fnm/node-versions/${NODE_VERSION}/installation/bin/node")
  candidates+=("$HOME/.asdf/installs/nodejs/${NODE_VERSION}/bin/node")
  candidates+=("/opt/homebrew/opt/node@22/bin/node")
  candidates+=("/usr/local/opt/node@22/bin/node")
  if login_node="$(zsh -lic 'command -v node' 2>/dev/null)"; then
    candidates+=("$login_node")
  fi
  candidates+=("$(command -v node 2>/dev/null || true)")

  for candidate in "${candidates[@]}"; do
    [[ -n "$candidate" ]] || continue
    version="$(node_version_of "$candidate" || true)"
    if [[ "$version" == "$NODE_VERSION" ]]; then
      NODE="$candidate"
      progress "使用本机 Node.js $version"
      return
    fi
  done

  local node_name="node-${NODE_VERSION}-darwin-arm64"
  local node_root="$CACHE_DIR/node/${node_name}"
  NODE="$node_root/bin/node"
  if node_version_of "$NODE" >/dev/null && [[ "$(node_version_of "$NODE")" == "$NODE_VERSION" ]]; then
    progress "使用已缓存的 Node.js ${NODE_VERSION}"
    return
  fi

  progress "本机没有 Node.js ${NODE_VERSION}，改为通过代理下载"
  local sums="$CACHE_DIR/node/SHASUMS256.txt"
  local tarball="$CACHE_DIR/node/${node_name}.tar.gz"
  mkdir -p "$CACHE_DIR/node"
  download_file "https://nodejs.org/dist/${NODE_VERSION}/SHASUMS256.txt" "$sums" "Node.js 校验文件"
  download_file "https://nodejs.org/dist/${NODE_VERSION}/${node_name}.tar.gz" "$tarball" "Node.js ${NODE_VERSION}"
  local expected actual
  expected="$(awk -v name="${node_name}.tar.gz" '$2 == name { print $1; exit }' "$sums")"
  actual="$(sha256_file "$tarball")"
  if [[ -z "$expected" || "$expected" != "$actual" ]]; then
    echo "Node.js 校验失败。expected=${expected:-missing} actual=$actual" >&2
    rm -f "$tarball"
    exit 1
  fi
  rm -rf "$node_root"
  tar -xzf "$tarball" -C "$CACHE_DIR/node"
  mv "$CACHE_DIR/node/${node_name}" "$node_root"
  xattr -dr com.apple.quarantine "$node_root" 2>/dev/null || true
  progress "Node.js ${NODE_VERSION} 已就绪"
}

read_host_version() {
  ASAR_PATH="$ASAR" "$NODE" <<'JS'
const fs = require("fs");
const asarPath = process.env.ASAR_PATH;
const buf = fs.readFileSync(asarPath);
const jsonSize = buf.readUInt32LE(12);
const header = JSON.parse(buf.subarray(16, 16 + jsonSize).toString("utf8"));
const entry = header.files && header.files["package.json"];
if (!entry || entry.size == null || entry.offset == null) {
  console.error("root package.json not found in app.asar");
  process.exit(1);
}
const dataStart = 16 + ((jsonSize + 3) & ~3);
const start = dataStart + Number(entry.offset);
const pkg = JSON.parse(buf.subarray(start, start + Number(entry.size)).toString("utf8"));
if (!pkg.version) {
  console.error("app.asar package.json has no version");
  process.exit(1);
}
process.stdout.write(String(pkg.version));
JS
}

sha256_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

lookup_release_asset() {
  local repo="$1"
  local version="$2"
  local asset_name="$3"
  local json="$4"
  progress "在 ${repo} 查找 ${version} 的 ${asset_name}"
  local tag_url="https://api.github.com/repos/${repo}/releases/tags/v${version}"
  local list_url="https://api.github.com/repos/${repo}/releases?per_page=100"
  if ! "${CURL[@]}" -H "Accept: application/vnd.github+json" -H "User-Agent: antigravity-proxy" -o "$json" "$tag_url"; then
    progress "没有同名标签，改为检索发布列表"
    if ! "${CURL[@]}" -H "Accept: application/vnd.github+json" -H "User-Agent: antigravity-proxy" -o "$json" "$list_url"; then
      echo "无法读取 ${repo} 的发布列表。" >&2
      return 1
    fi
  fi
  ASSET_NAME="$asset_name" RELEASE_VERSION="$version" RELEASE_JSON="$json" "$NODE" <<'JS'
const fs = require("fs");
const wantedVersion = process.env.RELEASE_VERSION;
const wantedAsset = process.env.ASSET_NAME;
const raw = JSON.parse(fs.readFileSync(process.env.RELEASE_JSON, "utf8"));
const releases = Array.isArray(raw) ? raw : [raw];
const release = releases.find((item) => item && item.tag_name === `v${wantedVersion}`);
if (!release) {
  console.error(`汉化或发布列表中没有 v${wantedVersion}`);
  process.exit(1);
}
const asset = (release.assets || []).find((item) => item.name === wantedAsset);
if (!asset || !asset.browser_download_url) {
  console.error(`v${wantedVersion} 中没有 ${wantedAsset}`);
  process.exit(1);
}
process.stdout.write(asset.browser_download_url);
JS
}

install_localization() {
  local version="$1"
  local release_dir="$CACHE_DIR/localization/v${version}"
  local packed="$release_dir/app.asar"
  local sums="$release_dir/SHA256SUMS.txt"
  local meta="$release_dir/release.json"
  mkdir -p "$release_dir"

  local sums_url asar_url
  sums_url="$(lookup_release_asset "$LOCALIZATION_REPO" "$version" "SHA256SUMS.txt" "$meta")"
  asar_url="$(lookup_release_asset "$LOCALIZATION_REPO" "$version" "app.asar" "$meta")"
  progress "已找到汉化包 v${version}"

  if [[ ! -f "$sums" ]]; then
    download_file "$sums_url" "$sums" "汉化校验文件 v${version}"
  fi
  local expected=""
  if [[ -f "$sums" ]]; then
    expected="$(awk '$2 == "app.asar" { print $1; exit }' "$sums")"
  fi
  if [[ -f "$packed" && -n "$expected" && "$(sha256_file "$packed")" == "$expected" ]]; then
    progress "使用已缓存的汉化包 v${version}"
  else
    download_file "$asar_url" "$packed" "汉化包 app.asar v${version}"
  fi

  local expected actual
  expected="$(awk '$2 == "app.asar" {print $1; exit}' "$sums")"
  actual="$(sha256_file "$packed")"
  if [[ -z "$expected" || "$expected" != "$actual" ]]; then
    echo "汉化包校验失败，删除缓存后重试。expected=${expected:-missing} actual=$actual" >&2
    rm -rf "$release_dir"
    exit 1
  fi

  local packed_version
  local saved="$ASAR"
  ASAR="$packed"
  packed_version="$(read_host_version)"
  ASAR="$saved"
  if [[ "$packed_version" != "$version" ]]; then
    echo "汉化包内部版本是 ${packed_version}，与本机 Antigravity ${version} 不一致。" >&2
    exit 1
  fi

  cp "$packed" "$ASAR"
  echo "Applied Chinese localization v${version}"
}

install_viewer() {
  local zip_name="antigravity-context-viewer_${VIEWER_VERSION}_darwin_arm64.zip"
  local release_dir="$CACHE_DIR/viewer/v${VIEWER_VERSION}"
  local zip_path="$release_dir/$zip_name"
  local sums="$release_dir/checksums.txt"
  local meta="$release_dir/release.json"
  mkdir -p "$release_dir"

  if [[ ! -f "$release_dir/cli.js" ]]; then
    local sums_url zip_url
    sums_url="$(lookup_release_asset "$VIEWER_REPO" "$VIEWER_VERSION" "checksums.txt" "$meta")"
    zip_url="$(lookup_release_asset "$VIEWER_REPO" "$VIEWER_VERSION" "$zip_name" "$meta")"
    progress "已找到上下文查看器 v${VIEWER_VERSION}"
    download_file "$sums_url" "$sums" "上下文查看器校验文件"
    download_file "$zip_url" "$zip_path" "上下文查看器 v${VIEWER_VERSION}"
    local expected actual
    expected="$(awk -v name="$zip_name" '$2 == name {print $1; exit}' "$sums")"
    actual="$(sha256_file "$zip_path")"
    if [[ -z "$expected" || "$expected" != "$actual" ]]; then
      echo "上下文查看器校验失败。expected=${expected:-missing} actual=$actual" >&2
      rm -rf "$release_dir"
      exit 1
    fi
    local unpack="$release_dir/src"
    rm -rf "$unpack"
    mkdir -p "$unpack"
    ditto -x -k "$zip_path" "$unpack"
    local cli
    cli="$(find "$unpack" -name cli.js -print -quit)"
    [[ -n "$cli" ]] || { echo "上下文查看器压缩包里没有 cli.js" >&2; exit 1; }
    local src_dir
    src_dir="$(dirname "$cli")"
    find "$src_dir" -mindepth 1 -maxdepth 1 -exec mv {} "$release_dir/" \;
    rm -rf "$unpack"
    xattr -dr com.apple.quarantine "$release_dir" 2>/dev/null || true
  fi

  local state_dir="$CACHE_DIR/viewer-state"
  mkdir -p "$state_dir"
  progress "正在注入上下文查看器"
  (
    cd "$release_dir"
    ASAR_PATH="$ASAR" STATE_DIR="$state_dir" "$NODE" <<'JS'
const { install } = require("./install");
install({
  path: process.env.ASAR_PATH,
  allowIntegrityOverride: true,
  noHotInject: true,
  pureMeterOnly: true,
  silent: true,
  stateDir: process.env.STATE_DIR
}).then((manifest) => {
  if (!manifest || !manifest.installed) {
    console.error("context viewer install returned no manifest");
    process.exit(1);
  }
  console.log(`viewer ${manifest.meterVersion || ""} installed for host ${manifest.version || ""}`);
}).catch((error) => {
  console.error(error && error.stack ? error.stack : error);
  process.exit(1);
});
JS
  )
}

verify_composition() {
  local version="$1"
  local viewer_dir="$CACHE_DIR/viewer/v${VIEWER_VERSION}"
  (
    cd "$viewer_dir"
    ASAR_PATH="$ASAR" EXPECTED_VERSION="$version" "$NODE" <<'JS'
const { extractAsarFile } = require("./install");
const asarPath = process.env.ASAR_PATH;
const preload = extractAsarFile(asarPath, "dist/preload.js").toString("utf8");
const utils = extractAsarFile(asarPath, "dist/utils.js").toString("utf8");
const pkg = JSON.parse(extractAsarFile(asarPath, "package.json").toString("utf8"));
if (pkg.version !== process.env.EXPECTED_VERSION) {
  console.error(`composed asar version ${pkg.version} != ${process.env.EXPECTED_VERSION}`);
  process.exit(1);
}
if (!preload.includes("Antigravity 2.0 Chinese Localization Engine")) {
  console.error("localized preload marker is missing after viewer injection");
  process.exit(1);
}
if (!utils.includes("installContextMeter")) {
  console.error("context viewer marker is missing after injection");
  process.exit(1);
}
console.log(`composed asar OK: host ${pkg.version}, localization + context viewer`);
JS
  )
}

update_integrity() {
  local hash
  hash="$(sha256_file "$ASAR")"
  /usr/libexec/PlistBuddy -c "Set :ElectronAsarIntegrity:Resources/app.asar:algorithm SHA256" "$PLIST" \
    || /usr/libexec/PlistBuddy -c "Add :ElectronAsarIntegrity:Resources/app.asar:algorithm string SHA256" "$PLIST"
  /usr/libexec/PlistBuddy -c "Set :ElectronAsarIntegrity:Resources/app.asar:hash $hash" "$PLIST" \
    || /usr/libexec/PlistBuddy -c "Add :ElectronAsarIntegrity:Resources/app.asar:hash string $hash" "$PLIST"
  echo "Updated ElectronAsarIntegrity to $hash"
}

check_proxy
ensure_node
HOST_VERSION="$(read_host_version)"
progress "本机 Antigravity 版本 ${HOST_VERSION}"
install_localization "$HOST_VERSION"
install_viewer
verify_composition "$HOST_VERSION"
update_integrity
echo "Compose finished"
