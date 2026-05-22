#!/usr/bin/env bash
# tfgraph-agent —— Terraform 执行机端 Agent（纯 Shell 版）
#
# 依赖：bash >= 4 / curl / awk / sed / grep / tee
# 兼容：Linux、macOS（无需 Python）
#
# 子命令：
#   ping                       联通性检测
#   init   [--name X]          注册/更新会话
#   graph  [--name X]          执行 terraform graph 并上传
#   watch  [--name X] -- <cmd> 包裹执行命令并实时上报
#   tail   [--name X] <file>   tail 日志文件并实时上报
#   upload-log [--name X] <file>  整体上传日志文件
#   daemon-start [--name X]    启动后台守护：tail $TF_LOG_PATH 并上报
#   daemon-stop                停止后台守护
#   daemon-status              查看后台守护状态
#
# 环境变量：
#   TFGRAPH_SERVER     必填，例如 http://10.0.0.1:8000
#   TFGRAPH_NAME       默认会话名，未指定时取 $(basename "$PWD")
#   TFGRAPH_SESSION    指定会话 ID（默认按 hostname+name 自动派生）

set -u

# -------- 默认值 --------
SERVER="${TFGRAPH_SERVER:-}"
NAME="${TFGRAPH_NAME:-}"
SID_OVERRIDE="${TFGRAPH_SESSION:-}"
HOME_DIR="${TFGRAPH_HOME:-$HOME/.tfgraph}"
DAEMON_PID_FILE="$HOME_DIR/daemon.pid"

mkdir -p "$HOME_DIR"

# -------- 日志输出 --------
log()  { printf "[tfgraph] %s\n" "$*" >&2; }
err()  { printf "[tfgraph][ERROR] %s\n" "$*" >&2; }

# -------- 工具：派生稳定 sid --------
# 用 hostname + workdir 派生：同一台机器同一目录永远是同一会话，避免重名重复创建。
derive_sid() {
  local host
  host=$(hostname 2>/dev/null || echo unknown)
  printf '%s::%s' "$host" "$PWD" | _md5 | cut -c1-12
}

_md5() {
  if command -v md5sum >/dev/null 2>&1; then
    md5sum | awk '{print $1}'
  elif command -v md5 >/dev/null 2>&1; then
    md5
  else
    err "需要 md5sum 或 md5 命令"; exit 2
  fi
}

# -------- JSON 字符串转义 --------
# 输出符合 JSON 规范的字符串字面量（含两端引号）。处理：
#   反斜杠、双引号、\r \n \t \b \f、其他 0x00-0x1F 控制字符。
# 适合多行内容（如 terraform graph 输出）。
json_quote() {
  # 用环境变量传输入避免参数过长，用 awk 逐字节扫描以正确处理多行 + 控制字符
  __TFG_INPUT="$1" awk '
    function ord(c) { return _ord[c]; }
    BEGIN {
      for (i = 0; i < 256; i++) _ord[sprintf("%c", i)] = i;
      s = ENVIRON["__TFG_INPUT"];
      out = "\"";
      n = length(s);
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1);
        v = ord(c);
        if      (c == "\\") out = out "\\\\";
        else if (c == "\"") out = out "\\\"";
        else if (v == 8)    out = out "\\b";
        else if (v == 9)    out = out "\\t";
        else if (v == 10)   out = out "\\n";
        else if (v == 12)   out = out "\\f";
        else if (v == 13)   out = out "\\r";
        else if (v < 32)    out = out sprintf("\\u%04x", v);
        else                out = out c;
      }
      print out "\"";
    }
  '
}

# 兼容旧名字
json_str() { json_quote "$1"; }

# -------- HTTP --------
require_server() {
  if [[ -z "$SERVER" ]]; then
    err "未配置 \$TFGRAPH_SERVER（或在 ~/.tfgraph/env 中导出）"
    exit 2
  fi
}

http_get() {
  curl -sS --max-time 10 "$SERVER$1"
}

http_post() {
  curl -sS --max-time 10 -X POST -H "Content-Type: application/json" --data "$2" "$SERVER$1"
}

