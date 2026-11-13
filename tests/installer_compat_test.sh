#!/bin/sh
set -eu

REPO_DIR="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT INT TERM

assert_contains() {
  haystack="$1"
  needle="$2"
  printf '%s' "$haystack" | grep -F -- "$needle" >/dev/null 2>&1 || {
    printf 'assert_contains failed: missing [%s]\nin output:\n%s\n' "$needle" "$haystack" >&2
    exit 1
  }
}

assert_not_contains() {
  haystack="$1"
  needle="$2"
  if printf '%s' "$haystack" | grep -F -- "$needle" >/dev/null 2>&1; then
    printf 'assert_not_contains failed: unexpected [%s]\nin output:\n%s\n' "$needle" "$haystack" >&2
    exit 1
  fi
}

assert_eq() {
  got="$1"
  want="$2"
  label="$3"
  if [ "$got" != "$want" ]; then
    printf 'assert_eq failed (%s): got [%s], want [%s]\n' "$label" "$got" "$want" >&2
    exit 1
  fi
}

compute_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    openssl dgst -sha256 "$1" | awk '{print $NF}'
  fi
}

file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

make_fakebin() {
  fakebin="$1"
  mkdir -p "$fakebin"

  sample_bin="$fakebin/sample_vohive_bin"
  cat >"$sample_bin" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "--print-cwd" ]; then
  pwd
  exit 0
fi
exit 0
EOF
  chmod +x "$sample_bin"
  sample_hash="$(compute_sha256 "$sample_bin")"
  printf '%s\n' "$sample_hash" >"$fakebin/good.sha256"

  cat >"$fakebin/uname" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "-s" ]; then
  printf 'Linux\n'
elif [ "${1:-}" = "-m" ]; then
  printf '%s\n' "${FAKE_UNAME_M:-x86_64}"
else
  printf 'Linux\n'
fi
EOF

  cat >"$fakebin/id" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "-u" ]; then
  printf '0\n'
else
  /usr/bin/id "$@"
fi
EOF

  cat >"$fakebin/hostname" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "-I" ]; then
  printf '%s\n' "${FAKE_HOSTNAME_IPS:-192.0.2.10 fe80::1 2001:db8::88 ::1 127.0.0.1}"
  exit 0
fi
printf 'testhost\n'
EOF

  cat >"$fakebin/curl" <<'EOF'
#!/bin/sh
set -eu
self_dir="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
out=""
last=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o)
      out="$2"
      shift 2
      ;;
    *)
      last="$1"
      shift
      ;;
  esac
done
if [ -n "${FAKE_NET_LOG:-}" ]; then
  printf 'curl %s\n' "$last" >>"${FAKE_NET_LOG}"
fi
good_hash="$(cat "$self_dir/good.sha256")"
case "$last" in
  *"/versions.json")
    if [ "${FAKE_DISABLE_VERSIONS_JSON:-0}" = "1" ]; then
      exit 22
    fi
    body='{"stable":"v9.9.9","latest":"v9.10.0-rc.1"}'
    if [ -n "$out" ]; then
      printf '%s\n' "$body" >"$out"
    else
      printf '%s\n' "$body"
    fi
    ;;
  *"/releases/latest")
    if [ -n "$out" ]; then
      printf '{"tag_name":"v9.9.8"}\n' >"$out"
    else
      printf '{"tag_name":"v9.9.8"}\n'
    fi
    ;;
  *"/SHA256SUMS")
    if [ "${FAKE_MISSING_SUMS:-0}" = "1" ]; then
      exit 22
    fi
    ver="$(printf '%s' "$last" | sed 's#.*/download/\([^/]*\)/SHA256SUMS#\1#')"
    sum_val="${FAKE_OVERRIDE_SHA256:-$good_hash}"
    printf '%s  vohive_%s_linux_amd64\n%s  vohive_%s_linux_arm64\n%s  vohive_%s_linux_armv7\n' \
      "$sum_val" "$ver" "$sum_val" "$ver" "$sum_val" "$ver" >"$out"
    ;;
  *"vohive_"*"_linux_"*)
    cp "$self_dir/sample_vohive_bin" "$out"
    ;;
  *)
    printf 'unexpected curl url: %s\n' "$last" >&2
    exit 1
    ;;
