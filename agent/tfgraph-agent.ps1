# tfgraph-agent —— Terraform 执行机端 Agent（Windows PowerShell 版）
#
# 用法：
#   .\tfgraph-agent.ps1 ping
#   .\tfgraph-agent.ps1 graph -Name prod-network
#   .\tfgraph-agent.ps1 watch -- terraform plan
#   .\tfgraph-agent.ps1 tail C:\path\to\terraform.log
#   .\tfgraph-agent.ps1 upload-log C:\path\to\terraform.log
#   .\tfgraph-agent.ps1 daemon-start
#
# 环境变量：
#   $env:TFGRAPH_SERVER  在线系统地址（必填）
#   $env:TFGRAPH_NAME    默认会话名

[CmdletBinding(PositionalBinding=$false)]
param(
  [Parameter(Position=0)]
  [string]$Subcommand = 'help',

  [string]$Server,
  [string]$Name,
  [string]$Sid,
  [switch]$FromStart,

  [Parameter(ValueFromRemainingArguments=$true)]
  [object[]]$Rest
)

$ErrorActionPreference = 'Stop'

# -------- 配置 --------
if (-not $Server) { $Server = $env:TFGRAPH_SERVER }
if (-not $Name)   { $Name   = $env:TFGRAPH_NAME }
if (-not $Sid)    { $Sid    = $env:TFGRAPH_SESSION }
$HomeDir       = if ($env:TFGRAPH_HOME) { $env:TFGRAPH_HOME } else { Join-Path $env:USERPROFILE '.tfgraph' }
$DaemonPidFile = Join-Path $HomeDir 'daemon.pid'
$DaemonLog     = Join-Path $HomeDir 'daemon.log'
New-Item -ItemType Directory -Path $HomeDir -Force | Out-Null

function Log($msg) { Write-Host "[tfgraph] $msg" -ForegroundColor DarkGreen }
function Err($msg) { Write-Host "[tfgraph][ERROR] $msg" -ForegroundColor Red }

function Require-Server {
  if (-not $Server) {
    Err "未配置 `$env:TFGRAPH_SERVER"
    exit 2
  }
  $script:Server = $Server.TrimEnd('/')
}

function Derive-Sid([string]$n) {
  # 用 hostname + 当前工作目录派生 sid，同一目录永远是同一会话。
  $h = [System.Net.Dns]::GetHostName()
  $raw = "$h::$((Get-Location).Path)"
  $md5 = [System.Security.Cryptography.MD5]::Create()
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($raw)
  $hash  = $md5.ComputeHash($bytes)
  return ($hash | ForEach-Object { $_.ToString("x2") }) -join "" | ForEach-Object { $_.Substring(0, 12) }
}

function Http-Get($path) {
  return Invoke-RestMethod -Method Get -Uri ($Server + $path) -TimeoutSec 10
}
function Http-Post($path, $bodyObj) {
  $json = $bodyObj | ConvertTo-Json -Depth 10 -Compress
  return Invoke-RestMethod -Method Post -Uri ($Server + $path) -ContentType 'application/json' -Body $json -TimeoutSec 30
}

function Ensure-Session([string]$n) {
  $useSid = if ($Sid) { $Sid } else { Derive-Sid $n }
  $payload = @{
    id       = $useSid
    name     = $n
    hostname = [System.Net.Dns]::GetHostName()
    workdir  = (Get-Location).Path
  }
  Http-Post '/api/sessions' $payload | Out-Null
  Log "会话已注册：sid=$useSid  name=$n"
  return $useSid
}

function Report-Line([string]$sid, [string]$stream, [string]$line) {
  if ([string]::IsNullOrEmpty($line)) { return }
  $payload = @{ lines = @(@{ stream = $stream; line = $line }) }
  try { Http-Post "/api/sessions/$sid/logs" $payload | Out-Null } catch { }
}

# -------- 子命令 --------

function Cmd-Ping {
  Require-Server
  Log "检测在线系统连通性： $Server"
  try {
    $r = Http-Get '/api/ping'
    Log ("OK  service=" + $r.service + "  version=" + $r.version)
  } catch {
    Err "连接失败：$($_.Exception.Message)"
    exit 2
  }
}

function Cmd-Init {
  Require-Server
  $n = if ($Name) { $Name } else { Split-Path -Leaf (Get-Location) }
  $sid = Ensure-Session $n
  Write-Output $sid
}

