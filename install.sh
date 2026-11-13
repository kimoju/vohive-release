#!/bin/sh
set -eu

REPO="${VOHIVE_RELEASE_REPO:-kimoju/vohive-release}"
CHANNEL="${VOHIVE_RELEASE_CHANNEL:-stable}"
VERSION=""
NO_SYSTEMD=0
DRY_RUN=0
FORCE=0
SKIP_CHECKSUM=0

ROOT_DIR="${VOHIVE_INSTALL_ROOT:-/opt/vohive}"
INSTALL_DIR="${ROOT_DIR}/bin"
CONFIG_DIR="${ROOT_DIR}/config"
CONFIG_FILE="${CONFIG_DIR}/config.yaml"
DATA_DIR="${ROOT_DIR}/data"
LOG_DIR="${ROOT_DIR}/logs"
BIN_PATH="${INSTALL_DIR}/vohive"
BACKUP_PATH="${INSTALL_DIR}/vohive.bak"
SYSTEMD_SERVICE_PATH="${VOHIVE_SYSTEMD_SERVICE_PATH:-/etc/systemd/system/vohive.service}"
OPENWRT_INIT_PATH="${VOHIVE_OPENWRT_INIT_PATH:-/etc/init.d/vohive}"
OPENWRT_RELEASE_FILE="${VOHIVE_OPENWRT_RELEASE_FILE:-/etc/openwrt_release}"
PROCD_PATH="${VOHIVE_PROCD_PATH:-/sbin/procd}"
SYSTEMD_RUN_DIR="${VOHIVE_SYSTEMD_RUN_DIR:-/run/systemd/system}"
SERVICE_VERIFY_DELAY="${VOHIVE_SERVICE_VERIFY_DELAY:-1}"

DOWNLOAD_CMD=""
TMP_DIR=""
ACTIVE_PLATFORM="none"
CONFIG_CREATED=0

log() { printf '[vohive-install] %s\n' "$*"; }
err() { printf '[vohive-install] 错误: %s\n' "$*" >&2; }

usage() {
  cat <<USAGE
用法: install.sh [选项]
  --version <vX.Y.Z|latest|stable>
  --channel <stable|latest>
  --no-systemd
  --skip-checksum
  --dry-run
  --force
USAGE
}

