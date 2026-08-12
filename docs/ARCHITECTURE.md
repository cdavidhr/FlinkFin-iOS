# Architecture — FlinkFin iOS

This document describes the internal architecture of the FlinkFin iOS app in detail.

## High-Level Flow

```
App Launch
    │
    ▼
FlinkFinApp.swift
    │
    ├─► [No credentials] ──► OnboardingCredentialsView
    │                              │
    │                              ▼
    │                         User imports service_account.json
    │                         → stored in Keychain
    │                         → spreadsheetId stored in UserDefaults
    │
    └─► [Credentials exist] ──► ContentView (TabView)
                                    │
                                    ▼
                               PortfolioStore.refresh()
                                    │
                        ┌───────────┼────────────────┐
                        ▼           ▼                ▼
               GoogleSheets     YahooFinance     TradingView
               Client           Client           Scanner API
                        │           │                │
                        └───────────┴────────────────┘
                                    │
                                    ▼
                              PortfolioEngine
                              .computeHoldings()
                                    │
                                    ▼
                           RecommendationEngine
                           .generateSignals()
                                    │
                                    ▼
                            @Published properties
                            → SwiftUI views update
```

---

## Layer 1: Models

### `Transaction.swift`
Represents a single buy or sell event read from Google Sheets.

```swift
struct Transaction {
    var date: Date
    var ticker: String
    var action: String    // "buy" | "sell"
    var shares: Double
    var pricePerShare: Double
    var currency: String  // "USD" | "SGD" | "HKD" | "AUD"
    var fees: Double
}
```

### `Holding.swift`
An aggregated position — the result of netting all transactions for a given ticker. Also carries live market data populated by `PortfolioStore` after fetching prices and analyst targets.

Key fields:
- `ticker`, `name`, `currency`, `exchange`
- `shares`, `avgCost`, `totalCost`
- `livePrice`, `marketValue`, `unrealizedPL`, `unrealizedPLPct`
- `avgTarget`, `minTarget`, `maxTarget` — analyst consensus targets
- `recommendationKey` — TradingView / Yahoo rating string

### `HistoryPoint.swift`
A `(date, value)` pair used to build the performance chart. Read directly from the Google Sheet's history tab.

---

## Layer 2: Networking

### `SecureCredentialStore.swift`

Central gateway to credential storage. Uses `SecItemAdd` / `SecItemCopyMatching` with:
- `kSecClass = kSecClassGenericPassword`
- `kSecAttrAccessible = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`

This means credentials survive app restarts and device reboots (after first unlock), but are not backed up to iCloud and are device-specific.

The spreadsheet ID is stored separately in `UserDefaults` because it is not a secret.

### `JWTSigner.swift`

Google's service account authentication requires a **RS256-signed JWT**. This file:

1. Parses the PEM-encoded RSA private key from the service account JSON.
2. Manually strips the PKCS#8 DER wrapper to get the raw PKCS#1 RSA key bytes (Apple's `SecKeyCreateWithData` for RSA requires PKCS#1 format).
3. Creates a `SecKey` from those bytes.
4. Signs the JWT header+payload using `SecKeyCreateSignature` with `.rsaSignatureMessagePKCS1v15SHA256`.
5. Returns a base64url-encoded JWT.

This JWT is then exchanged for an OAuth2 access token at `https://oauth2.googleapis.com/token`.

**Why not use a library?** The decision was made to keep zero SPM dependencies in the code that handles private key material. See `AGENTS.md` for the full rationale.

### `GoogleSheetsClient.swift`

Reads four ranges from the spreadsheet via the Sheets API v4:
- **Transactions**: all buy/sell records
- **FX history**: historical exchange rates (fallback if Yahoo FX fails)
- **Portfolio history**: pre-computed portfolio value over time
- **Holdings metadata**: names, sectors, etc.

Each request:
1. Calls `accessToken()` → which checks the cached token (refreshes if expired via `JWTSigner`)
2. Builds a `GET` to `https://sheets.googleapis.com/v4/spreadsheets/{id}/values/{range}`
3. Adds `Authorization: Bearer {token}`
4. Decodes the `[[Any]]` values array

**Header row skip discrepancy**: `fetchPortfolioHistory()` skips 1 header row while the Python `parse_history()` skips 2. This is intentionally preserved to match the existing Python behavior — see inline comment for details.

### `YahooFinanceClient.swift`

This is the most complex networking file. It has three distinct responsibilities:

#### A) Price fetching (`fetchPrices`, `fetchFXRates`, `fetchSparklines`)

Uses `query1.finance.yahoo.com/v8/finance/chart/{ticker}?range=5d&interval=1d`.

- Returns OHLCV arrays in the `indicators.quote` field.
- `fetchPrices` takes the last non-nil close value.
- `fetchSparklines` returns the last N close values for the mini-chart.
- `fetchFXRates` fetches pairs like `USDSGD=X`.

#### B) Analyst targets (`fetchAnalystTargets`)

Three-tier fallback:

**Tier 1 — TradingView Scanner API** (primary):
```
POST https://scanner.tradingview.com/global/scan
Content-Type: application/json

{
  "symbols": { "tickers": ["NASDAQ:PLTR", "SGX:D05", "LSE:VWRA", "ASX:WEB"] },
  "columns": ["name", "price_target_average", "price_target_high",
              "price_target_low", "recommendation_mark"]
}
```
- Free, no API key, works for all major global exchanges.
- `recommendation_mark`: 1.0 (Strong Buy) → 5.0 (Strong Sell).
- `tradingViewSymbol(for:)` converts Yahoo-style tickers to TradingView format:
  - `D05.SI` → `SGX:D05`
  - `VWRA.L` → `LSE:VWRA`
  - `WEB.AX` → `ASX:WEB`
  - `PLTR` → `PLTR` (TradingView auto-resolves US tickers)

**Tier 2 — Yahoo Finance `quoteSummary`** (secondary):
```
GET https://query1.finance.yahoo.com/v10/finance/quoteSummary/{ticker}
    ?modules=financialData&crumb={crumb}
```
Requires a session crumb. The crumb is obtained by:
1. Seeding cookies via `fc.yahoo.com` and `finance.yahoo.com`
2. Fetching `query1.finance.yahoo.com/v1/test/getcrumb`

Uses a **dedicated `URLSession`** with `HTTPCookieStorage.shared` and `httpCookieAcceptPolicy = .always`. This is critical — `URLSession.shared` does not reliably persist cookies across sequential async calls on iOS.

**Tier 3 — Finviz** (US-only fallback):
HTML scraping of `finviz.com/quote.ashx?t={ticker}`. Only attempted for tickers without a `.` (i.e., US tickers).

#### C) Quote detail (`fetchQuoteDetail`)

Uses the same v8 chart endpoint with `range=1y&interval=1d` to compute:
- Current price from `meta.regularMarketPrice`
- 52-week high/low from `meta.fiftyTwoWeekHigh/Low` (or calculated from the 1-year close series)

Fields that require `quoteSummary` (PE, beta, market cap) are returned as `nil` since that endpoint requires a crumb that may not always be available.

---

## Layer 3: Engine

### `PortfolioEngine.swift`

Pure Swift, no async, no side effects. Takes `[Transaction]` and returns `[Holding]`.

Algorithm:
1. Group transactions by ticker.
2. For each ticker, process transactions chronologically:
   - **Buy**: add shares, update average cost (weighted average).
   - **Sell**: subtract shares, cost basis follows FIFO-ish average.
3. Filter out fully-closed positions (shares ≈ 0).
4. Convert all cost bases to SGD using FX rates.

This mirrors `compute_holdings()` in `database.py` of the Python dashboard. If the Python logic changes, this file must be updated in sync.

### `RecommendationEngine.swift`

Pure function: `func generateSignals(holdings: [Holding], prices: [String: Double]) -> [RecommendationSignal]`

Scoring (see README for the full table):
- Analyst rating from `recommendationKey` → +3/+2/+1
- Current price vs. analyst targets (mean, low, high) → ±1/±2

Final signal:
- `score ≥ 4` → **STRONG BUY**
- `score ≥ 2` → **BUY**
- `score 0–1` → **HOLD**
- `score < 0` → **TAKE PROFIT**

Important: personal unrealized P&L does **not** affect the score. The recommendation reflects only what the market thinks of the stock, not whether you bought at a good price.

### `PortfolioStore.swift`

The `@MainActor ObservableObject` that:
1. Holds all state consumed by views (`holdings`, `history`, `prices`, `fxRates`, `signals`).
2. Coordinates the `refresh()` async pipeline:
   - Fetch transactions from Sheets
   - Fetch prices and FX from Yahoo (parallel `TaskGroup`)
   - Compute holdings (`PortfolioEngine`)
   - Fetch analyst targets (`YahooFinanceClient.fetchAnalystTargets`)
   - Enrich holdings with live prices and targets
   - Run recommendation engine
   - Fetch portfolio history from Sheets
3. Publishes `isLoading` and `error` for the UI.

---

## Layer 4: Views

All views are SwiftUI with `@EnvironmentObject var store: PortfolioStore`.

| View | Description |
|---|---|
| `OnboardingCredentialsView` | File picker for service account JSON + spreadsheet ID field |
| `OverviewView` | Hero card with total value, P&L, and a sparkline chart |
| `HoldingsView` | List of all positions with live price and P&L badge |
| `PerformanceView` | Line chart of portfolio value over time (multiple periods) |
| `RecommendationsView` | Signal cards with analyst target ranges, upside %, and key factors |
| `TransactionsView` | Chronological list of all buy/sell transactions |

---

## Threading Model

- All networking is `async/await` on Swift's cooperative thread pool.
- `PortfolioStore` is `@MainActor` — UI updates happen on the main thread automatically.
- `withTaskGroup` is used for concurrent fetching (prices, sparklines, FX, analyst targets all in parallel).
- `YahooFinanceClient` methods are `static func` — stateless, safe to call from any actor.

---

## Error Handling

- Network errors: silently logged; last known data is kept in state.
- Credential errors: `PortfolioStore.error` is set and shown in the UI via an alert.
- Missing analyst coverage: holding is kept; signal falls back to the no-coverage path in `RecommendationEngine`.
- Partial data: if some tickers fail to get prices, those holdings show `--` in the UI.
