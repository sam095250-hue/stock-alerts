# During trading hours (09:00-13:30), watch Taiwan stocks and ETFs and push to LINE the moment one
# crosses above its 20-week moving average, following the trend-swing course's rules: today's volume at
# least $MinLots lots (張) and above its $AvgDays-day average, trading above today's open (a red candle),
# the 20-week MA not falling, and paid-in capital at least $MinCapital NT$ for companies.
# Each stock is pushed at most once a day. This is only a technical filter, not a buy recommendation:
# the course treats standing above the 20-week MA as a first look, with the buy point at a trendline break.
#
# Usage:
#   .\intraday-alert.ps1                 # wait for the open, watch until the close, push to LINE
#   .\intraday-alert.ps1 -DryRun         # same, but print instead of sending
#   .\intraday-alert.ps1 -Once -DryRun   # one pass right now on the latest quotes (for testing on a closed day)
#
# The 20-week MA includes the current, still-forming week, so the price at which a stock crosses it is
# the average of the last 19 completed weekly closes. Those levels are computed once a week (the first
# run of the week takes ~15 minutes, from Yahoo) and cached in data\ma20-<monday>.json.
# "Crossing" means yesterday's close was at or below that level and the live price is now above it.
# Stocks that gapped up above the level at the open are pushed too, marked 跳空, since buying them
# means chasing a price that has already jumped.
param(
    [int]$Weeks = 20,
    [long]$MinLots = 5000,
    [int]$AvgDays = 5,
    [double]$MinCapital = 2000000000,
    [double]$FlatTolerance = 0.001,   # how far the 20-week MA may dip and still count as flat
    [int]$HighWeeks = 26,
    [int]$IntervalSeconds = 60,
    [switch]$Once,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\common.ps1')
$dataDir = Join-Path $PSScriptRoot 'data'
$sendLine = Join-Path $PSScriptRoot '..\line\send-line.ps1'
New-Item -ItemType Directory -Force $dataDir | Out-Null
if (-not $DryRun) { Start-Transcript -Path (Join-Path $dataDir 'intraday-last-run.log') -Force | Out-Null }
trap { Write-Crash $_ '盤中突破通知' $sendLine -DryRun:$DryRun; break }
Test-StockSetup $PSScriptRoot $sendLine -DryRun:$DryRun

$today = (Get-Date).Date
$monday = Get-WeekStart $today
$levelFile = Join-Path $dataDir "ma$Weeks-$($monday.ToString('yyyyMMdd')).json"
$sentFile = Join-Path $dataDir "intraday-$($today.ToString('yyyyMMdd')).json"
$taipei = [TimeZoneInfo]::FindSystemTimeZoneById('Taipei Standard Time')

# --- Crossing level per stock: average of the last ($Weeks - 1) completed weekly closes ---
if (Test-Path $levelFile) {
    $levels = Get-Content -Raw -Encoding UTF8 $levelFile | ConvertFrom-Json
    $levels = @($levels)   # (two steps: in PowerShell 5.1 ConvertFrom-Json emits the whole array as one item)
} else {
    $universe = @(Get-Universe 0 $MinCapital)
    Write-Host "Computing $Weeks-week levels for $($universe.Count) stocks..."
    $levels = @()
    $n = 0
    foreach ($stock in $universe) {
        $n++
        if ($n % 200 -eq 0) { Write-Host "  $n / $($universe.Count)" }
        $chart = Get-WeeklyChart $stock.Symbol
        if (-not $chart) { continue }
        $closes = $chart.indicators.quote[0].close
        $highs = $chart.indicators.quote[0].high
        $completed = @()
        $completedHighs = @()
        for ($i = 0; $i -lt $chart.timestamp.Count; $i++) {
            $week = [TimeZoneInfo]::ConvertTimeFromUtc([DateTimeOffset]::FromUnixTimeSeconds($chart.timestamp[$i]).UtcDateTime, $taipei)
            if ($week.Date -lt $monday -and $closes[$i] -ne $null) {
                $completed += [double]$closes[$i]
                $completedHighs += [double]$highs[$i]
            }
        }
        if ($completed.Count -lt $Weeks) { continue }   # too new to tell which way the 20-week MA is heading
        $levels += [pscustomobject]@{
            Code = $stock.Code; Name = $stock.Name; Market = $stock.Market; Ex = $stock.Ex
            Level = [math]::Round(($completed[(-$Weeks + 1)..-1] | Measure-Object -Average).Average, 4)
            PrevMA = [math]::Round(($completed[(-$Weeks)..-1] | Measure-Object -Average).Average, 4)
            High = ($completedHighs[(-[math]::Min($HighWeeks, $completedHighs.Count))..-1] | Measure-Object -Maximum).Maximum
        }
        Start-Sleep -Milliseconds 150
    }
    [IO.File]::WriteAllText($levelFile, ($levels | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding $true))
}
$levels = @($levels | Where-Object { $_.Code -notmatch $excludedEtf })   # the cache may predate the exclusion
$levelByCode = @{}
foreach ($l in $levels) { $levelByCode[$l.Code] = $l }

# --- Average daily volume in lots over the last $AvgDays completed trading days, recomputed daily ---
$avgFile = Join-Path $dataDir "vol$AvgDays-$($today.ToString('yyyyMMdd')).json"
$avgLots = @{}
if (Test-Path $avgFile) {
    (Get-Content -Raw $avgFile | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $avgLots[$_.Name] = [double]$_.Value }
} else {
    Write-Host "Computing $AvgDays-day average volume for $($levels.Count) stocks..."
    $n = 0
    foreach ($l in $levels) {
        $n++
        if ($n % 200 -eq 0) { Write-Host "  $n / $($levels.Count)" }
        $suffix = if ($l.Ex -eq 'otc') { 'TWO' } else { 'TW' }
        $chart = Get-Chart "$($l.Code).$suffix" '1mo' '1d'
        if (-not $chart) { continue }
        $volumes = $chart.indicators.quote[0].volume
        $past = @()
        for ($i = 0; $i -lt $chart.timestamp.Count; $i++) {
            $day = [TimeZoneInfo]::ConvertTimeFromUtc([DateTimeOffset]::FromUnixTimeSeconds($chart.timestamp[$i]).UtcDateTime, $taipei)
            # Zero-volume bars are market holidays (e.g. typhoon days) that Yahoo still lists.
            if ($day.Date -lt $today -and $volumes[$i] -gt 0) { $past += [double]$volumes[$i] }
        }
        if ($past.Count -lt $AvgDays) { continue }
        $avgLots[$l.Code] = [math]::Round(($past[($past.Count - $AvgDays)..($past.Count - 1)] | Measure-Object -Average).Average / 1000)
        Start-Sleep -Milliseconds 150
    }
    $avgLots | ConvertTo-Json -Compress | Set-Content $avgFile
}
Write-Host "Watching $($levels.Count) stocks."

$sent = @{}
if (Test-Path $sentFile) {
    $codes = Get-Content -Raw $sentFile | ConvertFrom-Json
    foreach ($c in $codes) { $sent[$c] = $true }
}

function Get-Quotes {
    $quotes = @()
    for ($i = 0; $i -lt $levels.Count; $i += 100) {
        $batch = $levels[$i..([math]::Min($i + 99, $levels.Count - 1))] | ForEach-Object { "$($_.Ex)_$($_.Code).tw" }
        try {
            $quotes += @((Get-Json ("https://mis.twse.com.tw/stock/api/getStockInfo.jsp?json=1&delay=0&ex_ch=" + ($batch -join '|'))).msgArray)
        } catch {
            Write-Host "  quote batch failed: $($_.Exception.Message)"
        }
        Start-Sleep -Milliseconds 500
    }
    $quotes
}

$open = $today.AddHours(9)
$close = $today.AddHours(13).AddMinutes(31)
if (-not $Once) {
    if ((Get-Date) -ge $close) { Write-Host 'Market already closed for today.'; return }
    while ((Get-Date) -lt $open) { Start-Sleep -Seconds 20 }
}

$todayStamp = $today.ToString('yyyyMMdd')
do {
    $started = Get-Date
    # A bad snapshot or network hiccup only skips this round; the watch keeps going until the close.
    try {
        $quotes = @(Get-Quotes)
        # On a holiday or typhoon day the API keeps returning the last trading day's quotes.
        if (-not $Once -and $started -gt $open.AddMinutes(5) -and -not ($quotes | Where-Object { $_.d -eq $todayStamp })) {
            Write-Host 'No quotes dated today: market closed.'
            return
        }

        $hits = @()
        foreach ($q in $quotes) {
            if (-not $q.c -or $q.y -notmatch '^\d' -or $q.v -notmatch '^\d') { continue }
            $l = $levelByCode[$q.c]
            # The last-trade price is often "-" between snapshots; fall back to the best bid.
            $last = if ($q.z -match '^\d') { $q.z } else { ($q.b -split '_')[0] }
            if (-not $l -or $sent[$q.c] -or $last -notmatch '^\d' -or $q.o -notmatch '^\d') { continue }
            $price = [double]$last
            $prev = [double]$q.y
            $openPrice = [double]$q.o
            $lots = [long]$q.v
            $avg = $avgLots[$q.c]
            $ratio = if ($avg -gt 0) { $lots / $avg } else { 0 }
            $heavy = $lots -ge $MinLots -and $ratio -gt 1
            $liveMA = ($l.Level * ($Weeks - 1) + $price) / $Weeks
            $notFalling = $liveMA -ge $l.PrevMA * (1 - $FlatTolerance)
            if ($prev -gt 0 -and $prev -le $l.Level -and $price -gt $l.Level -and $price -gt $openPrice -and $heavy -and $notFalling) {
                $hits += [pscustomobject]@{
                    Code = $q.c; Name = $l.Name; Market = $l.Market; Price = $price; Gap = $openPrice -gt $l.Level
                    Change = ($price - $prev) / $prev * 100; MA = $liveMA; Lots = $lots; Avg = $avg; Ratio = $ratio
                    NewHigh = $price -gt $l.High
                }
            }
        }

        if ($hits.Count) {
            $lines = @("🚀 盤中站上 $Weeks 週線", (Get-Date).ToString('MM/dd HH:mm'))
            $light = Get-MarketLight
            if ($light) { $lines += $light }
            $lines += ''
            foreach ($h in $hits | Sort-Object Code) {
                $tag = if ($h.NewHigh) { '★' } else { '' }
                if ($h.Gap) { $tag += '【跳空】' }
                $lines += "$tag$($h.Code) $($h.Name)（$($h.Market)）現價 $($h.Price)（$('{0:+0.00;-0.00}' -f $h.Change)%）｜$($Weeks)週線 $([math]::Round($h.MA, 2))｜量 $('{0:N0}' -f $h.Lots) 張（$($AvgDays)日均 $('{0:N0}' -f $h.Avg) 張，量比 $('{0:0.0}' -f $h.Ratio) 倍）｜跌到週線 1 張約賠 $('{0:N0}' -f (($h.Price - $h.MA) * 1000)) 元"
            }
            $lines += ''
            if ($hits | Where-Object NewHigh) { $lines += "★＝同時突破近 $HighWeeks 週高點。" }
            if ($hits | Where-Object Gap) { $lines += '【跳空】＝開盤就站上週線，已先漲一段，追價風險較高。' }
            $lines += '※ 站上週線只是初步觀察，趨勢線和型態請自己看圖。僅為技術條件篩選，不是買進建議。'
            $text = $lines -join "`n"
            if ($text.Length -gt 4900) { $text = $text.Substring(0, 4900) + "`n…(太多，已截斷)" }
            Write-Host $text
            if (-not $DryRun) {
                try { & $sendLine -Text $text } catch { Write-Host "LINE push failed: $($_.Exception.Message)" }
                foreach ($h in $hits) { $sent[$h.Code] = $true }
                ConvertTo-Json @($sent.Keys) | Set-Content $sentFile
            }
        } else {
            Write-Host "$((Get-Date).ToString('HH:mm:ss')) no new crossings ($($quotes.Count) quotes)"
        }
    } catch {
        Write-Host "$((Get-Date).ToString('HH:mm:ss')) round failed: $_"
        Write-Host $_.ScriptStackTrace
    }

    if ($Once) { break }
    $wait = $IntervalSeconds - ((Get-Date) - $started).TotalSeconds
    if ($wait -gt 0) { Start-Sleep -Seconds ([int]$wait) }
} while ((Get-Date) -lt $close)