validate_safe_path() {
  label="$1"
  val="$2"
  case "$val" in
    ""|/|*[!A-Za-z0-9._/-]*|*/../*|*/..|../*)
      err "${label} 包含非法或不安全路径: ${val}"
      exit 1
      ;;
    /*)
      ;;
    *)
      err "${label} 必须为绝对路径: ${val}"
      exit 1
      ;;
  esac
}

validate_repo() {
  val="$1"
  case "$val" in
    ""|*/*/*|*[!A-Za-z0-9._/-]*|/*|*/|.|..)
      err "非法的仓库标识: ${val}"
      exit 1
      ;;
    */*)
      ;;
    *)
      err "仓库标识必须为 owner/repo 格式: ${val}"
      exit 1
      ;;
  esac
}

validate_channel() {
  case "$1" in
    stable|latest)
      ;;
    *)
      err "不支持的发布通道: $1（仅支持 stable 或 latest）"
      exit 1
      ;;
  esac
}

validate_version_tag() {
  val="$1"
  case "$val" in
    ""|.|..|-*|*[!A-Za-z0-9._+-]*)
      err "非法的版本号: ${val}"
      exit 1
      ;;
  esac
}

run_root() {
  if [ "${DRY_RUN}" = "1" ]; then
    printf '[dry-run] %s' "$1"
    shift
    for arg in "$@"; do
      printf ' %s' "$arg"
    done
    printf '\n'
    return 0
  fi

  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    err "需要 root 权限（请使用 root 用户或安装 sudo）。"
    exit 1
  fi
}

install_file_atomic() {
  mode="$1"
  src="$2"
  dst="$3"
  tmp_dst="${dst}.tmp"

  if [ "${DRY_RUN}" = "1" ]; then
    run_root install -m "${mode}" "${src}" "${tmp_dst}"
    run_root mv -f "${tmp_dst}" "${dst}"
    return 0
  fi

  if command -v install >/dev/null 2>&1; then
    run_root install -m "${mode}" "${src}" "${tmp_dst}"
  else
    run_root cp -f "${src}" "${tmp_dst}"
    run_root chmod "${mode}" "${tmp_dst}"
  fi
  run_root mv -f "${tmp_dst}" "${dst}"
}

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    err "缺少命令: $1"
    exit 1
  fi
}

need_download_cmd() {
  if command -v curl >/dev/null 2>&1; then
    DOWNLOAD_CMD="curl"
    return 0
  fi
  if command -v wget >/dev/null 2>&1; then
    DOWNLOAD_CMD="wget"
    return 0
  fi
  err "缺少下载命令: 需要 curl 或 wget"
  exit 1
}

download_to() {
  url="$1"
  dest="$2"
  if [ "${DOWNLOAD_CMD}" = "curl" ]; then
    curl -fsSL "$url" -o "$dest"
  else
    wget -q -O "$dest" "$url"
  fi
}

try_fetch_text() {
  url="$1"
  tmp_file="${TMP_DIR}/fetch.txt"
  rm -f "$tmp_file"
  download_to "$url" "$tmp_file" || return 1
  cat "$tmp_file"
}

resolve_version() {
  requested="$1"

  if [ -z "${requested}" ]; then
    requested="${CHANNEL}"
  fi

  case "${requested}" in
    latest|stable)
      versions_url="${VOHIVE_VERSIONS_URL:-https://raw.githubusercontent.com/${REPO}/master/versions.json}"
      resolved=""
      if versions_json="$(try_fetch_text "${versions_url}" 2>/dev/null)"; then
        resolved="$(printf '%s\n' "${versions_json}" | sed -n "s/.*\"${requested}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n 1)"
      fi
      if [ -z "${resolved}" ]; then
        api_url="https://api.github.com/repos/${REPO}/releases/latest"
        if latest_json="$(try_fetch_text "${api_url}")"; then
          resolved="$(printf '%s\n' "${latest_json}" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
        fi
      fi
      if [ -z "${resolved}" ]; then
        err "无法从 versions.json 或 GitHub API 获取最新 Release 版本号。"
        exit 1
      fi
      validate_version_tag "${resolved}"
      printf '%s\n' "${resolved}"
      ;;
    *)
      validate_version_tag "${requested}"
      printf '%s\n' "${requested}"
      ;;
  esac
}

extract_expected_sha256() {
  sums_file="$1"
  target_asset="$2"
  (
    set -f
    while IFS= read -r line || [ -n "$line" ]; do
      line="$(printf '%s' "$line" | tr -d '\r')"
      case "$line" in
        ""|\#*)
          continue
          ;;
      esac
      # shellcheck disable=SC2086
      set -- $line
      hash="${1:-}"
      file="${2:-}"
      file="${file#\*}"
      file="${file#./}"
      file="${file##*/}"
      if [ "$file" = "$target_asset" ]; then
        lower_hash="$(printf '%s' "$hash" | tr '[:upper:]' '[:lower:]')"
        if [ "${#lower_hash}" -ne 64 ]; then
          exit 1
        fi
        case "$lower_hash" in
          *[!0-9a-f]*)
            exit 1
            ;;
        esac
        printf '%s\n' "$lower_hash"
        exit 0
      fi
    done <"$sums_file"
    exit 1
  )
}

compute_file_sha256() {
  target_file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$target_file" | awk '{print tolower($1)}'
    return 0
  fi
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$target_file" | awk '{print tolower($1)}'
    return 0
  fi
  if command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$target_file" | awk '{print tolower($NF)}'
    return 0
  fi
  err "缺少 SHA-256 校验工具（需要 sha256sum、shasum 或 openssl）。"
  return 1
}

verify_binary_checksum() {
  sums_url="$1"
  asset_name="$2"
  binary_path="$3"
  sums_path="${TMP_DIR}/SHA256SUMS"

  log "正在下载校验文件: ${sums_url}"
  if ! download_to "${sums_url}" "${sums_path}"; then
    err "无法下载校验文件: ${sums_url}（如确认安装无校验文件的旧版本，可显式指定 --skip-checksum）"
    exit 1
  fi

  if ! expected_hash="$(extract_expected_sha256 "${sums_path}" "${asset_name}")" || [ -z "${expected_hash}" ]; then
    err "SHA256SUMS 中未找到有效资产校验项: ${asset_name}"
    exit 1
  fi

  if ! actual_hash="$(compute_file_sha256 "${binary_path}")" || [ -z "${actual_hash}" ]; then
    err "无法计算下载文件的 SHA-256 摘要"
    exit 1
  fi

  if [ "${actual_hash}" != "${expected_hash}" ]; then
    err "SHA-256 校验失败: 期望 ${expected_hash}，实际 ${actual_hash}"
    exit 1
  fi

  log "SHA-256 校验通过: ${actual_hash}"
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --version)
        if [ "$#" -lt 2 ]; then
          err "--version 缺少参数"
          usage
          exit 1
        fi
        VERSION="$2"
        shift 2
        ;;
      --channel)
        if [ "$#" -lt 2 ]; then
          err "--channel 缺少参数"
          usage
          exit 1
        fi
        CHANNEL="$2"
        shift 2
        ;;
      --no-systemd)
        NO_SYSTEMD=1
        shift
        ;;
      --skip-checksum)
        SKIP_CHECKSUM=1
        shift
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --force)
        FORCE=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        err "未知参数: $1"
        usage
        exit 1
        ;;
    esac
  done
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) printf 'amd64\n' ;;
    aarch64|arm64) printf 'arm64\n' ;;
    armv7|armv7l) printf 'armv7\n' ;;
    *)
      err "不支持的架构: $(uname -m)"
      exit 1
      ;;
  esac
}

