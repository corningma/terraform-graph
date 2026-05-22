#!/usr/bin/env bash
# tfgraph-agent 一键安装脚本（纯 Shell 版，无需 Python）
#
# 用法：
#   bash install.sh <SERVER_URL>                  # 普通安装；安装完会提示 source 命令
#   bash install.sh <SERVER_URL> --exec-shell     # 安装完用 exec $SHELL 替换当前终端，立即生效
#   source install.sh <SERVER_URL>                # 直接 source 启动；安装完自动在当前 shell 生效
#   curl -fsSL http://<server>/install.sh | bash -s -- http://<server>
#
#   bash install.sh --uninstall                   # 卸载：删除所有 tfgraph 相关数据
#
# 注意：
#   `bash install.sh` 是子进程，无法修改父 shell 的环境变量。要让 tfgraph-agent
#   命令"立即可用"，请用 `source install.sh` 或加上 `--exec-shell`。

# 检测当前是被 source 还是 bash 直接执行
# - bash:  $0 == .../install.sh，BASH_SOURCE[0] != "" 且 BASH_SOURCE[0] == $0 时为直接执行；不等时为 source
# - zsh:   没有 BASH_SOURCE；用 $ZSH_EVAL_CONTEXT 判断（包含 :file 时为 source）
_TFG_SOURCED=0
if [[ -n "${ZSH_VERSION:-}" ]]; then
  case "${ZSH_EVAL_CONTEXT:-}" in
    *:file:*|*:file) _TFG_SOURCED=1 ;;
  esac
elif [[ -n "${BASH_SOURCE[0]:-}" && "${BASH_SOURCE[0]}" != "$0" ]]; then
  _TFG_SOURCED=1
fi

# 注意：被 source 时不能开 `set -euo pipefail`，否则会污染调用方 shell；
# 改为函数内显式判断错误码。
if [[ $_TFG_SOURCED -eq 0 ]]; then
  set -euo pipefail
fi

# 解析参数
SERVER=""
EXEC_SHELL_AFTER=0
DO_UNINSTALL=0
for arg in "$@"; do
  case "$arg" in
    --exec-shell) EXEC_SHELL_AFTER=1 ;;
    --uninstall|uninstall) DO_UNINSTALL=1 ;;
    -h|--help)
      echo "用法： bash install.sh <SERVER_URL> [--exec-shell]"
      echo "或：   source install.sh <SERVER_URL>"
      echo "卸载： bash install.sh --uninstall"
      [[ $_TFG_SOURCED -eq 1 ]] && return 0 || exit 0
      ;;
    *)
      [[ -z "$SERVER" ]] && SERVER="$arg"
      ;;
  esac
done

# 出错退出工具：source 模式用 return，bash 模式用 exit，避免 source 时把用户的 shell 杀掉
_tfg_die() {
  local code="${1:-2}"
  [[ $_TFG_SOURCED -eq 1 ]] && return "$code" || exit "$code"
}

INSTALL_DIR="${TFGRAPH_HOME:-$HOME/.tfgraph}"
BIN_DIR="${TFGRAPH_BIN:-$HOME/.local/bin}"

