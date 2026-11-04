# Taiwan stock alerts

Pushes technical-filter lists for Taiwan stocks to LINE, from GitHub Actions. This is only a technical filter, not investment advice.

- `Intraday alert`: 20-week moving average breakouts during trading hours
- `After-close list`: the evening lists
- `Connection test`: checks the data sources answer from GitHub's machines

Needs the repository secrets `LINE_CHANNEL_TOKEN` and `LINE_USER_ID`. Both workflows only print their results until `DRY_RUN` is set to `'false'` in the workflow file.
