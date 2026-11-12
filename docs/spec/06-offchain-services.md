# 06 · Off-chain services

Scope: the processes that run the vaults. The L1 contracts bound custody (assets only move between the vault, its Derive account and claimants), and Derive bounds each key's scopes. These services decide everything else, so they are built to check each other.

---

## 1. Services

| Service | Runs | Keys | Main job |
|---|---|---|---|
| Strategy service | Continuously, 5-minute cycle | `K_hedge`, `K_spot` | Read the Derive account, compute `δ`, hedge, choose strikes, prepare option trades |
| Operator ×3 (signer + attester) | Continuously | One `K_option` threshold share; one attester key | Co-sign option trades under the active policy; snapshot Derive and sign NAV reports |
| Round processor | At each cutoff | An L1 gas key (calls `withdrawToVault`) | Submit the NAV report, `processRound`, rebalance the buffer, gateway `flush`/`settle*` |
| Reporter | After each round and each expiry | none | Public reports; diff of every NAV report against Derive's `margin_watch` |
| Monitor | Continuously | none | Metrics, alerts, policy-breach detection, backup-keeper heartbeat |

Every service is layered: **repository** (Derive API, L1/Base RPC, database) → **service** (pure decisions) → **executor** (orders, transactions). Decisions never touch the network, so the whole decision path can be replayed against recorded market data.

---

## 2. Strategy service

### 2.1 Cycle (every 5 min, 1 min in fast mode, and on any fill)

1. **Snapshot.** Read the Derive subaccount (`private/get_subaccount`: positions, collaterals, margin) and the L1 vault (buffer, in-transit amounts, state).
2. **Reconcile.** Compare with the previous snapshot and the open orders. Any unexplained change pauses decisions for that vault and pages.
3. **Compute.** `δ`, `NAV_$`, margin ratio, distance to the breaker, funding since the last cycle.
4. **Decide.** Run the band logic ([03 §4.2](03-strategy-execution.md#42-delta-engine)) and, inside the sell window, strike selection ([03 §2](03-strategy-execution.md#2-strike-and-size-selection)).
5. **Execute.** Hedges and cash-leg trades are signed with `K_hedge` / `K_spot`. Option trades are sent to the three operators for threshold signing.

### 2.2 Order management

- Client ids derive from `(vault, epoch, cycle, leg)`, so a retry never duplicates an order.
- Hedges are IOC at the worst acceptable price; whatever doesn't fill is re-decided next cycle.
- Option sales go to RFQ first, then the ladder ([03 §2.3](03-strategy-execution.md#23-execution)).
- Before sending anything, the executor checks it against the active policy. A rejection is a bug, so it alerts.

---

## 3. Operators

Each operator runs on its own cloud account and RPC providers, with its own deploy pipeline, and does two jobs.

**Co-signing option trades.** An operator contributes its `K_option` share only if all of these hold:
1. It loaded the policy document, and its hash matches `PolicyRegistry.activeHash()` on L1.
2. It re-read the vault state on L1 (`ACTIVE`, or `REDUCE_ONLY` for buy-to-close only) and the Derive account itself, not through the strategy service.
3. The trade passes every policy rule for its action ([03 §6](03-strategy-execution.md#6-action-policy)), computed from its own reads.
4. No alert is open for the vault.

**Attesting NAV.** At each cutoff (and every 15 min for display), the operator:
1. snapshots the subaccount through its own Derive session (read-only key),
2. fetches signed feeds from `public/get_latest_signed_feeds`,
3. builds the `NavReport` ([02 §2](02-nav-oracle.md#2-report)),
4. recomputes the on-chain checks locally, and signs only if they pass.

The round processor collects `k` signatures and submits.

---

## 4. Round processor

Per round, each step idempotent and checking on-chain state first:

1. At `cutoff − spokeLead`: `flush` the Base batch.
2. At `cutoff`: collect attester signatures; `submitReport`.
3. `processRound(r)`.
4. `settleDeposit` / `settleRedeem` on `SpokeAdapter`.
5. Rebalance the buffer ([01 §6](01-vault-accounting.md#6-liquidity-buffer-and-reserves)): deposit the surplus to Derive, or ask the strategy to free collateral and then call `DeriveAccountModule.withdrawToVault` (lands in about 10–15 min).

A backup processor on separate infrastructure takes over if a step misses its deadline.

---

## 5. Epoch report

Published after each weekly rollover as JSON plus a readable page. Every number can be rebuilt from L1 events and Derive history. The values below are an illustration: flat price, 7.5% buffer left unsold, one mid-week round with flows.

```json
{
  "vault": "CC-ETH", "epoch": 12, "expiry": "2027-01-29T08:00:00Z",
  "nav": { "start": "1000.0000", "end": "1033.0306", "unit": "WETH" },
  "pps": { "start": "1.0000000", "end": "1.0023160" }, "hwm": "1.0023160",
  "rounds": { "processed": 41, "skippedForBlackout": 1, "maxWaitMinutes": 262 },
  "flows": { "deposits": "50.0", "redemptions": "19.9994", "swingIncome": "0.0700" },
  "fees": { "management": "0.3836", "performance": "0.3865" },
  "options": [ { "type": "call", "strike": 3650, "qty": -925.0, "deltaAtSale": 0.152,
                 "venue": "rfq", "avgPremiumUsd": 13.65, "settlementPrice": 3412.5, "payoutUsd": 0.0 } ],
  "pnl": { "premium": "3.7000", "optionPnL": "0.0000", "hedgePnL": "0.0000",
           "executionCost": "0.7400", "unit": "WETH" },
  "hedging": { "band": [0.70, 0.90], "actions": 9, "turnoverNav": 0.41, "fundingPaid": "0.1200" },
  "liquidity": { "bufferAvg": "7.4%", "bufferMin": "4.1%", "maxUnfundedHours": 0 },
  "nav_oracle": { "reports": 712, "held": 0, "maxDiffVsMarginWatch": "0.03%" },
  "policy": { "activeHash": "0x…", "changedThisEpoch": false }
}
```

---

## 6. Monitoring and alerts

| Metric | Warn | Page | Failure mode |
|---|---|---|---|
| Strategy heartbeat | 1 missed cycle | 3 missed → backup | F1 |
| Round not processed by `cutoff + navMaxDelay` | — | yes | F2 |
| NAV report vs `margin_watch` | > 0.1% | > `navTolerance` | F11 |
| Feed or Chainlink age | > 60 s | > `feedMaxAge` | F3 |
| `δ` outside the band + `τ` | > 1 cycle | > 3 cycles | F6 |
| Margin ratio | < 3× | < 2× | F7 |
| Buffer | < `bufferMin` | `reserveUnfunded` older than 6 h | F5 |
| Distance to breaker | < 2% | < 1% | F6 |
| Any fill outside policy | — | yes → guardian | F9, F10 |
| Session key expiring | < 7 days | < 2 days | — |
| Base batch not settled by `cutoff + 1 h` | yes | `+ 4 h` | F13 |

---

## 7. Environments

| Environment | L1 | Derive | Base | Purpose |
|---|---|---|---|---|
| Local | Fork of Ethereum | mocked API + recorded data | Fork of Base | Contract tests, invariants, replay |
| Testnet | Sepolia | Derive v3 testnet (Sepolia) | Base Sepolia | End-to-end: rounds, weekly cycle, withdrawal latency measurement |
| Canary | Ethereum | Derive mainnet | Base | Small `tvlCap` |
| Mainnet | Ethereum | Derive mainnet | Base | Gradual `tvlCap` increases |
