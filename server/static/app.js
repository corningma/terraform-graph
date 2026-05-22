/* ============================================================
 *  Terraform Graph Online — 前端逻辑
 *
 *  布局：
 *    - dagre   分层布局（dagre-d3 计算坐标，自绘 SVG）
 *    - force   力导布局（d3-force）
 *    - circular 环形布局（同一模块聚成弧段）
 *    - grid    网格布局（按模块分块、每块行优先排列）
 *
 *  统一在 state.positions: Map<nodeId, {x,y}> 上落点，统一一套
 *  绘制函数 (drawNodes / drawEdges) 渲染，从而保证状态着色、点击、
 *  适配等行为对所有布局一致。
 * ============================================================ */

(function () {
  "use strict";

  /* ============ 全局状态 ============ */
  const state = {
    sessions: [],
    currentSid: null,
    nodes: [],
    edges: [],
    statesMap: new Map(),     // node_id -> {status, action, message, updated_at}
    positions: new Map(),     // node_id -> {x, y}
    selectedNode: null,
    ws: null,

    layout: "dagre",
    direction: "LR",          // 仅 dagre 用
    forceSim: null,           // force 布局的仿真器
    logTab: "stdout",         // 当前激活的日志 Tab：stdout | event
    unread: { stdout: 0, event: 0 },
    resourceFilter: "",       // 资源列表的搜索关键字

    // SVG
    svg: null,
    inner: null,
    layerEdges: null,
    layerNodes: null,
    layerClusters: null,
    zoom: null,
    bbox: { x: 0, y: 0, w: 0, h: 0 },
  };

  const NODE_W = 160;
  const NODE_H = 44;

  /* ============ DOM ============ */
  const $ = (sel) => document.querySelector(sel);
  const sel = {
    sessionSelect: $("#sessionSelect"),
    refreshBtn: $("#refreshBtn"),
    resetBtn: $("#resetBtn"),
    deleteSessionBtn: $("#deleteSessionBtn"),
    connStatus: $("#connStatus"),
    sessionInfo: $("#sessionInfo"),
    nodeDetail: $("#nodeDetail"),
    statNodes: $("#statNodes"),
    statEdges: $("#statEdges"),
    statActive: $("#statActive"),
    emptyHint: $("#emptyHint"),
    resourceList: $("#resourceList"),
    resourceCount: $("#resourceCount"),
    resourceSearch: $("#resourceSearch"),
    logBoxStdout: $("#logBoxStdout"),
    logBoxEvent: $("#logBoxEvent"),
    autoScroll: $("#autoScroll"),
    logTabs: $("#logTabs"),
    badgeStdout: $("#badgeStdout"),
    badgeEvent: $("#badgeEvent"),
    layoutSeg: $("#layoutSeg"),
    dirSelect: $("#dirSelect"),
    relayoutBtn: $("#relayoutBtn"),
  };

  /* ============ HTTP ============ */
  async function api(path, opts) {
    const res = await fetch(path, {
      headers: { "Content-Type": "application/json" },
      ...opts,
    });
    if (!res.ok) throw new Error(`${res.status} ${res.statusText}`);
    return res.json();
  }

  async function loadSessions() {
    state.sessions = await api("/api/sessions");
    renderSessionSelect();
  }

  async function loadGraph(sid) {
    try {
      const data = await api(`/api/sessions/${sid}/graph`);
      state.nodes = data.nodes || [];
      state.edges = data.edges || [];
      state.statesMap.clear();
      (data.states || []).forEach((s) => state.statesMap.set(s.node_id, s));
    } catch {
      state.nodes = []; state.edges = []; state.statesMap.clear();
    }
    relayoutAndRender();
    renderStats();
    restoreSelectedNode();
  }

  /* ============ WebSocket ============ */
  // 重连参数：指数退避，避免"无限重连"压垮服务端（曾出现过 30s 60+ 次重连）
  const WS_RECONNECT_MIN_MS = 2000;
  const WS_RECONNECT_MAX_MS = 30000;
  let _wsBackoff = WS_RECONNECT_MIN_MS;
  let _wsReconnectTimer = null;
  let _wsManuallyClosed = false;

  function openWS(sid) {
    // 关闭旧连接前先标记为"手动关闭"，避免触发自动重连链
    if (state.ws) {
      _wsManuallyClosed = true;
      try { state.ws.close(); } catch {}
      _wsManuallyClosed = false;
    }
    if (_wsReconnectTimer) { clearTimeout(_wsReconnectTimer); _wsReconnectTimer = null; }

    // 页面被隐藏时不主动建立连接，等可见时再连，避免后台标签页空跑
    if (document.hidden) {
      setConn(false);
      return;
    }

    const proto = location.protocol === "https:" ? "wss:" : "ws:";
    const ws = new WebSocket(`${proto}//${location.host}/ws/${sid}`);
    state.ws = ws;

    ws.addEventListener("open", () => {
      setConn(true);
      _wsBackoff = WS_RECONNECT_MIN_MS;  // 连上后重置退避
    });
    ws.addEventListener("close", () => {
      setConn(false);
      if (_wsManuallyClosed) return;
      if (state.currentSid !== sid) return;
      if (document.hidden) return;       // 页面不可见就别重连
      // 指数退避重连
      _wsReconnectTimer = setTimeout(() => openWS(sid), _wsBackoff);
      _wsBackoff = Math.min(_wsBackoff * 2, WS_RECONNECT_MAX_MS);
    });
    ws.addEventListener("error", () => setConn(false));
    ws.addEventListener("message", (ev) => {
      let msg; try { msg = JSON.parse(ev.data); } catch { return; }
      handleEvent(msg);
    });
  }

  // 页面可见性变化：隐藏时主动断开 ws；恢复时立即重连。
  // 这能避免后台标签页/被遮挡的预览面板长期占用 server 连接数。
  document.addEventListener("visibilitychange", () => {
    if (document.hidden) {
      if (state.ws) {
        _wsManuallyClosed = true;
        try { state.ws.close(); } catch {}
        _wsManuallyClosed = false;
        state.ws = null;
      }
      if (_wsReconnectTimer) { clearTimeout(_wsReconnectTimer); _wsReconnectTimer = null; }
    } else if (state.currentSid) {
      _wsBackoff = WS_RECONNECT_MIN_MS;
      openWS(state.currentSid);
    }
  });

  // 页面卸载时主动关 ws（不等浏览器超时）
  window.addEventListener("pagehide", () => {
    if (state.ws) {
      _wsManuallyClosed = true;
      try { state.ws.close(); } catch {}
    }
  });

  function setConn(ok) {
    sel.connStatus.classList.toggle("is-on",  ok);
    sel.connStatus.classList.toggle("is-off", !ok);
    const msg = ok
      ? "与 Terraform 执行机网络连接正常"
      : "与 Terraform 执行机网络未连接";
    sel.connStatus.dataset.tooltip = msg;
    if (_tooltip) {
      _tooltip.querySelector(".tp-text").textContent = msg;
      _tooltip.classList.toggle("tp-on",  ok);
      _tooltip.classList.toggle("tp-off", !ok);
      // 未连接：强制常驻；连接恢复：自动隐藏
      if (ok) {
        _hideTooltip();
      } else {
        _showTooltip(sel.connStatus);
      }
    }
  }

  /* ---- 自定义 Tooltip ---- */
  let _tooltip = null;

  function _ensureTooltip() {
    if (_tooltip) return _tooltip;
    _tooltip = document.createElement("div");
    _tooltip.className = "tooltip-popup tp-off";
    _tooltip.innerHTML = '<span class="tp-dot"></span><span class="tp-text"></span>';
    document.body.appendChild(_tooltip);
    return _tooltip;
  }

  function _showTooltip(anchor) {
    const tip = _ensureTooltip();
    const msg = anchor.dataset.tooltip || "";
    const isOn = anchor.classList.contains("is-on");
    tip.querySelector(".tp-text").textContent = msg;
    tip.classList.toggle("tp-on",  isOn);
    tip.classList.toggle("tp-off", !isOn);

    tip.style.visibility = "hidden";
    tip.style.display = "flex";
    requestAnimationFrame(() => {
      const ar = anchor.getBoundingClientRect();
      const tr = tip.getBoundingClientRect();
      const left = ar.left + ar.width / 2 - tr.width / 2;
      const top  = ar.bottom + 8;
      tip.style.left = `${Math.max(8, left)}px`;
      tip.style.top  = `${top}px`;
      tip.style.visibility = "";
      tip.classList.add("visible");
    });
  }

  function _hideTooltip() {
    if (_tooltip) _tooltip.classList.remove("visible");
  }

  sel.connStatus.addEventListener("mouseenter", () => _showTooltip(sel.connStatus));
  // 未连接时 tooltip 常驻，鼠标离开不关闭
  sel.connStatus.addEventListener("mouseleave", () => {
    if (sel.connStatus.classList.contains("is-on")) _hideTooltip();
  });

  function handleEvent(msg) {
    switch (msg.type) {
      case "graph":
        state.nodes = msg.data.nodes || [];
        state.edges = msg.data.edges || [];
        relayoutAndRender();
        renderStats();
        restoreSelectedNode();
        break;
      case "states_snapshot":
        state.statesMap.clear();
        (msg.data || []).forEach((s) => state.statesMap.set(s.node_id, s));
        applyAllNodeStatuses();
        renderStats();
        break;
      case "state": {
        const s = msg.data;
        state.statesMap.set(s.node_id, s);
        applyNodeStatus(s.node_id);
        renderStats();
        appendLog({ stream: "event", line: `[${s.status}] ${s.node_id} — ${s.message || ""}` });
        if (state.selectedNode === s.node_id) renderNodeDetail(s.node_id);
        break;
      }
      case "logs":
        (msg.data || []).forEach((l) => appendLog(l));
        break;
      case "states_reset":
        state.statesMap.clear();
        applyAllNodeStatuses();
        renderStats();
        appendLog({ stream: "event", line: "状态已重置" });
        break;
      case "logs_cleared":
        clearLog();
        appendLog({ stream: "event", line: "--- 新一轮 graph 已上传，日志已清空 ---" });
        break;
      case "session":
        loadSessions();
        break;
      default: break;
    }
  }

  /* ============ 会话渲染 ============ */
  function renderSessionSelect() {
    sel.sessionSelect.innerHTML = "";
    if (state.sessions.length === 0) {
      const o = document.createElement("option");
      o.value = ""; o.textContent = "（暂无会话）";
      sel.sessionSelect.appendChild(o);
      sel.sessionInfo.textContent = "未选择会话";
      return;
    }
    state.sessions.forEach((s) => {
      const o = document.createElement("option");
      o.value = s.id;
      // 标注最近更新时间（相对时间）
      const ago = formatAgo(s.updated_at);
      o.textContent = `${s.name} · ${s.hostname || "?"}` + (ago ? ` · ${ago}` : "");
      sel.sessionSelect.appendChild(o);
    });

    let sid = state.currentSid;
    if (!sid) {
      // 从 localStorage 读取上次选择
      try { sid = localStorage.getItem("tfgraph:lastSid"); } catch {}
    }
    if (!sid || !state.sessions.find((s) => s.id === sid)) sid = state.sessions[0].id;
    sel.sessionSelect.value = sid;
    // 仅当 sid 真的发生变化时才切换；否则重复 loadSessions（如收到 session
    // 广播）会反复重建 WebSocket，造成"无限创建/关闭"循环。
    if (sid !== state.currentSid) {
      selectSession(sid);
    }
  }

  function selectSession(sid) {
    if (!sid) return;
    state.currentSid = sid;
    try { localStorage.setItem("tfgraph:lastSid", sid); } catch {}
    const s = state.sessions.find((x) => x.id === sid);
    if (s) {
      sel.sessionInfo.innerHTML = `
        <div><span class="muted">名称：</span><b>${escapeHtml(s.name)}</b></div>
        <div><span class="muted">主机：</span>${escapeHtml(s.hostname || "-")}</div>
        <div><span class="muted">目录：</span>${escapeHtml(s.workdir || "-")}</div>
        <div><span class="muted">ID：</span>${s.id}</div>
      `;
    }
    clearLog();
    loadGraph(sid);
    openWS(sid);
  }

  /* ============ SVG 初始化 ============ */
  function ensureSvg() {
    if (state.svg) return;
    state.svg = d3.select("#graph");
    state.inner = state.svg.append("g").attr("class", "viewport");

    // 三层：簇背景 -> 边 -> 节点
    state.layerClusters = state.inner.append("g").attr("class", "layer-clusters");
    state.layerEdges    = state.inner.append("g").attr("class", "layer-edges");
    state.layerNodes    = state.inner.append("g").attr("class", "layer-nodes");

    // 箭头标记
    const defs = state.svg.append("defs");
    defs.append("marker")
      .attr("id", "arrow")
      .attr("viewBox", "0 -5 10 10")
      .attr("refX", 8).attr("refY", 0)
      .attr("markerWidth", 8).attr("markerHeight", 8)
      .attr("orient", "auto")
      .append("path")
      .attr("d", "M0,-5L10,0L0,5")
      .attr("fill", "#b6cdc1");

    state.zoom = d3.zoom().scaleExtent([0.1, 4]).on("zoom", (e) => {
      state.inner.attr("transform", e.transform);
    });
    state.svg.call(state.zoom);
    // 禁用 d3.zoom 默认的"双击放大"，避免与节点双击取消选中冲突
    state.svg.on("dblclick.zoom", null);
  }

  /* ============ 布局算法 ============ */

  /** 把所有 positions 标准化（求 bbox），用于适配画布。 */
  function computeBBox() {
    let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
    state.positions.forEach((p) => {
      if (p.x < minX) minX = p.x;
      if (p.y < minY) minY = p.y;
      if (p.x > maxX) maxX = p.x;
      if (p.y > maxY) maxY = p.y;
    });
    if (!isFinite(minX)) { state.bbox = { x: 0, y: 0, w: 0, h: 0 }; return; }
    state.bbox = {
      x: minX - NODE_W / 2 - 20,
      y: minY - NODE_H / 2 - 20,
      w: (maxX - minX) + NODE_W + 40,
      h: (maxY - minY) + NODE_H + 40,
    };
  }

  /* ---- dagre 分层 ---- */
  function layoutDagre() {
    const g = new dagre.graphlib.Graph()
      .setGraph({
        rankdir: state.direction,
        nodesep: 40, ranksep: 70, marginx: 30, marginy: 30,
      })
      .setDefaultEdgeLabel(() => ({}));

    state.nodes.forEach((n) => {
      g.setNode(n.id, { width: NODE_W, height: NODE_H });
    });
    state.edges.forEach((e) => {
      if (g.hasNode(e.source) && g.hasNode(e.target)) {
        g.setEdge(e.source, e.target, {});
      }
    });

    dagre.layout(g);
    state.positions.clear();
    g.nodes().forEach((id) => {
      const nd = g.node(id);
      state.positions.set(id, { x: nd.x, y: nd.y });
    });
  }

  /* ---- 自由布局：先用力导跑一遍得到合理坐标，然后冻结。
   *      拖一个节点不会带动其它节点，仅连线随之伸缩。 ---- */
  function layoutFree() {
    const w = state.svg.node().clientWidth || 800;
    const h = state.svg.node().clientHeight || 600;

    const simNodes = state.nodes.map((n) => {
      const prev = state.positions.get(n.id);
      return { id: n.id, x: prev ? prev.x : Math.random() * w, y: prev ? prev.y : Math.random() * h };
    });
    const idSet = new Set(simNodes.map((n) => n.id));
    const links = state.edges
      .filter((e) => idSet.has(e.source) && idSet.has(e.target))
      .map((e) => ({ source: e.source, target: e.target }));

    const sim = d3.forceSimulation(simNodes)
      .force("link", d3.forceLink(links).id((d) => d.id).distance(140).strength(0.5))
      .force("charge", d3.forceManyBody().strength(-450))
      .force("center", d3.forceCenter(w / 2, h / 2))
      .force("collide", d3.forceCollide(NODE_W * 0.55))
      .stop(); // 不调度 tick，仅用于离线计算

    // 离线迭代到稳定
    for (let i = 0; i < 300; i++) sim.tick();

    state.positions.clear();
    simNodes.forEach((d) => state.positions.set(d.id, { x: d.x, y: d.y }));
    // 注意：state.forceSim 保持为 null —— 自由布局没有运行中的仿真器
  }

  /* ---- 力导布局 ---- */
  function layoutForce() {
    if (state.forceSim) state.forceSim.stop();

    const w = state.svg.node().clientWidth;
    const h = state.svg.node().clientHeight;
    const nodes = state.nodes.map((n) => {
      const prev = state.positions.get(n.id);
      return { id: n.id, x: prev ? prev.x : Math.random() * w, y: prev ? prev.y : Math.random() * h };
    });
    const links = state.edges
      .filter((e) => state.nodes.some(n => n.id === e.source) && state.nodes.some(n => n.id === e.target))
      .map((e) => ({ source: e.source, target: e.target }));

    const sim = d3.forceSimulation(nodes)
      .force("link", d3.forceLink(links).id((d) => d.id).distance(120).strength(0.6))
      .force("charge", d3.forceManyBody().strength(-450))
      .force("center", d3.forceCenter(w / 2, h / 2))
      .force("collide", d3.forceCollide(NODE_W * 0.55))
      .alpha(1).alphaDecay(0.04);

    state.forceSim = sim;

    sim.on("tick", () => {
      nodes.forEach((d) => state.positions.set(d.id, { x: d.x, y: d.y }));
      // 仅更新位置（不重建节点/重新挂 drag）
      state.layerNodes.selectAll("g.tf-node")
        .attr("transform", (d) => {
          const p = state.positions.get(d.id) || { x: 0, y: 0 };
          return `translate(${p.x},${p.y})`;
        });
      state.layerEdges.selectAll("path.tf-edge").attr("d", (d) => edgePath(d));
    });
    sim.on("end", () => {
      computeBBox();
    });

    // 立刻迭代一定步数得到一个像样的初始布局
    for (let i = 0; i < 80; i++) sim.tick();
    nodes.forEach((d) => state.positions.set(d.id, { x: d.x, y: d.y }));
  }

  /* ---- 环形布局 ---- */
  function layoutCircular() {
    state.positions.clear();
    const groups = groupByModule(state.nodes);
    const all = [];
    // 按模块顺序连续排列
    Object.keys(groups).sort().forEach((mod) => {
      groups[mod].forEach((n) => all.push({ ...n, _mod: mod }));
    });

    const N = all.length;
    if (N === 0) return;
    const radius = Math.max(220, N * 22);
    const cx = radius + 40, cy = radius + 40;
    all.forEach((n, i) => {
      const angle = (i / N) * Math.PI * 2 - Math.PI / 2;
      state.positions.set(n.id, {
        x: cx + radius * Math.cos(angle),
        y: cy + radius * Math.sin(angle),
      });
    });
  }

  /* ---- 网格布局 ---- */
  function layoutGrid() {
    state.positions.clear();
    const groups = groupByModule(state.nodes);
    const cellW = NODE_W + 40;
    const cellH = NODE_H + 28;
    let cursorY = 30;

    Object.keys(groups).sort().forEach((mod) => {
      const list = groups[mod];
      const cols = Math.max(1, Math.ceil(Math.sqrt(list.length * 1.6)));
      list.forEach((n, i) => {
        const r = Math.floor(i / cols);
        const c = i % cols;
        state.positions.set(n.id, {
          x: 30 + c * cellW + cellW / 2,
          y: cursorY + r * cellH + cellH / 2,
        });
      });
      const rows = Math.ceil(list.length / cols);
      cursorY += rows * cellH + 30; // 模块间留白
    });
  }

  function groupByModule(nodes) {
    const groups = {};
    nodes.forEach((n) => {
      const m = n.module || "root";
      (groups[m] = groups[m] || []).push(n);
    });
    return groups;
  }

  /* ============ 主渲染入口 ============ */

  /** 拖动后的位置持久化到 localStorage，按 (会话, 布局) 隔离。 */
  function positionsStorageKey() {
    return `tfgraph:positions:${state.currentSid || "_"}:${state.layout}`;
  }

  function savePositions() {
    if (!state.currentSid) return;
    const obj = {};
    state.positions.forEach((p, id) => { obj[id] = { x: p.x, y: p.y }; });
    try { localStorage.setItem(positionsStorageKey(), JSON.stringify(obj)); } catch {}
  }

  function loadPositions() {
    if (!state.currentSid) return null;
    try {
      const raw = localStorage.getItem(positionsStorageKey());
      return raw ? JSON.parse(raw) : null;
    } catch { return null; }
  }

  function clearPositions() {
    if (!state.currentSid) return;
    try { localStorage.removeItem(positionsStorageKey()); } catch {}
  }

  /**
   * @param {{ force?: boolean }} opts
   *   force=true  ：忽略持久化位置，强制重新跑布局算法
   *   force=false ：(默认) 若有持久化位置则恢复，仅给新节点跑算法补位
   */
  function relayoutAndRender(opts = {}) {
    const force = !!opts.force;
    ensureSvg();
    sel.emptyHint.classList.toggle("hidden", state.nodes.length > 0);
    if (state.nodes.length === 0) {
      state.layerClusters.selectAll("*").remove();
      state.layerEdges.selectAll("*").remove();
      state.layerNodes.selectAll("*").remove();
      return;
    }

    // 停掉之前的力导仿真
    if (state.forceSim) { state.forceSim.stop(); state.forceSim = null; }

    const saved = force ? null : loadPositions();
    const savedIds = saved ? new Set(Object.keys(saved)) : null;
    const allInSaved = saved
      ? state.nodes.every((n) => savedIds.has(n.id))
      : false;

    if (saved && allInSaved) {
      // 完全命中持久化：直接恢复
      state.positions.clear();
      state.nodes.forEach((n) => state.positions.set(n.id, saved[n.id]));
    } else {
      // 跑布局算法（强制重排，或图中出现未持久化的新节点）
      switch (state.layout) {
        case "force":    layoutForce();    break;
        case "free":     layoutFree();     break;
        case "circular": layoutCircular(); break;
        case "grid":     layoutGrid();     break;
        case "dagre":
        default:         layoutDagre();    break;
      }
      // 算法跑完后，再用持久化位置覆盖原有节点（仅恢复"老节点"的人工位置）
      if (saved) {
        state.nodes.forEach((n) => {
          if (savedIds.has(n.id)) state.positions.set(n.id, saved[n.id]);
        });
      }
    }

    drawAll(true);
    computeBBox();
    fitView(true);
  }

  /* ============ 绘制（节点 + 边 + 模块簇） ============ */
  function drawAll(animate) {
    drawClusters();
    drawEdges();
    drawNodes(animate);
  }

  function drawClusters() {
    // 仅在 grid / circular / dagre 三种"静态"布局下展示模块底框；force 下不画
    state.layerClusters.selectAll("*").remove();
    if (state.layout === "force") return;

    const groups = groupByModule(state.nodes);
    Object.keys(groups).forEach((mod) => {
      if (mod === "root") return;
      const list = groups[mod];
      let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
      list.forEach((n) => {
        const p = state.positions.get(n.id); if (!p) return;
        if (p.x < minX) minX = p.x; if (p.y < minY) minY = p.y;
        if (p.x > maxX) maxX = p.x; if (p.y > maxY) maxY = p.y;
      });
      if (!isFinite(minX)) return;
      const pad = 18;
      const x = minX - NODE_W / 2 - pad;
      const y = minY - NODE_H / 2 - pad - 14;
      const w = (maxX - minX) + NODE_W + pad * 2;
      const h = (maxY - minY) + NODE_H + pad * 2 + 14;

      const g = state.layerClusters.append("g")
        .attr("class", "cluster")
        .attr("data-module", mod)
        .datum({ module: mod });

      g.append("rect")
        .attr("x", x).attr("y", y).attr("width", w).attr("height", h)
        .attr("rx", 10).attr("ry", 10)
        .attr("fill", "#f0f8f3").attr("stroke", "#c8e6d6")
        .attr("stroke-dasharray", "4 3");
      g.append("text")
        .attr("x", x + 12).attr("y", y + 16)
        .attr("font-size", 11).attr("fill", "#4ea57c").attr("font-weight", 600)
        .text(mod);

      g.call(makeClusterDrag());
    });
  }

  function drawEdges() {
    const validEdges = state.edges.filter((e) =>
      state.positions.has(e.source) && state.positions.has(e.target)
    );

    const sel0 = state.layerEdges.selectAll("path.tf-edge").data(validEdges, (d) => `${d.source}::${d.target}`);
    sel0.exit().remove();
    const enter = sel0.enter().append("path").attr("class", "tf-edge").attr("marker-end", "url(#arrow)");
    enter.merge(sel0).attr("d", (d) => edgePath(d));
  }

  function edgePath(e) {
    const s = state.positions.get(e.source);
    const t = state.positions.get(e.target);
    if (!s || !t) return "";

    // 计算连接到节点矩形边缘的端点
    const [sx, sy] = clipToRect(s, t);
    const [tx, ty] = clipToRect(t, s);

    if (state.layout === "dagre") {
      // 分层布局：用贝塞尔，依据方向决定切线
      const horizontal = state.direction === "LR" || state.direction === "RL";
      const dx = tx - sx, dy = ty - sy;
      const c1 = horizontal ? [sx + dx * 0.5, sy] : [sx, sy + dy * 0.5];
      const c2 = horizontal ? [tx - dx * 0.5, ty] : [tx, ty - dy * 0.5];
      return `M${sx},${sy}C${c1[0]},${c1[1]} ${c2[0]},${c2[1]} ${tx},${ty}`;
    }
    if (state.layout === "circular") {
      // 二次贝塞尔向中心微弯
      const mx = (sx + tx) / 2, my = (sy + ty) / 2;
      const cx = state.bbox.x + state.bbox.w / 2;
      const cy = state.bbox.y + state.bbox.h / 2;
      const k = 0.25;
      return `M${sx},${sy}Q${mx + (cx - mx) * k},${my + (cy - my) * k} ${tx},${ty}`;
    }
    // force / grid：直线
    return `M${sx},${sy}L${tx},${ty}`;
  }

  /** 求线段从 from 节点中心射向 to 时，与 from 矩形相交的点。 */
  function clipToRect(from, to) {
    const dx = to.x - from.x;
    const dy = to.y - from.y;
    if (dx === 0 && dy === 0) return [from.x, from.y];
    const w = NODE_W / 2, h = NODE_H / 2;
    const tx = dx === 0 ? Infinity : Math.abs(w / dx);
    const ty = dy === 0 ? Infinity : Math.abs(h / dy);
    const t = Math.min(tx, ty);
    return [from.x + dx * t, from.y + dy * t];
  }

  function drawNodes(animate) {
    const sel0 = state.layerNodes.selectAll("g.tf-node").data(state.nodes, (d) => d.id);
    sel0.exit().remove();

    const enter = sel0.enter().append("g")
      .attr("class", (d) => nodeClass(d.id))
      .attr("data-id", (d) => d.id)
      .call(makeNodeDrag());

    enter.append("rect")
      .attr("class", "tf-shape")
      .attr("width", NODE_W).attr("height", NODE_H)
      .attr("x", -NODE_W / 2).attr("y", -NODE_H / 2)
      .attr("rx", 8).attr("ry", 8);

    enter.append("text")
      .attr("class", "tf-sublabel")
      .attr("y", -4)
      .text((d) => d.type)
      .each(function(d) { fitTextToWidth(this, d.type, NODE_W - 12); });

    enter.append("text")
      .attr("class", "tf-label")
      .attr("y", 12)
      .text((d) => d.name)
      .each(function(d) { fitTextToWidth(this, d.name, NODE_W - 12); });

    // 鼠标悬停 SVG 文字时显示完整内容
    enter.append("title")
      .text((d) => `${d.type}.${d.name}${d.module ? ` @ ${d.module}` : ""}`);

    const merged = enter.merge(sel0);
    merged.attr("class", (d) => fullNodeClass(d.id));

    const move = animate ? merged.transition().duration(380) : merged;
    move.attr("transform", (d) => {
      const p = state.positions.get(d.id) || { x: 0, y: 0 };
      return `translate(${p.x},${p.y})`;
    });

    // 重绘后同步 layer 上的 has-selected 标记和选中节点 raise
    if (state.layerNodes && state.layerEdges) {
      const has = !!state.selectedNode;
      state.layerNodes.classed("has-selected", has);
      state.layerEdges.classed("has-selected", has);
      if (has) {
        state.layerNodes.selectAll("g.tf-node")
          .filter((d) => d.id === state.selectedNode).raise();
      }
    }
  }

  /** 计算节点的完整 class 串：状态色 + selected + related。 */
  function fullNodeClass(nodeId) {
    let cls = nodeClass(nodeId);
    if (state.selectedNode === nodeId) cls += " selected";
    else if (state.selectedNode && _isRelated(nodeId)) cls += " related";
    return cls;
  }

  function _isRelated(nodeId) {
    const sel = state.selectedNode;
    if (!sel) return false;
    return state.edges.some(
      (e) => (e.source === sel && e.target === nodeId) ||
             (e.target === sel && e.source === nodeId)
    );
  }

  function nodeClass(nodeId) {
    const status = (state.statesMap.get(nodeId) || {}).status || "pending";
    return `tf-node status-${status}`;
  }

  /* ============ 状态着色（增量更新） ============ */
  function applyNodeStatus(nodeId) {
    state.layerNodes.selectAll(`g.tf-node[data-id="${cssEscape(nodeId)}"]`)
      .attr("class", fullNodeClass(nodeId));
  }

  function applyAllNodeStatuses() {
    state.layerNodes.selectAll("g.tf-node")
      .attr("class", function (d) { return fullNodeClass(d.id); });
  }

  function cssEscape(s) {
    if (window.CSS && CSS.escape) return CSS.escape(s);
    return String(s).replace(/(["\\])/g, "\\$1");
  }

  /* ============ 拖拽：节点 / 模块 ============ */

  /** 仅刷新指定节点的 transform，及与之关联的边 path。 */
  function refreshNodeAt(nodeId) {
    state.layerNodes.selectAll(`g.tf-node[data-id="${cssEscape(nodeId)}"]`)
      .attr("transform", () => {
        const p = state.positions.get(nodeId) || { x: 0, y: 0 };
        return `translate(${p.x},${p.y})`;
      });
    state.layerEdges.selectAll("path.tf-edge")
      .filter((d) => d.source === nodeId || d.target === nodeId)
      .attr("d", (d) => edgePath(d));
  }

  /** 一次性刷新一组节点的位置与相关的边（拖动模块时用）。 */
  function refreshNodesAt(idSet) {
    state.layerNodes.selectAll("g.tf-node")
      .filter((d) => idSet.has(d.id))
      .attr("transform", (d) => {
        const p = state.positions.get(d.id) || { x: 0, y: 0 };
        return `translate(${p.x},${p.y})`;
      });
    state.layerEdges.selectAll("path.tf-edge")
      .filter((d) => idSet.has(d.source) || idSet.has(d.target))
      .attr("d", (d) => edgePath(d));
  }

  /** 重画当前模块的底框（不重建其它簇，避免影响正在拖拽的对象的事件绑定）。 */
  function refreshClusterFrame(mod) {
    const list = state.nodes.filter((n) => (n.module || "root") === mod);
    let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
    list.forEach((n) => {
      const p = state.positions.get(n.id); if (!p) return;
      if (p.x < minX) minX = p.x; if (p.y < minY) minY = p.y;
      if (p.x > maxX) maxX = p.x; if (p.y > maxY) maxY = p.y;
    });
    if (!isFinite(minX)) return;
    const pad = 18;
    const x = minX - NODE_W / 2 - pad;
    const y = minY - NODE_H / 2 - pad - 14;
    const w = (maxX - minX) + NODE_W + pad * 2;
    const h = (maxY - minY) + NODE_H + pad * 2 + 14;
    const g = state.layerClusters.select(`g.cluster[data-module="${cssEscape(mod)}"]`);
    g.select("rect").attr("x", x).attr("y", y).attr("width", w).attr("height", h);
    g.select("text").attr("x", x + 12).attr("y", y + 16);
  }

  // 区分单击与双击：单击立即选中；双击同一节点取消选中
  const _clickState = { id: null, ts: 0 };
  const DBLCLICK_MS = 320;

  function handleNodeClick(nodeId, opts = {}) {
    const now = Date.now();
    const isDouble =
      _clickState.id === nodeId && (now - _clickState.ts) < DBLCLICK_MS;

    if (isDouble) {
      // 双击同一节点：取消选中
      _clickState.id = null;
      _clickState.ts = 0;
      selectNode(null);
    } else {
      // 单击：立即选中（无延迟）
      _clickState.id = nodeId;
      _clickState.ts = now;
      selectNode(nodeId, opts);
    }
  }

  function makeNodeDrag() {
    // 通过闭包跟踪本次按下是否真的产生了位移；用于区分"点击"与"拖拽"
    let moved = false;
    return d3.drag()
      .clickDistance(5)  // 位移 <= 5px 视为点击而非拖拽
      .on("start", function (event, d) {
        moved = false;
        d3.select(this).raise().classed("dragging", true);
        if (state.layout === "force" && state.forceSim) {
          if (!event.active) state.forceSim.alphaTarget(0.18).restart();
          const simNode = state.forceSim.nodes().find((n) => n.id === d.id);
          if (simNode) { simNode.fx = simNode.x; simNode.fy = simNode.y; }
        }
      })
      .on("drag", function (event, d) {
        moved = true;
        if (state.layout === "force" && state.forceSim) {
          const simNode = state.forceSim.nodes().find((n) => n.id === d.id);
          if (simNode) { simNode.fx = event.x; simNode.fy = event.y; }
        } else {
          state.positions.set(d.id, { x: event.x, y: event.y });
          refreshNodeAt(d.id);
          if (d.module && d.module !== "root") refreshClusterFrame(d.module);
        }
      })
      .on("end", function (event, d) {
        d3.select(this).classed("dragging", false);
        if (state.layout === "force" && state.forceSim) {
          if (!event.active) state.forceSim.alphaTarget(0);
          const simNode = state.forceSim.nodes().find((n) => n.id === d.id);
          if (simNode) { simNode.fx = null; simNode.fy = null; }
        }
        // 没有真正拖动 => 视为点击；区分单击/双击
        if (!moved) {
          handleNodeClick(d.id);
        } else if (state.layout !== "force") {
          // 真正发生了拖动：持久化新位置（force 布局节点会被仿真持续拉动，不持久化）
          savePositions();
        }
      });
  }

  function makeClusterDrag() {
    // 拖拽时记录开始位置，对该模块下所有节点整体平移
    let memo = null;
    return d3.drag()
      .filter((event) => {
        // 如果起手在节点上（事件冒泡上来），就别接管
        const target = event.target;
        return !target.closest("g.tf-node");
      })
      .on("start", function (event, d) {
        d3.select(this).raise().classed("dragging", true);
        const mod = d.module;
        const ids = state.nodes
          .filter((n) => (n.module || "root") === mod)
          .map((n) => n.id);
        const origin = new Map();
        ids.forEach((id) => {
          const p = state.positions.get(id);
          if (p) origin.set(id, { x: p.x, y: p.y });
        });
        memo = { mod, ids: new Set(ids), origin, startX: event.x, startY: event.y };
      })
      .on("drag", function (event) {
        if (!memo) return;
        const dx = event.x - memo.startX;
        const dy = event.y - memo.startY;
        memo.ids.forEach((id) => {
          const o = memo.origin.get(id); if (!o) return;
          state.positions.set(id, { x: o.x + dx, y: o.y + dy });
        });
        refreshNodesAt(memo.ids);
        refreshClusterFrame(memo.mod);
      })
      .on("end", function () {
        d3.select(this).classed("dragging", false);
        if (memo) savePositions();   // 持久化模块整体平移后的位置
        memo = null;
      });
  }

  /* ============ 适配画布 ============ */
  function fitView(animate) {
    if (!state.bbox.w || !state.bbox.h) return;
    const svgEl = state.svg.node();
    const W = svgEl.clientWidth, H = svgEl.clientHeight;
    const scale = Math.min(W / state.bbox.w, H / state.bbox.h, 1.2);
    const tx = (W - state.bbox.w * scale) / 2 - state.bbox.x * scale;
    const ty = (H - state.bbox.h * scale) / 2 - state.bbox.y * scale;
    const t = d3.zoomIdentity.translate(tx, ty).scale(scale);
    if (animate) state.svg.transition().duration(420).call(state.zoom.transform, t);
    else state.svg.call(state.zoom.transform, t);
  }

  /** 把指定节点居中到画布中心。保持当前 zoom scale。 */
  function centerOnNode(nodeId) {
    const p = state.positions.get(nodeId);
    if (!p || !state.svg || !state.zoom) return;
    const svgEl = state.svg.node();
    const W = svgEl.clientWidth, H = svgEl.clientHeight;
    // 取当前 transform
    const cur = d3.zoomTransform(svgEl);
    const scale = cur.k && cur.k > 0.1 ? cur.k : 1;
    const tx = W / 2 - p.x * scale;
    const ty = H / 2 - p.y * scale;
    const t = d3.zoomIdentity.translate(tx, ty).scale(scale);
    state.svg.transition().duration(420).call(state.zoom.transform, t);
  }

  /* ============ 统计 / 详情 ============ */
  function renderStats() {
    sel.statNodes.textContent = state.nodes.length;
    sel.statEdges.textContent = state.edges.length;
    let active = 0;
    state.statesMap.forEach((s) => {
      if (["creating", "modifying", "destroying", "refreshing", "reading"].includes(s.status)) active++;
    });
    sel.statActive.textContent = active;
    renderResourceList();
  }

  /** 渲染左侧"资源列表"。按 module 分组排序，状态色点 + 高亮选中。 */
  function renderResourceList() {
    const filter = (state.resourceFilter || "").trim().toLowerCase();
    // 排序：先按 module（root 排前），再按 type、name
    const list = state.nodes.slice().sort((a, b) => {
      const ma = a.module || "root", mb = b.module || "root";
      if (ma !== mb) {
        if (ma === "root") return -1;
        if (mb === "root") return 1;
        return ma.localeCompare(mb);
      }
      if (a.type !== b.type) return a.type.localeCompare(b.type);
      return a.name.localeCompare(b.name);
    });

    const filtered = filter
      ? list.filter((n) => {
          const text = `${n.module} ${n.type}.${n.name}`.toLowerCase();
          return text.includes(filter);
        })
      : list;

    sel.resourceCount.textContent = `${filtered.length}/${list.length}`;
    sel.resourceList.innerHTML = "";

    if (filtered.length === 0) {
      const li = document.createElement("li");
      li.className = "muted empty-tip";
      li.textContent = list.length === 0 ? "暂无资源" : "没有匹配的资源";
      sel.resourceList.appendChild(li);
      return;
    }

    let lastModule = null;
    filtered.forEach((n) => {
      const status = (state.statesMap.get(n.id) || {}).status || "pending";
      const li = document.createElement("li");
      li.className = `resource-item status-${status}` +
        (state.selectedNode === n.id ? " selected" : "");
      li.dataset.id = n.id;
      li.title = `${n.module} · ${n.type}.${n.name}\n点击选中并居中`;

      const showModule = n.module && n.module !== "root" && n.module !== lastModule;

      li.innerHTML = `
        <span class="res-dot"></span>
        <div class="res-info">
          <div class="res-type">${escapeHtml(n.type)}</div>
          <div class="res-name">${escapeHtml(n.name)}${
            showModule ? `<span class="res-module">@ ${escapeHtml(n.module)}</span>` : ""
          }</div>
        </div>
      `;
      sel.resourceList.appendChild(li);
      lastModule = n.module;
    });
  }

  function renderNodeDetail(id) {
    const n = id ? state.nodes.find((x) => x.id === id) : null;
    const s = id ? state.statesMap.get(id) : null;

    // 占位符
    const PH = '<span class="ph">—</span>';
    const val = (v) => (v === null || v === undefined || v === "") ? PH : escapeHtml(String(v));

    const resourceText = n ? `${n.type}.${n.name}` : null;
    const moduleText   = n ? n.module : null;
    const statusText   = s ? s.status : (n ? "pending" : null);
    const actionText   = s ? s.action : null;
    const updatedText  = s ? new Date(s.updated_at * 1000).toLocaleTimeString() : null;
    const messageText  = s ? s.message : null;

    sel.nodeDetail.innerHTML = `
      <div class="nd-grid">
        <div class="nd-row"><span class="k">资源</span><span class="v">${val(resourceText)}</span></div>
        <div class="nd-row"><span class="k">模块</span><span class="v">${val(moduleText)}</span></div>
        <div class="nd-row"><span class="k">状态</span><span class="v">${
          statusText ? `<span class="status-pill status-${statusText}">${escapeHtml(statusText)}</span>` : PH
        }</span></div>
        <div class="nd-row"><span class="k">动作</span><span class="v">${val(actionText)}</span></div>
        <div class="nd-row"><span class="k">更新</span><span class="v">${val(updatedText)}</span></div>
      </div>
      <div class="nd-message">
        <div class="k">消息</div>
        <div class="v">${messageText ? escapeHtml(messageText) : '<span class="ph">—</span>'}</div>
      </div>
    `;
  }

  /** 统一的"选中一个节点"入口：更新选中态、图、列表、详情、可选居中。 */
  function selectNode(id, opts = {}) {
    const { center = false, persist = true } = opts;
    state.selectedNode = id;
    if (persist && state.currentSid) {
      try { localStorage.setItem(`tfgraph:selected:${state.currentSid}`, id || ""); } catch {}
    }
    // 计算与选中节点直接相连的节点 + 边
    const relatedNodes = new Set();
    const relatedEdgeKeys = new Set();
    if (id) {
      state.edges.forEach((e) => {
        if (e.source === id) {
          relatedNodes.add(e.target);
          relatedEdgeKeys.add(`${e.source}::${e.target}`);
        } else if (e.target === id) {
          relatedNodes.add(e.source);
          relatedEdgeKeys.add(`${e.source}::${e.target}`);
        }
      });
    }

    // 图上节点：selected / related
    if (state.layerNodes) {
      state.layerNodes.classed("has-selected", !!id);
      state.layerNodes.selectAll("g.tf-node")
        .classed("selected", (d) => d.id === id)
        .classed("related",  (d) => relatedNodes.has(d.id));
      // 把选中节点提到末尾（z-order 更高，盖住相邻节点的边缘）
      if (id) {
        state.layerNodes.selectAll("g.tf-node")
          .filter((d) => d.id === id).raise();
      }
    }
    // 边：related
    if (state.layerEdges) {
      state.layerEdges.classed("has-selected", !!id);
      state.layerEdges.selectAll("path.tf-edge")
        .classed("related", (d) => relatedEdgeKeys.has(`${d.source}::${d.target}`));
    }

    // 资源列表高亮
    sel.resourceList.querySelectorAll(".resource-item").forEach((li) => {
      li.classList.toggle("selected", li.dataset.id === id);
    });
    // 详情
    renderNodeDetail(id);
    // 居中
    if (center) centerOnNode(id);
  }

  /** 从 localStorage 读取上次选中的节点（仅当节点仍存在于当前会话时恢复）。 */
  function restoreSelectedNode() {
    if (!state.currentSid) return;
    let id = null;
    try { id = localStorage.getItem(`tfgraph:selected:${state.currentSid}`); } catch {}
    if (id && state.nodes.find((n) => n.id === id)) {
      // 恢复选中（不居中，避免视图突然跳动；用户主动点击列表才居中）
      selectNode(id, { persist: false });
    } else {
      // 该节点不存在 → 渲染空状态详情
      renderNodeDetail(null);
    }
  }

  /* ============ 日志 ============ */
  function appendLog(item) {
    const stream = item.stream || "stdout";
    // 路由：file 流（来自 TF_LOG_PATH 的 terraform 日志）进"实时日志" Tab；
    //       其余（stdout / stderr / event / 其它）合并进"控制台" Tab
    const tab = stream === "file" ? "event" : "stdout";
    const box = tab === "stdout" ? sel.logBoxStdout : sel.logBoxEvent;

    // 清掉空占位
    const empty = box.querySelector(".line.empty");
    if (empty) empty.remove();

    const div = document.createElement("div");
    div.className = `line ${stream}`;
    div.textContent = item.line;
    box.appendChild(div);

    while (box.children.length > 2000) {
      box.removeChild(box.firstChild);
    }

    // 当前激活 Tab 才滚动；非激活 Tab 累加未读 badge
    if (tab === state.logTab) {
      if (sel.autoScroll.checked) box.scrollTop = box.scrollHeight;
    } else {
      state.unread[tab] += 1;
      updateBadge(tab);
    }
  }

  function clearLog() {
    sel.logBoxStdout.innerHTML = '<div class="line empty">暂无控制台输出，等待 Agent 上报…</div>';
    sel.logBoxEvent.innerHTML  = '<div class="line empty">暂无 terraform 日志（请确保已设置 TF_LOG / TF_LOG_PATH）</div>';
    state.unread.stdout = 0;
    state.unread.event = 0;
    updateBadge("stdout");
    updateBadge("event");
  }

  function updateBadge(tab) {
    const badge = tab === "stdout" ? sel.badgeStdout : sel.badgeEvent;
    const n = state.unread[tab];
    if (n > 0) {
      badge.hidden = false;
      badge.textContent = n > 99 ? "99+" : String(n);
    } else {
      badge.hidden = true;
    }
  }

  function switchLogTab(tab) {
    if (tab !== "stdout" && tab !== "event") return;
    state.logTab = tab;
    sel.logTabs.querySelectorAll(".logtab").forEach((b) => {
      b.classList.toggle("active", b.dataset.tab === tab);
    });
    sel.logBoxStdout.hidden = tab !== "stdout";
    sel.logBoxEvent.hidden  = tab !== "event";
    // 进入该 Tab，清掉它的未读
    state.unread[tab] = 0;
    updateBadge(tab);
    // 自动滚动到底
    const box = tab === "stdout" ? sel.logBoxStdout : sel.logBoxEvent;
    if (sel.autoScroll.checked) box.scrollTop = box.scrollHeight;
  }

  /* ============ 工具 ============ */
  function escapeHtml(s) {
    return String(s == null ? "" : s)
      .replace(/&/g, "&amp;").replace(/</g, "&lt;")
      .replace(/>/g, "&gt;").replace(/"/g, "&quot;");
  }
  function truncate(s, n) {
    s = String(s || "");
    return s.length > n ? s.slice(0, n - 1) + "…" : s;
  }
  /**
   * 把 SVG <text> 节点 textNode 的内容 full 拟合到 maxWidth 像素内：
   *   - 若 full 渲染后即可放下 → 保持完整
   *   - 否则二分截断 + 末尾"…"
   */
  function fitTextToWidth(textNode, full, maxWidth) {
    if (!textNode || !full) return;
    textNode.textContent = full;
    if (textNode.getComputedTextLength() <= maxWidth) return;
    // 二分查找最长能容纳的子串
    let lo = 0, hi = full.length;
    while (lo < hi) {
      const mid = ((lo + hi + 1) >> 1);
      textNode.textContent = full.slice(0, mid) + "…";
      if (textNode.getComputedTextLength() <= maxWidth) lo = mid;
      else hi = mid - 1;
    }
    textNode.textContent = lo > 0 ? full.slice(0, lo) + "…" : "…";
  }
  function formatAgo(ts) {
    if (!ts) return "";
    const diff = Math.floor(Date.now() / 1000 - ts);
    if (diff < 0) return "";
    if (diff < 60) return `${diff}秒前`;
    if (diff < 3600) return `${Math.floor(diff / 60)}分钟前`;
    if (diff < 86400) return `${Math.floor(diff / 3600)}小时前`;
    return `${Math.floor(diff / 86400)}天前`;
  }

  /* ============ 事件绑定 ============ */
  sel.sessionSelect.addEventListener("change", (e) => selectSession(e.target.value));

  /* ··· 更多菜单 */
  const moreTrigger  = $("#moreTrigger");
  const moreDropdown = $("#moreDropdown");

  function toggleMoreMenu(force) {
    const next = force !== undefined ? force : moreDropdown.hidden;
    moreDropdown.hidden = !next;
  }

  moreTrigger.addEventListener("click", (e) => {
    e.stopPropagation();
    toggleMoreMenu();
  });

  document.addEventListener("click", (e) => {
    if (!moreDropdown.hidden && !$("#moreMenu").contains(e.target)) {
      toggleMoreMenu(false);
    }
  });

  // 点击菜单项后自动关闭
  moreDropdown.addEventListener("click", () => toggleMoreMenu(false));

  sel.refreshBtn.addEventListener("click", async () => {
    await loadSessions();
    if (state.currentSid) await loadGraph(state.currentSid);
  });

  sel.resetBtn.addEventListener("click", async () => {
    if (!state.currentSid) return;
    if (!confirm("确定清空当前会话的所有资源状态？")) return;
    await api(`/api/sessions/${state.currentSid}/states/reset`, { method: "POST" });
  });

  sel.deleteSessionBtn.addEventListener("click", async () => {
    if (!state.currentSid) return;
    const cur = state.sessions.find((x) => x.id === state.currentSid);
    const label = cur ? `${cur.name} (${cur.hostname || "?"})` : state.currentSid;
    if (!confirm(`确定删除会话「${label}」？\n该会话的图、状态与日志都会被清除。`)) return;
    await api(`/api/sessions/${state.currentSid}`, { method: "DELETE" });
    state.currentSid = null;
    await loadSessions();
  });

  sel.layoutSeg.addEventListener("click", (ev) => {
    const btn = ev.target.closest(".seg-btn");
    if (!btn) return;
    const layout = btn.dataset.layout;
    if (!layout || layout === state.layout) return;
    state.layout = layout;
    sel.layoutSeg.querySelectorAll(".seg-btn").forEach((b) =>
      b.classList.toggle("active", b === btn)
    );
    sel.dirSelect.disabled = layout !== "dagre";
    sel.dirSelect.style.opacity = layout === "dagre" ? "1" : "0.4";
    relayoutAndRender();
  });

  sel.dirSelect.addEventListener("change", (e) => {
    state.direction = e.target.value;
    if (state.layout === "dagre") relayoutAndRender({ force: true });
  });

  sel.relayoutBtn.addEventListener("click", () => {
    clearPositions();
    relayoutAndRender({ force: true });
  });

  // 资源列表搜索 + 点击
  sel.resourceSearch.addEventListener("input", (e) => {
    state.resourceFilter = e.target.value;
    renderResourceList();
  });

  sel.resourceList.addEventListener("click", (ev) => {
    const li = ev.target.closest(".resource-item");
    if (!li || !li.dataset.id) return;
    handleNodeClick(li.dataset.id, { center: true });
  });

  sel.logTabs.addEventListener("click", (ev) => {
    const btn = ev.target.closest(".logtab");
    if (!btn) return;
    switchLogTab(btn.dataset.tab);
  });

  window.addEventListener("resize", () => fitView(false));

  /* ============ 安装脚本弹窗 ============ */
  const installModal = document.getElementById("installModal");
  const installBtn = document.getElementById("installBtn");

  function getServerUrl() {
    return location.origin.replace(/\/$/, "");
  }

  /** 渲染弹窗中各代码块的内容（依据当前页面地址生成命令）。 */
  function renderInstallSnippets() {
    const server = getServerUrl();

    const quickCurl =
      `# 一键安装（curl，无需 Python；--exec-shell 让 tfgraph-agent 命令立即可用）\n` +
      `curl -fsSL ${server}/install.sh | bash -s -- ${server} --exec-shell`;

    const quickWget =
      `# 一键安装（wget）\n` +
      `wget -qO- ${server}/install.sh | bash -s -- ${server} --exec-shell`;

    const win =
      `# 下载并执行（PowerShell）\n` +
      `iwr ${server}/agent/install.ps1 -OutFile $env:TEMP\\install.ps1\n` +
      `powershell -ExecutionPolicy Bypass -File $env:TEMP\\install.ps1 -Server ${server}`;

    const winIrm =
      `# 单行（IRM | IEX）\n` +
      `$env:TFGRAPH_SERVER='${server}'; iwr ${server}/agent/install.ps1 | iex`;

    const manual =
      `# 1. 下载安装脚本\n` +
      `curl -fsSL ${server}/install.sh -o install.sh\n` +
      `# 2. 执行安装（推荐 source 启动，安装完自动在当前 shell 生效）\n` +
      `source install.sh ${server}\n` +
      `# 或：bash install.sh ${server} && source ~/.tfgraph/env`;

    const raw =
      `# 仅下载 Agent 主程序（shell 版）\n` +
      `mkdir -p ~/.tfgraph\n` +
      `curl -fsSL ${server}/agent/tfgraph-agent.sh -o ~/.tfgraph/tfgraph-agent.sh\n` +
      `chmod +x ~/.tfgraph/tfgraph-agent.sh\n` +
      `export TFGRAPH_SERVER=${server}\n` +
      `bash ~/.tfgraph/tfgraph-agent.sh ping`;

    const usage =
      `# === 1. 开启 terraform 日志（推荐 DEBUG，进"实时日志"卡片）===\n` +
      `# Linux/macOS\n` +
      `export TF_LOG=DEBUG\n` +
      `export TF_LOG_PATH=$HOME/.tfgraph/terraform.log\n` +
      `# Windows（PowerShell）\n` +
      `# $env:TF_LOG='DEBUG'\n` +
      `# $env:TF_LOG_PATH="$env:USERPROFILE\\.tfgraph\\terraform.log"\n\n` +
      `# === 2. 联通性检测 ===\n` +
      `tfgraph-agent ping\n\n` +
      `# === 3. 进入 terraform 项目目录，上传依赖图 ===\n` +
      `cd /path/to/your/tf-project\n` +
      `tfgraph-agent graph\n\n` +
      `# === 4. 启动后台守护：自动 tail $TF_LOG_PATH 进入"实时日志"卡片 ===\n` +
      `tfgraph-agent daemon-start\n` +
      `tfgraph-agent daemon-status\n\n` +
      `# === 5. 包裹执行命令，stdout/stderr 实时进入"控制台"卡片 ===\n` +
      `tfgraph-agent watch -- terraform plan\n` +
      `tfgraph-agent watch -- terraform apply\n\n` +
      `# === 其他 ===\n` +
      `# tail 别人正在写入的日志文件\n` +
      `tfgraph-agent tail /path/to/terraform.log\n` +
      `# 整体上传一份日志文件\n` +
      `tfgraph-agent upload-log /path/to/terraform.log\n` +
      `# 终端镜像 sub-shell（所有命令输出自动捕获）\n` +
      `tfgraph-agent shell`;

    setText("#codeQuick",     quickCurl);
    setText("#codeQuickWget", quickWget);
    setText("#codeWin",       win);
    setText("#codeWinIrm",    winIrm);
    setText("#codeManual",    manual);
    setText("#codeRaw",       raw);
    setText("#codeUsage",     usage);
  }

  function setText(selector, text) {
    const el = document.querySelector(selector);
    if (el) el.textContent = text;
  }

  function openInstallModal() {
    renderInstallSnippets();
    installModal.hidden = false;
    installModal.setAttribute("aria-hidden", "false");
    document.body.style.overflow = "hidden";
  }

  function closeInstallModal() {
    installModal.hidden = true;
    installModal.setAttribute("aria-hidden", "true");
    document.body.style.overflow = "";
  }

  installBtn.addEventListener("click", openInstallModal);

  installModal.addEventListener("click", (ev) => {
    if (ev.target.closest("[data-close]")) closeInstallModal();
  });

  document.addEventListener("keydown", (ev) => {
    if (ev.key === "Escape" && !installModal.hidden) closeInstallModal();
  });

  // Tab 切换
  installModal.querySelector("#installTabs").addEventListener("click", (ev) => {
    const btn = ev.target.closest(".modal-tab");
    if (!btn) return;
    const tab = btn.dataset.tab;
    installModal.querySelectorAll(".modal-tab").forEach((b) =>
      b.classList.toggle("active", b.dataset.tab === tab)
    );
    installModal.querySelectorAll(".modal-tab-pane").forEach((p) =>
      p.classList.toggle("active", p.dataset.tab === tab)
    );
  });

  // 复制按钮
  installModal.addEventListener("click", async (ev) => {
    const btn = ev.target.closest(".copy-btn");
    if (!btn) return;
    const target = document.querySelector(btn.dataset.copy);
    if (!target) return;
    const text = target.textContent || "";
    try {
      await navigator.clipboard.writeText(text);
    } catch {
      // 降级：用 textarea
      const ta = document.createElement("textarea");
      ta.value = text;
      ta.style.position = "fixed"; ta.style.left = "-9999px";
      document.body.appendChild(ta);
      ta.select();
      try { document.execCommand("copy"); } catch {}
      ta.remove();
    }
    const original = btn.textContent;
    btn.textContent = "已复制";
    btn.classList.add("copied");
    setTimeout(() => {
      btn.textContent = original;
      btn.classList.remove("copied");
    }, 1400);
  });

  /* ============ 响应式文字切换 ============ */
  function applyResponsiveText() {
    const vw = window.innerWidth;
    const isCompact = vw <= 780;   // 浮动工具栏压缩
    const isTiny    = vw <= 960;   // 顶栏压缩

    // 1. 顶栏 btn-adaptive：≤960 显示 data-icon，否则显示 data-label
    //    注意：包含 .btn-icon SVG 的按钮交给 CSS 控制，这里跳过
    document.querySelectorAll(".btn-adaptive[data-icon]").forEach((btn) => {
      if (btn.querySelector(".btn-icon")) return;
      btn.textContent = isTiny
        ? btn.dataset.icon
        : (btn.dataset.label || btn.dataset.icon);
    });

    // 2. 布局 seg-btn：≤780 显示 data-icon，否则显示 data-label
    document.querySelectorAll("#layoutSeg .seg-btn[data-icon]").forEach((btn) => {
      btn.textContent = isCompact
        ? btn.dataset.icon
        : (btn.dataset.label || btn.textContent);
    });

    // 3. 方向 select option：≤780 用 data-short 箭头符号
    document.querySelectorAll("#dirSelect option[data-short]").forEach((opt) => {
      opt.textContent = isCompact ? opt.dataset.short : opt.dataset.short; // 始终保持简洁
    });
    // dirSelect 本身宽度：≤780 不显示文字只显示箭头符号，用 title 提示全称
    sel.dirSelect && (sel.dirSelect.title = isCompact ? "分层方向" : "分层方向");

    // 4. 搜索框 placeholder：展开时整行宽度够用，始终保持完整文案
    const rs = document.getElementById("resourceSearch");
    if (rs) {
      rs.placeholder = rs.dataset.phFull || "筛选资源（type / name / module）...";
    }

    // 5. 统计标签：展开时空间足够，始终保持完整文字
    document.querySelectorAll(".stat-label[data-full]").forEach((el) => {
      el.textContent = el.dataset.full;
    });
  }

  /* ============ 可折叠面板 ============ */
  const COLLAPSE_BP = 680;       // ≤ 该宽度默认折叠（与纵向布局断点对齐）
  let _autoCollapsed = false;    // 是否处于"系统自动折叠"状态

  function _isMobile() { return window.innerWidth <= COLLAPSE_BP; }

  function setCollapsed(panel, collapsed) {
    panel.classList.toggle("collapsed", !!collapsed);
  }

  /** 大屏 ↔ 小屏切换时的 collapsed 状态同步：
   *  - 进入小屏：sidebar 内 panel 由 CSS 隐藏 body，collapsed 状态不再使用
   *  - 离开小屏：清除自动添加的 collapsed，恢复全部展开
   */
  function syncCollapsibleByViewport() {
    const collapsibles = document.querySelectorAll(".sidebar .collapsible, .node-detail-card.collapsible");
    if (!_isMobile() && _autoCollapsed) {
      collapsibles.forEach((p) => setCollapsed(p, false));
      _autoCollapsed = false;
    }
  }

  // 点击标题区域切换折叠 / 弹窗（小屏）
  document.addEventListener("click", (e) => {
    const head = e.target.closest(".collapsible .panel-head, .collapsible .logpane-head");
    if (!head) return;
    if (e.target.closest("#connStatus")) return;
    const panel = head.closest(".collapsible");
    if (!panel) return;

    // 小屏：sidebar 内的卡片用弹窗
    if (_isMobile() && panel.parentElement && panel.parentElement.classList.contains("sidebar")) {
      openPanelModal(panel);
      return;
    }

    // 大屏：保留原折叠/展开行为
    panel.classList.toggle("collapsed");
  });

  /* ---- 小屏 Panel 弹窗 ---- */
  let _panelModal = null;
  let _modalBorrow = null;   // { body, parent, nextSibling } 关闭时归还

  function _ensurePanelModal() {
    if (_panelModal) return _panelModal;
    _panelModal = document.createElement("div");
    _panelModal.className = "panel-modal";
    _panelModal.hidden = true;
    _panelModal.innerHTML = `
      <div class="panel-modal-mask" data-close></div>
      <div class="panel-modal-card" role="dialog" aria-modal="true">
        <div class="panel-modal-head">
          <h3 class="panel-modal-title"></h3>
          <button class="panel-modal-close" data-close aria-label="关闭">×</button>
        </div>
        <div class="panel-modal-body"></div>
      </div>
    `;
    document.body.appendChild(_panelModal);

    _panelModal.addEventListener("click", (ev) => {
      if (ev.target.closest("[data-close]")) closePanelModal();
    });
    return _panelModal;
  }

  function openPanelModal(panel) {
    const modal = _ensurePanelModal();
    const body  = panel.querySelector(":scope > .panel-body, :scope > .node-detail");
    if (!body) return;

    // 标题：取 head 内 h3 的纯文本（去掉箭头）
    const h3 = panel.querySelector(".panel-head h3, .logpane-head h3");
    const title = h3 ? h3.firstChild.textContent.trim() : "";
    modal.querySelector(".panel-modal-title").textContent = title;

    // 借走 body 到弹窗
    const parent = body.parentElement;
    const nextSibling = body.nextElementSibling;
    _modalBorrow = { body, parent, nextSibling };

    const slot = modal.querySelector(".panel-modal-body");
    slot.innerHTML = "";
    slot.appendChild(body);
    // 弹窗里需要展示 body（小屏 CSS 隐藏 sidebar 内的 panel-body，但弹窗里可见）
    body.style.display = "";

    modal.hidden = false;
    document.body.style.overflow = "hidden";
  }

  function closePanelModal() {
    if (!_panelModal || _panelModal.hidden) return;
    _panelModal.hidden = true;
    document.body.style.overflow = "";

    if (_modalBorrow) {
      const { body, parent, nextSibling } = _modalBorrow;
      body.style.display = "";  // 归还后由 CSS 在小屏下隐藏
      if (nextSibling) parent.insertBefore(body, nextSibling);
      else parent.appendChild(body);
      _modalBorrow = null;
    }
  }

  // ESC 关闭
  document.addEventListener("keydown", (ev) => {
    if (ev.key === "Escape" && _panelModal && !_panelModal.hidden) closePanelModal();
  });

  // 离开小屏时自动关闭弹窗
  window.addEventListener("resize", () => {
    if (!_isMobile()) closePanelModal();
  });

  /** 小屏纵向布局下，把"选中节点"卡片移到资源列表下方的 slot；
   *  回到大屏后还原回日志面板第一个位置。 */
  function syncNodeDetailLocation() {
    const card = document.querySelector(".node-detail-card");
    const slot = document.getElementById("nodeDetailSlot");
    const logpane = document.getElementById("logpane");
    if (!card || !slot || !logpane) return;

    if (_isMobile()) {
      // 移到资源列表后面（slot 之前）
      if (card.nextElementSibling !== slot) {
        slot.before(card);
      }
    } else {
      // 还原到 logpane 第一个子元素位置
      if (card.parentElement !== logpane || card !== logpane.firstElementChild) {
        logpane.prepend(card);
      }
    }
  }

  /* ============ 日志面板拖拽（自适应横向/纵向） ============ */
  (function initLogpaneResize() {
    const STORAGE_KEY_W = "tfgraph:logpane-width";
    const STORAGE_KEY_H = "tfgraph:logpane-height";
    const resizer = document.getElementById("logpaneResizer");
    const main    = document.querySelector(".main");

    const VERTICAL_BP = 680;   // ≤ 680 切换为上下堆叠

    function isVertical() { return window.innerWidth <= VERTICAL_BP; }
    function vwPct(pct) { return Math.round(window.innerWidth  * pct); }
    function vhPct(pct) { return Math.round(window.innerHeight * pct); }

    /* ----- 宽度（大屏） ----- */
    function minW()     { return vwPct(0.2); }
    function maxW()     { return vwPct(0.7); }
    function defaultW() { return vwPct(0.3) > 700 ? 720 : 360; }
    function applyWidth(w) {
      w = Math.min(maxW(), Math.max(minW(), w));
      main.style.setProperty("--logpane-w", `${w}px`);
    }

    /* ----- 高度（小屏纵向） ----- */
    function minH()     { return vhPct(0.2); }
    function maxH()     { return vhPct(0.7); }
    function defaultH() { return vhPct(0.38); }
    function applyHeight(h) {
      h = Math.min(maxH(), Math.max(minH(), h));
      main.style.setProperty("--logpane-h", `${h}px`);
    }

    /** 同步侧栏宽度变量（仅大屏生效） */
    function syncSidebarVar() {
      const vw = window.innerWidth;
      let sw;
      if (vw <= 680)       sw = 0;       // 纵向布局下未使用
      else if (vw <= 960)  sw = 180;
      else if (vw <= 1280) sw = 220;
      else                 sw = 280;
      main.style.setProperty("--sidebar-w", `${sw}px`);
    }

    // 初始化
    syncSidebarVar();
    try {
      const sw = parseInt(localStorage.getItem(STORAGE_KEY_W), 10);
      applyWidth(isNaN(sw) ? defaultW() : sw);
    } catch { applyWidth(defaultW()); }
    try {
      const sh = parseInt(localStorage.getItem(STORAGE_KEY_H), 10);
      applyHeight(isNaN(sh) ? defaultH() : sh);
    } catch { applyHeight(defaultH()); }

    // 窗口缩放：钳位、同步、文字适配、画布重适配
    window.addEventListener("resize", () => {
      syncSidebarVar();
      applyResponsiveText();
      syncCollapsibleByViewport();
      syncNodeDetailLocation();
      const curW = parseInt(getComputedStyle(main).getPropertyValue("--logpane-w"), 10);
      applyWidth(isNaN(curW) ? defaultW() : curW);
      const curH = parseInt(getComputedStyle(main).getPropertyValue("--logpane-h"), 10);
      applyHeight(isNaN(curH) ? defaultH() : curH);
      fitView(false);
    });

    resizer.addEventListener("mousedown", (e) => {
      e.preventDefault();
      const vertical = isVertical();
      resizer.classList.add("dragging");
      document.body.style.cursor = vertical ? "row-resize" : "col-resize";
      document.body.style.userSelect = "none";

      const startX = e.clientX;
      const startY = e.clientY;
      const startW = parseInt(getComputedStyle(main).getPropertyValue("--logpane-w"), 10) || defaultW();
      const startH = parseInt(getComputedStyle(main).getPropertyValue("--logpane-h"), 10) || defaultH();

      function onMove(ev) {
        if (vertical) {
          // 向上拖 → 日志区变高
          applyHeight(startH - (ev.clientY - startY));
        } else {
          // 向左拖 → 日志区变宽
          applyWidth(startW - (ev.clientX - startX));
        }
      }

      function onUp() {
        resizer.classList.remove("dragging");
        document.body.style.cursor = "";
        document.body.style.userSelect = "";
        document.removeEventListener("mousemove", onMove);
        document.removeEventListener("mouseup",   onUp);
        if (vertical) {
          const curH = parseInt(getComputedStyle(main).getPropertyValue("--logpane-h"), 10);
          try { localStorage.setItem(STORAGE_KEY_H, curH); } catch {}
        } else {
          const curW = parseInt(getComputedStyle(main).getPropertyValue("--logpane-w"), 10);
          try { localStorage.setItem(STORAGE_KEY_W, curW); } catch {}
        }
        fitView(false);
      }

      document.addEventListener("mousemove", onMove);
      document.addEventListener("mouseup",   onUp);
    });
  }());

  /* ============ 画布全屏切换 ============ */
  (function initFullscreen() {
    const btn = document.getElementById("fullscreenBtn");
    if (!btn) return;

    function isFs() { return document.body.classList.contains("is-graph-fs"); }

    function enter() {
      document.body.classList.add("is-graph-fs");
      // 尝试请求浏览器全屏（隐藏地址栏/状态栏，但失败也不影响 CSS 全屏）
      const root = document.documentElement;
      const req = root.requestFullscreen || root.webkitRequestFullscreen;
      if (req) req.call(root).catch(() => {});
      requestAnimationFrame(() => fitView(false));
    }

    function exit() {
      document.body.classList.remove("is-graph-fs");
      if (document.fullscreenElement || document.webkitFullscreenElement) {
        const ex = document.exitFullscreen || document.webkitExitFullscreen;
        if (ex) ex.call(document).catch(() => {});
      }
      requestAnimationFrame(() => fitView(false));
    }

    btn.addEventListener("click", () => (isFs() ? exit() : enter()));

    // 用户按 ESC 退出浏览器全屏时，同步去掉 body 类
    document.addEventListener("fullscreenchange", () => {
      if (!document.fullscreenElement && isFs()) {
        document.body.classList.remove("is-graph-fs");
        requestAnimationFrame(() => fitView(false));
      }
    });
  }());

  /* ============ 启动 ============ */
  renderNodeDetail(null);
  applyResponsiveText();
  syncCollapsibleByViewport();
  syncNodeDetailLocation();
  // 页面加载时默认未连接，主动展示常驻 tooltip
  _showTooltip(sel.connStatus);
  loadSessions().catch((e) => console.error(e));
})();
