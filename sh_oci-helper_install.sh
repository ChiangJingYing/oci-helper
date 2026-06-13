#!/usr/bin/env bash
set -euo pipefail

APP_DIR="${APP_DIR:-/app/oci-helper}"
REPO_OWNER="ChiangJingYing"
REPO_NAME="oci-helper"
MAIN_IMAGE="ghcr.io/chiangjingying/oci-helper:master"
WATCHER_IMAGE="ghcr.io/yohann0617/oci-helper-watcher:main"
WEBSOCKIFY_IMAGE="ghcr.io/yohann0617/oci-helper-websockify:master"
DEPLOY_RELEASE_BASE="https://github.com/Yohann0617/oci-helper/releases/download/deploy"
SOURCE_TARBALL_URL="https://codeload.github.com/${REPO_OWNER}/${REPO_NAME}/tar.gz/refs/heads/master"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "缺少命令: $1" >&2
    exit 1
  }
}

fetch_if_missing() {
  local target="$1"
  local url="$2"
  if [ ! -f "$target" ]; then
    echo "下载 $(basename "$target") ..."
    curl -fsSL "$url" -o "$target"
  fi
}

write_compose() {
  cat > "${APP_DIR}/docker-compose.yml" <<EOF
services:
  watcher:
    image: ${WATCHER_IMAGE}
    container_name: oci-helper-watcher
    restart: always
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /usr/local/bin/docker-compose:/usr/local/bin/docker-compose
      - ${APP_DIR}/docker-compose.yml:${APP_DIR}/docker-compose.yml
      - ${APP_DIR}/update_version_trigger.flag:${APP_DIR}/update_version_trigger.flag
      - ${APP_DIR}/oci-helper.db:${APP_DIR}/oci-helper.db

  oci-helper:
    image: ${MAIN_IMAGE}
    container_name: oci-helper
    restart: always
    ports:
      - "8818:8818"
    volumes:
      - ${APP_DIR}/application.yml:${APP_DIR}/application.yml
      - ${APP_DIR}/oci-helper.db:${APP_DIR}/oci-helper.db
      - ${APP_DIR}/keys:${APP_DIR}/keys
      - ${APP_DIR}/update_version_trigger.flag:${APP_DIR}/update_version_trigger.flag
    networks:
      - app-network

  websockify:
    image: ${WEBSOCKIFY_IMAGE}
    container_name: websockify
    restart: always
    ports:
      - "6080:6080"
    depends_on:
      - oci-helper
    networks:
      - app-network

networks:
  app-network:
    driver: bridge
EOF
}

build_main_image_locally() {
  local tmpdir
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "${tmpdir}"' RETURN

  echo "主镜像拉取失败，改为从 ${REPO_OWNER}/${REPO_NAME}@master 本地构建 ..."
  curl -fsSL "${SOURCE_TARBALL_URL}" -o "${tmpdir}/source.tar.gz"
  tar -xzf "${tmpdir}/source.tar.gz" -C "${tmpdir}"

  local source_dir
  source_dir="$(find "${tmpdir}" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  if [ -z "${source_dir}" ]; then
    echo "无法解析源码目录" >&2
    exit 1
  fi

  docker build -t "${MAIN_IMAGE}" -f "${source_dir}/Dockerfile" "${source_dir}"
}

main() {
  need_cmd curl
  need_cmd docker

  mkdir -p "${APP_DIR}/keys"
  touch "${APP_DIR}/update_version_trigger.flag"

  fetch_if_missing "${APP_DIR}/application.yml" "${DEPLOY_RELEASE_BASE}/application.yml"
  fetch_if_missing "${APP_DIR}/oci-helper.db" "${DEPLOY_RELEASE_BASE}/oci-helper.db"
  write_compose

  if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD=(docker compose)
  elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD=(docker-compose)
  else
    echo "缺少 docker compose / docker-compose" >&2
    exit 1
  fi

  echo "拉取并启动 ${REPO_OWNER}/${REPO_NAME} ..."
  docker pull "${WATCHER_IMAGE}"
  docker pull "${WEBSOCKIFY_IMAGE}"
  if ! docker pull "${MAIN_IMAGE}"; then
    build_main_image_locally
  fi
  "${COMPOSE_CMD[@]}" -f "${APP_DIR}/docker-compose.yml" up -d

  cat <<MSG

部署完成。
- Web UI: http://<你的IP>:8818
- 本次安装主镜像: ${MAIN_IMAGE}
- 配置目录: ${APP_DIR}

如需再次更新，可重复执行：
bash <(curl -fsSL https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/master/sh_oci-helper_install.sh)
MSG
}

main "$@"
