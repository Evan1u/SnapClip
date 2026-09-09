#!/bin/sh

set -u

REPOSITORY="Evan1u/SnapClip"
BUNDLE_ID="com.local.SnapClip"
DEFAULT_APP_PATH="/Applications/SnapClip.app"
API_URL="https://api.github.com/repos/${REPOSITORY}/releases?per_page=100"

APP_PATH_INPUT=${SNAPCLIP_APP_PATH:-$DEFAULT_APP_PATH}
TEST_MODE=${SNAPCLIP_TEST_MODE:-0}
MODE=update
TEMP_DIR=
LOCK_DIR=
LOCK_HELD=0
STAGING_PATH=
BACKUP_PATH=
FAILED_PATH=
OLD_WAS_RUNNING=0
OLD_STOPPED=0
COMMITTED=0
SUDO_NEEDED=0
ROLLING_BACK=0

log() {
  /bin/echo "SnapClip Updater: $*"
}

fail() {
  log "错误：$*" >&2
  exit 1
}

usage() {
  /bin/cat <<'EOF'
用法：./scripts/update-snapclip.sh [--check | --dry-run | --help]

  --check    只比较本地与远端版本
  --dry-run  显示将要执行的更新，不下载或替换应用
  --help     显示帮助

默认安装路径是 /Applications/SnapClip.app；可用 SNAPCLIP_APP_PATH 覆盖。
EOF
}

for argument in "$@"; do
  case "$argument" in
    --check)
      [ "$MODE" = update ] || fail "参数不能组合使用"
      MODE=check
      ;;
    --dry-run)
      [ "$MODE" = update ] || fail "参数不能组合使用"
      MODE=dry-run
      ;;
    --help)
      [ "$#" -eq 1 ] || fail "--help 不能与其他参数组合"
      usage
      exit 0
      ;;
    *)
      fail "未知参数：$argument"
      ;;
  esac
done

