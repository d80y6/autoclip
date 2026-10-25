#!/usr/bin/env bash
# Railway 启动入口：先以 root 修 Volume 权限，再降权到 autoclip 运行。
#
# Railway 会把 Volume 以 root 身份挂载，而镜像里的应用用户是 autoclip（uid 10001）。
# Dockerfile 里的 chown 会被挂载点覆盖，所以只能在启动时补一次 —— 也就是这里。
set -euo pipefail

DATA_DIR="${AUTOCLIP_DATA_DIR:-/app/data}"
LOG_DIR="$(dirname "${LOG_FILE:-/app/data/autoclip.log}")"

log() { printf '[autoclip-entrypoint] %s\n' "$*"; }

if [ "$(id -u)" = "0" ]; then
  mkdir -p "$DATA_DIR" "$DATA_DIR/projects" "$DATA_DIR/uploads" "$DATA_DIR/temp" "$DATA_DIR/output" "$LOG_DIR"
  # -R 只在一次修复上花时间；之后的部署目录归属已经正确，chown 是幂等的。
  chown -R autoclip:autoclip "$DATA_DIR" "$LOG_DIR" 2>/dev/null || true
  log "数据目录 $DATA_DIR 归属已交给 autoclip（uid 10001）"
  # 用数字 uid/gid 降权：不依赖容器内 /etc/passwd 的名字解析，行为更可预测。
  exec setpriv --reuid=10001 --regid=10001 --init-groups --no-new-privs \
    autoclip-start "$@"
fi

# 已经以非 root 启动（本地 docker run --user 等）：不降权，直接跑。
exec autoclip-start "$@"
