#!/bin/sh

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(/usr/bin/dirname "$0")" && /bin/pwd -P)
UPDATER="$SCRIPT_DIR/update-snapclip.sh"
TEST_ROOT=$(/usr/bin/mktemp -d /tmp/snapclip-updater-tests.XXXXXX) || exit 1
PASSED=0
FAILED=0

cleanup() {
  if [ "${SNAPCLIP_KEEP_TESTS:-0}" = 1 ]; then
    /bin/echo "Preserved test fixtures: $TEST_ROOT"
    return
  fi
  /bin/rm -rf "$TEST_ROOT"
}
trap cleanup 0 HUP INT TERM

make_app() {
  destination=$1
  version=$2
  bundle_id=${3:-com.local.SnapClip}
  team=${4:-38BDLQYAVJ}
  requirement=${5:-snapclip-test-requirement}
  signature_valid=${6:-1}

  /bin/mkdir -p "$destination/Contents/MacOS" "$destination/Contents/_CodeSignature" "$destination/Contents/_TestSignature"
  /bin/cat >"$destination/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$bundle_id</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
EOF
  printf '%s\n' '#!/bin/sh' 'exit 0' >"$destination/Contents/MacOS/SnapClip"
  /bin/chmod 755 "$destination/Contents/MacOS/SnapClip"
  printf '%s\n' arm64 >"$destination/Contents/_TestArch"
  printf '%s\n' placeholder >"$destination/Contents/_CodeSignature/CodeResources"
  printf '%s\n' "$team" >"$destination/Contents/_TestSignature/team"
  printf '%s\n' "$requirement" >"$destination/Contents/_TestSignature/requirement"
  printf '%s\n' "$signature_valid" >"$destination/Contents/_TestSignature/valid"
}

make_release() {
  case_dir=$1
  version=$2
  bundle_id=${3:-com.local.SnapClip}
  team=${4:-38BDLQYAVJ}
  requirement=${5:-snapclip-test-requirement}
  signature_valid=${6:-1}

  release_root="$case_dir/release"
  /bin/mkdir -p "$release_root"
  make_app "$release_root/SnapClip.app" "$version" "$bundle_id" "$team" "$requirement" "$signature_valid"
  archive="$case_dir/SnapClip-v${version}-arm64.zip"
  (cd "$release_root" && /usr/bin/ditto -c -k --keepParent SnapClip.app "$archive") || return 1
  digest=$(/usr/bin/shasum -a 256 "$archive" | /usr/bin/awk '{print $1}') || return 1
  json="$case_dir/releases.json"
  /bin/cat >"$json" <<EOF
[{"tag_name":"v$version","draft":false,"assets":[{"name":"SnapClip-v$version-arm64.zip","browser_download_url":"file://$archive","digest":"sha256:$digest"}]}]
EOF
}

prepare_case() {
  name=$1
  old_version=${2:-1.4.1}
  case_dir="$TEST_ROOT/$name"
  /bin/mkdir -p "$case_dir/install"
  make_app "$case_dir/install/SnapClip.app" "$old_version"
  /bin/echo "$case_dir"
}

run_updater() {
  case_dir=$1
  shift
  env SNAPCLIP_TEST_MODE=1 \
    SNAPCLIP_APP_PATH="$case_dir/install/SnapClip.app" \
    SNAPCLIP_TEST_RELEASES_FILE="$case_dir/releases.json" \
    "$UPDATER" "$@"
}

assert_version() {
  case_dir=$1
  expected=$2
  actual=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$case_dir/install/SnapClip.app/Contents/Info.plist" 2>/dev/null)
  [ "$actual" = "$expected" ]
}

record() {
  name=$1
  shift
  if "$@"; then
    PASSED=$((PASSED + 1))
    /bin/echo "PASS $name"
  else
    FAILED=$((FAILED + 1))
    /bin/echo "FAIL $name" >&2
  fi
}

test_same_version() {
  case_dir=$(prepare_case same-version)
  make_release "$case_dir" 1.4.1 || return 1
  run_updater "$case_dir" --check >"$case_dir/output" 2>&1 || return 1
  /usr/bin/grep -q '无需更新' "$case_dir/output" && assert_version "$case_dir" 1.4.1
}

test_dry_run() {
  case_dir=$(prepare_case dry-run)
  make_release "$case_dir" 1.5.0 || return 1
  run_updater "$case_dir" --dry-run >"$case_dir/output" 2>&1 || return 1
  /usr/bin/grep -q '将下载' "$case_dir/output" && assert_version "$case_dir" 1.4.1
}

test_successful_update() {
  case_dir=$(prepare_case success)
  make_release "$case_dir" 1.5.0 || return 1
  run_updater "$case_dir" >"$case_dir/output" 2>&1 || return 1
  /usr/bin/grep -q '更新完成' "$case_dir/output" && assert_version "$case_dir" 1.5.0 &&
    [ -z "$(/usr/bin/find "$case_dir/install" -maxdepth 1 \( -name '.*.backup.*' -o -name '.*.update.*' \) -print)" ]
}

test_digest_mismatch() {
  case_dir=$(prepare_case digest-mismatch)
  make_release "$case_dir" 1.5.0 || return 1
  /usr/bin/sed -i '' 's/sha256:[0-9a-f]*/sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/' "$case_dir/releases.json"
  if run_updater "$case_dir" >"$case_dir/output" 2>&1; then return 1; fi
  /usr/bin/grep -q 'SHA-256' "$case_dir/output" && assert_version "$case_dir" 1.4.1
}

