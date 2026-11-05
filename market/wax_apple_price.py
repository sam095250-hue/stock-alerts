#!/usr/bin/env python3
"""查詢農產品批發市場行情(農業部開放資料 FarmTransData)。

預設:蓮霧-子彈型,台北一 / 台北二 / 三重區。

用法:
    python3 wax_apple_price.py
    python3 wax_apple_price.py --crop 蓮霧 --variety 子彈 --markets 台北一 台北二 三重區
    python3 wax_apple_price.py --variety 黑糖芭比 --markets 台北一 板橋區
"""
import argparse
import json
import sys
import urllib.parse
import urllib.request

API = "https://data.moa.gov.tw/Service/OpenData/FromM/FarmTransData.aspx"


def fetch(crop: str) -> list[dict]:
    url = f"{API}?{urllib.parse.urlencode({'Crop': crop, '$top': 5000})}"
    with urllib.request.urlopen(url, timeout=60) as resp:
        return json.load(resp)


def main() -> int:
    ap = argparse.ArgumentParser(description="查詢批發市場農產品行情")
    ap.add_argument("--crop", default="蓮霧", help="作物關鍵字(預設 蓮霧)")
    ap.add_argument("--variety", default="子彈", help="作物名稱需包含的字(預設 子彈)")
    ap.add_argument("--markets", nargs="+", default=["台北一", "台北二", "三重區"],
                    help="市場名稱(預設 台北一 台北二 三重區)")
    args = ap.parse_args()

    try:
        rows = fetch(args.crop)
    except Exception as e:  # noqa: BLE001
        print(f"查詢失敗:{e}", file=sys.stderr)
        return 1

    rows = [r for r in rows if args.variety in r["作物名稱"]]
    if not rows:
        print("查無資料")
        return 0

    dates = sorted({r["交易日期"] for r in rows}, reverse=True)
    latest = dates[0]
    names = sorted({r["作物名稱"] for r in rows})
    print(f"品項:{', '.join(names)}    單位:元/公斤    最新資料日:{latest}(民國年)\n")

    # 最新一日
    print(f"== {latest} ==")
    print(f"{'市場':<8}{'上價':>8}{'中價':>8}{'下價':>8}{'平均價':>8}{'交易量(kg)':>12}")
    by = {(r["交易日期"], r["市場名稱"]): r for r in rows}
    for m in args.markets:
        r = by.get((latest, m))
        if r:
            print(f"{m:<8}{r['上價']:>8}{r['中價']:>8}{r['下價']:>8}{r['平均價']:>8}{r['交易量']:>12}")
        else:
            prev = next((d for d in dates if (d, m) in by), None)
            note = f"(最近一筆 {prev} 平均 {by[(prev, m)]['平均價']})" if prev else ""
            print(f"{m:<8} 今日無交易 {note}")

    # 近幾日平均價
    print("\n== 近日平均價 ==")
    print(f"{'日期':<10}" + "".join(f"{m:>8}" for m in args.markets))
    for d in dates:
        cells = "".join(
            f"{by[(d, m)]['平均價']:>8}" if (d, m) in by else f"{'—':>8}"
            for m in args.markets
        )
        print(f"{d:<10}{cells}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
