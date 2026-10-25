"""AUTOCLIP_SERVE_FRONTEND_DIR：用一个容器同时提供 API 与前端（全 Railway 部署方案）。

覆盖点：挂了静态资源之后 /api/* 仍然优先、缺 index.html 时不挂、环境变量入口生效。
"""
import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from backend.core.frontend_static import mount_frontend, resolve_frontend_dir


def _build_dist(tmp_path):
    (tmp_path / "index.html").write_text("<!doctype html><title>autoclip</title>", encoding="utf-8")
    assets = tmp_path / "assets"
    assets.mkdir()
    (assets / "app.js").write_text("console.log('hi')", encoding="utf-8")
    return tmp_path


def _api_only_app() -> FastAPI:
    app = FastAPI()

    @app.get("/api/v1/health/")
    def health():
        return {"status": "healthy"}

    @app.get("/health")
    def root_health():
        return {"status": "ok", "mode": "web"}

    return app


def test_mounts_assets_without_shadowing_api_routes(tmp_path):
    app = _api_only_app()
    assert mount_frontend(app, _build_dist(tmp_path)) is True

    client = TestClient(app)
    assert client.get("/api/v1/health/").json() == {"status": "healthy"}
    assert client.get("/health").json()["status"] == "ok"

    page = client.get("/")
    assert page.status_code == 200
    assert "autoclip" in page.text
    assert client.get("/assets/app.js").text == "console.log('hi')"


def test_skips_directory_without_index_html(tmp_path):
    app = _api_only_app()
    assert mount_frontend(app, tmp_path) is False

    client = TestClient(app)
    assert client.get("/").status_code == 404
    assert client.get("/api/v1/health/").status_code == 200


def test_reads_env_var_when_directory_omitted(tmp_path, monkeypatch):
    monkeypatch.setenv("AUTOCLIP_SERVE_FRONTEND_DIR", str(_build_dist(tmp_path)))
    app = _api_only_app()
    assert mount_frontend(app) is True
    assert TestClient(app).get("/").status_code == 200


@pytest.mark.parametrize("value", [None, "", "   "])
def test_disabled_by_default(monkeypatch, value):
    monkeypatch.delenv("AUTOCLIP_SERVE_FRONTEND_DIR", raising=False)
    assert resolve_frontend_dir(value) is None
    assert mount_frontend(_api_only_app()) is False
