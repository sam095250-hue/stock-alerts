# Taiwan stock alerts

Pushes technical-filter lists for Taiwan stocks to LINE, from GitHub Actions. This is only a technical filter, not investment advice.

- `Intraday alert`: 20-week moving average breakouts during trading hours
- `After-close list`: the evening lists
- `Connection test`: checks the data sources answer from GitHub's machines

Needs the repository secrets `LINE_CHANNEL_TOKEN` and `LINE_USER_ID`. Both workflows only print their results until `DRY_RUN` is set to `'false'` in the workflow file.

## Produce market prices

`market/wax_apple_price.py` looks up wholesale prices from the Ministry of Agriculture open data (default: bullet-type wax apple at 台北一, 台北二, 三重區). Needs only Python 3.

```
python3 market/wax_apple_price.py
python3 market/wax_apple_price.py --variety 黑糖芭比 --markets 台北一 板橋區
```

The `Wax apple price` workflow runs it every day at 11:17 Taipei time and pushes a short message to LINE (same `LINE_CHANNEL_TOKEN` / `LINE_USER_ID` secrets). Set `DRY_RUN` to `'true'` in `.github/workflows/wax-apple-price.yml` to only print the message. Locally, `--line --dry-run` shows the message without sending.
