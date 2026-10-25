"""可选的前端静态资源挂载。

默认情况下 AutoClip 的后端只提供 API：桌面端由 Tauri 加载前端，Docker/Cloudflare 方案里前端
由独立的静态托管提供。但如果希望「前后端同一个容器」（例如全部部署在 Railway），可以设置
``AUTOCLIP_SERVE_FRONTEND_DIR`` 指向 ``npm run build`` 的产物（需要 index.html），
由后端在根路径把这些文件发出去。

路由顺序很重要：调用方必须在注册完 ``/api/*`` 与 ``/health`` 之后才调用 :func:`mount_frontend`，
否则挂到 ``/`` 的静态资源会先匹配，API 被吞掉。
"""
from __future__ import annotations

import logging
import os
from pathlib import Path

from fastapi import FastAPI

logger = logging.getLogger(__name__)

ENV_VAR = "AUTOCLIP_SERVE_FRONTEND_DIR"


def resolve_frontend_dir(directory: str | os.PathLike[str] | None) -> Path | None:
    """把配置值解析成可用的构建目录；没有 index.html 时返回 None。"""
    raw = str(directory or "").strip()
    if not raw:
        return None
    dist = Path(raw).expanduser()
    if not (dist / "index.html").is_file():
        return None
    return dist


def mount_frontend(app: FastAPI, directory: str | os.PathLike[str] | None = None) -> bool:
    """按需把前端构建产物挂到 ``/``，返回是否真的挂载了。

    ``directory`` 省略时读取环境变量 ``AUTOCLIP_SERVE_FRONTEND_DIR``。
    """
    configured = directory if directory is not None else os.getenv(ENV_VAR, "")
    target = resolve_frontend_dir(configured)
    if target is None:
        if str(configured or "").strip():
            logger.warning("%s 指向的目录里没有 index.html，跳过前端静态资源挂载", configured)
        return False

    from fastapi.staticfiles import StaticFiles

    app.mount("/", StaticFiles(directory=str(target), html=True), name="frontend")
    logger.info("已挂载前端静态资源: %s", target)
    return True