detect_platform() {
  if [ -n "${VOHIVE_PLATFORM_OVERRIDE:-}" ]; then
    printf '%s\n' "${VOHIVE_PLATFORM_OVERRIDE}"
    return 0
  fi
  if [ -f "${OPENWRT_RELEASE_FILE}" ] || [ -x "${PROCD_PATH}" ]; then
    printf 'openwrt\n'
    return 0
  fi
  if command -v systemctl >/dev/null 2>&1 && { [ -d "${SYSTEMD_RUN_DIR}" ] || [ -f "${SYSTEMD_RUN_DIR}" ]; }; then
    printf 'systemd\n'
    return 0
  fi
  printf 'none\n'
}

install_default_config() {
  run_root mkdir -p "${INSTALL_DIR}" "${CONFIG_DIR}" "${DATA_DIR}" "${LOG_DIR}"
  if [ ! -f "${CONFIG_FILE}" ] || [ "${FORCE}" = "1" ]; then
    CONFIG_CREATED=1
    if [ "${DRY_RUN}" = "1" ]; then
      install_file_atomic 0600 "<generated-config.yaml>" "${CONFIG_FILE}"
      return 0
    fi
    tmp_cfg="${TMP_DIR}/config.yaml"
    (
      umask 077
      cat >"${tmp_cfg}" <<'CFG'
server:
  port: ":7575"

web:
  username: "admin"
  password: "admin"
CFG
    )
    chmod 0600 "${tmp_cfg}"
    install_file_atomic 0600 "${tmp_cfg}" "${CONFIG_FILE}"
  fi
}

install_service_systemd() {
  tmp_unit_path="$1"
  if [ "${DRY_RUN}" = "1" ]; then
    install_file_atomic 0644 "<generated-vohive.service>" "${SYSTEMD_SERVICE_PATH}"
    run_root systemctl daemon-reload
    run_root systemctl enable vohive
    run_root systemctl restart vohive
    run_root systemctl is-active --quiet vohive
    return 0
  fi

  cat >"${tmp_unit_path}" <<EOF
[Unit]
Description=VoHive Service
After=network-online.target pcscd.socket
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${ROOT_DIR}
ExecStart="${BIN_PATH}" -c "${CONFIG_FILE}"
Restart=always
RestartSec=3
TimeoutStopSec=20
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  install_file_atomic 0644 "${tmp_unit_path}" "${SYSTEMD_SERVICE_PATH}"
  run_root systemctl daemon-reload
  run_root systemctl enable vohive
  run_root systemctl restart vohive
  case "${SERVICE_VERIFY_DELAY}" in
    ""|0) ;;
    *[!0-9]*) sleep 1 ;;
    *) sleep "${SERVICE_VERIFY_DELAY}" ;;
  esac
  run_root systemctl is-active --quiet vohive
}

run_openwrt_init() {
  if [ -n "${VOHIVE_RC_COMMON_PATH:-}" ] && [ "${DRY_RUN}" != "1" ]; then
    run_root /bin/sh "${VOHIVE_RC_COMMON_PATH}" "${OPENWRT_INIT_PATH}" "$@"
  else
    run_root "${OPENWRT_INIT_PATH}" "$@"
  fi
}