esac
EOF

  cat >"$fakebin/wget" <<'EOF'
#!/bin/sh
set -eu
self_dir="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
out=""
url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -O)
      out="$2"
      shift 2
      ;;
    *)
      url="$1"
      shift
      ;;
  esac
done
if [ -n "${FAKE_NET_LOG:-}" ]; then
  printf 'wget %s\n' "$url" >>"${FAKE_NET_LOG}"
fi
good_hash="$(cat "$self_dir/good.sha256")"
case "$url" in
  *"/versions.json")
    if [ "${FAKE_DISABLE_VERSIONS_JSON:-0}" = "1" ]; then
      exit 8
    fi
    printf '{"stable":"v9.9.9","latest":"v9.10.0-rc.1"}\n' >"$out"
    ;;
  *"/releases/latest")
    printf '{"tag_name":"v9.9.8"}\n' >"$out"
    ;;
  *"/SHA256SUMS")
    if [ "${FAKE_MISSING_SUMS:-0}" = "1" ]; then
      exit 8
    fi
    ver="$(printf '%s' "$url" | sed 's#.*/download/\([^/]*\)/SHA256SUMS#\1#')"
    sum_val="${FAKE_OVERRIDE_SHA256:-$good_hash}"
    printf '%s  vohive_%s_linux_amd64\n' "$sum_val" "$ver" >"$out"
    ;;
  *"vohive_"*"_linux_"*)
    cp "$self_dir/sample_vohive_bin" "$out"
    ;;
  *)
    printf 'unexpected wget url: %s\n' "$url" >&2
    exit 1
    ;;
esac
EOF

  cat >"$fakebin/systemctl" <<'EOF'
#!/bin/sh
if [ -n "${FAKE_SYSTEMCTL_LOG:-}" ]; then
  printf 'systemctl %s\n' "$*" >>"${FAKE_SYSTEMCTL_LOG}"
fi
printf 'systemctl %s\n' "$*" >&2
if [ "${1:-}" = "is-active" ] && [ "${FAKE_SYSTEMCTL_FAIL_ACTIVE:-0}" = "1" ]; then
  exit 3
fi
exit 0
EOF

  chmod +x "$fakebin/uname" "$fakebin/id" "$fakebin/hostname" "$fakebin/curl" "$fakebin/wget" "$fakebin/systemctl"
}

run_install_case() {
  shell_name="$1"
  platform="$2"
  shift 2
  case_dir="$TMP_ROOT/install-$shell_name-$platform"
  fakebin="$case_dir/fakebin"
  root_dir="$case_dir/root"
  dry_tmp="$case_dir/dry_tmp"
  net_log="$case_dir/net.log"
  mkdir -p "$root_dir" "$dry_tmp"
  : >"$net_log"
  make_fakebin "$fakebin"

  openwrt_release="$case_dir/openwrt_release"
  procd_path="$case_dir/procd"
  systemd_dir="$case_dir/systemd"
  init_path="$case_dir/init.d/vohive"
  service_path="$case_dir/vohive.service"

  mkdir -p "$(dirname "$init_path")" "$systemd_dir"
  : >"$procd_path"

  if [ "$platform" = "openwrt" ]; then
    printf 'DISTRIB_ID=OpenWrt\n' >"$openwrt_release"
  else
    rm -f "$openwrt_release"
  fi

  if [ "$platform" = "systemd" ]; then
    : >"$systemd_dir/active"
  else
    rm -f "$systemd_dir/active"
  fi

  output="$(env \
    PATH="$fakebin:$PATH" \
    TMPDIR="$dry_tmp" \
    FAKE_NET_LOG="$net_log" \
    VOHIVE_INSTALL_ROOT="$root_dir/opt/vohive" \
    VOHIVE_OPENWRT_RELEASE_FILE="$openwrt_release" \
    VOHIVE_PROCD_PATH="$procd_path" \
    VOHIVE_SYSTEMD_RUN_DIR="$systemd_dir/active" \
    VOHIVE_OPENWRT_INIT_PATH="$init_path" \
    VOHIVE_SYSTEMD_SERVICE_PATH="$service_path" \
    "$shell_name" "$REPO_DIR/install.sh" --dry-run "$@" 2>&1)"

  # Verify --dry-run touched zero network endpoints, zero TMPDIR files, and zero install files!
  if [ -s "$net_log" ]; then
    printf 'dry-run unexpectedly made network calls:\n%s\n' "$(cat "$net_log")" >&2
    exit 1
  fi
  if [ -n "$(ls -A "$dry_tmp")" ]; then
    printf 'dry-run unexpectedly created temp files in TMPDIR\n' >&2
    exit 1
  fi
  if [ -d "$root_dir/opt" ]; then
    printf 'dry-run unexpectedly created install directory\n' >&2
    exit 1
  fi

  printf '%s\n' "$output"
}

