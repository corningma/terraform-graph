"""
Terraform Graph Online —— 后端入口

API:
  POST /api/sessions                 创建/更新会话
  GET  /api/sessions                 列出会话
  GET  /api/sessions/{sid}           会话详情
  DELETE /api/sessions/{sid}         删除会话
  POST /api/sessions/{sid}/graph     上传 DOT
  GET  /api/sessions/{sid}/graph     获取图
  POST /api/sessions/{sid}/logs      追加日志（批量行）
  GET  /api/sessions/{sid}/logs      读取日志
  POST /api/sessions/{sid}/states/reset  重置资源状态
  GET  /api/ping                     联通性
  WS   /ws/{sid}                     实时事件推送

静态：
  GET /                  前端首页
  GET /install.sh        Agent 安装脚本

类型说明:
  本文件使用 `# pyright: ...` 文件头抑制少量"非关键"规则:
  - reportImplicitRelativeImport: server/ 目录被作为脚本运行入口
    (uvicorn app:app)，按"模块"加载更自然；显式相对导入反而失败。
  - reportImplicitStringConcatenation: 复杂正则按行拆写更可读。
  - reportUnusedCallResult: FastAPI 的 set/dict mutation 表达式语义清晰。
  - reportExplicitAny: WebSocket / SQLite / 第三方库返回值确实是 Any。
  - reportUnnecessaryCast: 静态推断有时已收紧，但保留 cast 注释更显式。
  - reportUnknownMemberType / reportUnknownVariableType: store 模块部分
    函数签名使用 list/dict 无泛型参数，调用处会被标 Unknown。
  其余规则继续生效。
"""
# pyright: reportImplicitRelativeImport=false
# pyright: reportImplicitStringConcatenation=false
# pyright: reportUnusedCallResult=false
# pyright: reportExplicitAny=false
# pyright: reportUnnecessaryCast=false
# pyright: reportUnknownMemberType=false
# pyright: reportUnknownVariableType=false
from __future__ import annotations

import asyncio
import re
import uuid
from pathlib import Path
from typing import Any, cast

from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

import store
# `parser` 是项目内业务模块（不是 stdlib 的 `parser`）。
# 因目录未声明为包，pyright 静态分析会误判该符号；运行时正常。
from parser import parse_dot  # pyright: ignore[reportAttributeAccessIssue]


BASE_DIR = Path(__file__).parent
STATIC_DIR = BASE_DIR / "static"
AGENT_DIR = BASE_DIR.parent / "agent"

# JSON 事件 / 通用字典
JsonDict = dict[str, Any]

app = FastAPI(title="Terraform Graph Online", version="1.0.0")
store.init_db()


# ---------------- WebSocket 管理 ----------------

class Hub:
    _conns: dict[str, set[WebSocket]]
    _lock: asyncio.Lock

    def __init__(self) -> None:
        self._conns = {}
        self._lock = asyncio.Lock()

    async def join(self, sid: str, ws: WebSocket) -> None:
        async with self._lock:
            bucket = self._conns.setdefault(sid, set())
            bucket.add(ws)

    async def leave(self, sid: str, ws: WebSocket) -> None:
        async with self._lock:
            if sid in self._conns:
                self._conns[sid].discard(ws)
                if not self._conns[sid]:
                    self._conns.pop(sid, None)

    async def broadcast(self, sid: str, event: JsonDict) -> None:
        async with self._lock:
            targets = list(self._conns.get(sid, set()))
        dead: list[WebSocket] = []
        for ws in targets:
            try:
                await ws.send_json(event)
            except Exception:
                dead.append(ws)
        if dead:
            async with self._lock:
                bucket = self._conns.get(sid)
                if bucket is not None:
                    for ws in dead:
                        bucket.discard(ws)


hub = Hub()


# ---------------- Pydantic 模型 ----------------

class SessionIn(BaseModel):
    id: str | None = None
    name: str = Field(min_length=1, max_length=128)
    hostname: str = ""
    workdir: str = ""