install_service_openwrt() {
  tmp_init_path="$1"
  if [ "${DRY_RUN}" = "1" ]; then
    install_file_atomic 0755 "<generated-vohive.init>" "${OPENWRT_INIT_PATH}"
    run_openwrt_init enable
    run_openwrt_init restart
    return 0
  fi

  cat >"${tmp_init_path}" <<EOF
#!/bin/sh /etc/rc.common
START=99
STOP=10
USE_PROCD=1

start_service() {
  procd_open_instance
  procd_set_param command /bin/sh -c 'cd "\$1" && shift && exec "\$@"' sh "${ROOT_DIR}" "${BIN_PATH}" -c "${CONFIG_FILE}"
  procd_set_param file "${CONFIG_FILE}"
  procd_set_param term_timeout 15
  procd_set_param respawn 3600 5 5
  procd_set_param stdout 1
  procd_set_param stderr 1
  procd_close_instance
}
EOF

  install_file_atomic 0755 "${tmp_init_path}" "${OPENWRT_INIT_PATH}"
  run_openwrt_init enable
  run_openwrt_init restart
}

restart_service() {
  case "$1" in
    systemd)
      run_root systemctl daemon-reload || true
      run_root systemctl restart vohive || true
      ;;
    openwrt)
      run_openwrt_init restart || true
      ;;
  esac
}

collect_ips() {
  ips=""
  if command -v hostname >/dev/null 2>&1; then
    ips="$(hostname -I 2>/dev/null || true)"
  fi
  if [ -n "${ips}" ]; then
    printf '%s\n' "${ips}"
    return 0
  fi
  if command -v ip >/dev/null 2>&1; then
    ip -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1
  fi
}

format_http_url() {
  raw_ip="$1"
  port="$2"
  ip_no_zone="${raw_ip%%%*}"
  ip_clean="${ip_no_zone#\[}"
  ip_clean="${ip_clean%\]}"

  case "${ip_clean}" in
    ""|127.*|169.254.*|::1|[fF][eE][89aAbB][0-9a-fA-F]:*)
      return 1
      ;;
    *:*)
      printf 'http://[%s]:%s\n' "${ip_clean}" "${port}"
      return 0
      ;;
    *)
      printf 'http://%s:%s\n' "${ip_clean}" "${port}"
      return 0
      ;;
  esac
}

print_access_info() {
  port="7575"
  if [ "${CONFIG_CREATED}" = "1" ]; then
    log "最小配置已生成: ${CONFIG_FILE}"
    log "默认 Web 账号密码: admin / admin"
  else
    log "已保留现有配置: ${CONFIG_FILE}"
  fi
  log "一键访问链接: http://127.0.0.1:${port}"
  for ip in $(collect_ips); do
    if url="$(format_http_url "$ip" "$port")"; then
      log "一键访问链接: ${url}"
    fi
  done
}

