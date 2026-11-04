# Helpers shared by the stock scripts. Dot-source it: . (Join-Path $PSScriptRoot 'lib\common.ps1')

$headers = @{ 'User-Agent' = 'Mozilla/5.0' }

# Invoke-RestMethod in PowerShell 5.1 mis-decodes Chinese names, so decode the bytes as UTF-8 ourselves.
# Retries a few times: the TWSE/TPEx feeds occasionally time out or return a half-updated page.
function Get-Json([string]$Url) {
    for ($try = 1; ; $try++) {
        try {
            $resp = Invoke-WebRequest $Url -Headers $headers -UseBasicParsing -TimeoutSec 30
            return [Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray()) | ConvertFrom-Json
        } catch {
            if ($try -ge 3) { throw }
            Start-Sleep -Seconds (5 * $try)
        }
    }
}

# Log an unexpected error with where it happened, and tell the user on LINE that the program stopped.
function Write-Crash($ErrorRecord, [string]$Program, [string]$SendLine, [switch]$DryRun) {
    Write-Host "ERROR: $ErrorRecord"
    Write-Host $ErrorRecord.ScriptStackTrace
    if (-not $DryRun) {
        try { & $SendLine -Text "⚠️ $Program 執行出錯而停止：$ErrorRecord" } catch { Write-Host "LINE push failed: $_" }
    }
}

# The scheduled tasks and scripts that make up the alerts. Task and script names must stay in step
# with what is registered in Task Scheduler.
$stockTasks = '盤中突破20週線通知', '盤後趨勢波段名單'
$stockScripts = 'intraday-alert.ps1', 'after-close.ps1'

# Something outside these scripts removed a task and a script before (2026-10-28, cause never found),
# so each run checks for the other parts and warns on LINE instead of failing silently for days.
function Test-StockSetup([string]$ScriptRoot, [string]$SendLine, [switch]$DryRun) {
    if ($env:GITHUB_ACTIONS) { return }   # no Task Scheduler in the cloud; GitHub reports failed runs itself
    $missing = @()
    foreach ($t in $stockTasks) {
        if (-not (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue)) { $missing += "排程「$t」" }
    }
    foreach ($s in $stockScripts) {
        if (-not (Test-Path (Join-Path $ScriptRoot $s))) { $missing += "程式 $s" }
    }
    if ($missing.Count -eq 0) { return }
    $text = "⚠️ 選股通知有東西不見了：$($missing -join '、')。請告訴 Claude 修復。"
    Write-Host $text
    if (-not $DryRun) {
        try { & $SendLine -Text $text } catch { Write-Host "LINE push failed: $_" }
    }
}

# Monday of the week a date falls in.
function Get-WeekStart([datetime]$Date) { $Date.Date.AddDays(-(([int]$Date.DayOfWeek + 6) % 7)) }

# Paid-in capital in NT$ by company code, from the TWSE and TPEx company lists.
function Get-CapitalMap {
    $map = @{}
    $listed = Get-Json 'https://openapi.twse.com.tw/v1/opendata/t187ap03_L'
    foreach ($c in $listed) { $map["$($c.公司代號)"] = [double]$c.實收資本額 }
    $otc = Get-Json 'https://www.tpex.org.tw/openapi/v1/mopsfin_t187ap03_O'
    foreach ($c in $otc) { $map["$($c.SecuritiesCompanyCode)"] = [double]$c.'Paidin.Capital.NTDollars' }
    $map
}