# ============================================================
# 卸载逻辑
# ============================================================
do_uninstall() {
  echo "[tfgraph] 开始卸载 ..."
  echo "[tfgraph] 安装目录: ${INSTALL_DIR}"
  echo "[tfgraph] 命令目录: ${BIN_DIR}"

  # 1) 优雅停止后台守护
  if [[ -x "${BIN_DIR}/tfgraph-agent" ]]; then
    echo "[tfgraph] 停止后台守护 ..."
    "${BIN_DIR}/tfgraph-agent" daemon-stop >/dev/null 2>&1 || true
  elif [[ -f "${INSTALL_DIR}/tfgraph-agent.sh" ]]; then
    bash "${INSTALL_DIR}/tfgraph-agent.sh" daemon-stop >/dev/null 2>&1 || true
  fi

  # 2) 兜底 1：按 pid 文件杀进程组
  if [[ -f "${INSTALL_DIR}/daemon.pid" ]]; then
    local _pid
    _pid="$(cat "${INSTALL_DIR}/daemon.pid" 2>/dev/null || true)"
    if [[ -n "${_pid}" ]] && kill -0 "${_pid}" 2>/dev/null; then
      # 先尝试杀整个进程组（负数 PID），覆盖 nohup bash -c 派生出来的 tail / curl 等子进程
      kill -TERM "-${_pid}" 2>/dev/null || kill -TERM "${_pid}" 2>/dev/null || true
      sleep 0.3
      kill -KILL "-${_pid}" 2>/dev/null || kill -KILL "${_pid}" 2>/dev/null || true
    fi
  fi

  # 3) 兜底 2：按命令行特征清理所有 tfgraph-agent 相关进程
  # 覆盖：daemon (nohup bash -c "... tail ..."), shell (script + reporter),
  #       watch (_buffered_report), 残留的 tail -F / gtail 上报管道、上报中的 curl 等。
  echo "[tfgraph] 清理 tfgraph-agent 相关残留进程 ..."
  local _self_pid=$$
  local _patterns=(
    "${INSTALL_DIR}/tfgraph-agent.sh"
    "${BIN_DIR}/tfgraph-agent"
    "tfgraph-agent"
    "TFGRAPH_SERVER="
    "tfgraph-shell\\."
  )
  _kill_by_pattern() {
    local pattern="$1" sig="$2"
    local pids=""
    if command -v pgrep >/dev/null 2>&1; then
      # -f 全命令行匹配
      pids="$(pgrep -f "$pattern" 2>/dev/null || true)"
    else
      pids="$(ps -A -o pid=,command= 2>/dev/null | awk -v pat="$pattern" '$0 ~ pat {print $1}' || true)"
    fi
    for p in $pids; do
      # 跳过自己 / 父进程链（避免 source 模式自杀）
      [[ "$p" == "$_self_pid" ]] && continue
      [[ "$p" == "$PPID" ]] && continue
      kill -0 "$p" 2>/dev/null || continue
      kill "-${sig}" "$p" 2>/dev/null || true
    done
  }
  for pat in "${_patterns[@]}"; do
    _kill_by_pattern "$pat" TERM
  done
  sleep 0.3
  for pat in "${_patterns[@]}"; do
    _kill_by_pattern "$pat" KILL
  done

  # 4) 删除 wrapper 命令
  if [[ -f "${BIN_DIR}/tfgraph-agent" ]]; then
    rm -f "${BIN_DIR}/tfgraph-agent"
    echo "[tfgraph] 已删除命令: ${BIN_DIR}/tfgraph-agent"
  fi

  # 5) 删除安装目录（含 agent 脚本、env、daemon.pid/log、terraform.log 等所有数据）
  if [[ -d "${INSTALL_DIR}" ]]; then
    rm -rf "${INSTALL_DIR}"
    echo "[tfgraph] 已删除目录: ${INSTALL_DIR}"
  fi

  # 6) 清理 /tmp 下 shell 镜像残留（cmd_shell 用 mktemp -t tfgraph-shell.* 创建）
  rm -f /tmp/tfgraph-shell.* 2>/dev/null || true
  rm -f /tmp/tfgraph-shell-flag.* 2>/dev/null || true

  # 7) 从 shell 启动文件中移除注入块
  remove_source_block() {
    local rcfile="$1"
    [[ -f "$rcfile" ]] || return 0
    if grep -q 'tfgraph/env\|# tfgraph-agent' "$rcfile" 2>/dev/null; then
      # 删除 "# tfgraph-agent" 注释行 + 紧随其后的 source 行；
      # 同时兜底删除任何包含 tfgraph/env 的行；并清理产生的连续空行
      local tmp
      tmp="$(mktemp 2>/dev/null || mktemp -t tfgraph)"
      awk '
        BEGIN { skip = 0 }
        {
          if (skip > 0) { skip--; next }
          if ($0 ~ /^[[:space:]]*#[[:space:]]*tfgraph-agent[[:space:]]*$/) { skip = 1; next }
          if ($0 ~ /tfgraph\/env/) { next }
          print
        }
      ' "$rcfile" > "$tmp" && mv "$tmp" "$rcfile"
      echo "[tfgraph]   已清理: ${rcfile}"
    fi
  }
  echo "[tfgraph] 清理 shell 启动文件 ..."
  remove_source_block "$HOME/.bashrc"
  remove_source_block "$HOME/.zshrc"
  remove_source_block "$HOME/.bash_profile"

  cat <<EOM

================================================================
tfgraph-agent 已卸载完成。

提示：当前 shell 中已 export 的环境变量（TFGRAPH_SERVER / TF_LOG /
TF_LOG_PATH / PATH 等）和 alias terraform 仍残留在当前进程中，
重新打开终端即可彻底清除。
================================================================
EOM
}

if [[ $DO_UNINSTALL -eq 1 ]]; then
  do_uninstall
  [[ $_TFG_SOURCED -eq 1 ]] && return 0 || exit 0
fi

# ============================================================
# 安装：到这里才需要 SERVER
# ============================================================
SERVER="${SERVER:-${TFGRAPH_SERVER:-}}"
if [[ -z "${SERVER}" ]]; then
  echo "用法： bash install.sh <SERVER_URL> [--exec-shell]" >&2
  echo "或：   bash install.sh --uninstall" >&2
  echo "例：  bash install.sh http://10.0.0.1:8000" >&2
  [[ $_TFG_SOURCED -eq 1 ]] && return 1 || exit 1
fi
SERVER="${SERVER%/}"

echo "[tfgraph] 安装目录: ${INSTALL_DIR}"
echo "[tfgraph] 命令目录: ${BIN_DIR}"
echo "[tfgraph] 在线系统: ${SERVER}"

mkdir -p "${INSTALL_DIR}" "${BIN_DIR}"

# 1) 必要工具检查
for tool in curl bash awk sed grep tail; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "[tfgraph][ERROR] 缺少必要工具: $tool" >&2
    _tfg_die 2
  fi
done

# 2) 下载 Agent 主程序（shell 版）
echo "[tfgraph] 下载 tfgraph-agent.sh ..."
if command -v curl >/dev/null 2>&1; then
  curl -fsSL "${SERVER}/agent/tfgraph-agent.sh" -o "${INSTALL_DIR}/tfgraph-agent.sh"
elif command -v wget >/dev/null 2>&1; then
  wget -q "${SERVER}/agent/tfgraph-agent.sh" -O "${INSTALL_DIR}/tfgraph-agent.sh"
else
  echo "[tfgraph][ERROR] 需要 curl 或 wget。" >&2
  _tfg_die 2
fi
chmod +x "${INSTALL_DIR}/tfgraph-agent.sh"

# 3) 写入 wrapper 命令到 BIN_DIR
cat > "${BIN_DIR}/tfgraph-agent" <<EOF
#!/usr/bin/env bash
export TFGRAPH_SERVER="\${TFGRAPH_SERVER:-${SERVER}}"
exec bash "${INSTALL_DIR}/tfgraph-agent.sh" "\$@"
EOF
chmod +x "${BIN_DIR}/tfgraph-agent"

# 4) 写一份默认环境配置（含 terraform 命令包装）
cat > "${INSTALL_DIR}/env" <<EOF
# ===== tfgraph-agent 环境配置 =====
# 在线系统地址
export TFGRAPH_SERVER="${SERVER}"

# 加入 PATH
case ":\$PATH:" in
  *":${BIN_DIR}:"*) ;;
  *) export PATH="${BIN_DIR}:\$PATH" ;;
