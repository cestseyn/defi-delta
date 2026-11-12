# 05 · Risk and governance

Scope: who can do what, every parameter with its bounds and where it is enforced, the breaker, upgrades, and what happens when things break.

---

## 1. Roles

| Role | Holder | Can | Cannot |
|---|---|---|---|
| `owner` | Governance multisig (proposed 3-of-5) behind the `Timelock` | Change L1 parameters within hard bounds; activate a new policy hash (§3.6); add attesters, signers or keepers; approve new session keys or scopes; resume a vault; upgrade after the freeze | Bypass the timelock; exceed a hard bound; grant a forbidden scope; move assets |
| `guardian` | Separate fast multisig (proposed 2-of-4) | Set `REDUCE_ONLY`; **revoke any Derive session key from L1**; remove an attester or signer; tighten fast-tighten parameters; confirm a held NAV report; pause gateway `flush` | Resume; add anyone; loosen anything; change fees; move assets |
| `attesters` | `n` = 3 independent operators | Sign NAV reports (`k` = 2) ([02](02-nav-oracle.md)) | Anything else |
| `signers` | The same 3 operators as attesters, on separate keys | Hold the 2-of-3 threshold key `K_option` ([03 §1.2](03-strategy-execution.md#12-session-keys)) and co-sign option trades under the active policy | Sign anything when the vault isn't `ACTIVE` (except buy-to-close in `REDUCE_ONLY`) |
| `keeper` | Strategy service and round processor | Hold `K_hedge`, `K_spot`; trigger `withdrawToVault`; renew already-approved keys; rebalance the buffer; submit reports for processing; `checkpoint()` | Sell options; change parameters; add keys or scopes |
| anyone | — | `processRound`, `checkpoint`, `triggerBreaker`, claims, gateway `flush` and claims | — |

Principle: **reducing risk is fast, adding risk is slow.** Revoking a key, removing an attester or tightening a limit takes one guardian transaction. Adding any of those waits out the timelock.

**Resume** (from `REDUCE_ONLY` or `PAUSED` to `ACTIVE`): owner multisig, **no timelock**, effective from the next round. Resuming restores parameters that already went through the timelock, so it changes nothing users didn't have a chance to exit from.

---

## 2. Hard limits (immutable on L1)

| Limit | Value |
|---|---|
| Management fee | ≤ 3% per year |
| Performance fee | ≤ 25% |
| Swing | ≤ 1% each side, any tier |
| Buffer bounds | `0 ≤ bufferMin ≤ bufferTarget ≤ bufferMax ≤ 30%` |
| Asset paths | L1 vault → Derive account (`OnchainActionManager.deposit`); Derive → `DeltaVault` (owner's L1 `withdraw`, recipient fixed in code); vault → claimants; fee shares → FeeCollector |
| Scopes `DeriveAccountModule` may grant | `trade:orderbook:perp`, `trade:orderbook:option`, `trade:rfq:option`, `trade:orderbook:spot`, always bound to the vault's subaccount ID. Anything else (including `withdraw`, `transfer:*`, `admin`) reverts |
| Session key expiry | ≤ 30 days |
| NAV attestation | `k ≥ 2`, `n ≥ 3`; feed and Chainlink checks always on ([02 §3](02-nav-oracle.md#3-verification)) |
| Timelock delay | ≥ 7 days |
| Upgrade freeze | No upgrade before launch + 180 days |

---

## 3. Parameter registry

"Where" says what enforces each value:
- **L1:** checked by a contract.
- **policy:** checked by the threshold signers (for option trades) and the monitor (for every key), against the policy whose hash is active on L1 (§3.6).

### 3.1 Vault and rounds

| Parameter | Unit | Default | Bounds | Where |
|---|---|---|---|---|
| `mgmtFee` / `perfFee` | per year / of gains over HWM | 2% / 15% | hard caps | L1 |
| `roundSchedule` | `WEEKLY_AT_EXPIRY` / `INTERVAL` | **`WEEKLY_AT_EXPIRY` in phase 1** | — | L1 |
| `roundLength` (`INTERVAL` only) | seconds | 4 h | 1–24 h | L1 |
| `navMaxDelay` | seconds after cutoff | 20 min | 5–60 min | L1 |
| `swingIn` / `swingOut` (normal) | of `pps` | phase 1: 0 · phase 2: 10 bps / 10 bps | 0–100 bps | L1 |
| `swingIn` / `swingOut` (large) | of `pps` | phase 1: 0 · phase 2: 30 bps / 30 bps | 0–100 bps | L1 |
| `largeFlow` | net flow / NAV | 5% | 1–50% | L1 |
| `bufferMin` / `bufferTarget` / `bufferMax` | of NAV | phase 1: 0 / 0 / 0 · phase 2: 2.5% / 7.5% / 12.5% | hard bounds | L1 |
| `crystallizeMaxInterval` | seconds | 7 days | 1–30 days | L1 |
| `minDeposit` | asset | CC 0.01 WETH · CSP 25 USDC | > 0 | L1 |
| `tvlCap` | asset | per vault | ≥ 0 | L1, fast-tighten |

### 3.2 NAV oracle

| Parameter | Default | Bounds | Where |
|---|---|---|---|
| `k` / `n` | 2 / 3 | hard minimums | L1 |
| `navMaxAge` | 10 min | 1–30 min | L1 |
| `feedMaxAge` | 120 s | 10–600 s | L1 |
| `maxSourceDeviation` (Derive vs Chainlink spot) | 2% | 0.5–5% | L1 |
| `navTolerance` (own valuation vs Derive MtM) | 0.25% | 0.05–1% | L1 |
| `navJumpTolerance` | 0.5% | 0.1–3% | L1 |
| `confirmDelay` | 15 min | 5–120 min | L1 |

### 3.3 Option selling

| Parameter | Default | Where |
|---|---|---|
| `optionDeltaMin` / `Target` / `Max` | 0.10 / 0.15 / 0.20 (`Max` < 0.5) | policy |
| `minPremium` | 0.30% of notional per epoch | policy |
| `maxSpread` | 5% of premium | policy |
| `ladderStep` / `ladderInterval` / `sellWindow` | 2% / 10 min / 6 h | policy |
| `minSellTimeLeft` | 2 days | policy |
| `volFactorSell` / `volFactorBuy` | 0.95 / 1.10 | policy |
| `maxStrikesPerEpoch` | 4 | L1 (NAV report size) and policy |

### 3.4 Delta engine and hedging

| Parameter | Default | Where |
|---|---|---|
| Band `L / c / U` | CC 0.70 / 0.80 / 0.90 · CSP 0.00 / 0.10 / 0.20 | policy |
| `τ` / `τFast` / `fastMove` | 0.05 / 0.02 / 4% in 5 min | policy |
| `perpCap` | 1.0 × NAV | policy |
| `maxHedgePerTx` | 0.10 × NAV (ETH delta) | policy |
| `hedgeRatePerHour` / `dailyTurnoverCap` | 30 / 2.0 × NAV | policy |
| `hedgeSlippage` / `spotSlippage` | 0.5% / 0.3% vs index | policy |
| `cashBuffer` | 0.5% of NAV | policy |
| `pinBand` / `pinWindow` | 1% / 24 h | policy |
| `marginBufferMin` / `marginAlert` | 3× / 2× maintenance | policy |
| `fundingCap` | 0.1% per 8 h | policy |

### 3.5 Breaker, gateway, governance

| Parameter | Default | Bounds | Where |
|---|---|---|---|
| `drawdownThreshold` | 6% of `ppsMid` vs 24 h peak | 2–15% | L1, fast-tighten |
| `drawdownWindow` / `checkpointInterval` | 24 h / 1 h | — | L1 |
| `spokeLead` | phase 1: 2 h · phase 2: 30 min before each cutoff | 10 min–24 h | L1 (gateway) |
| `batchCap` | per vault | ≥ 0 | L1 (gateway), fast-tighten |
| `timelockDelay` | 7 days | ≥ 7 days | L1 |
| `keyLifetime` | 30 days | ≤ 30 days | L1 |

### 3.6 Changing parameters

- **L1, loosening** (and any change to fees, addresses or swing): owner through the timelock. Effective from the first round after it matures.
- **L1, tightening** a fast-tighten parameter: guardian, immediately.
- **Policy:** the full policy (§3.3–3.4) is a JSON document. Its `keccak256` hash is stored in `PolicyRegistry` on L1, and changing the active hash goes through the timelock. Signers and the monitor load the policy, check its hash against the active one, and **refuse to sign or approve under any other policy**. So a policy can't be changed quietly, even though no contract checks individual trades.

---

## 4. Breaker

```
ppsMid = navPre(latest accepted report) · k / N
```

- **`checkpoint()`**: anyone; at most once per `checkpointInterval`. It records `(timestamp, ppsMid)` from the latest accepted report in a 25-entry ring buffer.
- **`triggerBreaker()`**: anyone. If `ppsMid_now < peak_24h · (1 − drawdownThreshold)`, the vault becomes `REDUCE_ONLY`.
- **In `REDUCE_ONLY`:**
  - Deposits stop being processed. Redemptions continue.
  - Signers refuse to co-sign option sales.
  - The keeper closes options: buy-to-close, or let them expire if fewer than 24 h remain.
  - The keeper then flattens the hedge.
  - Once the subaccount holds no positions, anyone can move the vault to `PAUSED`.
- **Measured in the vault's unit.** For CC (unit ETH, `δ ≈ 0.8`), an 8–10% ETH drop is a gain of about 2% in ETH. The breaker reacts to CC's real risk, a sharp rally that drives the short calls ITM.

---

## 5. Price sources

| Use | Source | Check |
|---|---|---|
| Option, perp and spot marks | Derive-signed feeds (Block Scholes) | Signature and freshness on L1 ([02 §3](02-nav-oracle.md#3-verification)) |
| Independent spot | Chainlink ETH/USD on Ethereum | Within 2% of Derive spot |
| Option settlement | Derive's 30-minute TWAP | Read from settlement history; reflected in the next NAV report |
| Our NAV vs Derive's | `deriveMtm` relayed by attesters, plus public `margin_watch` | Within `navTolerance`; public diff |

Moving to L1 gave us something Derive Chain lacked: **an independent second price source** (Chainlink).

---

## 6. Upgrades (D10)

| Contract | Upgradeable? | Why |
|---|---|---|
| `DeltaVault`, `NavOracle`, `PolicyRegistry` | UUPS proxy; upgrades only via the timelock and only after `launch + 180 days` | A bug fix stays possible, and nothing can land without at least a week's notice |
| `DeriveAccountModule` | **Immutable** | It owns the Derive account. Derive documents no way to transfer account ownership ([07 Q6](07-open-questions.md)), so this contract must never need replacing. It is kept tiny: deposit, grant/renew/revoke allowed scopes, the one-time setup, and the escape-hatch withdrawal |
| `BaseGateway`, `SpokeAdapter`, `DVShare`, `FeeCollector` | Immutable | They hold funds in transit or fee shares |

---

## 7. Failure modes

| # | Failure | Automatic behavior | Response |
|---|---|---|---|
| F1 | Keeper offline | No hedging; rounds still processable by anyone once a report exists | Backup keeper |
| F2 | No acceptable NAV report | Rounds wait; requests keep queueing | Investigate attesters/feeds; guardian may confirm a held report |
| F3 | Derive feeds or Chainlink stale | Reports revert; rounds wait | Wait; guardian `REDUCE_ONLY` if prolonged |
| F4 | Derive matching halted | Positions sit; reports may still be valid | `REDUCE_ONLY` if it spans an expiry |
| F5 | Derive → L1 withdrawals slow (normally 10–15 min; global throttle about $1M/h; Derive can pause payouts) | Redemptions beyond the buffer stay `reserveUnfunded` longer | `forceBatch` after 1 h; raise `bufferTarget` |
| F6 | Sharp rally (CC) / crash (CSP) | Hedge engine; breaker | Review after `PAUSED` |
| F7 | Margin near liquidation | Signers refuse risk-increasing trades below `marginBufferMin` | Keeper shrinks the perp |
| F8 | One signer/attester key compromised | Nothing: 2-of-3 | Guardian removes it; owner adds a replacement |
| F9 | Two signer keys compromised | `K_option` can trade options within Derive's price bands | Guardian revokes `K_option` from L1 and sets `REDUCE_ONLY` |
| F10 | `K_hedge` compromised | Perp trades within price bands and margin | Guardian revokes it from L1 |
| F11 | `k` attesters collude | NAV shift bounded per report ([02 §8](02-nav-oracle.md#8-trust-summary)); visible in the public diff | Guardian pauses, removes attesters |
| F12 | Governance compromised | Nothing executes for 7 days | Users exit through rounds |
| F13 | Base bridge or messaging failure | Gateway invariants; `batchCap` | Guardian pauses `flush` ([04 §10](04-base-gateway.md#10-failure-handling)) |
| F14 | Derive operator offline or censoring | No trading. The owner's L1 `withdraw` is queued but not paid | **No practical exit.** After 28 days anyone may submit batches, but only with an SP1 proof from Derive's unpublished prover ([07 Q7](07-open-questions.md)). Treat it as full counterparty risk |
| F15 | Derive hacked, insolvent, or its admin key misused | Nothing on-chain can help | Derive's contracts are upgradeable by a **1-of-2 Safe with no timelock**, which can also change the verifier and state root. This is the largest single risk to user funds. Mitigations: `tvlCap` sized to it, at most 50% of AUM per venue from phase 2, and stating it plainly to users |

---

## 8. Key management

- **`K_option`** is a 2-of-3 threshold (MPC) key across the three operators. Each runs on its own cloud account and RPC, and re-checks the trade and the vault state on L1 before contributing its share.
- **Attester keys** live in KMS/HSM, separate from the threshold-key shares.
- **`K_hedge`, `K_spot`** are hot. Their power is bounded by their scopes; neither can move funds out of Derive.
- **Owner and guardian multisigs** use hardware wallets, with no overlap between their signers.
