#!/usr/bin/env python3
# pyright: reportAny=false
"""
tfgraph-agent —— Terraform 执行机端 Agent

子命令：
    ping                       联通性检测
    init   --name              注册/更新会话（不上传图）
    graph  --name [--no-init]  执行 terraform graph 并上传 DOT
    shell                      进入终端镜像 sub-shell（推荐）：所有终端输出自动上报
    watch  -- <command...>     包裹执行命令，实时上传 stdout/stderr
    tail   <log_file>          tail 一个日志文件，实时上传新增行
    upload-log <log_file>      整体上传一个日志文件

环境变量：
    TFGRAPH_SERVER     在线系统地址，例如 http://10.0.0.1:8000
    TFGRAPH_SESSION    会话 ID（不指定则按 name 自动派生）
    TFGRAPH_NAME       默认会话名（cwd basename）

类型说明：
    本文件用文件头 `# pyright: reportAny=false` 关闭 `reportAny` 规则，
    因为 `argparse.Namespace` 的属性在静态类型上就是 Any（动态属性容器），
    即使局部 cast 也会被 basedpyright 持续标记，属于已知的"argparse +
    strict 模式"误报。其它类型规则（reportExplicitAny / reportUnused* /
    reportMissingParameterType 等）继续生效。
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import queue
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path
from typing import IO, Callable, cast
from urllib import request as urlreq
from urllib import error as urlerr

DEFAULT_SERVER = os.environ.get("TFGRAPH_SERVER", "http://127.0.0.1:8000")
DEFAULT_TIMEOUT = 10
BATCH_INTERVAL = 0.5
BATCH_MAX_LINES = 50

# 注：JSON 数据结构因接口而异，统一用 `dict[str, object]` 表达"键是字符串、
# 值是任意 Python 对象"。相对 `Any`，`object` 是有边界的顶层类型——调用方
# 取出值时需要 isinstance 或 cast 才能使用，避免类型检查被静默跳过。

# ---------------- HTTP（标准库，避免额外依赖） ----------------

def _http(method: str, url: str,
          payload: dict[str, object] | None = None,
          timeout: int = DEFAULT_TIMEOUT) -> dict[str, object]:
    data: bytes | None = None
    headers: dict[str, str] = {"Accept": "application/json"}
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urlreq.Request(url, data=data, headers=headers, method=method)
    with urlreq.urlopen(req, timeout=timeout) as resp:
        # urllib/json 标准库返回 Any，本处用 cast 收敛到具体类型
        body: str = cast(bytes, resp.read()).decode("utf-8")
        if not body:
            return {}
        try:
            parsed = cast(object, json.loads(body))
        except json.JSONDecodeError:
            return {"raw": body}
        if isinstance(parsed, dict):
            return cast("dict[str, object]", parsed)
        # 服务端理论上始终返回 JSON 对象；非对象时降级为 raw
        return {"raw": parsed}


def http_get(server: str, path: str) -> dict[str, object]:
    return _http("GET", server.rstrip("/") + path)


def http_post(server: str, path: str, payload: dict[str, object]) -> dict[str, object]:
    return _http("POST", server.rstrip("/") + path, payload)


# ---------------- 工具 ----------------

def derive_sid(_name: str = "") -> str:
    """根据 hostname + 当前工作目录派生稳定 session id。
    同一台机器同一个目录永远是同一会话，避免重名导致的重复创建。

    `_name` 形参出于历史兼容保留（当前实现不使用，但调用方仍按位置传入）。
    """
    hostname = socket.gethostname()
    raw = f"{hostname}::{Path.cwd()}".encode("utf-8")
    return hashlib.md5(raw).hexdigest()[:12]


def info(msg: str) -> None:
    print(f"[tfgraph] {msg}", file=sys.stderr, flush=True)


def err(msg: str) -> None:
    print(f"[tfgraph][ERROR] {msg}", file=sys.stderr, flush=True)


# ---------------- 子命令 ----------------

def cmd_ping(args: argparse.Namespace) -> int:
    # 优先级：位置参数 address > --server > $TFGRAPH_SERVER
    server: str = (getattr(args, "address", None) or args.server).rstrip("/")
    info(f"检测在线系统连通性： {server}")
    t0 = time.time()
    try:
        r = http_get(server, "/api/ping")
        dt = (time.time() - t0) * 1000
        info(f"OK  service={r.get('service')} version={r.get('version')} latency={dt:.0f}ms")
        return 0
    except urlerr.URLError as e:
        err(f"连接失败：{e.reason}")
        return 2
    except Exception as e:
        err(f"未知错误：{e}")
        return 2


def ensure_session(server: str, name: str, sid: str | None) -> str:
    """注册或更新会话，返回 sid。"""
    sid = sid or os.environ.get("TFGRAPH_SESSION") or derive_sid(name)
    payload: dict[str, object] = {
        "id": sid,
        "name": name,
        "hostname": socket.gethostname(),
        "workdir": str(Path.cwd()),
    }
    r = http_post(server, "/api/sessions", payload)
    info(f"会话已注册：sid={r.get('id', sid)}  name={r.get('name', name)}")
    # 服务端返回的 id 一定是字符串；object 取出后用 str() 收敛类型
    return str(r.get("id", sid))


def cmd_init(args: argparse.Namespace) -> int:
    name: str = args.name or Path.cwd().name
    try:
        sid = ensure_session(args.server, name, args.sid)
        print(sid)
        return 0
    except Exception as e:
        err(f"注册会话失败：{e}")
        return 2


def cmd_logout(args: argparse.Namespace) -> int:
    """注销当前会话：停止本地 daemon + 清理状态文件 + 删除服务端会话数据。"""
    server: str = args.server
    sid = args.sid or os.environ.get("TFGRAPH_SESSION") or derive_sid()
    home_dir = Path(os.environ.get("TFGRAPH_HOME", str(Path.home() / ".tfgraph")))
    daemon_pid_file = home_dir / "daemon.pid"

    # 1) 停止本地 daemon
    if daemon_pid_file.exists():
        try:
            pid = int(daemon_pid_file.read_text().strip())
            import signal as _signal
            os.kill(pid, _signal.SIGTERM)
            info(f"已停止后台守护 pid={pid}")
        except Exception:
            pass
        try:
            daemon_pid_file.unlink()
        except OSError:
            pass

    # 2) 清理本地 offset 状态文件
    state_dir = home_dir / "state"
    if state_dir.exists():
        for f in state_dir.glob(f"{sid}.*"):
            try:
                f.unlink()
            except OSError:
                pass
        info("已清理本地状态文件")

    # 3) 向服务端发 DELETE 删除会话
    info(f"注销会话 sid={sid} ...")
    try:
        _ = _http("DELETE", server.rstrip("/") + f"/api/sessions/{sid}")
        info("会话已注销，服务端数据已删除")
    except Exception as e:
        err(f"注销失败（服务端可能已无该会话）：{e}")
        return 2

    info("若要重新注册，执行：tfgraph-agent init")
    return 0


def cmd_graph(args: argparse.Namespace) -> int:
    name: str = args.name or Path.cwd().name
    server: str = args.server

    try:
        sid = ensure_session(server, name, args.sid)
    except Exception as e:
        err(f"注册会话失败：{e}")
        return 2

    # 自动开启 terraform 调试日志（仅为本子进程注入；用户已设置则尊重）
    tf_log = os.environ.get("TF_LOG") or "DEBUG"
    tf_log_path = os.environ.get("TF_LOG_PATH") or str(Path.cwd() / "terraform.log")
    sub_env = os.environ.copy()
    sub_env["TF_LOG"] = tf_log
    sub_env["TF_LOG_PATH"] = tf_log_path
    info(f"开启 terraform 日志：TF_LOG={tf_log}  TF_LOG_PATH={tf_log_path}")

    info("执行 terraform graph ...")
    try:
        proc = subprocess.run(
            ["terraform", "graph"] + (["-type=plan"] if args.type == "plan" else []),
            capture_output=True, text=True, timeout=120, env=sub_env,
        )
    except FileNotFoundError:
        err("未找到 terraform 可执行文件，请先安装。")
        return 2
    except subprocess.TimeoutExpired:
        err("terraform graph 执行超时。")
        return 2

    if proc.returncode != 0:
        err(f"terraform graph 失败 (exit={proc.returncode})：\n{proc.stderr.strip()}")
        return proc.returncode

    dot = proc.stdout
    if not dot.strip():
        err("terraform graph 输出为空。")
        return 2

    info(f"上传 DOT，长度 {len(dot)} 字符 ...")
    try:
        r = http_post(server, f"/api/sessions/{sid}/graph", {"dot": dot})
        info(f"OK  nodes={r.get('nodes')} edges={r.get('edges')}")
        info(f"打开浏览器查看： {server}")
        log_file = Path(tf_log_path)
        if log_file.exists() and log_file.stat().st_size > 0:
            info(f"调试日志已写入：{log_file}（可用：tfgraph-agent tail {log_file} 上报）")
        return 0
    except Exception as e:
        err(f"上传失败：{e}")
        return 2


# ---------- 日志上报：异步批量发送 ----------

class LogShipper:
    # 显式声明实例属性类型，便于外部调用方与 IDE 提示
    server: str
    sid: str
    q: queue.Queue[dict[str, object]]
    stop_evt: threading.Event
    thr: threading.Thread

    def __init__(self, server: str, sid: str) -> None:
        self.server = server
        self.sid = sid
        self.q = queue.Queue()
        self.stop_evt = threading.Event()
        self.thr = threading.Thread(target=self._run, daemon=True)
        self.thr.start()

    def push(self, stream: str, line: str) -> None:
        self.q.put({"stream": stream, "line": line})

    def close(self) -> None:
        self.stop_evt.set()
        self.thr.join(timeout=5)

    def _run(self) -> None:
        url_path = f"/api/sessions/{self.sid}/logs"
        buf: list[dict[str, object]] = []
        last_flush = time.time()
        while not (self.stop_evt.is_set() and self.q.empty() and not buf):
            try:
                item = self.q.get(timeout=BATCH_INTERVAL)
                buf.append(item)
            except queue.Empty:
                pass

            now = time.time()
            if buf and (len(buf) >= BATCH_MAX_LINES or now - last_flush >= BATCH_INTERVAL):
                self._flush(url_path, buf)
                buf = []
                last_flush = now

        if buf:
            self._flush(url_path, buf)

    def _flush(self, url_path: str, lines: list[dict[str, object]]) -> None:
        try:
            _ = http_post(self.server, url_path, {"lines": lines})
        except Exception as e:
            err(f"日志上报失败（保留本地输出）：{e}")


def cmd_watch(args: argparse.Namespace) -> int:
    name: str = args.name or Path.cwd().name
    server: str = args.server
    cmd_argv: list[str] = list(args.shell_cmd or [])
    if cmd_argv and cmd_argv[0] == "--":
        cmd_argv = cmd_argv[1:]
    if not cmd_argv:
        err("用法： tfgraph-agent watch -- <command...>")
        return 2

    try:
        sid = ensure_session(server, name, args.sid)
    except Exception as e:
        err(f"注册会话失败：{e}")
        return 2

    shipper = LogShipper(server, sid)
    info(f"开始执行并监控： {' '.join(cmd_argv)}")

    # Windows 不支持 pty，退化到管道模式
    if platform.system() == "Windows":
        return _watch_pipe(cmd_argv, sid, shipper)

    # Unix：用 pty 伪终端包裹子进程——子进程保留 tty，可以正常交互输入；
    # 父进程读取 pty master 端获得输出，同步显示并上报。
    try:
        import pty as _pty
        import fcntl as _fcntl
        import termios as _termios
    except ImportError:
        return _watch_pipe(cmd_argv, sid, shipper)

    master_fd, slave_fd = _pty.openpty()

    # 继承当前终端的窗口尺寸（避免子进程渲染错位）
    try:
        import struct
        ts = _termios.tcgetattr(sys.stdin.fileno())
        import fcntl
        win_size = fcntl.ioctl(sys.stdin.fileno(), _termios.TIOCGWINSZ, b'\x00' * 8)
        fcntl.ioctl(master_fd, _termios.TIOCSWINSZ, win_size)
    except Exception:
        pass

    try:
        proc = subprocess.Popen(
            cmd_argv,
            stdin=slave_fd,
            stdout=slave_fd,
            stderr=slave_fd,
            close_fds=True,
        )
    except FileNotFoundError as e:
        os.close(master_fd); os.close(slave_fd)
        err(str(e))
        shipper.close()
        return 2

    os.close(slave_fd)  # 父进程不需要 slave 端

    buf = b""
    rc = 0
    try:
        while True:
            try:
                chunk = os.read(master_fd, 4096)
            except OSError:
                break  # 子进程退出，master 端 EOF
            if not chunk:
                break
            # 同步输出到当前终端
            sys.stdout.buffer.write(chunk)
            sys.stdout.buffer.flush()
            # 按行切割上报
            buf += chunk
            while b"\n" in buf:
                line_b, buf = buf.split(b"\n", 1)
                line = _ANSI_RE.sub("", line_b.decode("utf-8", errors="replace")).rstrip("\r")
                if line:
                    shipper.push("stdout", line)
    except KeyboardInterrupt:
        proc.terminate()
        rc = 130
    finally:
        os.close(master_fd)

    if rc == 0:
        rc = proc.wait()
    # 上报最后一行（没有 \n 的尾部）
    if buf:
        line = _ANSI_RE.sub("", buf.decode("utf-8", errors="replace")).rstrip("\r\n")
        if line:
            shipper.push("stdout", line)

    shipper.push("event", f"--- 命令结束，退出码 {rc} ---")
    shipper.close()
    info(f"完成，退出码 {rc}")
    return rc


def _watch_pipe(cmd_argv: list[str], sid: str, shipper: "LogShipper") -> int:
    """退化的管道模式（Windows 或无 pty 时）：子进程 stdout/stderr 被接管，不能交互。"""
    info("[WARN] 当前环境不支持 pty，退化为管道模式（交互输入不可用）")
    try:
        proc = subprocess.Popen(
            cmd_argv,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
    except FileNotFoundError as e:
        err(str(e))
        shipper.close()
        return 2

    def pump(fp: IO[str], stream: str, mirror: IO[str]) -> None:
        for line in iter(fp.readline, ""):
            line = line.rstrip("\r\n")
            if not line:
                continue
            _ = mirror.write(line + "\n")
            mirror.flush()
            shipper.push(stream, line)
        fp.close()

    t1 = threading.Thread(target=pump, args=(cast("IO[str]", proc.stdout), "stdout", sys.stdout), daemon=True)
    t2 = threading.Thread(target=pump, args=(cast("IO[str]", proc.stderr), "stderr", sys.stderr), daemon=True)
    t1.start(); t2.start()

    rc = proc.wait()
    t1.join(); t2.join()
    shipper.push("event", f"--- 命令结束，退出码 {rc} ---")
    shipper.close()
    info(f"完成，退出码 {rc}")
    return rc


def cmd_tail(args: argparse.Namespace) -> int:
    name: str = args.name or Path.cwd().name
    server: str = args.server
    log_file = Path(args.log_file).expanduser().resolve()

    if not log_file.exists():
        err(f"日志文件不存在： {log_file}")
        return 2

    try:
        sid = ensure_session(server, name, args.sid)
    except Exception as e:
        err(f"注册会话失败：{e}")
        return 2

    shipper = LogShipper(server, sid)
    info(f"开始 tail： {log_file}")

    try:
        with open(log_file, "r", encoding="utf-8", errors="replace") as f:
            if not args.from_start:
                _ = f.seek(0, os.SEEK_END)
            while True:
                line = f.readline()
                if not line:
                    time.sleep(0.5)
                    continue
                line = line.rstrip("\r\n")
                if line:
                    _ = sys.stdout.write(line + "\n")
                    _ = sys.stdout.flush()
                    shipper.push("file", line)
    except KeyboardInterrupt:
        info("已停止 tail")
        return 0
    finally:
        shipper.close()


# ANSI 转义序列正则：剥除颜色/光标控制字符，避免污染上报内容
_ANSI_RE = re.compile(r"\x1B\[[0-9;]*[mGKHfJ]")
# `script` 工具自身的开场/结束标记行
_SCRIPT_MARK_RE = re.compile(r"^Script (started|done)")


def cmd_shell(args: argparse.Namespace) -> int:
    """进入终端镜像 sub-shell：用 `script` 把整个 sub-shell 的输入输出录到临时
    文件，再起一条 tail 协程把新增内容清洗后批量上报。用户在 sub-shell 里
    像往常一样敲命令即可（无需 `tfgraph-agent watch -- ...` 包裹）。
    """
    if platform.system() == "Windows":
        err("Windows 请使用 tfgraph-agent.ps1 shell（PowerShell 版）")
        return 2
    if shutil.which("script") is None:
        err("未找到 `script` 命令，无法启动终端镜像")
        return 2

    name: str = args.name or Path.cwd().name
    server: str = args.server
    try:
        sid = ensure_session(server, name, args.sid)
    except Exception as e:
        err(f"注册会话失败：{e}")
        return 2

    # 镜像文件：sub-shell 的所有输出都会被 `script` 写入这里
    fd, mirror_path = tempfile.mkstemp(prefix="tfgraph-shell.", suffix=".log")
    os.close(fd)
    mirror = Path(mirror_path)

    info(f"启动终端镜像：所有命令输出都会被上报到 {server}")
    info("退出 sub-shell（exit / Ctrl-D）即停止录制")
    info(f"镜像文件：{mirror}")
    print()

    shipper = LogShipper(server, sid)
    stop_evt = threading.Event()

    def reporter() -> None:
        """tail 镜像文件 -> 清洗 ANSI/script 标记 -> 异步上报。"""
        # 等 `script` 把头部写完，避免立刻读到空文件
        time.sleep(0.3)
        try:
            with open(mirror, "r", encoding="utf-8", errors="replace") as f:
                while not stop_evt.is_set():
                    line = f.readline()
                    if not line:
                        time.sleep(0.1)
                        continue
                    clean = _ANSI_RE.sub("", line).rstrip("\r\n")
                    if not clean or _SCRIPT_MARK_RE.match(clean):
                        continue
                    shipper.push("stdout", clean)
        except FileNotFoundError:
            pass

    rep_thr = threading.Thread(target=reporter, daemon=True)
    rep_thr.start()

    # 选择平台对应的 script 调用方式
    user_shell = os.environ.get("SHELL", "/bin/bash")
    env = os.environ.copy()
    env["TFGRAPH_IN_SHELL"] = "1"
    if platform.system() == "Darwin":
        # macOS/BSD：script -q <file> <command...>
        cmd: list[str] = ["script", "-q", str(mirror), user_shell, "-i"]
    else:
        # Linux util-linux：script -q -f <file> -c <command>
        cmd = ["script", "-q", "-f", "-c", f"{user_shell} -i", str(mirror)]

    try:
        rc = subprocess.call(cmd, env=env)
    except KeyboardInterrupt:
        rc = 130

    # 收尾：sub-shell 退出后 `script` 会把残留 buffer flush 到 mirror，
    # 这里等一小段时间让 reporter 把尾部内容读完再停。
    time.sleep(1.0)
    stop_evt.set()
    rep_thr.join(timeout=2)
    shipper.close()
    try:
        mirror.unlink()
    except OSError:
        pass
    info("已退出终端镜像")
    return rc


def cmd_upload_log(args: argparse.Namespace) -> int:
    name: str = args.name or Path.cwd().name
    server: str = args.server
    log_file = Path(args.log_file).expanduser().resolve()

    if not log_file.exists():
        err(f"日志文件不存在： {log_file}")
        return 2

    try:
        sid = ensure_session(server, name, args.sid)
    except Exception as e:
        err(f"注册会话失败：{e}")
        return 2

    info(f"上传 {log_file} ...")
    lines: list[dict[str, object]] = []
    with open(log_file, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.rstrip("\r\n")
            if line:
                lines.append({"stream": "file", "line": line})

    # 分片上传
    sent = 0
    for i in range(0, len(lines), 200):
        chunk = lines[i:i + 200]
        try:
            _ = http_post(server, f"/api/sessions/{sid}/logs", {"lines": chunk})
            sent += len(chunk)
            info(f"  已上传 {sent}/{len(lines)} 行")
        except Exception as e:
            err(f"上传失败： {e}")
            return 2
    info("完成")
    return 0


# ---------------- CLI ----------------

def build_parser() -> argparse.ArgumentParser:
    # 公共可选参数：让它们出现在每个子命令上（在子命令前/后都能写）
    # 注意：default=SUPPRESS 让"未提供时"不写入 namespace，避免子命令覆盖主命令的值
    common = argparse.ArgumentParser(add_help=False)
    _ = common.add_argument("--server", default=argparse.SUPPRESS,
                            help="在线系统地址，默认取 $TFGRAPH_SERVER")
    _ = common.add_argument("--name", default=argparse.SUPPRESS,
                            help="会话名，默认取当前目录名")
    _ = common.add_argument("--sid", default=argparse.SUPPRESS,
                            help="指定会话 ID（默认按 hostname+name 自动派生）")

    p = argparse.ArgumentParser(
        prog="tfgraph-agent",
        description="Terraform Graph 在线系统的执行机 Agent",
        parents=[common],
    )

    # required=False：无参数时由 main() 输出完整 help（argparse 默认只打印
    # 简短 usage 并报错，体验不友好）。
    sub = p.add_subparsers(dest="subcmd", required=False)

    ping_p = sub.add_parser("ping", help="联通性检测", parents=[common])
    _ = ping_p.add_argument(
        "address", nargs="?", default=None,
        help="（可选）直接传入服务器地址，例如 http://aa6.ai:8000；"
             "未提供时回退到 --server 或 $TFGRAPH_SERVER",
    )

    _ = sub.add_parser("init", help="注册/更新会话", parents=[common])

    _ = sub.add_parser("logout", help="注销当前会话（停止 daemon + 删除服务端数据）", parents=[common])

    pg = sub.add_parser("graph", help="执行 terraform graph 并上传", parents=[common])
    _ = pg.add_argument("--type", choices=["plan", "apply"], default="plan",
                        help="terraform graph -type，默认 plan")

    pw = sub.add_parser("watch", help="包裹执行命令，实时上报输出（已知命令时使用）", parents=[common])
    _ = pw.add_argument("shell_cmd", nargs=argparse.REMAINDER, help="要执行的命令（用 -- 分隔）")

    _ = sub.add_parser(
        "shell",
        help="进入终端镜像 sub-shell：所有终端输出自动上报【推荐】",
        parents=[common],
    )

    pt = sub.add_parser("tail", help="tail 日志文件并实时上报", parents=[common])
    _ = pt.add_argument("log_file", help="日志文件路径")
    _ = pt.add_argument("--from-start", action="store_true", help="从文件开头读")

    pu = sub.add_parser("upload-log", help="整体上传日志文件", parents=[common])
    _ = pu.add_argument("log_file", help="日志文件路径")

    return p


# 子命令分发表：subcmd 名 -> 处理函数
_DISPATCH: dict[str, Callable[[argparse.Namespace], int]] = {
    "ping": cmd_ping,
    "init": cmd_init,
    "logout": cmd_logout,
    "graph": cmd_graph,
    "watch": cmd_watch,
    "shell": cmd_shell,
    "tail": cmd_tail,
    "upload-log": cmd_upload_log,
}


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    # 公共参数用了 SUPPRESS，未提供时 namespace 上没有该属性；这里补上默认值
    if not hasattr(args, "server"): args.server = DEFAULT_SERVER
    if not hasattr(args, "name"):   args.name   = os.environ.get("TFGRAPH_NAME")
    if not hasattr(args, "sid"):    args.sid    = None
    subcmd: str | None = cast("str | None", getattr(args, "subcmd", None))
    if not subcmd:
        # 无子命令：打印完整 help，方便用户上手
        parser.print_help()
        return 0
    fn = _DISPATCH.get(subcmd)
    if not fn:
        print(f"未知子命令：{subcmd}", file=sys.stderr)
        return 2
    return fn(args)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