test_bundle_mismatch() {
  case_dir=$(prepare_case bundle-mismatch)
  make_release "$case_dir" 1.5.0 com.example.Wrong || return 1
  if run_updater "$case_dir" >"$case_dir/output" 2>&1; then return 1; fi
  /usr/bin/grep -q '未通过应用' "$case_dir/output" && assert_version "$case_dir" 1.4.1
}

test_signature_mismatch() {
  case_dir=$(prepare_case signature-mismatch)
  make_release "$case_dir" 1.5.0 com.local.SnapClip DIFFERENT snapclip-test-requirement 1 || return 1
  if run_updater "$case_dir" >"$case_dir/output" 2>&1; then return 1; fi
  /usr/bin/grep -q 'TeamIdentifier 不一致' "$case_dir/output" && assert_version "$case_dir" 1.4.1
}

test_invalid_signature() {
  case_dir=$(prepare_case invalid-signature)
  make_release "$case_dir" 1.5.0 com.local.SnapClip 38BDLQYAVJ snapclip-test-requirement 0 || return 1
  if run_updater "$case_dir" >"$case_dir/output" 2>&1; then return 1; fi
  /usr/bin/grep -q '未通过应用' "$case_dir/output" && assert_version "$case_dir" 1.4.1
}

test_second_move_rollback() {
  case_dir=$(prepare_case move-rollback)
  make_release "$case_dir" 1.5.0 || return 1
  if env SNAPCLIP_TEST_MODE=1 \
    SNAPCLIP_APP_PATH="$case_dir/install/SnapClip.app" \
    SNAPCLIP_TEST_RELEASES_FILE="$case_dir/releases.json" \
    SNAPCLIP_TEST_FAIL_SECOND_MOVE=1 \
    "$UPDATER" >"$case_dir/output" 2>&1; then return 1; fi
  /usr/bin/grep -q '已恢复原版本' "$case_dir/output" && assert_version "$case_dir" 1.4.1
}

test_launch_failure_rollback() {
  case_dir=$(prepare_case launch-rollback)
  make_release "$case_dir" 1.5.0 || return 1
  state_file="$case_dir/process-state"
  printf '%s\n' running >"$state_file"
  if env SNAPCLIP_TEST_MODE=1 \
    SNAPCLIP_APP_PATH="$case_dir/install/SnapClip.app" \
    SNAPCLIP_TEST_RELEASES_FILE="$case_dir/releases.json" \
    SNAPCLIP_TEST_PROCESS_STATE_FILE="$state_file" \
    SNAPCLIP_TEST_FAIL_LAUNCH_VERSION=1.5.0 \
    "$UPDATER" >"$case_dir/output" 2>&1; then return 1; fi
  /usr/bin/grep -q '已恢复原版本' "$case_dir/output" && assert_version "$case_dir" 1.4.1 &&
    [ "$(/bin/cat "$state_file")" = running ]
}

test_active_lock() {
  case_dir=$(prepare_case active-lock)
  make_release "$case_dir" 1.5.0 || return 1
  canonical_parent=$(CDPATH= cd -- "$case_dir/install" && /bin/pwd -P) || return 1
  canonical="$canonical_parent/SnapClip.app"
  hash=$(printf '%s' "$canonical" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')
  lock="/tmp/com.local.SnapClip.update.${hash}.lock"
  /bin/mkdir "$lock" || return 1
  printf '%s\n' "$$" >"$lock/pid"
  if run_updater "$case_dir" >"$case_dir/output" 2>&1; then /bin/rm -rf "$lock"; return 1; fi
  result=0
  /usr/bin/grep -q '另一个更新进程' "$case_dir/output" || result=1
  assert_version "$case_dir" 1.4.1 || result=1
  /bin/rm -rf "$lock"
  return "$result"
}

test_signal_rollback() {
  case_dir=$(prepare_case signal-rollback)
  make_release "$case_dir" 1.5.0 || return 1
  marker="$case_dir/after-backup"
  env SNAPCLIP_TEST_MODE=1 \
    SNAPCLIP_APP_PATH="$case_dir/install/SnapClip.app" \
    SNAPCLIP_TEST_RELEASES_FILE="$case_dir/releases.json" \
    SNAPCLIP_TEST_AFTER_BACKUP_MARKER="$marker" \
    SNAPCLIP_TEST_PAUSE_AFTER_BACKUP=10 \
    "$UPDATER" >"$case_dir/output" 2>&1 &
  updater_pid=$!
  attempts=0
  while [ ! -f "$marker" ] && [ "$attempts" -lt 50 ]; do
    /bin/sleep 0.1
    attempts=$((attempts + 1))
  done
  [ -f "$marker" ] || { /bin/kill "$updater_pid" 2>/dev/null; return 1; }
  /bin/kill -TERM "$updater_pid" || return 1
  wait "$updater_pid" 2>/dev/null
  status=$?
  [ "$status" -ne 0 ] && /usr/bin/grep -q '已恢复原版本' "$case_dir/output" && assert_version "$case_dir" 1.4.1
}

record "same version check" test_same_version
record "dry run has no mutation" test_dry_run
record "successful update" test_successful_update
record "digest mismatch" test_digest_mismatch
record "bundle mismatch" test_bundle_mismatch
record "signature subject mismatch" test_signature_mismatch
record "invalid signature" test_invalid_signature
record "second move rollback" test_second_move_rollback
record "launch failure rollback" test_launch_failure_rollback
record "active lock" test_active_lock
record "signal rollback" test_signal_rollback

/bin/echo "$PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