case "$APP_PATH_INPUT" in
  /*) ;;
  *) fail "SNAPCLIP_APP_PATH 必须是绝对路径" ;;
esac

case "$APP_PATH_INPUT" in
  *.app) ;;
  *) fail "目标路径必须以 .app 结尾" ;;
esac

case "$APP_PATH_INPUT" in
  *"
"* | *""*) fail "目标路径不能包含换行符" ;;
esac

APP_PARENT_INPUT=$(/usr/bin/dirname "$APP_PATH_INPUT") || fail "无法解析目标父目录"
APP_BASENAME=$(/usr/bin/basename "$APP_PATH_INPUT") || fail "无法解析应用名称"
[ -d "$APP_PARENT_INPUT" ] || fail "目标父目录不存在：$APP_PARENT_INPUT"
APP_PARENT=$(CDPATH= cd -- "$APP_PARENT_INPUT" 2>/dev/null && /bin/pwd -P) || fail "无法解析目标父目录"
APP_PATH="${APP_PARENT}/${APP_BASENAME}"

[ -d "$APP_PATH" ] || fail "没有找到已安装的 SnapClip：$APP_PATH"
[ ! -L "$APP_PATH" ] || fail "目标应用不能是符号链接：$APP_PATH"

if [ "$TEST_MODE" = 1 ]; then
  [ "$(/usr/bin/id -u)" -ne 0 ] || fail "测试模式不能以 root 运行"
  case "$APP_PATH" in
    /tmp/* | /private/tmp/*) ;;
    *) fail "测试模式只允许操作 /tmp 下的应用" ;;
  esac
elif [ "$TEST_MODE" != 0 ]; then
  fail "SNAPCLIP_TEST_MODE 只能是 0 或 1"
fi

is_release_version() {
  /usr/bin/grep -Eq '^v(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$' <<EOF
$1
EOF
}

is_app_version() {
  /usr/bin/grep -Eq '^(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$' <<EOF
$1
EOF
}

version_gt() {
  left=${1#v}
  right=${2#v}
  old_ifs=$IFS
  IFS=.
  set -- $left
  left_major=$1 left_minor=$2 left_patch=$3
  set -- $right
  right_major=$1 right_minor=$2 right_patch=$3
  IFS=$old_ifs

  for pair in \
    "$left_major:$right_major" \
    "$left_minor:$right_minor" \
    "$left_patch:$right_patch"
  do
    left_part=${pair%%:*}
    right_part=${pair#*:}
    [ "$left_part" -gt "$right_part" ] && return 0
    [ "$left_part" -lt "$right_part" ] && return 1
  done
  return 1
}

os_supports() {
  /usr/bin/awk -v host="$1" -v minimum="$2" '
    function component(value, position, pieces, count) {
      count = split(value, pieces, ".")
      return position <= count ? pieces[position] + 0 : 0
    }
    BEGIN {
      for (i = 1; i <= 3; i++) {
        h = component(host, i)
        m = component(minimum, i)
        if (h > m) exit 0
        if (h < m) exit 1
      }
      exit 0
    }
  '
}

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null
}

app_version() {
  plist_value "$1" CFBundleShortVersionString
}

signature_valid() {
  app=$1
  if [ "$TEST_MODE" = 1 ]; then
    [ -f "$app/Contents/_TestSignature/valid" ] &&
      [ "$(/bin/cat "$app/Contents/_TestSignature/valid")" = 1 ]
    return
  fi
  verification_output=$(/usr/bin/codesign --verify --deep --strict "$app" 2>&1)
  verification_status=$?
  [ "$verification_status" -eq 0 ] && return 0

  # Apple Development Pre-releases can be structurally valid while their
  # non-public trust chain reports CSSMERR_TP_NOT_TRUSTED. Accept only that
  # exact trust-only result; resource, executable, or requirement errors fail.
  [ "$verification_status" -eq 1 ] || return 1
  printf '%s\n' "$verification_output" | /usr/bin/awk '
    BEGIN { trust = 0; unexpected = 0 }
    /: CSSMERR_TP_NOT_TRUSTED$/ { trust++; next }
    /^In architecture: (arm64|x86_64)$/ { next }
    { unexpected++ }
    END { exit !(trust == 1 && unexpected == 0) }
  '
}

signature_team() {
  app=$1
  if [ "$TEST_MODE" = 1 ]; then
    /bin/cat "$app/Contents/_TestSignature/team" 2>/dev/null
    return
  fi
  /usr/bin/codesign -dvv "$app" 2>&1 |
    /usr/bin/sed -n 's/^TeamIdentifier=//p' |
    /usr/bin/head -n 1
}

signature_requirement() {
  app=$1
  if [ "$TEST_MODE" = 1 ]; then
    /bin/cat "$app/Contents/_TestSignature/requirement" 2>/dev/null
    return
  fi
  /usr/bin/codesign -d -r- "$app" 2>&1 |
    /usr/bin/sed -n 's/^designated => //p' |
    /usr/bin/head -n 1
}

app_architectures() {
  app=$1
  if [ "$TEST_MODE" = 1 ]; then
    /bin/cat "$app/Contents/_TestArch" 2>/dev/null
    return
  fi
  /usr/bin/lipo -archs "$app/Contents/MacOS/SnapClip" 2>/dev/null
}

validate_app() {
  app=$1
  expected_version=$2
  require_no_links=$3

  [ -d "$app" ] || return 1
  [ ! -L "$app" ] || return 1
  [ -f "$app/Contents/Info.plist" ] && [ ! -L "$app/Contents/Info.plist" ] || return 1
  [ -f "$app/Contents/MacOS/SnapClip" ] && [ ! -L "$app/Contents/MacOS/SnapClip" ] || return 1
  [ -f "$app/Contents/_CodeSignature/CodeResources" ] &&
    [ ! -L "$app/Contents/_CodeSignature/CodeResources" ] || return 1

  if [ "$require_no_links" = 1 ]; then
    link=$(/usr/bin/find "$app" -type l -print -quit 2>/dev/null)
    [ -z "$link" ] || return 1
  fi

  identifier=$(plist_value "$app" CFBundleIdentifier) || return 1
  [ "$identifier" = "$BUNDLE_ID" ] || return 1

  version=$(app_version "$app") || return 1
  is_app_version "$version" || return 1
  [ -z "$expected_version" ] || [ "$version" = "$expected_version" ] || return 1

  minimum_system=$(plist_value "$app" LSMinimumSystemVersion) || return 1
  host_system=$(/usr/bin/sw_vers -productVersion) || return 1
  os_supports "$host_system" "$minimum_system" || return 1

  architectures=$(app_architectures "$app") || return 1
  case " $architectures " in
    *" arm64 "*) ;;
    *) return 1 ;;
  esac

  signature_valid "$app" || return 1
  team=$(signature_team "$app") || return 1
  requirement=$(signature_requirement "$app") || return 1
  [ -n "$team" ] && [ -n "$requirement" ] || return 1
}

OLD_VERSION=$(app_version "$APP_PATH") || fail "无法读取现有应用版本"
is_app_version "$OLD_VERSION" || fail "现有应用版本格式无效：$OLD_VERSION"
validate_app "$APP_PATH" "$OLD_VERSION" 0 || fail "现有 SnapClip 未通过身份、架构或签名检查"
OLD_TEAM=$(signature_team "$APP_PATH") || fail "无法读取现有应用 TeamIdentifier"
OLD_REQUIREMENT=$(signature_requirement "$APP_PATH") || fail "无法读取现有应用 designated requirement"

LOCK_HASH=$(printf '%s' "$APP_PATH" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}') || fail "无法生成更新锁"
LOCK_DIR="/tmp/com.local.SnapClip.update.${LOCK_HASH}.lock"

acquire_lock() {
  if /bin/mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%s\n' "$$" >"$LOCK_DIR/pid" || return 1
    LOCK_HELD=1
    return 0
  fi

  lock_pid=
  [ -f "$LOCK_DIR/pid" ] && lock_pid=$(/bin/cat "$LOCK_DIR/pid" 2>/dev/null)
  case "$lock_pid" in
    '' | *[!0-9]*) ;;
    *)
      if /bin/kill -0 "$lock_pid" 2>/dev/null; then
        fail "另一个更新进程正在运行（PID ${lock_pid}）"
      fi
      ;;
  esac

  /bin/rm -rf "$LOCK_DIR" 2>/dev/null || fail "无法清理残留更新锁"
  /bin/mkdir "$LOCK_DIR" 2>/dev/null || fail "无法取得更新锁"
  printf '%s\n' "$$" >"$LOCK_DIR/pid" || fail "无法写入更新锁"
  LOCK_HELD=1
}

run_privileged() {
  if [ "$SUDO_NEEDED" = 1 ]; then
    /usr/bin/sudo "$@"
  else
    "$@"
  fi
}

test_process_state() {
  state_file=${SNAPCLIP_TEST_PROCESS_STATE_FILE:-}
  [ -n "$state_file" ] && [ -f "$state_file" ] && /bin/cat "$state_file"
}

running_pids() {
  app=$1
  if [ "$TEST_MODE" = 1 ]; then
    [ "$(test_process_state 2>/dev/null)" = running ] && /bin/echo "99999"
    return 0
  fi

  executable_path="${app}/Contents/MacOS/SnapClip"
  /usr/bin/osascript -l JavaScript - "$executable_path" <<'JXA'
ObjC.import('AppKit')
function run(argv) {
  const wanted = $(argv[0]).stringByStandardizingPath.js
  return $.NSWorkspace.sharedWorkspace.runningApplications.js
    .filter(app => app.executableURL && app.executableURL.path.stringByStandardizingPath.js === wanted)
    .map(app => String(app.processIdentifier))
    .join(' ')
}
JXA
}

terminate_app() {
  app=$1
  if [ "$TEST_MODE" = 1 ]; then
    state_file=${SNAPCLIP_TEST_PROCESS_STATE_FILE:-}
    [ -z "$state_file" ] && return 0
    [ "${SNAPCLIP_TEST_FAIL_TERMINATE:-0}" = 1 ] && return 1
    printf '%s\n' stopped >"$state_file"
    return 0
  fi

  executable_path="${app}/Contents/MacOS/SnapClip"
  /usr/bin/osascript -l JavaScript - "$executable_path" <<'JXA' >/dev/null
ObjC.import('AppKit')
function run(argv) {
  const wanted = $(argv[0]).stringByStandardizingPath.js
  const matches = $.NSWorkspace.sharedWorkspace.runningApplications.js
    .filter(app => app.executableURL && app.executableURL.path.stringByStandardizingPath.js === wanted)
  matches.forEach(app => app.terminate)
  return matches.length
}
JXA
  [ $? -eq 0 ] || return 1

  attempts=0
  while [ "$attempts" -lt 10 ]; do
    [ -z "$(running_pids "$app")" ] && return 0
    /bin/sleep 1
    attempts=$((attempts + 1))
  done
  return 1
}

launch_app() {
  app=$1
  if [ "$TEST_MODE" = 1 ]; then
    state_file=${SNAPCLIP_TEST_PROCESS_STATE_FILE:-}
    [ -z "$state_file" ] && return 0
    version=$(app_version "$app" 2>/dev/null)
    [ "${SNAPCLIP_TEST_FAIL_LAUNCH_VERSION:-}" = "$version" ] && return 1
    printf '%s\n' running >"$state_file"
    return 0
  fi

  /usr/bin/open "$app" >/dev/null 2>&1 || return 1
  attempts=0
  while [ "$attempts" -lt 10 ]; do
    [ -n "$(running_pids "$app")" ] && return 0
    /bin/sleep 1
    attempts=$((attempts + 1))
  done
  return 1
}

rollback() {
  [ "$ROLLING_BACK" = 0 ] || return 1
  ROLLING_BACK=1
  restored=0

  if [ -n "$BACKUP_PATH" ] && [ -d "$BACKUP_PATH" ]; then
    if [ -d "$APP_PATH" ]; then
      if ! terminate_app "$APP_PATH"; then
        log "回滚暂停：新版仍在运行。保留当前应用 $APP_PATH 和备份 $BACKUP_PATH" >&2
        return 1
      fi
      if [ -z "$FAILED_PATH" ]; then
        FAILED_PATH="${APP_PARENT}/.${APP_BASENAME%.app}.failed.$$.app"
      fi
      run_privileged /bin/mv "$APP_PATH" "$FAILED_PATH" || {
        log "回滚失败：无法移开当前应用；备份保留在 $BACKUP_PATH" >&2
        return 1
      }
    fi
    run_privileged /bin/mv "$BACKUP_PATH" "$APP_PATH" || {
      log "回滚失败：备份保留在 $BACKUP_PATH" >&2
      return 1
    }
    restored=1
    log "已恢复原版本 $OLD_VERSION"
  elif [ "$OLD_STOPPED" = 1 ] && [ -d "$APP_PATH" ]; then
    restored=1
  fi

  if [ "$restored" = 1 ] && [ "$OLD_WAS_RUNNING" = 1 ]; then
    launch_app "$APP_PATH" || {
      log "原版本已恢复，但未能重新启动：$APP_PATH" >&2
      return 1
    }
  fi
  return 0
}

cleanup() {
  exit_status=$?
  trap - 0 HUP INT TERM

  if [ "$exit_status" -ne 0 ] && [ "$COMMITTED" = 0 ]; then
    rollback || exit_status=1
  fi

  if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
    /bin/rm -rf "$TEMP_DIR"
  fi
  if [ "$LOCK_HELD" = 1 ] && [ -d "$LOCK_DIR" ]; then
    owner=$(/bin/cat "$LOCK_DIR/pid" 2>/dev/null)
    [ "$owner" = "$$" ] && /bin/rm -rf "$LOCK_DIR"
  fi
  exit "$exit_status"
}

trap cleanup 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

acquire_lock
TEMP_DIR=$(/usr/bin/mktemp -d /tmp/snapclip-update.XXXXXX) || fail "无法创建临时目录"
CANDIDATES_FILE="$TEMP_DIR/candidates.tsv"
: >"$CANDIDATES_FILE" || fail "无法创建候选版本文件"

extract_candidates() {
  json_file=$1
  /usr/bin/osascript -l JavaScript - "$json_file" <<'JXA'
ObjC.import('Foundation')
function run(argv) {
  const error = Ref()
  const content = $.NSString.stringWithContentsOfFileEncodingError(
    argv[0], $.NSUTF8StringEncoding, error
  )
  if (!content) throw new Error('无法读取 GitHub Release 响应')
  const releases = JSON.parse(content.js)
  if (!Array.isArray(releases)) throw new Error('GitHub Release 响应不是数组')
  const rows = []
  for (const release of releases) {
    if (!release || release.draft === true) continue
    const tag = String(release.tag_name || '')
    if (!/^v(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$/.test(tag)) continue
    const expected = `SnapClip-${tag}-arm64.zip`
    const assets = Array.isArray(release.assets) ? release.assets : []
    const matches = assets.filter(asset => asset && asset.name === expected)
    const url = matches.length === 1 ? String(matches[0].browser_download_url || '') : ''
    const digest = matches.length === 1 ? String(matches[0].digest || '') : ''
    for (const value of [tag, url, digest]) {
      if (/[\t\r\n]/.test(value)) throw new Error('Release 字段包含非法控制字符')
    }
    rows.push([tag, String(matches.length), url, digest].join('\t'))
  }
  return rows.join('\n')
}
JXA
}

fetch_releases() {
  if [ "$TEST_MODE" = 1 ]; then
    source_file=${SNAPCLIP_TEST_RELEASES_FILE:-}
    [ -f "$source_file" ] || fail "测试模式缺少 SNAPCLIP_TEST_RELEASES_FILE"
    /bin/cp "$source_file" "$TEMP_DIR/releases-1.json" || fail "无法读取测试 Release 数据"
    extract_candidates "$TEMP_DIR/releases-1.json" >>"$CANDIDATES_FILE" || fail "无法解析测试 Release 数据"
    return
  fi

  next_url=$API_URL
  page=1
  while [ -n "$next_url" ]; do
    [ "$page" -le 10 ] || fail "GitHub Release 分页超过安全上限"
    case "$next_url" in
      https://api.github.com/repos/Evan1u/SnapClip/releases*) ;;
      *) fail "GitHub API 返回了非预期分页地址" ;;
    esac
    body="$TEMP_DIR/releases-$page.json"
    headers="$TEMP_DIR/releases-$page.headers"

    if [ -n "${GITHUB_TOKEN:-}" ]; then
      http_status=$(/usr/bin/curl --fail --silent --show-error --location \
        --proto '=https' --proto-redir '=https' \
        -H 'Accept: application/vnd.github+json' \
        -H 'X-GitHub-Api-Version: 2022-11-28' \
        -H 'User-Agent: SnapClip-Updater' \
        -H "Authorization: Bearer $GITHUB_TOKEN" \
        --write-out '%{http_code}' \
        -D "$headers" -o "$body" "$next_url")
      curl_status=$?
    else
      http_status=$(/usr/bin/curl --fail --silent --show-error --location \
        --proto '=https' --proto-redir '=https' \
        -H 'Accept: application/vnd.github+json' \
        -H 'X-GitHub-Api-Version: 2022-11-28' \
        -H 'User-Agent: SnapClip-Updater' \
        --write-out '%{http_code}' \
        -D "$headers" -o "$body" "$next_url")
      curl_status=$?
    fi

    if [ "$curl_status" -ne 0 ]; then
      if [ "$http_status" = 403 ] && [ -z "${GITHUB_TOKEN:-}" ]; then
        fail "GitHub API 拒绝了匿名请求；请设置 GITHUB_TOKEN 后重试"
      fi
      fail "无法读取 GitHub Releases（HTTP ${http_status:-unknown}）"
    fi

    extract_candidates "$body" >>"$CANDIDATES_FILE" || fail "GitHub Release 数据格式无效"
    next_url=$(
      /usr/bin/grep -i '^link:' "$headers" 2>/dev/null |
        /usr/bin/tr -d '\r' |
        /usr/bin/sed -n 's/.*<\([^>]*\)>; rel="next".*/\1/p' |
        /usr/bin/head -n 1
    )
    page=$((page + 1))
  done
}