# -------- 会话注册 --------
ensure_session() {
  local name="$1"
  local sid="${SID_OVERRIDE:-$(derive_sid)}"
  local host workdir payload
  host=$(hostname 2>/dev/null || echo unknown)
  workdir="$PWD"
  payload=$(printf '{"id":"%s","name":%s,"hostname":%s,"workdir":%s}' \
              "$sid" "$(json_quote "$name")" "$(json_quote "$host")" "$(json_quote "$workdir")")
  http_post "/api/sessions" "$payload" >/dev/null
  log "会话已注册：sid=$sid  name=$name"
  printf '%s' "$sid"
}

# -------- 子命令实现 --------

cmd_ping() {
  require_server
  log "检测在线系统连通性： $SERVER"
  local body http_code body_no_status
  body=$(curl -sS -w '\nHTTPSTATUS:%{http_code}' --max-time 10 "$SERVER/api/ping") || { err "连接失败"; return 2; }
  http_code=$(printf '%s' "$body" | sed -n 's/^HTTPSTATUS://p' | tail -n1)
  body_no_status=$(printf '%s' "$body" | sed '$d')
  if [[ "$http_code" == "200" ]]; then
    log "OK  $body_no_status"
    return 0
  else
    err "HTTP $http_code"
    return 2
  fi
}

cmd_init() {
  require_server
  local name="${NAME:-$(basename "$PWD")}"
  ensure_session "$name"
  echo
}

cmd_logout() {
  require_server
  local sid="${SID_OVERRIDE:-$(derive_sid)}"

  # 1) 停止本地 daemon（如果在跑）
  if [[ -f "$DAEMON_PID_FILE" ]] && kill -0 "$(cat "$DAEMON_PID_FILE")" 2>/dev/null; then
    log "停止后台守护 ..."
    cmd_daemon_stop
  fi

  # 2) 清理本地 offset 状态文件
  local state_dir="$HOME_DIR/state"
  if [[ -d "$state_dir" ]]; then
    rm -f "$state_dir/$sid."* 2>/dev/null || true
    log "已清理本地状态文件"
  fi

  # 3) 向服务端发 DELETE 删除会话及所有数据（图、日志、状态）
  log "注销会话 sid=$sid ..."
  local resp
  resp=$(curl -sS --max-time 10 -X DELETE "$SERVER/api/sessions/$sid") || true
  log "OK  $resp"
  log "会话已注销，本地 daemon 已停止"
  log "若要重新注册，执行：tfgraph-agent init"
}

cmd_graph() {
  require_server
  local name="${NAME:-$(basename "$PWD")}"
  local sid; sid=$(ensure_session "$name")

  # 自动开启 terraform 调试日志（仅为本子进程注入；用户已设置则尊重）
  # 注意：用 ${VAR-} 而不是 $VAR，兼容 set -u / zsh nounset 下变量未导出的情况
  local tf_log tf_log_path
  tf_log="${TF_LOG:-DEBUG}"
  tf_log_path="${TF_LOG_PATH:-$PWD/terraform.log}"
  log "开启 terraform 日志：TF_LOG=$tf_log  TF_LOG_PATH=$tf_log_path"

  log "执行 terraform graph ..."
  local dot
  if ! dot=$(TF_LOG="$tf_log" TF_LOG_PATH="$tf_log_path" terraform graph 2>/dev/null); then
    err "terraform graph 失败（请确认在 terraform 项目目录下，且已 init）"
    return 2
  fi
  if [[ -z "$dot" ]]; then
    err "terraform graph 输出为空"
    return 2
  fi
  log "上传 DOT，长度 ${#dot} 字符 ..."
  local payload result
  payload=$(printf '{"dot":%s}' "$(json_quote "$dot")")
  result=$(http_post "/api/sessions/$sid/graph" "$payload")
  log "OK  $result"
  log "打开浏览器查看： $SERVER"
  if [[ -s "$tf_log_path" ]]; then
    log "调试日志已写入：$tf_log_path（可用：tfgraph-agent tail $tf_log_path 上报）"
  fi
}

