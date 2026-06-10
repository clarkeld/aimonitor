# AI Monitor

AI Monitor is a native macOS menu bar utility for checking DeepSeek and MiMo API balances and imported model token usage.

## Features

- SwiftUI `MenuBarExtra` panel inspired by the provided glass monitor UI.
- DeepSeek balance refresh through `GET https://api.deepseek.com/user/balance`.
- MiMo balance, Token Plan credits, and historical usage through official CSV/XLSX imports.
- Local SQLite storage for balances and token usage.
- Local owner-only API key storage under Application Support to avoid repeated login keychain prompts.
- Seven-day usage chart, daily/monthly spend, model-level token totals.

## Run

```sh
swift run AIMonitor
```

The app appears in the macOS menu bar. Open Settings from the gear button, save API keys, then import official usage files with the import button. MiMo does not expose a public balance/history API; for personal use you can paste MiMo Dashboard balance/usage URLs and Cookie, or import Dashboard files.

## Import Format

CSV/XLSX files should include these columns:

```csv
date,provider,model,prompt_tokens,completion_tokens,total_tokens,cost,currency
```

Optional columns:

```csv
cache_hit_tokens,credit_total,credit_used,credit_remaining,balance,total_balance
```

`provider` must be `deepseek` or `mimo`. MiMo Token Plan credits are read from the optional credit columns.
