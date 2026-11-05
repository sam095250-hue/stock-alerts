#!/usr/bin/env python3
"""查詢農產品批發市場行情(農業部開放資料 FarmTransData),可選擇推播到 LINE。

預設:蓮霧-子彈型,台北一 / 台北二 / 三重區。

用法:
    python3 market/wax_apple_price.py                 # 印出完整表格
    python3 market/wax_apple_price.py --variety 黑糖芭比 --markets 台北一 板橋區
    python3 market/wax_apple_price.py --line          # 推播精簡訊息到 LINE
    python3 market/wax_apple_price.py --line --dry-run  # 只印出會推播的訊息

--line 需要環境變數 LINE_CHANNEL_TOKEN 與 LINE_USER_ID。
"""
import argparse
import json
import os
import sys
import urllib.parse
import urllib.request

API = "https://data.moa.gov.tw/Service/OpenData/FromM/FarmTransData.aspx"
LINE_PUSH = "https://api.line.me/v2/bot/message/push"


def fetch(crop: str) -> list[dict]:
    url = f"{API}?{urllib.parse.urlencode({'Crop': crop, '$top': 5000})}"
    with urllib.request.urlopen(url, timeout=60) as resp:
        return json.load(resp)


def full_report(by, dates, names, markets) -> str:
    latest = dates[0]
    out = [f"品項:{', '.join(names)}    單位:元/公斤    最新資料日:{latest}(民國年)", ""]
    out.append(f"== {latest} ==")
    out.append(f"{'市場':<8}{'上價':>8}{'中價':>8}{'下價':>8}{'平均價':>8}{'交易量(kg)':>12}")
    for m in markets:
        r = by.get((latest, m))
        if r:
            out.append(f"{m:<8}{r['上價']:>8}{r['中價']:>8}{r['下價']:>8}{r['平均價']:>8}{r['交易量']:>12}")
        else:
            prev = next((d for d in dates if (d, m) in by), None)
            note = f"(最近一筆 {prev} 平均 {by[(prev, m)]['平均價']})" if prev else ""
            out.append(f"{m:<8} 今日無交易 {note}")
    out += ["", "== 近日平均價 ==", f"{'日期':<10}" + "".join(f"{m:>8}" for m in markets)]
    for d in dates:
        cells = "".join(
            f"{by[(d, m)]['平均價']:>8}" if (d, m) in by else f"{'—':>8}" for m in markets
        )
        out.append(f"{d:<10}{cells}")
    return "\n".join(out)


def line_message(by, dates, names, markets) -> str:
    latest = dates[0]
    out = [f"🍎 {'、'.join(names)} 批發行情", f"資料日 {latest}｜元/公斤"]
    for m in markets:
        r = by.get((latest, m))
        if r:
            out.append(f"{m}：均價 {r['平均價']}（上 {r['上價']}／下 {r['下價']}）量 {r['交易量']:g}kg")
        else:
            prev = next((d for d in dates if (d, m) in by), None)
            note = f"，最近 {prev} 均價 {by[(prev, m)]['平均價']}" if prev else ""
            out.append(f"{m}：今日無交易{note}")
    return "\n".join(out)


def push_line(text: str) -> None:
    token = os.environ.get("LINE_CHANNEL_TOKEN", "").strip()
    user = os.environ.get("LINE_USER_ID", "").strip()
    if not token or not user:
        raise SystemExit("缺少環境變數 LINE_CHANNEL_TOKEN 或 LINE_USER_ID")
    body = json.dumps({"to": user, "messages": [{"type": "text", "text": text}]}).encode("utf-8")
    req = urllib.request.Request(
        LINE_PUSH, data=body, method="POST",
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=30):
        pass


def main() -> int:
    ap = argparse.ArgumentParser(description="查詢批發市場農產品行情")
    ap.add_argument("--crop", default="蓮霧", help="作物關鍵字(預設 蓮霧)")
    ap.add_argument("--variety", default="子彈", help="作物名稱需包含的字(預設 子彈)")
    ap.add_argument("--markets", nargs="+", default=["台北一", "台北二", "三重區"],
                    help="市場名稱(預設 台北一 台北二 三重區)")
    ap.add_argument("--line", action="store_true", help="推播精簡訊息到 LINE")
    ap.add_argument("--dry-run", action="store_true", help="與 --line 併用:只印出訊息,不推播")
    args = ap.parse_args()

    try:
        rows = fetch(args.crop)
    except Exception as e:  # noqa: BLE001
        print(f"查詢失敗:{e}", file=sys.stderr)
        return 1

    rows = [r for r in rows if args.variety in r["作物名稱"]]
    if not rows:
        print("查無資料")
        return 1 if args.line else 0

    dates = sorted({r["交易日期"] for r in rows}, reverse=True)
    names = sorted({r["作物名稱"] for r in rows})
    by = {(r["交易日期"], r["市場名稱"]): r for r in rows}

    if not args.line:
        print(full_report(by, dates, names, args.markets))
        return 0

    text = line_message(by, dates, names, args.markets)
    print(text)
    if args.dry_run:
        print("\n(dry-run:未推播)")
        return 0
    try:
        push_line(text)
    except Exception as e:  # noqa: BLE001
        print(f"LINE 推播失敗:{e}", file=sys.stderr)
        return 1
    print("\nSent")
    return 0


if __name__ == "__main__":
    sys.exit(main())