# 批量上报多行（buf 是按 \n 分隔的字符串，每行作为单独 line）
# stream: stdout / stderr / file / event
report_lines_buf() {
  local sid="$1" stream="$2" buf="$3"
  [[ -z "$buf" ]] && return
  [[ "${TFGRAPH_TRACE:-0}" == "1" ]] && _trace "ENCODE_START" "bytes=${#buf}"
  local payload
  # 用 awk 构造 JSON 数组，复用 json_quote 的转义逻辑（对每一行调用）
  payload=$(__TFG_INPUT="$buf" __TFG_STREAM="$stream" awk '
    function json_escape(s,    out, n, i, c, v) {
      out = "\""; n = length(s);
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1); v = _ord[c];
        if      (c == "\\") out = out "\\\\";
        else if (c == "\"") out = out "\\\"";
        else if (v == 8)    out = out "\\b";
        else if (v == 9)    out = out "\\t";
        else if (v == 10)   out = out "\\n";
        else if (v == 12)   out = out "\\f";
        else if (v == 13)   out = out "\\r";
        else if (v < 32)    out = out sprintf("\\u%04x", v);
        else                out = out c;
      }
      return out "\"";
    }
    BEGIN {
      for (i = 0; i < 256; i++) _ord[sprintf("%c", i)] = i;
      stream = ENVIRON["__TFG_STREAM"];
      data   = ENVIRON["__TFG_INPUT"];
      n = split(data, lines, "\n");
      printf "{\"lines\":[";
      first = 1;
      for (i = 1; i <= n; i++) {
        if (lines[i] == "") continue;
        if (!first) printf ",";
        first = 0;
        printf "{\"stream\":\"%s\",\"line\":%s}", stream, json_escape(lines[i]);
      }
      printf "]}";
    }
  ')
  [[ "${TFGRAPH_TRACE:-0}" == "1" ]] && _trace "ENCODE_DONE" "payload_bytes=${#payload}"
  curl -sS --max-time 5 -X POST -H "Content-Type: application/json" \
       --data "$payload" "$SERVER/api/sessions/$sid/logs" >/dev/null 2>&1 &
  [[ "${TFGRAPH_TRACE:-0}" == "1" ]] && _trace "CURL_FORKED" "pid=$!"
  # 后台上报，立即返回，让下一批的累积不被网络延迟阻塞
}

# 单行上报（保留给少量场景用，比如 watch 的 event 标记行）
report_line() {
  local sid="$1" stream="$2" line="$3"
  [[ -z "$line" ]] && return
  report_lines_buf "$sid" "$stream" "$line"
}

# 批量上报（性能更好；line 用 \n 分隔）
report_lines_batch() {
  local sid="$1" stream="$2" file="$3"
  [[ ! -s "$file" ]] && return
  # 把文件每一行变成 JSON object
  local body
  body=$(awk -v s="$stream" '
    BEGIN { ORS=""; print "{\"lines\":[" }
    {
      gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); gsub(/\r/, ""); gsub(/\t/, "    ");
      if (NR > 1) print ",";
      printf "{\"stream\":\"%s\",\"line\":\"%s\"}", s, $0;
    }
    END { print "]}" }
  ' "$file")
  curl -sS --max-time 30 -X POST -H "Content-Type: application/json" \
       --data "$body" "$SERVER/api/sessions/$sid/logs" >/dev/null 2>&1 || true
}

