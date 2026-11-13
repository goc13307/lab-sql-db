# ============================================================================
# M4-2 压测执行脚本（默认 200 并发抢 100 张）
# ----------------------------------------------------------------------------
# 用途：一键完成「调连接数 -> 造热点库存 -> 跑 mysqlslap -> 对账」全流程。
#
# 用法（在仓库根目录运行）：
#   .\script\run_stress_test.ps1
#   .\script\run_stress_test.ps1 -Concurrency 200 -Stock 100 -Iterations 5
#
# 注意：
#   本脚本会 TRUNCATE ticket_order / notification，清掉 seed.sql 的 5000 单基线。
#   压测完成后如需恢复基线，重跑：mysql ... ticket_db < sql/seed.sql
# ============================================================================

param(
    [int] $Concurrency = 200,
    [int] $Stock       = 100,
    [int] $Queries     = 10000,
    [int] $Iterations  = 1,
    [int] $CategoryId  = 10,
    [int] $EventId     = 3,
    [int] $UserId      = 1
)

$repoRoot = Split-Path -Parent $PSScriptRoot
$bin      = "C:\Program Files\MySQL\MySQL Server 8.4\bin"
$mysql    = Join-Path $bin "mysql.exe"
$slap     = Join-Path $bin "mysqlslap.exe"

foreach ($tool in @($mysql, $slap)) {
    if (-not (Test-Path $tool)) { throw "找不到工具：$tool" }
}

# mysql 客户端会把密码警告写到 stderr，统一过滤，避免干扰输出
function Invoke-MySql {
    param([string] $Sql, [switch] $Table)
    $fmt = if ($Table) { "-t" } else { "-N" }
    & $mysql -u root -p1234 --default-character-set=utf8mb4 $fmt -B ticket_db -e $Sql 2>$null |
        Where-Object { $_ -notmatch 'Warning.*password' }
}

function Write-Step {
    param([string] $Text)
    Write-Host $Text -ForegroundColor Cyan
}

# ---------------------------------------------------------------- 1. 调大连接数
Write-Step "[1/5] 调大 max_connections 到 300 ..."
& $mysql -u root -p1234 -e "SET GLOBAL max_connections = 300;" 2>$null | Out-Null
$mcRows = & $mysql -u root -p1234 -N -B -e "SHOW GLOBAL VARIABLES LIKE 'max_connections';" 2>$null
$mcVal  = (($mcRows | Where-Object { $_ -match 'max_connections' }) -split "`t")[1]
Write-Host "      max_connections = $mcVal"

# ------------------------------------------------------- 2. 清场 + 造热点库存
Write-Step "[2/5] 清场并造 $Stock 张热点库存（category_id=$CategoryId）..."
Invoke-MySql @"
SET FOREIGN_KEY_CHECKS = 0;
TRUNCATE TABLE notification;
TRUNCATE TABLE ticket_order;
SET FOREIGN_KEY_CHECKS = 1;
UPDATE seat_category
   SET sold_tickets = 0, total_tickets = $Stock
 WHERE category_id = $CategoryId;
"@ | Out-Null

Invoke-MySql "SELECT category_id, event_id, total_tickets, sold_tickets FROM seat_category WHERE category_id=$CategoryId;" -Table | Out-Host

# ------------------------------------------------------------ 3. 准备 grab.sql
Write-Step "[3/5] 生成压测语句 script/grab.sql ..."
$grabSql = Join-Path $PSScriptRoot "grab.sql"
"CALL sp_grab_ticket($UserId,$EventId,$CategoryId,1,@p_result_code);" |
    Set-Content -LiteralPath $grabSql -Encoding ASCII -NoNewline
Write-Host "      $((Get-Content -LiteralPath $grabSql -Raw))"

# ------------------------------------------------- 4. 采样 + 压测（并行启动）
Write-Step "[4/5] 启动锁指标采样，然后跑 mysqlslap $Concurrency 并发 ..."

$sampler = Join-Path $PSScriptRoot "sample_lock_metrics.ps1"

# 本次压测的采样数据写到独立文件，避免覆盖 report/ 里已归档的正式数据
$sampleOut = Join-Path $repoRoot ("report\lock_metrics_{0}.txt" -f (Get-Date -Format "yyyyMMdd_HHmmss"))