function Cmd-Logout {
  Require-Server
  $useSid = if ($Sid) { $Sid } else { Derive-Sid '' }

  # 1) 停止本地 daemon
  if (Test-Path $DaemonPidFile) {
    $pid = Get-Content $DaemonPidFile -ErrorAction SilentlyContinue
    if ($pid) {
      try { Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue } catch {}
      Log "已停止后台守护 pid=$pid"
    }
    Remove-Item $DaemonPidFile -ErrorAction SilentlyContinue
  }

  # 2) 清理本地 offset 状态文件
  $stateDir = Join-Path $HomeDir 'state'
  if (Test-Path $stateDir) {
    Get-ChildItem "$stateDir\$useSid.*" -ErrorAction SilentlyContinue | Remove-Item -ErrorAction SilentlyContinue
    Log "已清理本地状态文件"
  }

  # 3) 向服务端发 DELETE 删除会话
  Log "注销会话 sid=$useSid ..."
  try {
    Invoke-RestMethod -Method Delete -Uri ($Server + "/api/sessions/$useSid") -TimeoutSec 10 | Out-Null
    Log "会话已注销，服务端数据已删除"
  } catch {
    Err "注销失败（服务端可能已无该会话）：$($_.Exception.Message)"
    exit 2
  }
  Log "若要重新注册，执行：tfgraph-agent.ps1 init"
}

function Cmd-Graph {
  Require-Server
  $n = if ($Name) { $Name } else { Split-Path -Leaf (Get-Location) }
  $sid = Ensure-Session $n

  # 自动开启 terraform 调试日志（仅本进程作用域；用户已设置则尊重）
  $tfLog     = if ($env:TF_LOG)      { $env:TF_LOG }      else { 'DEBUG' }
  $tfLogPath = if ($env:TF_LOG_PATH) { $env:TF_LOG_PATH } else { Join-Path (Get-Location) 'terraform.log' }
  $oldLog     = $env:TF_LOG
  $oldLogPath = $env:TF_LOG_PATH
  $env:TF_LOG      = $tfLog
  $env:TF_LOG_PATH = $tfLogPath
  Log "开启 terraform 日志：TF_LOG=$tfLog  TF_LOG_PATH=$tfLogPath"

  Log "执行 terraform graph ..."
  try {
    $dot = (& terraform graph) -join "`n"
  } catch {
    Err "terraform graph 失败：$($_.Exception.Message)"
    $env:TF_LOG = $oldLog; $env:TF_LOG_PATH = $oldLogPath
    exit 2
  } finally {
    # 还原，避免污染调用方 shell
    $env:TF_LOG      = $oldLog
    $env:TF_LOG_PATH = $oldLogPath
  }
  if ([string]::IsNullOrWhiteSpace($dot)) {
    Err "terraform graph 输出为空"
    exit 2
  }
  Log ("上传 DOT，长度 " + $dot.Length + " 字符 ...")
  $r = Http-Post "/api/sessions/$sid/graph" @{ dot = $dot }
  Log ("OK  nodes=" + $r.nodes + "  edges=" + $r.edges)
  Log "打开浏览器查看： $Server"
  if ((Test-Path $tfLogPath) -and ((Get-Item $tfLogPath).Length -gt 0)) {
    Log "调试日志已写入：$tfLogPath（可用：tfgraph-agent.ps1 tail $tfLogPath 上报）"
  }
}

function Cmd-Watch {
  Require-Server
  if (-not $Rest -or $Rest.Count -eq 0) {
    Err "用法： tfgraph-agent.ps1 watch -- <command...>"
    exit 2
  }
  # 去除首部 "--"
  $argv = @()
  foreach ($x in $Rest) {
    if ($x -ne '--') { $argv += $x }
  }
  if ($argv.Count -eq 0) {
    Err "用法： tfgraph-agent.ps1 watch -- <command...>"
    exit 2
  }

  $n = if ($Name) { $Name } else { Split-Path -Leaf (Get-Location) }
  $sid = Ensure-Session $n
  Log ("开始执行并监控： " + ($argv -join ' '))

  # 用 ProcessStartInfo 实时拿 stdout/stderr
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName               = $argv[0]
  if ($argv.Count -gt 1) { $psi.Arguments = ($argv[1..($argv.Count-1)] | ForEach-Object { '"' + $_ + '"' }) -join ' ' }
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $psi.UseShellExecute        = $false
  $psi.CreateNoWindow         = $true

  $proc = New-Object System.Diagnostics.Process
  $proc.StartInfo = $psi

  $outAct = Register-ObjectEvent -InputObject $proc -EventName OutputDataReceived -Action {
    param($s, $e)
    if ($null -ne $e.Data) {
      Write-Host $e.Data
      Report-Line $using:sid 'stdout' $e.Data
    }
  } -MessageData $sid
  $errAct = Register-ObjectEvent -InputObject $proc -EventName ErrorDataReceived -Action {
    param($s, $e)
    if ($null -ne $e.Data) {
      [Console]::Error.WriteLine($e.Data)
      Report-Line $using:sid 'stderr' $e.Data
    }
  } -MessageData $sid

  $proc.Start() | Out-Null
  $proc.BeginOutputReadLine()
  $proc.BeginErrorReadLine()
  $proc.WaitForExit()
  Unregister-Event -SourceIdentifier $outAct.Name
  Unregister-Event -SourceIdentifier $errAct.Name
  Report-Line $sid 'event' "--- 命令结束，退出码 $($proc.ExitCode) ---"
  Log "完成，退出码 $($proc.ExitCode)"
  exit $proc.ExitCode
}