cmd_watch() {
  require_server
  local name="${NAME:-$(basename "$PWD")}"
  local sid; sid=$(ensure_session "$name")

  if [[ $# -eq 0 ]]; then
    err "用法： tfgraph-agent watch -- <command...>"
    return 2
  fi

  log "开始执行并监控： $*"
  log "停止：命令执行完自动退出；或按 Ctrl+C 强制中断"

  # 用 script 伪终端包裹：子进程保留 tty（可交互输入），输出被同步录到镜像文件后上报。
  # 若 script 不可用，退化为管道模式（不能交互）。
  if command -v script >/dev/null 2>&1; then
    local mirror flag_file
    mirror=$(mktemp -t tfgraph-watch.XXXXXX)   || { err "无法创建镜像文件"; return 2; }
    flag_file=$(mktemp -t tfgraph-watch-flag.XXXXXX) || { rm -f "$mirror"; err "无法创建 flag 文件"; return 2; }
    export REPORTER_RUN_FLAG="$flag_file"

    # 后台 reporter：轮询读镜像文件 → 清洗 ANSI → 批量上报
    (
      local pos=0
      local buf=""
      while [[ -f "$REPORTER_RUN_FLAG" ]]; do
        local size; size=$(_file_size "$mirror"); size=${size:-0}
        if [[ "$size" -gt "$pos" ]]; then
          local chunk
          chunk=$(dd if="$mirror" bs=1 skip="$pos" count=$((size - pos)) 2>/dev/null \
                  | sed -E 's/\x1B\[[0-9;]*[mGKHfJ]//g' | sed 's/\r$//' \
                  | sed -E '/^Script (started|done)/d')
          pos=$size
          buf+="$chunk"
          if [[ "$buf" == *$'\n'* ]]; then
            local complete="${buf%$'\n'*}"$'\n'
            buf="${buf##*$'\n'}"
            [[ -n "$complete" ]] && report_lines_buf "$sid" "stdout" "$complete"
          fi
        fi
        sleep 0.2
      done
      [[ -n "$buf" ]] && report_lines_buf "$sid" "stdout" "$buf"$'\n'
    ) &
    local reporter_pid=$!

    local rc=0
    if [[ "$(uname -s)" == "Darwin" ]]; then
      script -q "$mirror" "$@" || rc=$?
    else
      script -q -f -c "$*" "$mirror" || rc=$?
    fi

    # 等 1 秒让 reporter 读完尾部
    sleep 1
    rm -f "$flag_file"
    wait "$reporter_pid" 2>/dev/null || true
    rm -f "$mirror"
  else
    # 退化模式：管道捕获输出（子进程不能交互）
    log "[WARN] 未找到 script 命令，退化为管道模式（交互输入不可用）"
    local rc=0
    set +e
    local STDBUF=""
    command -v stdbuf >/dev/null 2>&1 && STDBUF="stdbuf -oL -eL"
    $STDBUF "$@" 2>&1 | _buffered_report "$sid" "stdout"
    rc=${PIPESTATUS[0]}
    set -e
  fi

  report_line "$sid" "event" "--- 命令结束，退出码 $rc ---"
  log "完成，退出码 $rc"
  return "$rc"
}

# 从 stdin 逐行读取，攒成批后上报；满 N 行 OR 静默超时就 flush。
# 兼容性：bash 4+ 用 0.3s 超时 + 30 行批量；bash 3.x（macOS 自带）用 1s + 1 行（每行立即 flush）。
# TFGRAPH_TRACE=1 开启探针，会把每条消息的关键时间戳打印到 stderr，便于排查链路延迟。
_buffered_report() {
  local sid="$1" stream="$2"
  local buf="" cnt=0 rc=0
  local READ_TIMEOUT=1
  local MAX_LINES=1
  if (( BASH_VERSINFO[0] >= 4 )); then
    READ_TIMEOUT="0.3"
    MAX_LINES=30
  fi
  local TRACE="${TFGRAPH_TRACE:-0}"
  while true; do
    local line=""
    IFS= read -r -t "$READ_TIMEOUT" line
    rc=$?
    if [[ $rc -eq 0 ]]; then
      # 完整读到一行
      [[ "$TRACE" == "1" ]] && _trace "READ" "$line"
      printf '%s\n' "$line"
      buf+="$line"$'\n'
      cnt=$((cnt + 1))
      if [[ $cnt -ge $MAX_LINES ]]; then
        [[ "$TRACE" == "1" ]] && _trace "FLUSH(maxlines=$MAX_LINES)" "$cnt lines"
        report_lines_buf "$sid" "$stream" "$buf"
        [[ "$TRACE" == "1" ]] && _trace "POSTED" "$cnt lines"
        buf=""; cnt=0
      fi
    elif [[ $rc -gt 128 ]]; then
      # 超时：flush 已积累的
      if [[ $cnt -gt 0 ]]; then
        [[ "$TRACE" == "1" ]] && _trace "FLUSH(timeout=${READ_TIMEOUT}s)" "$cnt lines"
        report_lines_buf "$sid" "$stream" "$buf"
        [[ "$TRACE" == "1" ]] && _trace "POSTED" "$cnt lines"
        buf=""; cnt=0
      fi
    else
      # EOF（rc=1）：flush 收尾并退出
      [[ -n "$line" ]] && {
        printf '%s\n' "$line"
        buf+="$line"$'\n'
        cnt=$((cnt + 1))
      }
      [[ $cnt -gt 0 ]] && report_lines_buf "$sid" "$stream" "$buf"
      break
    fi
  done
}

cmd_tail() {
  require_server
  local name="${NAME:-$(basename "$PWD")}"
  local file=""
  local from_start=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --from-start) from_start=1; shift ;;
      *) file="$1"; shift ;;
    esac
  done
  if [[ -z "$file" ]]; then
    err "用法： tfgraph-agent tail [--from-start] <log_file>"
    return 2
  fi
  if [[ ! -f "$file" ]]; then
    err "日志文件不存在： $file"
    return 2
  fi
  local sid; sid=$(ensure_session "$name")

  # 偏移持久化：按 sid + 文件路径 hash 维护一个上次读到的字节偏移
  local state_dir="$HOME_DIR/state"
  mkdir -p "$state_dir"
  local key="${sid}.$(printf '%s' "$file" | _md5)"
  local state_file="$state_dir/$key.offset"

  # 决定起始位置（字节偏移）
  local start_offset=0
  local cur_size; cur_size=$(_file_size "$file")
  cur_size=${cur_size:-0}
  if [[ $from_start -eq 1 ]]; then
    start_offset=0
    log "开始 tail： $file（--from-start，从头读）"
  elif [[ -f "$state_file" ]]; then
    local saved; saved=$(cat "$state_file" 2>/dev/null || echo 0)
    if [[ "$saved" =~ ^[0-9]+$ ]] && [[ $saved -le $cur_size ]]; then
      start_offset=$saved
      log "开始 tail： $file（从持久化偏移 $start_offset/$cur_size 续读）"
    else
      start_offset=$cur_size
      log "开始 tail： $file（偏移异常，从尾部 $start_offset 开始）"
    fi
  else
    start_offset=$cur_size
    log "开始 tail： $file（首次，从尾部 $start_offset 开始）"
  fi
  log "停止：按 Ctrl+C"

  # 用 tail -F 做内核级文件变更跟随。优先级：
  #   1) gtail（macOS brew install coreutils）支持 -s 0.1 把轮询间隔降到 100ms
  #   2) GNU tail（Linux 默认）支持 -s 0.1
  #   3) BSD tail（macOS 自带）只能 1 秒轮询
  # `-c +N` 表示从第 N 个字节开始输出（1-based）。
  local byte_pos=$((start_offset + 1))
  local TAIL_BIN="tail"
  if command -v gtail >/dev/null 2>&1; then
    TAIL_BIN="gtail"
  fi
  local TAIL_OPTS=(-F -c +"$byte_pos")
  if "$TAIL_BIN" --help 2>&1 | grep -q -- '--sleep-interval' ; then
    TAIL_OPTS=(-F -s 0.1 -c +"$byte_pos")
  fi
  # 用 export 把上下文传给管道右侧的子 shell（pipeline 的 RHS 在 subshell 中执行）
  export __TFG_SID="$sid"
  export __TFG_STREAM="file"
  export __TFG_STATE="$state_file"
  export __TFG_START_OFFSET="$start_offset"
  export SERVER  # report_lines_buf 通过 $SERVER 调 curl
  export TFGRAPH_TRACE  # 让管道下游的 subshell 也能看到探针开关
  "$TAIL_BIN" "${TAIL_OPTS[@]}" "$file" 2>/dev/null | _stream_report
}