# 采样时长要盖住压测窗口：按压测预计耗时给足余量（至少 30 秒）
$sampleCount = [math]::Max(100, [int](($Concurrency * $Iterations) / 4))

# 用 Start-Process 直接起独立进程，避免 Start-Job 的进程启动开销（约 2-4 秒）
$sampleProc = $null
if (Test-Path $sampler) {
    $sampleProc = Start-Process -FilePath "powershell.exe" `
        -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$sampler`"",
                        "-OutFile", "`"$sampleOut`"", "-Samples", "$sampleCount", "-IntervalMs", "100") `
        -WindowStyle Hidden -PassThru

    # 等第一个样本真正落盘，再开始压测（否则压测跑完了采样还没启动）
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline) {
        if ((Test-Path $sampleOut) -and ((Get-Content -LiteralPath $sampleOut -ErrorAction SilentlyContinue |
                Where-Object { $_ -match 'TR=' }).Count -ge 1)) { break }
        Start-Sleep -Milliseconds 100
    }
} else {
    Write-Host "      （未找到采样脚本，跳过采样）" -ForegroundColor Yellow
}

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$slapOut = & $slap --host=127.0.0.1 -u root -p1234 `
    --create-schema=ticket_db --query="$grabSql" --delimiter=";" `
    --concurrency=$Concurrency --iterations=$Iterations --number-of-queries=$Queries 2>&1 |
    Where-Object { $_ -notmatch 'Warning.*password' }
$sw.Stop()

Write-Host ""
Write-Host "=== mysqlslap 输出 ===" -ForegroundColor Green
$slapOut | Out-Host
Write-Host ("总耗时: {0} s" -f [math]::Round($sw.Elapsed.TotalSeconds, 3))

if ($sampleProc) {
    Write-Host ""
    Write-Step "停止采样（压测已结束）..."
    Start-Sleep -Seconds 2
    if (-not $sampleProc.HasExited) {
        try { $sampleProc.Kill() } catch { }
    }
    $sampleProc.WaitForExit(5000) | Out-Null

    if (Test-Path $sampleOut) {
        $n = (Get-Content -LiteralPath $sampleOut | Where-Object { $_ -match 'TR=' }).Count
        Write-Host ("      采样数据：{0}（{1} 个样本）" -f $sampleOut.Replace("$repoRoot\",""), $n)
    }
}

# ------------------------------------------------------------------- 5. 对账
Write-Step "[5/5] 对账：验证是否超卖 ..."
Invoke-MySql @"
SELECT
    sc.category_id,
    sc.total_tickets,
    sc.sold_tickets,
    (SELECT COUNT(*)                 FROM ticket_order t WHERE t.category_id = sc.category_id) AS order_cnt,
    (SELECT IFNULL(SUM(quantity), 0) FROM ticket_order t WHERE t.category_id = sc.category_id) AS sum_qty
FROM seat_category sc
WHERE sc.category_id = $CategoryId;
"@ -Table | Out-Host

$checkRows = Invoke-MySql @"
SELECT
  CASE WHEN sold_tickets <= total_tickets THEN 'PASS' ELSE 'FAIL' END,
  CASE WHEN sold_tickets = (SELECT IFNULL(SUM(quantity),0) FROM ticket_order WHERE category_id=$CategoryId)
       THEN 'PASS' ELSE 'FAIL' END
FROM seat_category WHERE category_id=$CategoryId;
"@

$parts = ($checkRows | Where-Object { $_ -match 'PASS|FAIL' }) -split "`t"
$r1 = if ($parts.Count -ge 1) { $parts[0] } else { 'N/A' }
$r2 = if ($parts.Count -ge 2) { $parts[1] } else { 'N/A' }

Write-Host ""
Write-Host ("判据1 sold_tickets <= total_tickets : {0}" -f $r1) -ForegroundColor $(if ($r1 -eq 'PASS') { 'Green' } else { 'Red' })
Write-Host ("判据2 sold_tickets = sum_qty        : {0}" -f $r2) -ForegroundColor $(if ($r2 -eq 'PASS') { 'Green' } else { 'Red' })
Write-Host ""
Write-Host "提示：压测已清空 5000 单基线，如需恢复请重跑 sql/seed.sql" -ForegroundColor Yellow
