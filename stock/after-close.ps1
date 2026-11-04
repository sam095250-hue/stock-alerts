# After the close, push to LINE the lists the trend-swing course says to review in the evening:
#   1. daily golden cross: the 20-day MA crossing above the 100-day MA, with the close above both
#   2. closed above the 20-week MA today, on the same volume, candle and trend rules as intraday-alert.ps1
#   3. on Fridays, stocks whose finished weekly candle crossed above the 20-week MA this week
# This is only a technical filter, not a buy recommendation.
#
# Usage:
#   .\after-close.ps1                    # screen and push to LINE
#   .\after-close.ps1 -DryRun            # screen and print only, at any hour
#   .\after-close.ps1 -DryRun -Friday    # include the weekly list on any day
#
# Volume, prices and weekly bars all come from Yahoo daily bars, because the TWSE daily list can lag
# until the next morning. Takes ~15 minutes. Does nothing on days the market was closed.
param(
    [int]$Weeks = 20,
    [int]$Fast = 20,
    [int]$Slow = 100,
    [long]$MinLots = 5000,
    [int]$AvgDays = 5,
    [double]$MinCapital = 2000000000,
    [double]$FlatTolerance = 0.001,   # how far the 20-week MA may dip and still count as flat
    [int]$HighWeeks = 26,
    [int]$RepeatDays = 60,            # days before the same stock's golden cross is pushed again
    [switch]$Friday,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\common.ps1')
$dataDir = Join-Path $PSScriptRoot 'data'
$logFile = Join-Path $dataDir 'golden-cross-notified.json'
$sendLine = Join-Path $PSScriptRoot '..\line\send-line.ps1'
New-Item -ItemType Directory -Force $dataDir | Out-Null
if (-not $DryRun) { Start-Transcript -Path (Join-Path $dataDir 'after-close-last-run.log') -Force | Out-Null }
trap { Write-Crash $_ '盤後趨勢波段名單' $sendLine -DryRun:$DryRun; break }
Test-StockSetup $PSScriptRoot $sendLine -DryRun:$DryRun

$now = Get-Date
$today = $now.Date
$monday = Get-WeekStart $today
$taipei = [TimeZoneInfo]::FindSystemTimeZoneById('Taipei Standard Time')
$isFriday = $Friday -or $today.DayOfWeek -eq 'Friday'

# Missed runs start at the next boot, which may be the next morning with a half-finished day.
if (-not $DryRun -and $now.Hour -lt 14) { Write-Host 'Market not closed yet.'; return }

function Get-Average([double[]]$Values, [int]$End, [int]$Length) {
    $sum = 0.0
    for ($i = $End - $Length + 1; $i -le $End; $i++) { $sum += $Values[$i] }
    $sum / $Length
}

# Bars that actually traded, oldest first. Zero-volume bars are holidays (e.g. typhoon days) Yahoo still lists.
function Get-DailyBars([string]$Symbol) {
    $chart = Get-Chart $Symbol '1y' '1d'
    if (-not $chart) { return $null }
    $q = $chart.indicators.quote[0]
    $bars = New-Object Collections.ArrayList
    for ($i = 0; $i -lt $chart.timestamp.Count; $i++) {
        if ($q.close[$i] -eq $null -or $q.open[$i] -eq $null -or -not ($q.volume[$i] -gt 0)) { continue }
        $date = [TimeZoneInfo]::ConvertTimeFromUtc([DateTimeOffset]::FromUnixTimeSeconds($chart.timestamp[$i]).UtcDateTime, $taipei).Date
        [void]$bars.Add([pscustomobject]@{ Date = $date; Open = [double]$q.open[$i]; High = [double]$q.high[$i]; Close = [double]$q.close[$i]; Lots = [double]$q.volume[$i] / 1000 })
    }
    , $bars
}

$reference = Get-DailyBars '2330.TW'
if (-not $reference -or $reference[$reference.Count - 1].Date -ne $today) {
    Write-Host 'No trading today: market closed.'
    return
}

$stocks = @(Get-Universe 0 $MinCapital)
Write-Host "Screening $($stocks.Count) stocks..."

$crosses = @()
$aboveWeekly = @()
$weeklyConfirmed = @()
$failed = 0
$n = 0
foreach ($stock in $stocks) {
    $n++
    if ($n % 200 -eq 0) { Write-Host "  $n / $($stocks.Count)" }
    Start-Sleep -Milliseconds 150
    $bars = Get-DailyBars $stock.Symbol
    if (-not $bars) { $failed++; continue }
    $count = $bars.Count
    if ($count -lt $AvgDays + 2 -or $bars[$count - 1].Date -ne $today) { continue }

    $last = $bars[$count - 1]
    $closes = [double[]]@($bars | ForEach-Object { $_.Close })
    $avgLots = (@($bars[($count - 1 - $AvgDays)..($count - 2)]) | Measure-Object -Property Lots -Average).Average
    $ratio = if ($avgLots -gt 0) { $last.Lots / $avgLots } else { 0 }
    $base = @{ Code = $stock.Code; Name = $stock.Name; Market = $stock.Market; Close = $last.Close; Lots = $last.Lots; Avg = $avgLots; Ratio = $ratio }

    # 1. Daily golden cross, with the close above both averages.
    if ($count -gt $Slow -and $last.Lots -ge $MinLots) {
        $fastNow = Get-Average $closes ($count - 1) $Fast
        $slowNow = Get-Average $closes ($count - 1) $Slow
        $fastPrev = Get-Average $closes ($count - 2) $Fast
        $slowPrev = Get-Average $closes ($count - 2) $Slow
        if ($fastPrev -le $slowPrev -and $fastNow -gt $slowNow -and $last.Close -gt $fastNow -and $last.Close -gt $slowNow) {
            $crosses += [pscustomobject]($base + @{ FastMA = $fastNow; SlowMA = $slowNow })
        }
    }

    # Completed weeks' closes and highs, and this week's opening price.
    $weekCloses = New-Object Collections.ArrayList
    $weekHighs = New-Object Collections.ArrayList
    $currentWeek = $null
    $weekOpen = $last.Open
    foreach ($bar in $bars) {
        $start = Get-WeekStart $bar.Date
        if ($start -ge $monday) {
            if ($start -ne $currentWeek) { $weekOpen = $bar.Open; $currentWeek = $start }
            continue
        }
        if ($start -ne $currentWeek) {
            [void]$weekCloses.Add($bar.Close); [void]$weekHighs.Add($bar.High); $currentWeek = $start
        } else {
            $weekCloses[$weekCloses.Count - 1] = $bar.Close
            if ($bar.High -gt $weekHighs[$weekHighs.Count - 1]) { $weekHighs[$weekHighs.Count - 1] = $bar.High }
        }
    }
    if ($weekCloses.Count -lt $Weeks) { continue }

    # The 20-week MA includes the current week, so the crossing price is the average of the last 19 completed weeks.
    $level = (@($weekCloses[($weekCloses.Count - $Weeks + 1)..($weekCloses.Count - 1)]) | Measure-Object -Average).Average
    $prevMA = (@($weekCloses[($weekCloses.Count - $Weeks)..($weekCloses.Count - 1)]) | Measure-Object -Average).Average
    $liveMA = ($level * ($Weeks - 1) + $last.Close) / $Weeks
    if ($liveMA -lt $prevMA * (1 - $FlatTolerance) -or $last.Close -le $level) { continue }
    $highCount = [math]::Min($HighWeeks, $weekHighs.Count)
    $recentHigh = (@($weekHighs[($weekHighs.Count - $highCount)..($weekHighs.Count - 1)]) | Measure-Object -Maximum).Maximum
    $row = $base + @{ MA = $liveMA; NewHigh = $last.Close -gt $recentHigh }

    # 2. Closed above the 20-week MA today after closing at or below it yesterday.
    if ($closes[$count - 2] -le $level -and $last.Lots -ge $MinLots -and $ratio -gt 1 -and $last.Close -gt $last.Open) {
        $aboveWeekly += [pscustomobject]$row
    }

    # 3. This week's candle crossed the 20-week MA: last week closed at or below it, this week is red and liquid.
    $weekAvgLots = (@($bars[($count - $AvgDays)..($count - 1)]) | Measure-Object -Property Lots -Average).Average
    if ($isFriday -and $weekCloses[$weekCloses.Count - 1] -le $prevMA -and $last.Close -gt $weekOpen -and $weekAvgLots -ge $MinLots) {
        $weeklyConfirmed += [pscustomobject]$row
    }
}

function Format-WeeklyRow($h) {
    $tag = if ($h.NewHigh) { '★' } else { '' }
    "$tag$($h.Code) $($h.Name)（$($h.Market)）收 $([math]::Round($h.Close, 2))｜$($Weeks)週線 $([math]::Round($h.MA, 2))｜量 $('{0:N0}' -f $h.Lots) 張（量比 $('{0:0.0}' -f $h.Ratio) 倍）｜跌到週線 1 張約賠 $('{0:N0}' -f (($h.Close - $h.MA) * 1000)) 元"
}

# Drop golden crosses already pushed within $RepeatDays.
$sent = @{}
if (Test-Path $logFile) {
    (Get-Content -Raw -Encoding UTF8 $logFile | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $sent[$_.Name] = $_.Value }
}
$newCrosses = @($crosses | Where-Object { -not $sent[$_.Code] -or ($today - [datetime]$sent[$_.Code]).TotalDays -ge $RepeatDays })

$lines = @("📋 盤後趨勢波段名單", $today.ToString('yyyy-MM-dd'))
$light = Get-MarketLight
if ($light) { $lines += $light }
$lines += ''
$lines += "【日 $Fast 穿日 $Slow 黃金交叉】$($newCrosses.Count) 檔"
foreach ($h in $newCrosses | Sort-Object Code) {
    $lines += "$($h.Code) $($h.Name)（$($h.Market)）收 $([math]::Round($h.Close, 2))｜日$Fast $([math]::Round($h.FastMA, 2))｜日$Slow $([math]::Round($h.SlowMA, 2))｜量 $('{0:N0}' -f $h.Lots) 張"
}
$lines += ''
$lines += "【今天收盤站上 $Weeks 週線】$($aboveWeekly.Count) 檔"
foreach ($h in $aboveWeekly | Sort-Object Code) { $lines += Format-WeeklyRow $h }
if ($isFriday) {
    $lines += ''
    $lines += "【本週週 K 確認站上 $Weeks 週線】$($weeklyConfirmed.Count) 檔"
    foreach ($h in $weeklyConfirmed | Sort-Object Code) { $lines += Format-WeeklyRow $h }
}
$lines += ''
if (@($aboveWeekly) + @($weeklyConfirmed) | Where-Object NewHigh) { $lines += "★＝同時突破近 $HighWeeks 週高點。" }
$lines += '※ 站上週線只是初步觀察，趨勢線和型態請自己看圖。僅為技術條件篩選，不是買進建議。'
if ($failed) { $lines += "（$failed 檔資料抓取失敗，已略過）" }
$text = $lines -join "`n"
if ($text.Length -gt 4900) { $text = $text.Substring(0, 4900) + "`n…(太多，已截斷)" }

Write-Host ''
Write-Host $text
if ($DryRun) { return }

& $sendLine -Text $text
foreach ($h in $newCrosses) { $sent[$h.Code] = $today.ToString('yyyy-MM-dd') }
$sent | ConvertTo-Json | Set-Content -Encoding UTF8 $logFile