run_uninstall_case() {
  shell_name="$1"
  platform="$2"
  shift 2
  case_dir="$TMP_ROOT/uninstall-$shell_name-$platform"
  fakebin="$case_dir/fakebin"
  root_dir="$case_dir/root"
  mkdir -p "$root_dir"
  make_fakebin "$fakebin"

  openwrt_release="$case_dir/openwrt_release"
  procd_path="$case_dir/procd"
  systemd_dir="$case_dir/systemd"
  init_path="$case_dir/init.d/vohive"
  service_path="$case_dir/vohive.service"

  mkdir -p "$(dirname "$init_path")" "$systemd_dir"
  : >"$procd_path"
  : >"$init_path"
  : >"$service_path"

  if [ "$platform" = "openwrt" ]; then
    printf 'DISTRIB_ID=OpenWrt\n' >"$openwrt_release"
  else
    rm -f "$openwrt_release"
  fi

  if [ "$platform" = "systemd" ]; then
    : >"$systemd_dir/active"
  else
    rm -f "$systemd_dir/active"
  fi

  env \
    PATH="$fakebin:$PATH" \
    VOHIVE_INSTALL_ROOT="$root_dir/opt/vohive" \
    VOHIVE_OPENWRT_RELEASE_FILE="$openwrt_release" \
    VOHIVE_PROCD_PATH="$procd_path" \
    VOHIVE_SYSTEMD_RUN_DIR="$systemd_dir/active" \
    VOHIVE_OPENWRT_INIT_PATH="$init_path" \
    VOHIVE_SYSTEMD_SERVICE_PATH="$service_path" \
    "$shell_name" "$REPO_DIR/uninstall.sh" --dry-run "$@" 2>&1
}

# 1. Existing dry-run smoke tests (sh & bash across none/systemd/openwrt)
install_sh_output="$(run_install_case sh none --no-systemd)"
assert_contains "$install_sh_output" "手动启动命令"
assert_contains "$install_sh_output" "[dry-run] download"
assert_contains "$install_sh_output" "http://[2001:db8::88]:7575"
assert_not_contains "$install_sh_output" "fe80::1"

install_systemd_output="$(run_install_case sh systemd)"
assert_contains "$install_systemd_output" "systemctl enable vohive"

install_openwrt_output="$(run_install_case sh openwrt)"
assert_contains "$install_openwrt_output" "init.d/vohive"

install_bash_output="$(run_install_case bash none --no-systemd)"
assert_contains "$install_bash_output" "手动启动命令"

uninstall_systemd_output="$(run_uninstall_case sh systemd --purge)"
assert_contains "$uninstall_systemd_output" "systemctl disable vohive"

uninstall_openwrt_output="$(run_uninstall_case sh openwrt --purge)"
assert_contains "$uninstall_openwrt_output" "init.d/vohive disable"

# 2. Static systemd/vohive.service verification ([MED-05])
repo_unit_content="$(cat "$REPO_DIR/systemd/vohive.service")"
assert_contains "$repo_unit_content" "After=network-online.target pcscd.socket"
assert_contains "$repo_unit_content" "TimeoutStopSec=20"

# 3. Real systemd installation: SHA256SUMS verification, 0600 config.yaml, versions.json channel resolution, unit template
real_sys_dir="$TMP_ROOT/real-systemd"
mkdir -p "$real_sys_dir/init.d" "$real_sys_dir/systemd"
make_fakebin "$real_sys_dir/fakebin"
: >"$real_sys_dir/procd"
: >"$real_sys_dir/systemd/active"
: >"$real_sys_dir/systemctl.log"