# The course's market light from the TAIEX against its 20- and 100-day averages; $null if unavailable.
function Get-MarketLight {
    try {
        $chart = Get-Chart '%5ETWII' '1y' '1d'
        $closes = @()
        foreach ($c in $chart.indicators.quote[0].close) {
            # Yahoo repeats the last close on holidays such as typhoon days.
            if ($c -ne $null -and ($closes.Count -eq 0 -or $c -ne $closes[-1])) { $closes += [double]$c }
        }
        $index = $closes[-1]
        $ma20 = ($closes[-20..-1] | Measure-Object -Average).Average
        $ma100 = ($closes[-100..-1] | Measure-Object -Average).Average
        $light = if ($index -gt $ma20 -and $index -gt $ma100) { '🔴 紅燈（多頭）' }
            elseif ($index -gt $ma100) { '🟠 紅黃燈（多頭拉回）' }
            elseif ($index -gt $ma20) { '🟡 綠黃燈（空頭反彈）' }
            else { '🟢 綠燈（空頭）' }
        "大盤 $light｜指數 $([math]::Round($index))｜日20 $([math]::Round($ma20))｜日100 $([math]::Round($ma100))"
    } catch {
        Write-Host "Market light unavailable: $_"
        $null
    }
}

# Leveraged (L), inverse (R) and bond (B) ETFs: a breakout means something else for them, so skip them.
$excludedEtf = '^00\d{2,4}[LRB]$'

# Common stocks (4-digit codes not starting with 0) and ETFs (codes starting with 00) on TWSE and TPEx,
# with the latest day's volume at least $MinVolume shares; drops warrants, preferred shares, the ETFs
# above and the like. Companies known to have less than $MinCapital NT$ of paid-in capital are dropped
# too (ETFs have no such figure). Ex is the prefix the TWSE real-time quote API uses (tse / otc).
function Get-Universe([long]$MinVolume = 0, [double]$MinCapital = 0) {
    $capital = if ($MinCapital -gt 0) { Get-CapitalMap } else { @{} }
    $stockCode = '^[1-9]\d{3}$'
    $etfCode = '^00\d{2,4}[A-Z]?(?<![LRB])$'
    # (Assign before looping: in PowerShell 5.1 ConvertFrom-Json emits the whole array as one item.)
    $twse = Get-Json 'https://openapi.twse.com.tw/v1/exchangeReport/STOCK_DAY_ALL'
    $tpex = Get-Json 'https://www.tpex.org.tw/openapi/v1/tpex_mainboard_daily_close_quotes'
    $list = @()
    foreach ($s in $twse) {
        if ($capital.ContainsKey($s.Code) -and $capital[$s.Code] -lt $MinCapital) { continue }
        if (($s.Code -match $stockCode -or $s.Code -match $etfCode) -and [long]$s.TradeVolume -ge $MinVolume) {
            $market = if ($s.Code -match $etfCode) { '上市ETF' } else { '上市' }
            $list += [pscustomobject]@{ Code = $s.Code; Name = "$($s.Name)".Trim(); Market = $market; Symbol = "$($s.Code).TW"; Ex = 'tse' }
        }
    }
    foreach ($s in $tpex) {
        $code = $s.SecuritiesCompanyCode
        if ($capital.ContainsKey($code) -and $capital[$code] -lt $MinCapital) { continue }
        if (($code -match $stockCode -or $code -match $etfCode) -and [long]$s.TradingShares -ge $MinVolume) {
            $market = if ($code -match $etfCode) { '上櫃ETF' } else { '上櫃' }
            $list += [pscustomobject]@{ Code = $code; Name = "$($s.CompanyName)".Trim(); Market = $market; Symbol = "$code.TWO"; Ex = 'otc' }
        }
    }
    $list
}

# Bars from Yahoo, retrying a few times; $null when the symbol can't be fetched.
function Get-Chart([string]$Symbol, [string]$Range, [string]$Interval) {
    for ($try = 1; $try -le 3; $try++) {
        try {
            return (Get-Json "https://query1.finance.yahoo.com/v8/finance/chart/$($Symbol)?range=$Range&interval=$Interval").chart.result[0]
        } catch {
            Start-Sleep -Seconds (2 * $try)
        }
    }
    $null
}

# Weekly bars, about 3 years.
function Get-WeeklyChart([string]$Symbol) { Get-Chart $Symbol '3y' '1wk' }
