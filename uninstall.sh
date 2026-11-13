#!/bin/sh
set -eu

DRY_RUN=0
PURGE=0
KEEP_CONFIG=0

ROOT_DIR="${VOHIVE_INSTALL_ROOT:-/opt/vohive}"
BIN_PATH="${ROOT_DIR}/bin/vohive"
BACKUP_PATH="${ROOT_DIR}/bin/vohive.bak"
SYSTEMD_SERVICE_PATH="${VOHIVE_SYSTEMD_SERVICE_PATH:-/etc/systemd/system/vohive.service}"
OPENWRT_INIT_PATH="${VOHIVE_OPENWRT_INIT_PATH:-/etc/init.d/vohive}"
OPENWRT_RELEASE_FILE="${VOHIVE_OPENWRT_RELEASE_FILE:-/etc/openwrt_release}"
PROCD_PATH="${VOHIVE_PROCD_PATH:-/sbin/procd}"
SYSTEMD_RUN_DIR="${VOHIVE_SYSTEMD_RUN_DIR:-/run/systemd/system}"
CONFIG_DIR="${ROOT_DIR}/config"
DATA_DIR="${ROOT_DIR}/data"
LOG_DIR="${ROOT_DIR}/logs"

log() { printf '[vohive-uninstall] %s\n' "$*"; }
err() { printf '[vohive-uninstall] 错误: %s\n' "$*" >&2; }

usage() {
  cat <<USAGE
用法: uninstall.sh [选项]
  --purge        同时清理数据与日志目录（默认仅移除服务与二进制）
  --keep-config  配合 --purge 使用时保留配置目录
  --dry-run      仅打印将要执行的操作，不修改系统文件
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

validate_install_root() {
  validate_safe_path "VOHIVE_INSTALL_ROOT" "$1"
  case "$1" in
    /bin|/sbin|/usr|/etc|/var|/opt|/home|/root|/tmp|/dev|/proc|/sys|/run|/lib|/lib64|/data)
      err "VOHIVE_INSTALL_ROOT 不能指向系统顶层目录: $1"
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

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --purge)
        PURGE=1
        shift
        ;;
      --keep-config)
        KEEP_CONFIG=1
        shift
        ;;
      --dry-run)
        DRY_RUN=1
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

remove_service_systemd() {
  run_root systemctl stop vohive || true
  run_root systemctl disable vohive || true
  run_root rm -f "${SYSTEMD_SERVICE_PATH}"
  run_root systemctl daemon-reload || true
  run_root systemctl reset-failed vohive || true
}

remove_service_openwrt() {
  if [ -f "${OPENWRT_INIT_PATH}" ] || [ -L "${OPENWRT_INIT_PATH}" ]; then
    if [ -n "${VOHIVE_RC_COMMON_PATH:-}" ] && [ "${DRY_RUN}" != "1" ]; then
      run_root /bin/sh "${VOHIVE_RC_COMMON_PATH}" "${OPENWRT_INIT_PATH}" stop || true
      run_root /bin/sh "${VOHIVE_RC_COMMON_PATH}" "${OPENWRT_INIT_PATH}" disable || true
    else
      run_root "${OPENWRT_INIT_PATH}" stop || true
      run_root "${OPENWRT_INIT_PATH}" disable || true
    fi
    run_root rm -f "${OPENWRT_INIT_PATH}"
  fi
}

main() {
  parse_args "$@"

  validate_install_root "${ROOT_DIR}"
  validate_safe_path "VOHIVE_SYSTEMD_SERVICE_PATH" "${SYSTEMD_SERVICE_PATH}"
  validate_safe_path "VOHIVE_OPENWRT_INIT_PATH" "${OPENWRT_INIT_PATH}"

  platform="$(detect_platform)"
  case "${platform}" in
    openwrt)
      remove_service_openwrt
      ;;
    systemd)
      remove_service_systemd
      ;;
    none)
      log "未检测到 systemd 或 OpenWrt procd，跳过服务卸载"
      ;;
    *)
      err "未知平台: ${platform}"
      exit 1
      ;;
  esac

  run_root rm -f "${BIN_PATH}" "${BACKUP_PATH}" "${BIN_PATH}.tmp" "${BACKUP_PATH}.tmp"

  if [ "${PURGE}" = "1" ]; then
    if [ "${KEEP_CONFIG}" = "0" ]; then
      run_root rm -rf "${CONFIG_DIR}"
    else
      log "已按 --keep-config 保留配置目录: ${CONFIG_DIR}"
    fi
    run_root rm -rf "${DATA_DIR}"
    run_root rm -rf "${LOG_DIR}"
    if [ "${DRY_RUN}" = "1" ] || [ -d "${ROOT_DIR}/bin" ]; then
      run_root rmdir "${ROOT_DIR}/bin" 2>/dev/null || true
    fi
    if [ "${KEEP_CONFIG}" = "0" ] && { [ "${DRY_RUN}" = "1" ] || [ -d "${ROOT_DIR}" ]; }; then
      run_root rmdir "${ROOT_DIR}" 2>/dev/null || true
    fi
  else
    if [ "${DRY_RUN}" = "1" ] || [ -d "${ROOT_DIR}/bin" ]; then
      run_root rmdir "${ROOT_DIR}/bin" 2>/dev/null || true
    fi
    log "已保留配置与数据目录: ${CONFIG_DIR}, ${DATA_DIR}, ${LOG_DIR}（如需彻底清理请附加 --purge）"
  fi

  log "卸载完成"
}

main "$@"