real_sys_out="$(env \
  PATH="$real_sys_dir/fakebin:$PATH" \
  FAKE_SYSTEMCTL_LOG="$real_sys_dir/systemctl.log" \
  VOHIVE_SERVICE_VERIFY_DELAY=0 \
  VOHIVE_INSTALL_ROOT="$real_sys_dir/opt/vohive" \
  VOHIVE_OPENWRT_RELEASE_FILE="$real_sys_dir/no_openwrt" \
  VOHIVE_PROCD_PATH="$real_sys_dir/procd" \
  VOHIVE_SYSTEMD_RUN_DIR="$real_sys_dir/systemd/active" \
  VOHIVE_OPENWRT_INIT_PATH="$real_sys_dir/init.d/vohive" \
  VOHIVE_SYSTEMD_SERVICE_PATH="$real_sys_dir/vohive.service" \
  sh "$REPO_DIR/install.sh" --channel latest 2>&1)"

assert_contains "$real_sys_out" "已解析版本: v9.10.0-rc.1"
assert_contains "$real_sys_out" "SHA-256 校验通过"
assert_contains "$real_sys_out" "最小配置已生成"
assert_contains "$real_sys_out" "http://[2001:db8::88]:7575"
assert_not_contains "$real_sys_out" "fe80::1"
assert_eq "$(file_mode "$real_sys_dir/opt/vohive/config/config.yaml")" "600" "config.yaml mode"
assert_eq "$(file_mode "$real_sys_dir/opt/vohive/bin/vohive")" "755" "vohive binary mode"

gen_unit="$(cat "$real_sys_dir/vohive.service")"
assert_contains "$gen_unit" "After=network-online.target pcscd.socket"
assert_contains "$gen_unit" "TimeoutStopSec=20"
assert_contains "$gen_unit" "ExecStart=\"$real_sys_dir/opt/vohive/bin/vohive\" -c \"$real_sys_dir/opt/vohive/config/config.yaml\""

# 4. Upgrade preserves customized config.yaml (no default password log), falls back when versions.json fails, and atomically replaces live running binary
printf 'server:\n  port: ":8585"\nsecret: "keep-me"\n' >"$real_sys_dir/opt/vohive/config/config.yaml"
chmod 0600 "$real_sys_dir/opt/vohive/config/config.yaml"

# Keep an executing process holding the old vohive binary open to guard against ETXTBSY!
cat >"$real_sys_dir/opt/vohive/bin/vohive" <<'EOF'
#!/bin/sh
sleep 2
EOF
chmod 0755 "$real_sys_dir/opt/vohive/bin/vohive"
"$real_sys_dir/opt/vohive/bin/vohive" &
bg_pid=$!

upgrade_out="$(env \
  PATH="$real_sys_dir/fakebin:$PATH" \
  FAKE_DISABLE_VERSIONS_JSON=1 \
  VOHIVE_SERVICE_VERIFY_DELAY=0 \
  VOHIVE_INSTALL_ROOT="$real_sys_dir/opt/vohive" \
  VOHIVE_OPENWRT_RELEASE_FILE="$real_sys_dir/no_openwrt" \
  VOHIVE_PROCD_PATH="$real_sys_dir/procd" \
  VOHIVE_SYSTEMD_RUN_DIR="$real_sys_dir/systemd/active" \
  VOHIVE_OPENWRT_INIT_PATH="$real_sys_dir/init.d/vohive" \
  VOHIVE_SYSTEMD_SERVICE_PATH="$real_sys_dir/vohive.service" \
  sh "$REPO_DIR/install.sh" 2>&1)"

kill "$bg_pid" 2>/dev/null || true
wait "$bg_pid" 2>/dev/null || true

assert_contains "$upgrade_out" "已解析版本: v9.9.8"
assert_contains "$upgrade_out" "已保留现有配置"
assert_not_contains "$upgrade_out" "默认 Web 账号密码"
assert_contains "$(cat "$real_sys_dir/opt/vohive/config/config.yaml")" 'secret: "keep-me"'
if [ ! -f "$real_sys_dir/opt/vohive/bin/vohive.bak" ]; then
  printf 'expected backup binary vohive.bak after upgrade\n' >&2
  exit 1
