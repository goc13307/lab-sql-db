# ============================================================================
# 锁指标采样脚本（M4-2 压测配套）
# ----------------------------------------------------------------------------
# 用途：压测期间另开一个窗口运行，每 100~300ms 采样一次 MySQL 全局状态，
#       用于判断「瓶颈在锁不在 CPU」。
#
# 用法：
#   # 先启动本脚本（持续采样），再在另一个窗口跑 mysqlslap 压测
#   .\script\sample_lock_metrics.ps1
#
#   # 自定义采样次数/间隔/输出文件
#   .\script\sample_lock_metrics.ps1 -Samples 200 -IntervalMs 100 -OutFile report\my.txt
#
# 重点关注：
#   Threads_running                峰值（活跃线程堆积）
#   Innodb_row_lock_current_waits  峰值（有多少事务在等行锁）
#   Innodb_row_lock_time           累计锁等待时间
#
# 判据：Threads_running 涨 + Questions 停滞 + Innodb_row_lock_current_waits > 0
#       = 吞吐被行锁卡住，加 CPU 无用。
# ============================================================================

param(
    [int]    $Samples    = 80,      # 采样次数
    [int]    $IntervalMs = 300,     # 采样间隔（毫秒）
    [string] $OutFile    = ""       # 默认写到 report/lock_metrics_raw.txt
)

# 不用 Stop：mysql 客户端会把密码警告写到 stderr，Stop 会把它当终止错误
$ErrorActionPreference = "Continue"

# ---- 定位 mysql.exe（不在 PATH 时用默认安装路径）----
$mysql = (Get-Command mysql.exe -ErrorAction SilentlyContinue).Source
if (-not $mysql) {
    $mysql = "C:\Program Files\MySQL\MySQL Server 8.4\bin\mysql.exe"
}
if (-not (Test-Path $mysql)) {
    throw "找不到 mysql.exe，请确认 MySQL 客户端安装路径"
}

# ---- 输出文件默认放在 report/ ----
if ([string]::IsNullOrWhiteSpace($OutFile)) {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $OutFile  = Join-Path $repoRoot "report\lock_metrics_raw.txt"
}

$outDir = Split-Path -Parent $OutFile
if ($outDir -and -not (Test-Path $outDir)) {
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null
}

$sql = "SHOW GLOBAL STATUS WHERE Variable_name IN (" +
       "'Threads_running','Questions','Innodb_row_lock_current_waits'," +
       "'Innodb_row_lock_waits','Innodb_row_lock_time');"

if (Test-Path $OutFile) { Remove-Item $OutFile -Force }

"=== lock metric sampling start $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') ===" |
    Set-Content -LiteralPath $OutFile -Encoding UTF8

for ($i = 1; $i -le $Samples; $i++) {
    $ts = Get-Date -Format 'HH:mm:ss.fff'

    $rows = & $mysql -u root -p1234 -N -B -e $sql 2>$null |
        Where-Object { $_ -notmatch 'Warning.*password' }

    $vals = @{}
    foreach ($row in $rows) {
        $parts = $row -split "`t"
        if ($parts.Count -ge 2) { $vals[$parts[0]] = $parts[1] }
    }

    ("{0}`tTR={1}`tQ={2}`tLRCW={3}`tLRW={4}`tLRT={5}" -f `
        $ts,
        $vals['Threads_running'],
        $vals['Questions'],
        $vals['Innodb_row_lock_current_waits'],
        $vals['Innodb_row_lock_waits'],
        $vals['Innodb_row_lock_time']) |
        Add-Content -LiteralPath $OutFile -Encoding UTF8

    Start-Sleep -Milliseconds $IntervalMs
}

"=== sampling end $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') ===" |
    Add-Content -LiteralPath $OutFile -Encoding UTF8

# ---- 汇总峰值 ----
$lines = Get-Content -LiteralPath $OutFile | Where-Object { $_ -match 'TR=' }
$tr = @(); $lrcw = @(); $lrw = @(); $lrt = @()
foreach ($l in $lines) {
    if ($l -match 'TR=(\d+)\s+Q=(\d+)\s+LRCW=(\d+)\s+LRW=(\d+)\s+LRT=(\d+)') {
        $tr   += [int]$matches[1]
        $lrcw += [int]$matches[3]
        $lrw  += [int]$matches[4]
        $lrt  += [int]$matches[5]
    }
}

Write-Host ""
Write-Host "=== 采样完成：$($lines.Count) 个样本 -> $OutFile ==="
if ($tr.Count -gt 0) {
    Write-Host ("Threads_running                峰值 = {0}" -f ($tr   | Measure-Object -Maximum).Maximum)
    Write-Host ("Innodb_row_lock_current_waits  峰值 = {0}" -f ($lrcw | Measure-Object -Maximum).Maximum)
    Write-Host ("Innodb_row_lock_waits          峰值 = {0}" -f ($lrw  | Measure-Object -Maximum).Maximum)
    Write-Host ("Innodb_row_lock_time           峰值 = {0} ms" -f ($lrt | Measure-Object -Maximum).Maximum)
}