# 从 stdin 读取 tail 输出，按行批量上报，并按已读字节量持久化偏移。
# 通过环境变量接收上下文（避免函数签名爆炸）。
_stream_report() {
  local sid="${__TFG_SID:-}"
  local stream="${__TFG_STREAM:-file}"
  local state="${__TFG_STATE:-}"
  local offset="${__TFG_START_OFFSET:-0}"

  if [[ -z "$sid" ]]; then
    err "_stream_report: 缺少 __TFG_SID"
    return 2
  fi
  local buf="" cnt=0
  # 兼容性：bash 4+ 用 0.2s 超时 + 10 行批量；bash 3.x 用 1s + 1 行（即每行立即 flush）。
  local READ_TIMEOUT=1
  local MAX_LINES=1
  if (( BASH_VERSINFO[0] >= 4 )); then
    READ_TIMEOUT="0.2"
    MAX_LINES=10
  fi
  # 探针开关：TFGRAPH_TRACE=1 时把每条消息的关键时间戳打印到 stderr
  local TRACE="${TFGRAPH_TRACE:-0}"
  while true; do
    local line=""
    local rc=0
    IFS= read -r -t "$READ_TIMEOUT" line
    rc=$?
    if [[ $rc -eq 0 ]]; then
      [[ "$TRACE" == "1" ]] && _trace "READ" "$line"
      # 完整读到一行：累入 buffer。+1 是行尾换行符
      offset=$((offset + ${#line} + 1))
      if [[ -n "$line" ]]; then
        buf+="$line"$'\n'
        cnt=$((cnt + 1))
      fi
      if [[ $cnt -ge $MAX_LINES ]]; then
        [[ "$TRACE" == "1" ]] && _trace "FLUSH(maxlines=$MAX_LINES)" "$cnt lines"
        report_lines_buf "$sid" "$stream" "$buf"
        [[ "$TRACE" == "1" ]] && _trace "POSTED" "$cnt lines"
        [[ -n "$state" ]] && printf '%s' "$offset" > "$state" 2>/dev/null || true
        buf=""; cnt=0
      fi
    elif [[ $rc -gt 128 ]]; then
      # 静默超时：flush 已积累的
      if [[ $cnt -gt 0 ]]; then
        [[ "$TRACE" == "1" ]] && _trace "FLUSH(timeout=${READ_TIMEOUT}s)" "$cnt lines"
        report_lines_buf "$sid" "$stream" "$buf"
        [[ "$TRACE" == "1" ]] && _trace "POSTED" "$cnt lines"
        [[ -n "$state" ]] && printf '%s' "$offset" > "$state" 2>/dev/null || true
        buf=""; cnt=0
      fi
    else
      # EOF（rc=1）：通常意味着 tail 进程退出了
      [[ -n "$line" ]] && {
        offset=$((offset + ${#line} + 1))
        buf+="$line"$'\n'
        cnt=$((cnt + 1))
      }
      if [[ $cnt -gt 0 ]]; then
        report_lines_buf "$sid" "$stream" "$buf"
        [[ -n "$state" ]] && printf '%s' "$offset" > "$state" 2>/dev/null || true
      fi
      break
    fi
  done
}

_file_size() {
  if [[ "$(uname -s)" == "Darwin" ]]; then
    stat -f%z "$1" 2>/dev/null
  else
    stat -c%s "$1" 2>/dev/null
  fi
}

_now_ms() {
  if command -v perl >/dev/null 2>&1; then
    perl -MTime::HiRes=time -e 'printf "%d", time*1000'
  elif command -v gdate >/dev/null 2>&1; then
    gdate +%s%3N
  else
    local now; now=$(date +%s%3N 2>/dev/null)
    if [[ "$now" =~ ^[0-9]+$ ]]; then
      printf '%s' "$now"
    else
      # 兜底：秒级 *1000，精度 1s（稳定可用）
      printf '%s' $(( $(date +%s) * 1000 ))
    fi
  fi
}

# 探针：把时间戳和事件标签打到 stderr。
# 启用方法：TFGRAPH_TRACE=1 tfgraph-agent tail <file>
# 输出格式： [TRACE 1779432123456] READ      | aws_vpc.main: Creating...
_trace() {
  local label="$1"
  local detail="${2:-}"
  printf '[TRACE %s] %-26s | %s\n' "$(_now_ms)" "$label" "$detail" >&2
}

cmd_upload_log() {
  require_server
  local name="${NAME:-$(basename "$PWD")}"
  local file="$1"
  if [[ -z "${file:-}" || ! -f "$file" ]]; then
    err "用法： tfgraph-agent upload-log <log_file>"
    return 2
  fi
  local sid; sid=$(ensure_session "$name")
  log "上传 $file ..."
  # 切片每 200 行一批
  local total=0
  local tmpdir
  tmpdir=$(mktemp -d)
  split -l 200 "$file" "$tmpdir/chunk."
  for c in "$tmpdir"/chunk.*; do
    report_lines_batch "$sid" "file" "$c"
    total=$((total + $(wc -l < "$c")))
    log "  已上传 $total 行"
  done
  rm -rf "$tmpdir"
  log "完成"
}

# -------- 守护进程 --------

cmd_daemon_start() {
  require_server
  local name="${NAME:-$(basename "$PWD")}"
  local logpath="${TF_LOG_PATH:-$HOME_DIR/terraform.log}"

  if [[ -f "$DAEMON_PID_FILE" ]] && kill -0 "$(cat "$DAEMON_PID_FILE")" 2>/dev/null; then
    log "守护已在运行（pid=$(cat "$DAEMON_PID_FILE")）"
    return 0
  fi

  # 确保日志文件存在（terraform 第一次跑时会写入）
  : > "$logpath" 2>/dev/null || true

  log "启动后台守护：tail $logpath -> $SERVER"
  # nohup 后台启动 tail；用一个子 shell 包裹
  nohup bash -c "
    export TFGRAPH_SERVER='$SERVER'
    export TFGRAPH_NAME='$name'
    \"$0\" tail '$logpath'
  " >>"$HOME_DIR/daemon.log" 2>&1 &
  echo $! > "$DAEMON_PID_FILE"
  log "守护已启动 pid=$(cat "$DAEMON_PID_FILE")  日志：$HOME_DIR/daemon.log"
}

cmd_daemon_stop() {
  if [[ ! -f "$DAEMON_PID_FILE" ]]; then
    log "守护未在运行"
    return 0
  fi
  local pid; pid=$(cat "$DAEMON_PID_FILE")
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    sleep 0.3
    kill -9 "$pid" 2>/dev/null || true
    log "已停止守护 pid=$pid"
  fi
  rm -f "$DAEMON_PID_FILE"
}

cmd_daemon_status() {
  if [[ -f "$DAEMON_PID_FILE" ]] && kill -0 "$(cat "$DAEMON_PID_FILE")" 2>/dev/null; then
    log "守护运行中  pid=$(cat "$DAEMON_PID_FILE")"
  else
    log "守护未运行"
  fi
}

# -------- 终端镜像（推荐用法：监控终端而非包裹执行） --------
# 进入一个被 `script` 录制的 sub-shell，所有命令的输出（含 stdout/stderr）
# 会被自动捕获并实时上报。用户在 sub-shell 里直接敲 terraform plan/apply 即可。
# 退出 sub-shell 即停止录制。
cmd_shell() {
  require_server
  local name="${NAME:-$(basename "$PWD")}"
  local sid; sid=$(ensure_session "$name")

  if ! command -v script >/dev/null 2>&1; then
    err "未找到 \`script\` 命令，无法启动终端镜像"
    return 2
  fi

  local mirror
  mirror=$(mktemp -t tfgraph-shell.XXXXXX) || { err "无法创建镜像文件"; return 2; }

  # RUN_FLAG：用文件存在性作为 reporter 的退出标记，避开后台 subshell 内
  # 看不到外层 local 变量更新的问题；外层 rm 掉它，reporter 自然退出。
  local REPORTER_RUN_FLAG
  REPORTER_RUN_FLAG=$(mktemp -t tfgraph-shell-flag.XXXXXX) || { err "无法创建 flag 文件"; rm -f "$mirror"; return 2; }
  export REPORTER_RUN_FLAG

  log "启动终端镜像：所有命令输出都会被上报到 $SERVER"
  log "停止：在 sub-shell 里执行 exit，或按 Ctrl-D"
  log "退出 sub-shell（exit / Ctrl-D）即停止录制"
  log "镜像文件：$mirror"
  echo

  # 后台 reporter：自己实现轮询读 mirror —— 比 `tail -F | _stream_report`
  # 更稳定（避开 BSD tail 的缓冲怪相和管道孤儿进程问题），关闭时也容易清理。
  # 用 dd bs=1 count=N 逐字节读取偏移之后的内容，每 0.2s 一轮。
  (
    [[ "${TFGRAPH_TRACE:-0}" == "1" ]] && _trace "SHELL_REPORTER" "starting on $mirror"
    local pos=0
    local buf=""
    while [[ -f "$REPORTER_RUN_FLAG" ]]; do
      local size; size=$(_file_size "$mirror")
      size=${size:-0}
      if [[ "$size" -gt "$pos" ]]; then
        # 新增字节：读出来，剥 ANSI / 跳过 script 元信息
        local chunk
        chunk=$(dd if="$mirror" bs=1 skip="$pos" count=$((size - pos)) 2>/dev/null \
                | sed -E 's/\x1B\[[0-9;]*[mGKHfJ]//g' \
                | sed 's/\r$//' \
                | sed -E '/^Script (started|done)/d')
        pos=$size
        buf+="$chunk"
        # 按 \n 切，行不完整的留到下一轮
        if [[ "$buf" == *$'\n'* ]]; then
          local complete="${buf%$'\n'*}"$'\n'
          buf="${buf##*$'\n'}"
          [[ -n "$complete" ]] && {
            [[ "${TFGRAPH_TRACE:-0}" == "1" ]] && _trace "SHELL_REPORTER" "flush ${#complete} bytes"
            report_lines_buf "$sid" "stdout" "$complete"
          }
        fi
      fi
      sleep 0.2
    done
    # 收尾：把残留（不带换行的最后一行）也发出去
    [[ -n "$buf" ]] && report_lines_buf "$sid" "stdout" "$buf"$'\n'
  ) &
  local reporter_pid=$!

  local user_shell="${SHELL:-/bin/bash}"
  # macOS/BSD：script -q <file> <command>
  # Linux util-linux：script -q -f <file> -c <command>
  if [[ "$(uname -s)" == "Darwin" ]]; then
    TFGRAPH_IN_SHELL=1 script -q "$mirror" "$user_shell" -i || true
  else
    TFGRAPH_IN_SHELL=1 script -qf -c "$user_shell -i" "$mirror" || true
  fi

  # sub-shell 退出后 `script` 会把残留 buffer flush 到 mirror，
  # 等 1 秒让 reporter 跑完最后一轮轮询，再撤掉 RUN_FLAG 让它优雅退出。
  sleep 1
  rm -f "$REPORTER_RUN_FLAG"
  wait "$reporter_pid" 2>/dev/null || true
  rm -f "$mirror"
  log "已退出终端镜像"
}

# -------- 参数解析（支持 --name/--server/--sid 在任意位置） --------
ARGS=()
SUBCMD=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --server)  SERVER="$2"; shift 2 ;;
    --name)    NAME="$2";   shift 2 ;;
    --sid)     SID_OVERRIDE="$2"; shift 2 ;;
    --help|-h) SUBCMD="help"; shift ;;
    --) shift; while [[ $# -gt 0 ]]; do ARGS+=("$1"); shift; done; break ;;
    *)
      if [[ -z "$SUBCMD" ]]; then
        SUBCMD="$1"; shift
      else
        ARGS+=("$1"); shift
      fi
      ;;
  esac
done

case "$SUBCMD" in
  ping)         cmd_ping ;;
  init)         cmd_init ;;
  logout)       cmd_logout ;;
  graph)        cmd_graph ;;
  watch)        cmd_watch "${ARGS[@]}" ;;
  tail)         cmd_tail "${ARGS[@]}" ;;
  upload-log)   cmd_upload_log "${ARGS[@]:-}" ;;
  daemon-start) cmd_daemon_start ;;
  daemon-stop)  cmd_daemon_stop ;;
  daemon-status) cmd_daemon_status ;;
  shell)        cmd_shell ;;
  help|"")
    cat <<EOF