class GraphIn(BaseModel):
    dot: str


class LogLine(BaseModel):
    stream: str = "stdout"  # stdout / stderr / file
    line: str


class LogsIn(BaseModel):
    lines: list[LogLine]


# ---------------- Terraform 输出解析 ----------------

# 匹配类似：
#   aws_instance.web: Creating...
#   module.vpc.aws_subnet.public[0]: Creation complete after 5s [id=...]
#   aws_instance.web: Modifying... [id=i-xxx]
#   aws_instance.web: Destruction complete after 1s
#   aws_instance.web: Still creating... [10s elapsed]
#   aws_instance.web: Refreshing state... [id=i-xxx]
#   Error: ... on main.tf line 10, in resource "aws_instance" "web":
_LINE_RE = re.compile(
    r"""^
    (?P<addr>(?:module\.[^.\s]+\.)*(?:data\.)?[a-zA-Z][\w-]*\.[\w\-\[\]"]+):\s*
    (?P<phase>Creating|Creation\ complete|Modifying|Modifications\ complete|
              Destroying|Destruction\ complete|Still\ creating|Still\ modifying|
              Still\ destroying|Refreshing\ state|Reading|Read\ complete|
              Provisioning|Provisioning\ complete)
    (?P<rest>.*)$
    """,
    re.VERBOSE,
)

# Plan 摘要：  # aws_instance.web will be created
_PLAN_RE = re.compile(
    r"""^\s*\#\s*
    (?P<addr>(?:module\.[^.\s]+\.)*(?:data\.)?[a-zA-Z][\w-]*\.[\w\-\[\]"]+)
    \s+will\s+be\s+
    (?P<verb>created|destroyed|updated\ in-place|replaced|read\ during\ apply)
    """,
    re.VERBOSE,
)

_ERROR_LINE_RE = re.compile(
    r"""^Error:\s*(?P<msg>.+)$
        |with\s+(?P<addr>(?:module\.[^.\s]+\.)*[a-zA-Z][\w-]*\.[\w\-\[\]"]+)""",
    re.VERBOSE,
)


_PHASE_TO_STATUS: dict[str, tuple[str, str | None]] = {
    "Creating": ("creating", "create"),
    "Creation complete": ("created", "create"),
    "Modifying": ("modifying", "update"),
    "Modifications complete": ("modified", "update"),
    "Destroying": ("destroying", "destroy"),
    "Destruction complete": ("destroyed", "destroy"),
    "Still creating": ("creating", "create"),
    "Still modifying": ("modifying", "update"),
    "Still destroying": ("destroying", "destroy"),
    "Refreshing state": ("refreshing", None),
    "Reading": ("reading", "read"),
    "Read complete": ("read", "read"),
    "Provisioning": ("provisioning", None),
    "Provisioning complete": ("provisioned", None),
}

_PLAN_VERB_TO_STATUS: dict[str, tuple[str, str | None]] = {
    "created": ("planned-create", "create"),
    "destroyed": ("planned-destroy", "destroy"),
    "updated in-place": ("planned-update", "update"),
    "replaced": ("planned-replace", "replace"),
    "read during apply": ("planned-read", "read"),
}


def _normalize_addr(addr: str) -> str:
    """terraform graph 节点 id 与日志中的 addr 一致；去除多余空白。"""
    return addr.strip()


def parse_terraform_line(line: str) -> JsonDict | None:
    """从一行 terraform 输出中提取 (node_id, status, action, message)。"""
    line = line.rstrip("\r\n")
    if not line:
        return None

    m = _LINE_RE.match(line)
    if m:
        addr = _normalize_addr(m.group("addr"))
        phase = m.group("phase")
        status, action = _PHASE_TO_STATUS.get(phase, (phase.lower(), None))
        return {
            "node_id": addr,
            "status": status,
            "action": action,
            "message": phase + m.group("rest"),
        }

    m = _PLAN_RE.match(line)
    if m:
        addr = _normalize_addr(m.group("addr"))
        verb = m.group("verb")
        status, action = _PLAN_VERB_TO_STATUS.get(verb, ("planned", None))
        return {
            "node_id": addr,
            "status": status,
            "action": action,
            "message": f"will be {verb}",
        }

    return None