esac

# 让 terraform 默认写一份日志文件，供 daemon tail
# TF_LOG 取值：TRACE / DEBUG / INFO / WARN / ERROR
export TF_LOG="\${TF_LOG:-DEBUG}"
export TF_LOG_PATH="\${TF_LOG_PATH:-${INSTALL_DIR}/terraform.log}"

# terraform 命令包装：自动用 tfgraph-agent watch 包裹 plan/apply 等
# 这样你直接敲 \`terraform plan\` 也能自动捕获 + 上报 stdout/stderr
if command -v terraform >/dev/null 2>&1; then
  _tfgraph_wrap_terraform() {
    local sub="\${1:-}"
    case "\$sub" in
      plan|apply|destroy|refresh|import)
        # 包裹执行
        command tfgraph-agent watch -- terraform "\$@"
        ;;
      *)
        command terraform "\$@"
        ;;
    esac
  }
  alias terraform='_tfgraph_wrap_terraform'
fi
EOF

# 5) 自动 source 到用户 shell 启动文件（去重 + 写入失败时 fallback）
# inject_source 行为：
#   - 文件存在且可写：追加注入块
#   - 文件存在但不可写（如 root 拥有的 .zshrc）：跳过并打印警告
#   - 文件不存在：跳过（除非传 create=1，会创建一个空文件再注入）
inject_source() {
  local rcfile="$1"
  local create="${2:-0}"
  if [[ ! -e "$rcfile" ]]; then
    if [[ "$create" -eq 1 ]]; then
      : > "$rcfile" 2>/dev/null || { echo "[tfgraph][WARN] 无法创建 ${rcfile}"; return 1; }
    else
      return 0
    fi
  fi
  if [[ ! -w "$rcfile" ]]; then
    echo "[tfgraph][WARN] ${rcfile} 不可写（owner=$(stat -f '%Su' "$rcfile" 2>/dev/null || stat -c '%U' "$rcfile" 2>/dev/null)），跳过注入"
    return 1
  fi
  if grep -q 'tfgraph/env' "$rcfile" 2>/dev/null; then
    return 0   # 已注入
  fi
  {
    echo ""
    echo "# tfgraph-agent"
    echo "[ -f ${INSTALL_DIR}/env ] && source ${INSTALL_DIR}/env"
  } >> "$rcfile" || { echo "[tfgraph][WARN] 写入 ${rcfile} 失败"; return 1; }
  echo "[tfgraph]   已写入 ${rcfile}"
  return 0
}