function Cmd-Tail {
  Require-Server
  $file = if ($Rest -and $Rest.Count -gt 0) { $Rest[0] } else { $null }
  if (-not $file -or -not (Test-Path $file)) {
    Err "用法： tfgraph-agent.ps1 tail [-FromStart] <log_file>"
    exit 2
  }
  $n = if ($Name) { $Name } else { Split-Path -Leaf (Get-Location) }
  $sid = Ensure-Session $n
  Log "开始 tail： $file"
  $params = @{ Path = $file; Wait = $true }
  if (-not $FromStart) { $params['Tail'] = 0 }
  Get-Content @params | ForEach-Object {
    $line = $_
    Write-Host $line
    Report-Line $sid 'file' $line
  }
}

function Cmd-Upload-Log {
  Require-Server
  $file = if ($Rest -and $Rest.Count -gt 0) { $Rest[0] } else { $null }
  if (-not $file -or -not (Test-Path $file)) {
    Err "用法： tfgraph-agent.ps1 upload-log <log_file>"
    exit 2
  }
  $n = if ($Name) { $Name } else { Split-Path -Leaf (Get-Location) }
  $sid = Ensure-Session $n
  Log "上传 $file ..."
  $lines = Get-Content $file
  $batch = 200
  $sent = 0
  for ($i = 0; $i -lt $lines.Count; $i += $batch) {
    $end = [Math]::Min($i + $batch - 1, $lines.Count - 1)
    $payload = @{ lines = ($lines[$i..$end] | ForEach-Object { @{ stream = 'file'; line = $_ } }) }
    Http-Post "/api/sessions/$sid/logs" $payload | Out-Null
    $sent = $end + 1
    Log "  已上传 $sent/$($lines.Count) 行"
  }
  Log "完成"
}

function Cmd-Daemon-Start {
  Require-Server
  $n = if ($Name) { $Name } else { Split-Path -Leaf (Get-Location) }
  $logpath = if ($env:TF_LOG_PATH) { $env:TF_LOG_PATH } else { Join-Path $HomeDir 'terraform.log' }
  if (-not (Test-Path $logpath)) { New-Item -ItemType File -Path $logpath -Force | Out-Null }

  if (Test-Path $DaemonPidFile) {
    $oldPid = Get-Content $DaemonPidFile -ErrorAction SilentlyContinue
    if ($oldPid -and (Get-Process -Id $oldPid -ErrorAction SilentlyContinue)) {
      Log "守护已在运行（pid=$oldPid）"
      return
    }
  }
  Log "启动后台守护：tail $logpath -> $Server"
  $self = $PSCommandPath
  $proc = Start-Process -FilePath 'powershell.exe' `
            -ArgumentList @('-NoProfile', '-WindowStyle', 'Hidden', '-File', $self, 'tail', $logpath) `
            -PassThru -WindowStyle Hidden
  $proc.Id | Out-File -FilePath $DaemonPidFile -Encoding ascii
  Log "守护已启动 pid=$($proc.Id)  日志：$DaemonLog"
}

function Cmd-Daemon-Stop {
  if (-not (Test-Path $DaemonPidFile)) { Log "守护未在运行"; return }
  $pid = Get-Content $DaemonPidFile -ErrorAction SilentlyContinue
  if ($pid) {
    try { Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue } catch {}
    Log "已停止守护 pid=$pid"
  }
  Remove-Item $DaemonPidFile -ErrorAction SilentlyContinue
}

function Cmd-Daemon-Status {
  if ((Test-Path $DaemonPidFile) -and (Get-Process -Id (Get-Content $DaemonPidFile) -ErrorAction SilentlyContinue)) {
    Log "守护运行中  pid=$(Get-Content $DaemonPidFile)"
  } else {
    Log "守护未运行"
  }
}