fetch_releases

BEST_TAG=
BEST_ASSET_COUNT=
BEST_URL=
BEST_DIGEST=
BEST_DUPLICATE=0
tab=$(printf '\t')
while IFS="$tab" read -r tag asset_count asset_url asset_digest; do
  [ -n "$tag" ] || continue
  is_release_version "$tag" || fail "Release tag 格式无效：$tag"
  if [ -z "$BEST_TAG" ] || version_gt "$tag" "$BEST_TAG"; then
    BEST_TAG=$tag
    BEST_ASSET_COUNT=$asset_count
    BEST_URL=$asset_url
    BEST_DIGEST=$asset_digest
    BEST_DUPLICATE=0
  elif [ "$tag" = "$BEST_TAG" ]; then
    BEST_DUPLICATE=1
  fi
done <"$CANDIDATES_FILE"

[ -n "$BEST_TAG" ] || fail "没有找到符合 vMAJOR.MINOR.PATCH 的 Release"
[ "$BEST_DUPLICATE" = 0 ] || fail "最高版本 $BEST_TAG 出现重复 Release"
[ "$BEST_ASSET_COUNT" = 1 ] || fail "$BEST_TAG 必须且只能包含一个 SnapClip-${BEST_TAG}-arm64.zip"

NEW_VERSION=${BEST_TAG#v}
is_app_version "$NEW_VERSION" || fail "远端版本格式无效：$BEST_TAG"

log "本地版本：$OLD_VERSION"
log "远端版本：${NEW_VERSION}（${BEST_TAG}）"

if ! version_gt "$BEST_TAG" "v$OLD_VERSION"; then
  log "当前已经是最新版或本地版本更高，无需更新。"
  COMMITTED=1
  exit 0
fi

if [ "$MODE" = check ]; then
  log "发现可用更新。"
  COMMITTED=1
  exit 0
fi

if [ "$MODE" = dry-run ]; then
  log "将下载 SnapClip-${BEST_TAG}-arm64.zip，验证摘要、应用身份、架构与签名后更新 ${APP_PATH}。"
  COMMITTED=1
  exit 0
fi

case "$BEST_DIGEST" in
  sha256:[0-9a-fA-F][0-9a-fA-F]*) ;;
  *) fail "$BEST_TAG 的 ZIP 缺少 GitHub sha256 digest" ;;