echo "[tfgraph] 注入 shell 启动文件 ..."
# 检测当前用户的默认 shell，挑选**至少一个可写**的 rc 文件确保命令注入成功
_injected=0
_user_shell="${SHELL:-/bin/bash}"
case "$_user_shell" in
  *zsh*)
    # zsh 加载顺序：交互登录 → .zprofile + .zshrc；交互非登录 → .zshrc
    # 如果 .zshrc 不可写（macOS 上有时被 root 拥有），fallback 到 .zprofile
    inject_source "$HOME/.zshrc"    && _injected=1
    inject_source "$HOME/.zprofile" 1 && _injected=1
    ;;
  *bash*)
    # bash 加载顺序：交互登录 → .bash_profile / .profile / .bashrc；
    # 交互非登录 → .bashrc。两者都注入以兼容。
    inject_source "$HOME/.bashrc"      1 && _injected=1
    inject_source "$HOME/.bash_profile" 1 && _injected=1
    ;;
  *)
    # 兜底：尽可能注入到所有常见 rc
    inject_source "$HOME/.bashrc"
    inject_source "$HOME/.bash_profile"
    inject_source "$HOME/.zshrc"
    inject_source "$HOME/.zprofile" 1 && _injected=1
    ;;
esac

if [[ $_injected -eq 0 ]]; then
  echo "[tfgraph][WARN] 未能写入任何 shell 启动文件！请手动在你的 rc 里加："
  echo "      [ -f ${INSTALL_DIR}/env ] && source ${INSTALL_DIR}/env"
fi

# 6) 联通性检测
echo "[tfgraph] 联通性检测 ..."
if "${BIN_DIR}/tfgraph-agent" ping; then
  echo "[tfgraph] 联通性检测通过。"
else
  echo "[tfgraph][WARN] 联通性检测失败，但 Agent 已安装。"
fi

# 7) 启动后台守护（tail $TF_LOG_PATH 并上报，默认开启）
TF_LOG_PATH_DEFAULT="${INSTALL_DIR}/terraform.log"
echo "[tfgraph] 启动后台守护（自动监听 terraform 日志） ..."
# 确保日志文件存在，否则首次 daemon 会等不到文件
: > "${TF_LOG_PATH_DEFAULT}" 2>/dev/null || true
if TFGRAPH_SERVER="${SERVER}" TF_LOG_PATH="${TF_LOG_PATH_DEFAULT}" \
     "${BIN_DIR}/tfgraph-agent" daemon-start; then
  echo "[tfgraph] 后台守护已启动。"
else
  echo "[tfgraph][WARN] 后台守护启动失败，可稍后手动执行： tfgraph-agent daemon-start"
fi

# 8) 如果当前目录像是一个 terraform 项目（含 *.tf），自动执行一次 graph
if compgen -G "*.tf" >/dev/null 2>&1; then
  echo "[tfgraph] 检测到当前目录是 terraform 项目，自动执行 tfgraph-agent graph ..."
  if TFGRAPH_SERVER="${SERVER}" "${BIN_DIR}/tfgraph-agent" graph; then
    echo "[tfgraph] 依赖图已上传。"
  else
    echo "[tfgraph][WARN] graph 上传失败（可能项目尚未 terraform init）。安装后手动执行： tfgraph-agent graph"
  fi
else
  echo "[tfgraph] 当前目录不是 terraform 项目，跳过自动 graph。"
  echo "[tfgraph] 进入 terraform 项目目录后执行： tfgraph-agent graph"
fi

cat <<EOM

================================================================
tfgraph-agent 安装完成。

快速上手：
  tfgraph-agent ping          # 联通性检测
  tfgraph-agent graph         # 上传依赖图
  tfgraph-agent shell         # 进入终端镜像，直接敲 terraform 命令

打开浏览器查看：${SERVER}

如需卸载：
  bash install.sh --uninstall
================================================================
EOM

# 9) 自动让配置在当前终端生效
if [[ $_TFG_SOURCED -eq 1 ]]; then
  # source 模式：直接把 env 注入到调用方 shell
  # shellcheck source=/dev/null
  source "${INSTALL_DIR}/env"
  echo "[tfgraph] 已在当前 shell 生效（source 模式）。直接执行： tfgraph-agent ping"
elif [[ $EXEC_SHELL_AFTER -eq 1 ]]; then
  # exec-shell 模式：用用户默认 shell 替换当前进程，下一次启动会自动 source 我们注入的 rc
  user_shell="${SHELL:-/bin/bash}"
  echo "[tfgraph] 启动新的 ${user_shell} 让配置生效（输入 exit 退出）..."
  exec "$user_shell" -l
fi
