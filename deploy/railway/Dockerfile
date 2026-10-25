# Railway 部署镜像：只构建后端（前端发布在 Cloudflare）。
#
# 为什么不用根目录的 Dockerfile：
#   - 那个镜像会顺带构建前端（Railway 上白跑一遍 vite build），前端产物在这里没人用；
#   - 它以非 root 用户启动，而 Railway 的 Volume 是 root 挂载的，写不进去。
# 这里以 root 启动，entrypoint 先给 Volume 修权限再降权到 autoclip 运行（不需要 RAILWAY_RUN_UID=0）。
FROM python:3.11-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONPATH=/app

# ffmpeg/ffprobe 是切片与导出的硬依赖；util-linux 提供 setpriv（降权用）。
RUN apt-get update && apt-get install -y --no-install-recommends \
      ffmpeg \
      curl \
      util-linux \
      ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY backend/ ./backend/
COPY scripts/ ./scripts/
COPY init_database.py ./
COPY deploy/railway/entrypoint.sh /usr/local/bin/autoclip-entrypoint
COPY deploy/railway/start.sh /usr/local/bin/autoclip-start

RUN chmod +x /usr/local/bin/autoclip-entrypoint /usr/local/bin/autoclip-start \
    && groupadd -r --gid 10001 autoclip \
    && useradd -r --uid 10001 --gid autoclip --home-dir /app autoclip \
    && mkdir -p /app/data /app/logs \
    && chown -R autoclip:autoclip /app

# 数据目录走 Volume（挂载点与 AUTOCLIP_DATA_DIR 必须一致，Railway 上填 /app/data）。
# PostgreSQL/Redis 由 Railway 插件注入；Volume 只能挂一个服务，所以 SQLite 就放在这里。
ENV AUTOCLIP_DATA_DIR=/app/data \
    DATABASE_URL=sqlite:////app/data/autoclip.db \
    LOG_FILE=/app/data/autoclip.log \
    PORT=8000

EXPOSE 8000

ENTRYPOINT ["autoclip-entrypoint"]
CMD ["api"]