# ---------------- API ----------------

@app.get("/api/ping")
async def ping() -> JsonDict:
    return {"ok": True, "service": "terraform-graph-online", "version": app.version}


@app.post("/api/sessions")
async def create_session(payload: SessionIn) -> JsonDict | None:
    sid = payload.id or uuid.uuid4().hex[:12]
    store.upsert_session(sid, payload.name, payload.hostname, payload.workdir)
    sess = cast("JsonDict | None", store.get_session(sid))
    await hub.broadcast(sid, {"type": "session", "data": sess})
    return sess


@app.get("/api/sessions")
async def get_sessions() -> list[JsonDict]:
    return cast("list[JsonDict]", store.list_sessions())


@app.get("/api/sessions/{sid}")
async def get_session(sid: str) -> JsonDict:
    sess = cast("JsonDict | None", store.get_session(sid))
    if not sess:
        raise HTTPException(404, "session not found")
    return sess


@app.delete("/api/sessions/{sid}")
async def del_session(sid: str) -> JsonDict:
    store.delete_session(sid)
    return {"ok": True}


@app.post("/api/sessions/{sid}/graph")
async def upload_graph(sid: str, payload: GraphIn) -> JsonDict:
    if not store.get_session(sid):
        raise HTTPException(404, "session not found")
    parsed = cast("JsonDict", parse_dot(payload.dot))
    nodes = cast("list[JsonDict]", parsed.get("nodes", []))
    edges = cast("list[JsonDict]", parsed.get("edges", []))
    # 覆盖图的同时清空旧日志和资源状态，开始新一轮
    store.reset_states(sid)
    store.clear_logs(sid)
    store.save_graph(sid, nodes, edges, payload.dot)
    await hub.broadcast(sid, {"type": "graph", "data": parsed})
    await hub.broadcast(sid, {"type": "states_reset"})
    await hub.broadcast(sid, {"type": "logs_cleared"})
    return {"ok": True, "nodes": len(nodes), "edges": len(edges)}


@app.get("/api/sessions/{sid}/graph")
async def get_graph_api(sid: str) -> JsonDict:
    g = cast("JsonDict | None", store.get_graph(sid))
    if not g:
        raise HTTPException(404, "graph not found")
    states = cast("list[JsonDict]", store.list_states(sid))
    return {**g, "states": states}


@app.post("/api/sessions/{sid}/logs")
async def append_logs(sid: str, payload: LogsIn) -> JsonDict:
    if not store.get_session(sid):
        raise HTTPException(404, "session not found")

    log_events: list[JsonDict] = []
    state_events: list[JsonDict] = []

    for item in payload.lines:
        log_id = store.append_log(sid, item.stream, item.line)
        log_events.append({
            "id": log_id, "stream": item.stream, "line": item.line,
        })
        parsed = parse_terraform_line(item.line)
        if parsed:
            updated = cast(
                "JsonDict",
                store.update_state(
                    sid,
                    cast("str", parsed["node_id"]),
                    cast("str", parsed["status"]),
                    cast("str | None", parsed["action"]),
                    cast("str | None", parsed["message"]),
                ),
            )
            state_events.append(updated)

    if log_events:
        await hub.broadcast(sid, {"type": "logs", "data": log_events})
    for ev in state_events:
        await hub.broadcast(sid, {"type": "state", "data": ev})

    return {"ok": True, "logs": len(log_events), "states": len(state_events)}


@app.get("/api/sessions/{sid}/logs")
async def get_logs(sid: str, after_id: int = 0, limit: int = 500) -> list[JsonDict]:
    if not store.get_session(sid):
        raise HTTPException(404, "session not found")
    return cast("list[JsonDict]", store.list_logs(sid, limit=limit, after_id=after_id))