fi

# 5. Real OpenWrt procd installation: verify generated init script syntax, term_timeout 15, NO directory param, and actual CWD wrapper execution!
real_owrt_dir="$TMP_ROOT/real-openwrt"
mkdir -p "$real_owrt_dir/init.d" "$real_owrt_dir/systemd"
make_fakebin "$real_owrt_dir/fakebin"
printf 'DISTRIB_ID=OpenWrt\n' >"$real_owrt_dir/openwrt_release"
: >"$real_owrt_dir/procd"

cat >"$real_owrt_dir/rc.common" <<'EOF'
#!/bin/sh
set -eu
init_script="$1"
action="$2"
procd_open_instance() { :; }
procd_close_instance() { :; }
procd_set_param() {
  param_type="$1"
  shift
  printf '%s:%s\n' "$param_type" "$*" >>"${PROCD_CAPTURE_FILE}"
  if [ "$param_type" = "command" ] && [ "$action" = "restart" ]; then
    # Replace -c <cfg> with --print-cwd to verify the wrapper cds into ROOT_DIR before exec!
    sh_bin="$1"
    sh_flag="$2"
    sh_script="$3"
    sh_arg0="$4"
    work_dir="$5"
    target_bin="$6"
    (cd / && "$sh_bin" "$sh_flag" "$sh_script" "$sh_arg0" "$work_dir" "$target_bin" --print-cwd) >"${PROCD_EXEC_CWD_FILE}"
  fi
}
# shellcheck disable=SC1090
. "$init_script"
case "$action" in
  enable|stop|disable) ;;
  restart) start_service ;;
esac
EOF

: >"$real_owrt_dir/procd.capture"
env \
  PATH="$real_owrt_dir/fakebin:$PATH" \
  PROCD_CAPTURE_FILE="$real_owrt_dir/procd.capture" \
  PROCD_EXEC_CWD_FILE="$real_owrt_dir/procd.cwd" \
  VOHIVE_RC_COMMON_PATH="$real_owrt_dir/rc.common" \
  VOHIVE_INSTALL_ROOT="$real_owrt_dir/opt/vohive" \
  VOHIVE_OPENWRT_RELEASE_FILE="$real_owrt_dir/openwrt_release" \
  VOHIVE_PROCD_PATH="$real_owrt_dir/procd" \
  VOHIVE_SYSTEMD_RUN_DIR="$real_owrt_dir/systemd/none" \
  VOHIVE_OPENWRT_INIT_PATH="$real_owrt_dir/init.d/vohive" \
  VOHIVE_SYSTEMD_SERVICE_PATH="$real_owrt_dir/vohive.service" \
  sh "$REPO_DIR/install.sh" >/dev/null

sh -n "$real_owrt_dir/init.d/vohive"
gen_init="$(cat "$real_owrt_dir/init.d/vohive")"
assert_not_contains "$gen_init" "procd_set_param directory"
assert_contains "$gen_init" 'procd_set_param command /bin/sh -c '\''cd "$1" && shift && exec "$@"'\'' sh'
assert_contains "$gen_init" "procd_set_param term_timeout 15"
assert_eq "$(cat "$real_owrt_dir/procd.cwd")" "$real_owrt_dir/opt/vohive" "OpenWrt wrapper CWD"

# 6. SHA256SUMS fail-closed on hash mismatch and missing SHA256SUMS, plus explicit --skip-checksum opt-out
bad_sum_dir="$TMP_ROOT/bad-checksum"
mkdir -p "$bad_sum_dir/init.d"
make_fakebin "$bad_sum_dir/fakebin"
: >"$bad_sum_dir/procd"

if env \
  PATH="$bad_sum_dir/fakebin:$PATH" \
  FAKE_OVERRIDE_SHA256="0000000000000000000000000000000000000000000000000000000000000000" \
  VOHIVE_INSTALL_ROOT="$bad_sum_dir/opt/vohive" \
  VOHIVE_OPENWRT_RELEASE_FILE="$bad_sum_dir/no_openwrt" \
  VOHIVE_PROCD_PATH="$bad_sum_dir/procd" \
  VOHIVE_SYSTEMD_RUN_DIR="$bad_sum_dir/no_systemd" \
  VOHIVE_OPENWRT_INIT_PATH="$bad_sum_dir/init.d/vohive" \
  VOHIVE_SYSTEMD_SERVICE_PATH="$bad_sum_dir/vohive.service" \
  sh "$REPO_DIR/install.sh" --no-systemd >/dev/null 2>&1; then
  printf 'expected install.sh to fail closed on SHA-256 mismatch\n' >&2
  exit 1