main() {
  parse_args "$@"

  validate_repo "${REPO}"
  validate_channel "${CHANNEL}"
  validate_safe_path "VOHIVE_INSTALL_ROOT" "${ROOT_DIR}"
  validate_safe_path "VOHIVE_SYSTEMD_SERVICE_PATH" "${SYSTEMD_SERVICE_PATH}"
  validate_safe_path "VOHIVE_OPENWRT_INIT_PATH" "${OPENWRT_INIT_PATH}"

  need_cmd uname
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  if [ "${os}" != "linux" ]; then
    err "不支持的系统: ${os}"
    exit 1
  fi

  arch="$(detect_arch)"

  if [ "${DRY_RUN}" = "1" ]; then
    need_download_cmd
    target_spec="${VERSION:-${CHANNEL}}"
    case "${target_spec}" in
      latest|stable)
        versions_url="${VOHIVE_VERSIONS_URL:-https://raw.githubusercontent.com/${REPO}/master/versions.json}"
        printf '[dry-run] resolve channel %s via %s (fallback: https://api.github.com/repos/%s/releases/latest)\n' "${target_spec}" "${versions_url}" "${REPO}"
        planned_ver="<${target_spec}>"
        ;;
      *)
        validate_version_tag "${target_spec}"
        planned_ver="${target_spec}"
        ;;
    esac
    planned_asset="vohive_${planned_ver}_linux_${arch}"
    planned_base="https://github.com/${REPO}/releases/download/${planned_ver}"
    printf '[dry-run] download %s/%s\n' "${planned_base}" "${planned_asset}"
    if [ "${SKIP_CHECKSUM}" = "1" ]; then
      log "警告: 已按参数跳过 SHA-256 校验 (--skip-checksum)"
    else
      printf '[dry-run] verify sha256 via %s/SHA256SUMS\n' "${planned_base}"
    fi
    if [ -x "${BIN_PATH}" ]; then
      install_file_atomic 0755 "${BIN_PATH}" "${BACKUP_PATH}"
    fi
    install_default_config
    install_file_atomic 0755 "<downloaded-${planned_asset}>" "${BIN_PATH}"

    ACTIVE_PLATFORM="$(detect_platform)"
    service_registered=0
    if [ "${NO_SYSTEMD}" = "0" ]; then
      case "${ACTIVE_PLATFORM}" in
        openwrt)
          install_service_openwrt "<dry-run-init>"
          service_registered=1
          ;;
        systemd)
          install_service_systemd "<dry-run-unit>"
          service_registered=1
          ;;
        none)
          log "未检测到 systemd 或 OpenWrt procd，跳过服务注册"
          ;;
        *)
          err "未知平台: ${ACTIVE_PLATFORM}"
          exit 1
          ;;
      esac
    else
      log "已跳过服务注册（--no-systemd 兼容模式）"
    fi

    log "安装计划预览完成: ${BIN_PATH} (${planned_ver})"
    if [ "${service_registered}" = "0" ]; then
      log "手动启动命令: \"${BIN_PATH}\" -c \"${CONFIG_FILE}\""
    fi
    print_access_info
    return 0
  fi

  need_cmd mktemp
  need_download_cmd

  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "${TMP_DIR}"' EXIT INT TERM

  resolved_version="$(resolve_version "${VERSION}")"
  asset="vohive_${resolved_version}_linux_${arch}"
  base="https://github.com/${REPO}/releases/download/${resolved_version}"
  downloaded="${TMP_DIR}/${asset}"

  log "已解析版本: ${resolved_version}"
  log "正在下载二进制: ${base}/${asset}"

  download_to "${base}/${asset}" "${downloaded}"
  if [ ! -f "${downloaded}" ] || [ ! -s "${downloaded}" ]; then
    err "下载的二进制文件不存在或为空"
    exit 1
  fi

  if [ "${SKIP_CHECKSUM}" = "1" ]; then
    log "警告: 已按参数跳过 SHA-256 校验 (--skip-checksum)"
  else
    verify_binary_checksum "${base}/SHA256SUMS" "${asset}" "${downloaded}"
  fi

  chmod 0755 "${downloaded}"

  if [ -x "${BIN_PATH}" ]; then
    log "检测到已安装版本，备份到: ${BACKUP_PATH}"
    install_file_atomic 0755 "${BIN_PATH}" "${BACKUP_PATH}"
  fi

  install_default_config
  rollback_needed=1

  rollback() {
    if [ "${rollback_needed}" = "1" ] && [ -f "${BACKUP_PATH}" ]; then
      err "正在回滚到上一个版本"
      install_file_atomic 0755 "${BACKUP_PATH}" "${BIN_PATH}" || true
      if [ "${NO_SYSTEMD}" = "0" ]; then
        restart_service "${ACTIVE_PLATFORM}"
      fi
    fi
  }

  install_file_atomic 0755 "${downloaded}" "${BIN_PATH}"

  ACTIVE_PLATFORM="$(detect_platform)"
  service_registered=0

  if [ "${NO_SYSTEMD}" = "0" ]; then
    case "${ACTIVE_PLATFORM}" in
      openwrt)
        if ! install_service_openwrt "${TMP_DIR}/vohive.init"; then
          rollback
          err "openwrt procd 安装或启动失败"
          exit 1
        fi
        service_registered=1
        ;;
      systemd)
        if ! install_service_systemd "${TMP_DIR}/vohive.service"; then
          rollback
          err "systemd 安装或启动失败"
          exit 1
        fi
        service_registered=1
        ;;
      none)
        log "未检测到 systemd 或 OpenWrt procd，跳过服务注册"
        ;;
      *)
        err "未知平台: ${ACTIVE_PLATFORM}"
        exit 1
        ;;
    esac
  else
    log "已跳过服务注册（--no-systemd 兼容模式）"
  fi

  rollback_needed=0
  log "安装完成: ${BIN_PATH} (${resolved_version})"

  if [ "${service_registered}" = "1" ]; then
    case "${ACTIVE_PLATFORM}" in
      openwrt)
        log "服务状态: 运行中（OpenWrt procd）"
        ;;
      systemd)
        log "服务状态: 运行中（systemd）"
        ;;
    esac
  else
    log "手动启动命令: \"${BIN_PATH}\" -c \"${CONFIG_FILE}\""
  fi
  print_access_info
}

main "$@"