@app.post("/api/sessions/{sid}/states/reset")
async def reset_states(sid: str) -> JsonDict:
    store.reset_states(sid)
    await hub.broadcast(sid, {"type": "states_reset"})
    return {"ok": True}


# ---------------- WebSocket ----------------

@app.websocket("/ws/{sid}")
async def ws_endpoint(ws: WebSocket, sid: str) -> None:
    await ws.accept()
    await hub.join(sid, ws)
    try:
        # 推送一次当前快照
        g = cast("JsonDict | None", store.get_graph(sid))
        if g:
            await ws.send_json({
                "type": "graph",
                "data": {"nodes": g["nodes"], "edges": g["edges"]},
            })
        states = cast("list[JsonDict]", store.list_states(sid))
        if states:
            await ws.send_json({"type": "states_snapshot", "data": states})

        while True:
            # 客户端通常不发消息，这里仅作 keepalive
            try:
                msg = await asyncio.wait_for(ws.receive_text(), timeout=30)
                if msg == "ping":
                    await ws.send_text("pong")
            except asyncio.TimeoutError:
                await ws.send_json({"type": "heartbeat"})
    except WebSocketDisconnect:
        pass
    finally:
        await hub.leave(sid, ws)


# ---------------- 静态资源 ----------------

@app.get("/install.sh")
async def install_script() -> FileResponse:
    fp = AGENT_DIR / "install.sh"
    if not fp.exists():
        raise HTTPException(404)
    return FileResponse(fp, media_type="text/x-shellscript")


@app.get("/agent/tfgraph_agent.py")
async def agent_script() -> FileResponse:
    fp = AGENT_DIR / "tfgraph_agent.py"
    if not fp.exists():
        raise HTTPException(404)
    return FileResponse(fp, media_type="text/x-python")


@app.get("/agent/tfgraph-agent.sh")
async def agent_shell_script() -> FileResponse:
    fp = AGENT_DIR / "tfgraph-agent.sh"
    if not fp.exists():
        raise HTTPException(404)
    return FileResponse(fp, media_type="text/x-shellscript")


@app.get("/agent/tfgraph-agent.ps1")
async def agent_powershell_script() -> FileResponse:
    fp = AGENT_DIR / "tfgraph-agent.ps1"
    if not fp.exists():
        raise HTTPException(404)
    return FileResponse(fp, media_type="text/x-powershell")


@app.get("/agent/install.ps1")
async def agent_install_ps1() -> FileResponse:
    fp = AGENT_DIR / "install.ps1"
    if not fp.exists():
        raise HTTPException(404)
    return FileResponse(fp, media_type="text/x-powershell")


@app.get("/agent/requirements.txt")
async def agent_requirements() -> FileResponse:
    fp = AGENT_DIR / "requirements.txt"
    if not fp.exists():
        raise HTTPException(404)
    return FileResponse(fp, media_type="text/plain")


app.mount("/static", StaticFiles(directory=str(STATIC_DIR)), name="static")


@app.get("/")
async def index() -> FileResponse:
    resp = FileResponse(STATIC_DIR / "index.html")
    resp.headers["Cache-Control"] = "no-cache, no-store, must-revalidate"
    return resp


@app.get("/static/{path:path}")
async def static_no_cache(path: str) -> FileResponse:
    """覆盖 StaticFiles 的默认缓存策略，让浏览器每次取最新版本。
    主要针对 app.js / style.css 频繁迭代的场景。
    """
    fp = STATIC_DIR / path
    if not fp.exists() or not fp.is_file():
        raise HTTPException(404)
    resp = FileResponse(fp)
    resp.headers["Cache-Control"] = "no-cache, no-store, must-revalidate"
    return resp


@app.exception_handler(HTTPException)
async def http_exc(_: Any, exc: HTTPException) -> JSONResponse:
    return JSONResponse({"error": exc.detail}, status_code=exc.status_code)


if __name__ == "__main__":
    import uvicorn
    uvicorn.run("app:app", host="0.0.0.0", port=8000, reload=False)