fi
if [ -f "$bad_sum_dir/opt/vohive/bin/vohive" ]; then
  printf 'tampered binary must NOT be installed on checksum mismatch\n' >&2
  exit 1
fi

if env \
  PATH="$bad_sum_dir/fakebin:$PATH" \
  FAKE_MISSING_SUMS=1 \
  VOHIVE_INSTALL_ROOT="$bad_sum_dir/opt/vohive" \
  VOHIVE_OPENWRT_RELEASE_FILE="$bad_sum_dir/no_openwrt" \
  VOHIVE_PROCD_PATH="$bad_sum_dir/procd" \
  VOHIVE_SYSTEMD_RUN_DIR="$bad_sum_dir/no_systemd" \
  VOHIVE_OPENWRT_INIT_PATH="$bad_sum_dir/init.d/vohive" \
  VOHIVE_SYSTEMD_SERVICE_PATH="$bad_sum_dir/vohive.service" \
  sh "$REPO_DIR/install.sh" --no-systemd >/dev/null 2>&1; then
  printf 'expected install.sh to fail closed when SHA256SUMS is missing\n' >&2
  exit 1
fi

skip_out="$(env \
  PATH="$bad_sum_dir/fakebin:$PATH" \
  FAKE_MISSING_SUMS=1 \
  VOHIVE_INSTALL_ROOT="$bad_sum_dir/opt/vohive" \
  VOHIVE_OPENWRT_RELEASE_FILE="$bad_sum_dir/no_openwrt" \
  VOHIVE_PROCD_PATH="$bad_sum_dir/procd" \
  VOHIVE_SYSTEMD_RUN_DIR="$bad_sum_dir/no_systemd" \
  VOHIVE_OPENWRT_INIT_PATH="$bad_sum_dir/init.d/vohive" \
  VOHIVE_SYSTEMD_SERVICE_PATH="$bad_sum_dir/vohive.service" \
  sh "$REPO_DIR/install.sh" --no-systemd --skip-checksum 2>&1)"
assert_contains "$skip_out" "跳过 SHA-256 校验"

# 7. Command injection & unsafe path / channel rejection ([HIGH-02] & [MED-04])
if env \
  PATH="$bad_sum_dir/fakebin:$PATH" \
  VOHIVE_INSTALL_ROOT="/tmp/evil\";touch /tmp/pwned;#" \
  sh "$REPO_DIR/install.sh" --dry-run >/dev/null 2>&1; then
  printf 'expected unsafe VOHIVE_INSTALL_ROOT to be rejected\n' >&2
  exit 1
fi
if env \
  PATH="$bad_sum_dir/fakebin:$PATH" \
  sh "$REPO_DIR/install.sh" --dry-run --channel invalid_chan >/dev/null 2>&1; then
  printf 'expected invalid --channel to be rejected\n' >&2
  exit 1
fi
if env \
  PATH="$bad_sum_dir/fakebin:$PATH" \
  VOHIVE_INSTALL_ROOT="/data" \
  sh "$REPO_DIR/uninstall.sh" --dry-run --purge >/dev/null 2>&1; then
  printf 'expected unsafe top-level /data VOHIVE_INSTALL_ROOT to be rejected by uninstall.sh\n' >&2
  exit 1
fi

# 8. Real uninstall.sh --purge --keep-config and full --purge
env \
  PATH="$real_sys_dir/fakebin:$PATH" \
  VOHIVE_INSTALL_ROOT="$real_sys_dir/opt/vohive" \
  VOHIVE_OPENWRT_RELEASE_FILE="$real_sys_dir/no_openwrt" \
  VOHIVE_PROCD_PATH="$real_sys_dir/procd" \
  VOHIVE_SYSTEMD_RUN_DIR="$real_sys_dir/systemd/active" \
  VOHIVE_OPENWRT_INIT_PATH="$real_sys_dir/init.d/vohive" \
  VOHIVE_SYSTEMD_SERVICE_PATH="$real_sys_dir/vohive.service" \
  sh "$REPO_DIR/uninstall.sh" --purge --keep-config >/dev/null

