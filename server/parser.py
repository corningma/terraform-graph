"""
DOT 解析器：将 `terraform graph` 输出解析为节点 / 边 列表。

支持两种标准格式：

1. 默认格式（terraform graph，无 -type）
   节点 id 直接是资源地址，行末带分号：
       "aws_instance.web" [label="aws_instance.web"];
       "aws_instance.web" -> "aws_vpc.main";

2. plan/apply 格式（terraform graph -type=plan 等）
   节点 id 带 [root] 前缀和 (expand)/(close)，无分号：
       "[root] aws_instance.web (expand)" [label = "aws_instance.web", shape = "box"]
       "[root] aws_instance.web (expand)" -> "[root] aws_vpc.main (expand)"
"""
from __future__ import annotations

import re
from dataclasses import dataclass, asdict
from typing import List, Dict, Any


# -------- 节点/边正则 --------
# 节点声明：`"id" [attrs]` 或 `"id" [attrs];`
# attrs 内容用 .* 宽松匹配（允许包含 ] 的 tooltip 等属性）
_NODE_RE = re.compile(r'^\s*"(?P<id>[^"]+)"\s*\[(?P<attrs>.*)\]\s*;?\s*$')

# 边：`"src" -> "dst"` （后面可能跟 [attrs] 或 ;，不强制匹配）
_EDGE_RE = re.compile(r'^\s*"(?P<src>[^"]+)"\s*->\s*"(?P<dst>[^"]+)"')

# label 属性提取
_LABEL_RE = re.compile(r'label\s*=\s*"([^"]+)"')

# 全局 node/graph/edge 属性行（不含具体节点）：`node [shape = rect]`
# 这类行里没有 "id" 开头，_NODE_RE 不会匹配，无需特殊处理


@dataclass
class GraphNode:
    id: str
    label: str
    type: str   # 资源类型，如 aws_instance
    name: str   # 资源名，如 web
    module: str # 模块路径，root / module.xxx


@dataclass
class GraphEdge:
    source: str
    target: str


def _normalize_id(raw_id: str) -> str:
    """统一两种格式的节点 id，得到纯资源地址。

    - plan 格式：`[root] aws_instance.web (expand)` → `aws_instance.web`
    - 默认格式：`aws_instance.web` → `aws_instance.web`（已经是干净地址）
    """
    s = raw_id.strip()
    # 去除 [root] 前缀（含可能的模块前缀 [root] module.xxx.）
    s = re.sub(r"^\[root\]\s*", "", s)
    # 去除 (expand) / (close) / (orphan) 等后缀
    s = re.sub(r"\s*\([^)]+\)\s*$", "", s)
    return s.strip()


def _classify(addr: str) -> tuple[str, str, str] | None:
    """根据资源地址判断 (module, type, name)，非资源节点返回 None。"""
    if not addr:
        return None

    # 模块前缀：module.vpc.aws_subnet.main
    module = "root"
    body = addr
    m = re.match(r"^(module\.[^.]+(?:\.module\.[^.]+)*)\.(.+)$", addr)
    if m:
        module = m.group(1)
        body = m.group(2)

    # data source：data.aws_ami.ubuntu
    if body.startswith("data."):
        rest = body[len("data."):]
        parts = rest.split(".", 1)
        if len(parts) == 2:
            return module, f"data.{parts[0]}", parts[1]
        return None

    # 过滤非资源节点
    if body.startswith(("provider[", "provider ", "var.", "output.",
                         "local.", "terraform_remote_state", "root")):
        return None
    # 裸 "root" 节点
    if body == "root":
        return None

    # 普通资源 type.name
    parts = body.split(".", 1)
    if len(parts) != 2:
        return None
    rtype, rname = parts
    # 过滤不像资源类型的内容（无下划线的单词通常是图形属性或关键字）
    if "_" not in rtype:
        return None
    return module, rtype, rname


def parse_dot(dot_text: str) -> Dict[str, Any]:
    """解析 DOT 文本，返回 {nodes: [...], edges: [...]}"""
    nodes: Dict[str, GraphNode] = {}
    edges: List[GraphEdge] = []

    raw_labels: Dict[str, str] = {}
    raw_ids: set[str] = set()

    for line in dot_text.splitlines():
        # 优先尝试匹配边（边行也可能包含 [...] 属性，需先判断）
        em = _EDGE_RE.match(line)
        if em:
            src = _normalize_id(em.group("src"))
            dst = _normalize_id(em.group("dst"))
            raw_ids.add(src)
            raw_ids.add(dst)
            edges.append(GraphEdge(source=src, target=dst))
            continue

        # 节点声明行
        nm = _NODE_RE.match(line)
        if nm:
            node_id = _normalize_id(nm.group("id"))
            attrs = nm.group("attrs")
            lm = _LABEL_RE.search(attrs)
            if lm:
                raw_labels[node_id] = lm.group(1)
            raw_ids.add(node_id)

    # 过滤为资源节点
    for nid in raw_ids:
        cls = _classify(nid)
        if cls is None:
            continue
        module, rtype, rname = cls
        label = raw_labels.get(nid) or f"{rtype}.{rname}"
        nodes[nid] = GraphNode(
            id=nid, label=label, type=rtype, name=rname, module=module
        )

    # 过滤掉端点不是资源的边
    valid_edges = [e for e in edges if e.source in nodes and e.target in nodes]

    return {
        "nodes": [asdict(n) for n in nodes.values()],
        "edges": [asdict(e) for e in valid_edges],
    }