esac
EXPECTED_DIGEST=${BEST_DIGEST#sha256:}
[ ${#EXPECTED_DIGEST} -eq 64 ] || fail "$BEST_TAG 的 sha256 digest 长度无效"
/usr/bin/grep -Eq '^[0-9a-fA-F]{64}$' <<EOF || fail "$BEST_TAG 的 sha256 digest 格式无效"
$EXPECTED_DIGEST
EOF

case "$BEST_URL" in
  https://github.com/Evan1u/SnapClip/releases/download/*)
    ;;
  file:///tmp/* | file:///private/tmp/*)
    [ "$TEST_MODE" = 1 ] || fail "生产模式只接受 GitHub HTTPS 下载地址"
    ;;
  *) fail "$BEST_TAG 的下载地址不受信任" ;;
esac

ARCHIVE_PATH="$TEMP_DIR/SnapClip-${BEST_TAG}-arm64.zip"
if [ "$TEST_MODE" = 1 ]; then
  /usr/bin/curl --fail --silent --show-error --location -o "$ARCHIVE_PATH" "$BEST_URL" || fail "无法读取测试更新包"
else
  /usr/bin/curl --fail --silent --show-error --location \
    --proto '=https' --proto-redir '=https' \
    -H 'User-Agent: SnapClip-Updater' \
    -o "$ARCHIVE_PATH" "$BEST_URL" || fail "下载更新包失败"
fi

ACTUAL_DIGEST=$(/usr/bin/shasum -a 256 "$ARCHIVE_PATH" | /usr/bin/awk '{print $1}') || fail "无法计算更新包摘要"
[ "$ACTUAL_DIGEST" = "$EXPECTED_DIGEST" ] || fail "更新包 SHA-256 与 GitHub 元数据不一致"

/usr/bin/zipinfo -1 "$ARCHIVE_PATH" >"$TEMP_DIR/archive-entries.txt" 2>/dev/null || fail "更新包不是有效 ZIP"
/usr/bin/awk '
  BEGIN { valid = 1; seen = 0 }
  {
    if ($0 !~ /^SnapClip\.app\//) valid = 0
    if ($0 ~ /(^|\/)\.\.($|\/)/ || $0 ~ /^\//) valid = 0
    seen = 1
  }
  END { exit !(valid && seen) }
' "$TEMP_DIR/archive-entries.txt" || fail "更新包包含非预期路径"

UNPACK_DIR="$TEMP_DIR/unpacked"
/bin/mkdir "$UNPACK_DIR" || fail "无法创建解压目录"
/usr/bin/ditto -x -k "$ARCHIVE_PATH" "$UNPACK_DIR" || fail "无法解压更新包"
CANDIDATE_APP="$UNPACK_DIR/SnapClip.app"
validate_app "$CANDIDATE_APP" "$NEW_VERSION" 1 || fail "下载的 SnapClip 未通过应用、架构或签名检查"

NEW_TEAM=$(signature_team "$CANDIDATE_APP") || fail "无法读取新版本 TeamIdentifier"
NEW_REQUIREMENT=$(signature_requirement "$CANDIDATE_APP") || fail "无法读取新版本 designated requirement"
[ "$NEW_TEAM" = "$OLD_TEAM" ] || fail "新旧版本 TeamIdentifier 不一致，已停止更新"
[ "$NEW_REQUIREMENT" = "$OLD_REQUIREMENT" ] || fail "新旧版本 designated requirement 不一致，已停止更新"

running=$(running_pids "$APP_PATH") || fail "无法检查 SnapClip 运行状态"
[ -n "$running" ] && OLD_WAS_RUNNING=1

if [ "$OLD_WAS_RUNNING" = 1 ]; then
  log "正在退出当前 SnapClip…"
  terminate_app "$APP_PATH" || fail "SnapClip 未在 10 秒内退出，未修改现有应用"
  OLD_STOPPED=1
fi

if [ ! -w "$APP_PARENT" ]; then
  SUDO_NEEDED=1
  /usr/bin/sudo -v || fail "没有获得更新 $APP_PARENT 所需的权限"
fi

STAGING_PATH="${APP_PARENT}/.${APP_BASENAME%.app}.update.$$.app"
BACKUP_PATH="${APP_PARENT}/.${APP_BASENAME%.app}.backup.$$.app"
FAILED_PATH="${APP_PARENT}/.${APP_BASENAME%.app}.failed.$$.app"
[ ! -e "$STAGING_PATH" ] && [ ! -L "$STAGING_PATH" ] || fail "暂存路径已存在：$STAGING_PATH"
[ ! -e "$BACKUP_PATH" ] && [ ! -L "$BACKUP_PATH" ] || fail "备份路径已存在：$BACKUP_PATH"
[ ! -e "$FAILED_PATH" ] && [ ! -L "$FAILED_PATH" ] || fail "失败副本路径已存在：$FAILED_PATH"

run_privileged /usr/bin/ditto --rsrc --extattr --acl "$CANDIDATE_APP" "$STAGING_PATH" || fail "无法在目标磁盘暂存新版本"
validate_app "$STAGING_PATH" "$NEW_VERSION" 1 || fail "目标磁盘上的暂存应用校验失败"
STAGED_TEAM=$(signature_team "$STAGING_PATH") || fail "无法读取暂存应用 TeamIdentifier"
STAGED_REQUIREMENT=$(signature_requirement "$STAGING_PATH") || fail "无法读取暂存应用 designated requirement"
[ "$STAGED_TEAM" = "$OLD_TEAM" ] && [ "$STAGED_REQUIREMENT" = "$OLD_REQUIREMENT" ] || fail "暂存应用签名主体发生变化"

run_privileged /bin/mv "$APP_PATH" "$BACKUP_PATH" || fail "无法建立原版本备份"

if [ "$TEST_MODE" = 1 ] && [ -n "${SNAPCLIP_TEST_AFTER_BACKUP_MARKER:-}" ]; then
  printf '%s\n' ready >"$SNAPCLIP_TEST_AFTER_BACKUP_MARKER"
  /bin/sleep "${SNAPCLIP_TEST_PAUSE_AFTER_BACKUP:-0}"
fi

if [ "$TEST_MODE" = 1 ] && [ "${SNAPCLIP_TEST_FAIL_SECOND_MOVE:-0}" = 1 ]; then
  fail "测试注入：第二次移动失败"
fi
run_privileged /bin/mv "$STAGING_PATH" "$APP_PATH" || fail "无法把新版本移到最终路径"

validate_app "$APP_PATH" "$NEW_VERSION" 1 || fail "最终路径上的新版本校验失败"
FINAL_TEAM=$(signature_team "$APP_PATH") || fail "无法读取最终应用 TeamIdentifier"
FINAL_REQUIREMENT=$(signature_requirement "$APP_PATH") || fail "无法读取最终应用 designated requirement"
[ "$FINAL_TEAM" = "$OLD_TEAM" ] && [ "$FINAL_REQUIREMENT" = "$OLD_REQUIREMENT" ] || fail "最终应用签名主体发生变化"

if [ "$OLD_WAS_RUNNING" = 1 ]; then
  launch_app "$APP_PATH" || fail "新版本未能启动，正在回滚"
fi

COMMITTED=1
if ! run_privileged /bin/rm -rf "$BACKUP_PATH"; then
  log "更新成功，但备份未能删除：$BACKUP_PATH" >&2
fi
BACKUP_PATH=
log "更新完成：SnapClip $OLD_VERSION → $NEW_VERSION"
exit 0