if [ ! -f "$real_sys_dir/opt/vohive/config/config.yaml" ]; then
  printf 'expected --keep-config to preserve config.yaml\n' >&2
  exit 1
fi
if [ -d "$real_sys_dir/opt/vohive/data" ] || [ -f "$real_sys_dir/opt/vohive/bin/vohive" ]; then
  printf 'expected --purge --keep-config to remove binary and data dir\n' >&2
  exit 1
fi

env \
  PATH="$real_sys_dir/fakebin:$PATH" \
  VOHIVE_INSTALL_ROOT="$real_sys_dir/opt/vohive" \
  VOHIVE_OPENWRT_RELEASE_FILE="$real_sys_dir/no_openwrt" \
  VOHIVE_PROCD_PATH="$real_sys_dir/procd" \
  VOHIVE_SYSTEMD_RUN_DIR="$real_sys_dir/systemd/active" \
  VOHIVE_OPENWRT_INIT_PATH="$real_sys_dir/init.d/vohive" \
  VOHIVE_SYSTEMD_SERVICE_PATH="$real_sys_dir/vohive.service" \
  sh "$REPO_DIR/uninstall.sh" --purge >/dev/null

if [ -d "$real_sys_dir/opt/vohive" ]; then
  printf 'expected full --purge to remove %s\n' "$real_sys_dir/opt/vohive" >&2
  exit 1
fi

# 9. Minimal OpenWrt/BusyBox environment test: wget-only (no curl) and no coreutils `install` binary!
min_dir="$TMP_ROOT/minimal-busybox"
min_bin="$min_dir/bin"
mkdir -p "$min_bin" "$min_dir/init.d"
make_fakebin "$min_dir/fakebin"
rm -f "$min_dir/fakebin/curl"
for cmd in sh cp chmod mv rm mkdir cat sed tr head awk mktemp sleep dirname pwd; do
  cmd_path="$(command -v "$cmd")"
  ln -sf "$cmd_path" "$min_bin/$cmd"
done
for cmd in sha256sum shasum openssl; do
  if cmd_path="$(command -v "$cmd" 2>/dev/null)"; then
    ln -sf "$cmd_path" "$min_bin/$cmd"
  fi
done
for f in uname id hostname wget sample_vohive_bin good.sha256; do
  cp "$min_dir/fakebin/$f" "$min_bin/$f"
done
printf 'DISTRIB_ID=OpenWrt\n' >"$min_dir/openwrt_release"
: >"$min_dir/procd"
: >"$min_dir/procd.capture"

env \
  PATH="$min_bin" \
  PROCD_CAPTURE_FILE="$min_dir/procd.capture" \
  PROCD_EXEC_CWD_FILE="$min_dir/procd.cwd" \
  VOHIVE_RC_COMMON_PATH="$real_owrt_dir/rc.common" \
  VOHIVE_INSTALL_ROOT="$min_dir/opt/vohive" \
  VOHIVE_OPENWRT_RELEASE_FILE="$min_dir/openwrt_release" \
  VOHIVE_PROCD_PATH="$min_dir/procd" \
  VOHIVE_SYSTEMD_RUN_DIR="$min_dir/no_systemd" \
  VOHIVE_OPENWRT_INIT_PATH="$min_dir/init.d/vohive" \
  VOHIVE_SYSTEMD_SERVICE_PATH="$min_dir/vohive.service" \
  "$min_bin/sh" "$REPO_DIR/install.sh" >/dev/null

assert_eq "$(file_mode "$min_dir/opt/vohive/config/config.yaml")" "600" "minimal wget/cp config.yaml mode"
assert_eq "$(file_mode "$min_dir/opt/vohive/bin/vohive")" "755" "minimal wget/cp binary mode"
assert_eq "$(cat "$min_dir/procd.cwd")" "$min_dir/opt/vohive" "minimal OpenWrt CWD"

printf 'ok - installer compatibility and security tests passed\n'
