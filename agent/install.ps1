# tfgraph-agent 一键安装脚本（Windows PowerShell 版）
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File .\install.ps1 -Server http://10.0.0.1:8000
#   或：iwr http://<server>/agent/install.ps1 | iex   (Server 来自 $env:TFGRAPH_SERVER)
#
# 卸载：
#   powershell -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall

param(
  [Parameter(Mandatory=$false, Position=0)]
  [string]$Server = $env:TFGRAPH_SERVER,

  [Parameter(Mandatory=$false)]
  [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

$InstallDir = Join-Path $env:USERPROFILE '.tfgraph'
$BinDir     = Join-Path $env:USERPROFILE '.tfgraph\bin'

# ============================================================
# 卸载逻辑
# ============================================================
function Invoke-Uninstall {
  Write-Host "[tfgraph] 开始卸载 ..." -ForegroundColor DarkYellow
  Write-Host "[tfgraph] 安装目录: $InstallDir"
  Write-Host "[tfgraph] 命令目录: $BinDir"

  # 1) 优雅停止后台守护
  $agentPs1 = Join-Path $InstallDir 'tfgraph-agent.ps1'
  if (Test-Path $agentPs1) {
    try {
      & powershell -NoProfile -ExecutionPolicy Bypass -File $agentPs1 daemon-stop | Out-Null
    } catch {}
  }

  # 2) 兜底 1：按 pid 文件杀进程
  $pidFile = Join-Path $InstallDir 'daemon.pid'
  if (Test-Path $pidFile) {
    $oldPid = Get-Content $pidFile -ErrorAction SilentlyContinue
    if ($oldPid) {
      try { Stop-Process -Id $oldPid -Force -ErrorAction SilentlyContinue } catch {}
    }
  }

  # 3) 兜底 2：按命令行特征清理所有 tfgraph-agent 相关进程
  # 覆盖：daemon (powershell -File ...\tfgraph-agent.ps1 tail ...),
  #       shell sub-shell (powershell -NoExit ... Start-Transcript ...mirror...),
  #       watch 子进程，以及残留的 reporter Job 进程。
  Write-Host "[tfgraph] 清理 tfgraph-agent 相关残留进程 ..."
  $selfPid = $PID
  try {
    # 用 CIM 拿到 CommandLine（Get-Process 默认拿不到）
    $procs = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
      $_.ProcessId -ne $selfPid -and $_.CommandLine -and (
        $_.CommandLine -like "*tfgraph-agent*" -or
        $_.CommandLine -like "*$InstallDir*"  -or
        $_.CommandLine -like "*tfgraph-shell.*"
      )
    }
    foreach ($p in $procs) {
      try {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
        Write-Host "[tfgraph]   已结束进程 pid=$($p.ProcessId)"
      } catch {}
    }
  } catch {
    # CIM 不可用时退化为按名字粗筛
    try {
      Get-Process powershell, pwsh -ErrorAction SilentlyContinue |
        Where-Object { $_.Id -ne $selfPid -and $_.MainWindowTitle -like "*tfgraph*" } |
        ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
    } catch {}
  }

  # 4) 从用户 PATH 中移除 BinDir
  $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
  if ($userPath) {
    $parts = $userPath -split ';' | Where-Object { $_ -and ($_ -ne $BinDir) }
    $newPath = ($parts -join ';')
    if ($newPath -ne $userPath) {
      [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
      Write-Host "[tfgraph] 已从用户 PATH 移除 $BinDir"
    }
  }

  # 5) 清理用户级环境变量
  foreach ($var in @('TFGRAPH_SERVER', 'TF_LOG', 'TF_LOG_PATH')) {
    if ([Environment]::GetEnvironmentVariable($var, 'User')) {
      [Environment]::SetEnvironmentVariable($var, $null, 'User')
      Write-Host "[tfgraph] 已删除环境变量: $var"
    }
  }

  # 6) 清理 Temp 下 shell 镜像残留（Cmd-Shell 用 GetTempPath() 创建 tfgraph-shell.*.log）
  try {
    Get-ChildItem -Path ([System.IO.Path]::GetTempPath()) -Filter 'tfgraph-shell.*' -ErrorAction SilentlyContinue |
      ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
  } catch {}

  # 7) 删除安装目录（含 BinDir，是其子目录；含 agent 脚本、daemon.pid/log、terraform.log 等所有数据）
  if (Test-Path $InstallDir) {
    Remove-Item -Path $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "[tfgraph] 已删除目录: $InstallDir"
  }

@"

================================================================
tfgraph-agent 已卸载完成。

提示：请重新打开 PowerShell 让 PATH/环境变量的清理彻底生效。
================================================================
"@ | Write-Host

  exit 0
}

if ($Uninstall) {
  Invoke-Uninstall
}

# ============================================================
# 安装：到这里才需要 Server
# ============================================================
if (-not $Server) {
  Write-Error "用法: install.ps1 -Server http://<server>:8000  或  install.ps1 -Uninstall"
  exit 1
}
$Server = $Server.TrimEnd('/')

Write-Host "[tfgraph] 安装目录: $InstallDir" -ForegroundColor DarkGreen
Write-Host "[tfgraph] 命令目录: $BinDir"
Write-Host "[tfgraph] 在线系统: $Server"

New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
New-Item -ItemType Directory -Path $BinDir     -Force | Out-Null

# 1) 下载 Agent 主程序
Write-Host "[tfgraph] 下载 tfgraph-agent.ps1 ..."
Invoke-WebRequest -UseBasicParsing -Uri "$Server/agent/tfgraph-agent.ps1" `
  -OutFile (Join-Path $InstallDir 'tfgraph-agent.ps1')

# 2) 写一个 wrapper .cmd / .ps1 到 BinDir
$WrapperCmd = @"
@echo off
set TFGRAPH_SERVER=$Server
powershell -NoProfile -ExecutionPolicy Bypass -File "$InstallDir\tfgraph-agent.ps1" %*
"@
$WrapperCmd | Out-File -FilePath (Join-Path $BinDir 'tfgraph-agent.cmd') -Encoding ascii

# 3) PATH 注入（用户级）
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if (($userPath -split ';') -notcontains $BinDir) {
  [Environment]::SetEnvironmentVariable('Path', "$userPath;$BinDir", 'User')
  Write-Host "[tfgraph] 已将 $BinDir 加入用户 PATH"
}

# 4) 设置默认环境变量（用户级）
[Environment]::SetEnvironmentVariable('TFGRAPH_SERVER', $Server, 'User')
$tfLogPath = Join-Path $InstallDir 'terraform.log'
[Environment]::SetEnvironmentVariable('TF_LOG',      'DEBUG',   'User')
[Environment]::SetEnvironmentVariable('TF_LOG_PATH', $tfLogPath,'User')

# 5) 联通性检测
Write-Host "[tfgraph] 联通性检测 ..."
try {
  & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $InstallDir 'tfgraph-agent.ps1') ping
  Write-Host "[tfgraph] 联通性检测通过。"
} catch {
  Write-Warning "[tfgraph] 联通性检测失败：$($_.Exception.Message)"
}

# 6) 启动后台守护
Write-Host "[tfgraph] 启动后台守护（自动监听 terraform 日志） ..."
try {
  & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $InstallDir 'tfgraph-agent.ps1') daemon-start
} catch {
  Write-Warning "[tfgraph] 守护启动失败：$($_.Exception.Message)"
}

@"

================================================================
tfgraph-agent 安装完成。

请重新打开 PowerShell（让 PATH/环境变量生效），然后正常使用 terraform：
    cd C:\path\to\your\tf-project
    tfgraph-agent graph              # 上传依赖图
    tfgraph-agent watch -- terraform plan
    tfgraph-agent watch -- terraform apply

后台守护：
    tfgraph-agent daemon-status
    tfgraph-agent daemon-stop
    tfgraph-agent daemon-start

打开浏览器查看： $Server
================================================================
"@ | Write-Host
