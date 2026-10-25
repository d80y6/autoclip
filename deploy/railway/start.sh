#!/usr/bin/env bash
# Railway 容器内真正的启动脚本（已降权到 autoclip 后执行）。
#
#   CMD/first arg = api   → 只跑 FastAPI（默认）
#   任何其他参数        → 原样执行（方便 `railway run` 排查，如 `bash`）
#
# AUTOCLIP_RUN_WORKER=true 时同时拉起 Celery worker：Railway 的 Volume 只能挂在一个服务上，
# 而 SQLite 数据库和切片文件都在这个 Volume 里，所以 API 和 worker 必须待在同一个容器里
# 共享 /app/data，不能拆成两个服务。
set -euo pipefail

APP_DIR=/app
DATA_DIR="${AUTOCLIP_DATA_DIR:-/app/data}"
PORT="${PORT:-8000}"

cd "$APP_DIR"
export PYTHONPATH="$APP_DIR" PYTHONUNBUFFERED=1

log() { printf '[autoclip] %s\n' "$*"; }

# 1) 数据库表结构（与 docker-entrypoint.sh 同一套初始化逻辑）
python init_database.py

# 2) Redis 是 Celery 的 broker，没有它项目会永远卡在“排队中”。给 Railway 插件一点启动余量。
redis_ready=false
for attempt in $(seq 1 15); do
  if python - <<'PY'
import os
import sys

import redis

try:
    redis.Redis.from_url(
        os.getenv('REDIS_URL', 'redis://localhost:6379/0'),
        socket_connect_timeout=3,
        socket_timeout=3,
    ).ping()
except Exception as error:  # noqa: BLE001
    print(f'Redis unavailable ({type(error).__name__})', file=sys.stderr)
    sys.exit(1)
PY
  then
    redis_ready=true
    log "Redis 连接成功"
    break
  fi
  log "等待 Redis（第 ${attempt}/15 次）…"
  sleep 4
done

if [ "$redis_ready" != "true" ]; then
  log "Redis 不可用：请在本项目里添加 Redis 服务，并把 REDIS_URL 注入到本服务（Railway 变量引用 \${{Redis.REDIS_URL}}）。"
  exit 1
fi

if [ "${AUTOCLIP_RUN_WORKER:-false}" = "true" ]; then
  log "启动 Celery worker（队列 celery,processing,video,notification,upload）"
  # 单容器共享 Volume，所以并发压到 1：一个视频任务本身就吃满 CPU，SQLite 也怕多写。
  celery -A backend.core.celery_app worker \
    --loglevel="${CELERY_LOG_LEVEL:-INFO}" \
    --concurrency="${CELERY_CONCURRENCY:-1}" \
    -Q celery,processing,video,notification,upload \
    --without-gossip --without-mingle \
    >&2 &
  WORKER_PID=$!
  trap 'kill -TERM "$WORKER_PID" 2>/dev/null || true' TERM INT
else
  log "AUTOCLIP_RUN_WORKER 未开启：本容器只跑 API，视频任务不会被消费（排队中）"
fi

case "${1:-api}" in
  api)
    log "启动 FastAPI：0.0.0.0:${PORT}"
    # --proxy-headers：Railway 在容器前面做 TLS 终止，靠 X-Forwarded-* 还原 https 与真实客户端 IP。
    exec python -m uvicorn backend.main:app \
      --host 0.0.0.0 \
      --port "$PORT" \
      --proxy-headers \
      --forwarded-allow-ips='*' \
      --timeout-keep-alive 75
    ;;
  *)
    exec "$@"
    ;;
esac