tfgraph-agent —— Terraform Graph 在线系统的执行机 Agent（纯 Shell 版）

用法：
  tfgraph-agent <子命令> [选项]

推荐流程（监控终端，无需包裹执行）：
  1) tfgraph-agent ping                 # 联通性检测
  2) tfgraph-agent graph                # 上传依赖图（terraform graph）
  3) tfgraph-agent shell                # 进入终端镜像，正常敲 terraform plan/apply
                                        # 所有终端输出会自动上报，退出即停止

子命令：
  shell                 进入终端镜像 sub-shell：所有终端输出自动上报【推荐】
  ping                  联通性检测
  init                  注册/更新会话
  logout                注销当前会话（停止 daemon + 删除服务端数据）
  graph                 执行 terraform graph 并上传依赖图
  watch -- <cmd...>     包裹执行命令并实时上报输出（已知命令时使用）
  tail [--from-start] <file>  tail 一份日志文件并实时上报
  upload-log <file>     整体上传一份日志文件
  daemon-start          启动后台守护：tail \$TF_LOG_PATH 并上报
  daemon-stop           停止后台守护
  daemon-status         查看守护状态

如何停止：
  shell         在 sub-shell 里执行 exit，或按 Ctrl-D
  watch         命令执行完自动退出；或按 Ctrl+C 强制中断
  tail          按 Ctrl+C
  daemon        tfgraph-agent daemon-stop

全局选项：
  --server URL          覆盖 \$TFGRAPH_SERVER
  --name NAME           会话名，默认取当前目录名
  --sid SID             指定会话 ID（默认按 hostname+workdir 派生）

环境变量：
  TFGRAPH_SERVER        在线系统地址
  TFGRAPH_NAME          默认会话名
  TFGRAPH_TRACE=1       打开链路探针，把时间戳输出到 stderr
  TF_LOG, TF_LOG_PATH   被守护进程读取
EOF
    ;;
  *)
    err "未知子命令：$SUBCMD"
    exit 2
    ;;
esac