# -------- 终端镜像（推荐用法：监控终端而非包裹执行） --------
# 用 Start-Transcript 把 sub-shell 内所有 host 输出（含外部命令 stdout/stderr）
# 写入临时文件，主进程后台 tail 这份文件并清洗后批量上报。
# 用户在 sub-shell 里像往常一样直接敲 terraform.exe plan/apply 即可。
function Cmd-Shell {
  Require-Server
  $n   = if ($Name) { $Name } else { Split-Path -Leaf (Get-Location) }
  $sid = Ensure-Session $n

  $mirror = Join-Path ([System.IO.Path]::GetTempPath()) ("tfgraph-shell." + [System.Guid]::NewGuid().ToString("N").Substring(0,8) + ".log")
  New-Item -ItemType File -Path $mirror -Force | Out-Null

  Log "启动终端镜像：所有终端输出会被上报到 $Server"
  Log "退出 sub-shell（exit）即停止录制"
  Log "镜像文件：$mirror"
  Write-Host ""

  # 后台 reporter：用独立 PowerShell 进程 tail 镜像并按行上报
  # 用 Start-Job 而不是 Runspace，跨 PS 5/7 兼容
  $reporter = Start-Job -ScriptBlock {
    param($srv, $sid, $file)
    # ANSI 转义
    $ansi = [regex]'\x1B\[[0-9;]*[mGKHfJ]'
    Get-Content -Path $file -Wait -Tail 0 | ForEach-Object {
      $line = $ansi.Replace($_, '').TrimEnd("`r")
      if ([string]::IsNullOrEmpty($line)) { return }
      # 跳过 Transcript 的元信息行
      if ($line -match '^\*+$|^Windows PowerShell transcript|^Start time:|^Username:|^RunAs|^Configuration|^Machine:|^Host Application|^Process ID|^PSVersion|^PSEdition|^PSCompatibleVersions|^BuildVersion|^CLRVersion|^WSManStackVersion|^PSRemotingProtocolVersion|^SerializationVersion|^Transcript started') { return }
      $payload = @{ lines = @(@{ stream = 'stdout'; line = $line }) } | ConvertTo-Json -Depth 5 -Compress
      try {
        Invoke-RestMethod -Method Post -Uri ($srv + "/api/sessions/$sid/logs") `
          -ContentType 'application/json' -Body $payload -TimeoutSec 5 | Out-Null
      } catch { }
    }
  } -ArgumentList $Server, $sid, $mirror

  # 启动一个新的 PowerShell 子进程作为 sub-shell：
  # 在子进程里调用 Start-Transcript 把整个会话的 host 输出录制到 $mirror。
  $env:TFGRAPH_IN_SHELL = '1'
  try {
    $bootstrap = "Start-Transcript -Path '$mirror' -Append -IncludeInvocationHeader | Out-Null; " +
                 "Write-Host '[tfgraph] 终端镜像已就绪，输入 exit 退出'; "
    & powershell.exe -NoLogo -NoExit -NoProfile -Command $bootstrap
  } finally {
    # 收尾
    Stop-Job  -Job $reporter -ErrorAction SilentlyContinue
    Remove-Job -Job $reporter -ErrorAction SilentlyContinue
    Remove-Item $mirror -ErrorAction SilentlyContinue
    Remove-Item Env:TFGRAPH_IN_SHELL -ErrorAction SilentlyContinue
    Log "已退出终端镜像"
  }
}

function Cmd-Help {
@"
tfgraph-agent —— Terraform Graph 在线系统的执行机 Agent（PowerShell 版）

用法：
  .\tfgraph-agent.ps1 <子命令> [选项]

推荐流程（监控终端，无需包裹执行）：
  1) .\tfgraph-agent.ps1 ping                 # 联通性检测
  2) .\tfgraph-agent.ps1 graph                # 上传依赖图
  3) .\tfgraph-agent.ps1 shell                # 进入终端镜像，正常敲 terraform plan/apply

子命令：
  shell                 进入终端镜像 sub-shell：所有终端输出自动上报【推荐】
  ping                  联通性检测
  init                  注册/更新会话
  logout                注销当前会话（停止 daemon + 删除服务端数据）
  graph                 执行 terraform graph 并上传依赖图
  watch -- <cmd>        包裹执行命令并实时上报输出（已知命令时使用）
  tail [-FromStart] <file>  tail 一份日志文件并实时上报
  upload-log <file>     整体上传一份日志文件
  daemon-start          启动后台守护
  daemon-stop           停止后台守护
  daemon-status         查看守护状态

选项：
  -Server URL           覆盖 `$env:TFGRAPH_SERVER
  -Name NAME            会话名，默认取当前目录名
  -Sid SID              指定会话 ID
"@ | Write-Host
}

switch ($Subcommand) {
  'ping'          { Cmd-Ping }
  'init'          { Cmd-Init }
  'logout'        { Cmd-Logout }
  'graph'         { Cmd-Graph }
  'watch'         { Cmd-Watch }
  'shell'         { Cmd-Shell }
  'tail'          { Cmd-Tail }
  'upload-log'    { Cmd-Upload-Log }
  'daemon-start'  { Cmd-Daemon-Start }
  'daemon-stop'   { Cmd-Daemon-Stop }
  'daemon-status' { Cmd-Daemon-Status }
  'help'          { Cmd-Help }
  default {
    Err "未知子命令：$Subcommand"
    Cmd-Help
    exit 2
  }
}
