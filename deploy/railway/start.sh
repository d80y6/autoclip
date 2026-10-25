#!/usr/bin/env bash
# Railway 容器内真正的启动脚本（已降权到 autoclip 后执行）。
#
#   CMD/first arg = api  → 跑 FastAPI（默认），并按 AUTOCLIP_RUN_WORKER 决定是否同容器跑 Celery
#   其他参数             → 原样执行（排查用，例如 `railway run -- bash`）
#
# 为什么要在一个容器里跑 API + worker：
#   Railway 的 Volume 只能挂在一个服务上，而 SQLite 数据库、切片与导出文件都在 /app/data。
#   拆成两个服务就必须把存储改成 Postgres + 对象存储，超出「一次部署」的范围。
set -euo pipefail

APP_DIR=/app
DATA_DIR="${AUTOCLIP_DATA_DIR:-/app/data}"
PORT="${PORT:-8000}"
SERVE_DIR="${AUTOCLIP_SERVE_FRONTEND_DIR:-}"

cd "$APP_DIR"
export PYTHONPATH="$APP_DIR" PYTHONUNBUFFERED=1

log() { printf '[autoclip] %s\n' "$*"; }

API_PID=""
WORKER_PID=""

# 有限等待：进程收到 TERM 后 20 秒内没退就 KILL，避免容器卡在 draining 里被平台强杀。
wait_or_kill() {
  local pid="$1" name="$2"
  [ -n "$pid" ] || return 0
  local waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge 20 ]; then
      log "$name 未在 20 秒内退出，强制结束"
      kill -KILL "$pid" 2>/dev/null || true
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  return 0
}

cleanup() {
  trap - TERM INT
  if [ -n "$WORKER_PID" ] && kill -0 "$WORKER_PID" 2>/dev/null; then
    log "停止 Celery worker"
    kill -TERM "$WORKER_PID" 2>/dev/null || true
  fi
  if [ -n "$API_PID" ] && kill -0 "$API_PID" 2>/dev/null; then
    log "停止 API"
    kill -TERM "$API_PID" 2>/dev/null || true
  fi
  wait_or_kill "$API_PID" "API"
  wait_or_kill "$WORKER_PID" "Celery worker"
  wait 2>/dev/null || true
}
trap 'log "收到停止信号"; cleanup; exit 0' TERM INT

# 1) 数据库表结构（与 docker-entrypoint.sh 同一套初始化逻辑）
python init_database.py

# 2) Redis 是 Celery 的 broker，也是进度/队列状态的后端。没有它项目会永远卡在「排队中」。
#    给 Railway 的 Redis 插件一点启动余量（首次部署时两边同时起来）。
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

# 3) Celery worker（可选，默认开启；单容器共享 Volume，所以并发保持 1）
if [ "${AUTOCLIP_RUN_WORKER:-true}" = "true" ]; then
  log "启动 Celery worker（队列 celery,processing,video,notification,upload）"
  celery -A backend.core.celery_app worker \
    --loglevel="${CELERY_LOG_LEVEL:-INFO}" \
    --concurrency="${CELERY_CONCURRENCY:-1}" \
    -Q celery,processing,video,notification,upload \
    --without-gossip --without-mingle &
  WORKER_PID=$!
else
  log "AUTOCLIP_RUN_WORKER=false：本容器只跑 API，视频任务将一直停留在排队中"
fi

case "${1:-api}" in
  api)
    if [ -n "$SERVE_DIR" ] && [ -f "$SERVE_DIR/index.html" ]; then
      log "同一域名提供前端：$SERVE_DIR"
    else
      log "未启用前端静态资源（AUTOCLIP_SERVE_FRONTEND_DIR=$SERVE_DIR），/ 只提供 API 文档 /docs"
    fi

    log "启动 FastAPI：0.0.0.0:${PORT}"
    # --proxy-headers：Railway 在容器前面做 TLS 终止，靠 X-Forwarded-* 还原 https 和真实客户端 IP。
    # 用后台进程 + wait 而不是 exec：这样收到 SIGTERM 时能把 worker 一起优雅关掉；
    # 任一进程退出就结束容器，交给 Railway 的 restart policy 拉起（不会出现「半个进程活着」）。
    python -m uvicorn backend.main:app \
      --host 0.0.0.0 \
      --port "$PORT" \
      --proxy-headers \
      --forwarded-allow-ips='*' \
      --timeout-keep-alive 75 &
    API_PID=$!

    if [ -n "$WORKER_PID" ]; then
      wait -n "$API_PID" "$WORKER_PID" || STATUS=$?
    else
      wait "$API_PID" || STATUS=$?
    fi
    STATUS="${STATUS:-0}"

    if ! kill -0 "$API_PID" 2>/dev/null; then
      log "API 已退出（status=$STATUS）"
    else
      log "Celery worker 已退出（status=$STATUS）；退出容器让 Railway 按重启策略拉起"
      [ "$STATUS" -eq 0 ] && STATUS=1
    fi

    cleanup
    exit "$STATUS"
    ;;
  *)
    exec "$@"
    ;;
esac
