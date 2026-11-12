# 01 · Vault accounting (`DeltaVault`, Ethereum L1)

Scope: the L1 contract that issues shares, queues requests, prices them at live NAV in rounds every few hours, charges fees, and keeps a liquidity buffer. One deployment per vault type: CC (asset WETH) and CSP (asset USDC). It never trades. Trading happens on Derive through session keys ([03](03-strategy-execution.md)); NAV comes from [02](02-nav-oracle.md).

Conventions (fixed point, rounding, time) are in [README §2](README.md#2-conventions).

---

## 1. Units and share price

Shares have 18 decimals in every vault. `pps` is an 18-decimal fixed-point number: **the value of one whole share in whole asset units**. A new vault starts at `pps = 1e18`.

```
k            = 10^(36 − assetDecimals)        // WETH: 1e18, USDC: 1e30
pps          = NAV · k / N
sharesFor(a, price) = a · k / price
assetsFor(s, price) = s · price / k
```

---

## 2. Rounds

Deposits and withdrawals are processed in **rounds**. A round is a queue of requests that closes at a scheduled cutoff and is then priced at the NAV measured **after** the cutoff (forward pricing).

The contract supports two schedules, selected by the `roundSchedule` parameter. Switching between them is an ordinary timelocked parameter change, with no new contracts.

| Schedule | When | Cutoff | Processed |
|---|---|---|---|
| `WEEKLY_AT_EXPIRY` | **Phase 1** (launch) | `T_e`, Friday 08:00 UTC: one round per option epoch | After the expired options are settled and the first NAV report shows **no open option positions**, normally about 08:15 |
| `INTERVAL` | Phase 2 | every `roundLength` (4 h) | As below |

### 2.1 Phase 1: weekly rounds

- A round is the same as an option epoch. Requests made during the week are all priced at the NAV measured right after expiry, when the account holds only ETH, USDC and the perp. That is the simplest and most robust NAV the vault ever has.
- **Longest wait:** 7 days plus about 15 minutes.
- **Liquidity:** at that moment no options are open, so collateral is free. Redemptions are paid by an L1 withdrawal from Derive in about 10–15 minutes ([03 §1.3](03-strategy-execution.md#13-withdrawing-from-derive)). Phase 1 therefore runs **without a buffer** (`bufferMin = bufferTarget = bufferMax = 0`).
- **Swing:** flows only change how many options are sold for the new week, and nothing is bought back. So phase 1 runs with **zero swing**, though the mechanism stays in the contract.
- New options for the week are sold **after** the round is processed, so deposits are invested in the same morning.

### 2.2 Phase 2: interval rounds

```
roundLength  = 4 h                                    // cutoffs at 00:00, 04:00, 08:00 … UTC
cutoff_r     = the r-th scheduled cutoff, skipping blackouts
blackout     = [T_e − 30 min, strategy rollover done]  // around every weekly expiry
```

- A request always joins the **open** round. At `cutoff_r` the round closes and the next one opens immediately.
- A closed round is priced with the oracle's **latest** accepted report, which must be timestamped at or after `cutoff_r` ([02 §7](02-nav-oracle.md#7-cadence)). Requiring the latest report means nobody can pick a favorable older one.
- A scheduled cutoff that falls inside a blackout is skipped, so the open round simply stays open until the next cutoff. On Fridays the 08:00 cutoff is skipped and the 12:00 one is used.
- **Longest wait:** `roundLength` + processing delay (≈ 20 min). On Fridays the longest wait is 8 h because of the blackout.

```
struct Round {
  uint64  cutoff;          // when it closed (0 while open)
  uint64  processedAt;     // 0 until processed
  uint64  navReportId;     // the report it was priced with
  uint128 navPre;          // vault NAV before flows, after liabilities
  uint128 pps;             // post-fee price
  uint128 depositPrice;    // pps · (1 + swingIn)
  uint128 redeemPrice;     // pps · (1 − swingOut)
  uint128 pendingAssets;   // deposits requested into this round
  uint128 pendingShares;   // redemptions requested into this round
  uint128 sharesMinted;
  uint128 assetsOwed;
  uint128 feeShares;       // 0 if fees didn't crystallize this round
}
```

`requestId` (ERC-7540) = the round id.

---

## 3. Vault states

| State | Deposits | Redemptions | Strategy |
|---|---|---|---|
| `ACTIVE` | processed | processed | normal |
| `REDUCE_ONLY` | new requests rejected; deposits already queued are **refunded** at the round (`claimRefund`) | processed | closing positions ([05 §4](05-risk-and-governance.md#4-breaker)) |
| `PAUSED` | new requests rejected; queued deposits refunded at the round | processed | no trading |

**Redemptions are processed in every state.** Users can always get out at the next round, paid from the buffer, or as soon as the strategy has withdrawn enough from Derive (§6). Resuming `ACTIVE` follows [05 §1](05-risk-and-governance.md#1-roles).

---

## 4. Processing a round

`processRound(r)` is one transaction, callable by anyone once its conditions hold. It runs these steps:

1. **Preconditions.** Round `r` is closed and every earlier round is processed. An accepted NAV report exists in the forward window ([02 §7](02-nav-oracle.md#7-cadence)).
2. **NAV.**
   ```
   navPre = oracleNav − reserveUnfunded
   ```
   - `oracleNav` ([02 §4](02-nav-oracle.md#4-valuation)) counts only the *free* `buffer` on L1. `idlePending` and `reserveFunded` were never in it.
   - `reserveUnfunded` is owed to earlier redeemers but still sits inside the Derive account (or in flight from it), so it is subtracted here.
3. **Fees.** Fees crystallize if this round has any flows, or if 7 days have passed since the last crystallization:
   ```
   Δt        = now − lastCrystallizedAt − pausedTime
   f_m       = navPre · mgmtFee · Δt / 365 days
   ppsGross  = (navPre − f_m) · k / N
   f_p       = perfFee · max(0, ppsGross − hwm) · N / k
   f         = f_m + f_p
   feeShares = f · N / (navPre − f)                      → mint to FeeCollector
   hwm       = max(hwm, navPre · k / (N + feeShares))
   ```
4. **Price.**
   ```
   pps          = navPre · k / (N + feeShares)
   tier         = |pendingAssets − assetsFor(pendingShares, pps)| / navPre > largeFlow ? large : normal
   depositPrice = pps · (1 + swingIn[tier])
   redeemPrice  = pps · (1 − swingOut[tier])
   ```
5. **Redemptions.** `assetsOwed = assetsFor(pendingShares, redeemPrice)`. Burn `pendingShares` (held by the vault since the request). Fund from the buffer first (§6).
6. **Deposits.** `sharesMinted = sharesFor(pendingAssets, depositPrice)`, minted to the vault for claims. `pendingAssets` moves from `idlePending` into the buffer.
7. **Record and emit** `RoundProcessed` (§9). The keeper then rebalances the buffer (§6).

**Why swing pricing.** Entering or leaving makes the strategy trade: sell or buy back options, resize the hedge, move collateral to or from Derive. The swing charges that cost to the person causing it, and the proceeds stay in the vault. Without it, every deposit and withdrawal would be paid for by the holders who stay.

**Why crystallize at every round with flows.** People entering and leaving transact at a post-fee price, so nobody inherits a fee liability that belongs to someone else, and no equalization accounting is needed.
- **Cost:** a fee can be taken on a gain that later reverses within the week (fee leakage).
- **Alternative:** weekly crystallization plus per-investor equalization, in [07 Q9](07-open-questions.md).

---

## 5. Requests and claims (ERC-7540)

### 5.1 Per-controller storage

```
struct Slot { uint32 roundId; uint128 amount; }
mapping(address => Slot[2]) depositSlots;      // assets
mapping(address => Slot[2]) redeemSlots;       // shares
mapping(address => uint128) claimableDepositAssets;
mapping(address => uint128) claimableShares;
mapping(address => uint128) claimableRedeemShares;
mapping(address => uint128) claimableAssets;
```

At most two rounds can be unprocessed at once: the closed one waiting for its NAV report, and the open one. So two slots per direction are enough.

Every entry point first calls `_settle(controller)`. It moves processed slots into the claimable counters at that round's `depositPrice` / `redeemPrice`. That is O(1) per controller, so processing never loops over users.

### 5.2 Entry points

| Function | Rules |
|---|---|
| `requestDeposit(assets, controller, owner)` | `msg.sender` is `owner` or its operator; `assets ≥ minDeposit`; `navLast + idlePending + assets ≤ tvlCap`; pulls assets into `idlePending`; joins the open round |
| `requestRedeem(shares, controller, owner)` | `msg.sender` is `owner`, its operator, or has an allowance; moves shares to the vault; joins the open round |
| `cancelDepositRequest(requestId, controller, receiver)` | Only while that round is still open, or the vault is `REDUCE_ONLY`/`PAUSED`; returns the assets |
| `cancelRedeemRequest(requestId, controller, receiver)` | Only while that round is still open; returns the shares |
| `deposit(assets, receiver, controller)` / `mint(shares, receiver, controller)` | Claim shares, pro-rata over the claimable counters |
| `redeem(shares, receiver, controller)` / `withdraw(assets, receiver, controller)` | Claim assets, pro-rata over the claimable counters; limited by `reserveFunded` |
| `setOperator(operator, approved)` | ERC-7540 |

ERC-4626 views:
- `totalAssets()` returns the last processed `navPre` plus that round's net flows.
- `convertTo*` uses the last `pps`.
- `preview*` revert, as ERC-7540 requires.
- `max*` return the claimable counters.

---

## 6. Liquidity: buffer and reserves

The vault keeps part of NAV on L1 as a **buffer**, so ordinary redemptions are paid at the next round without waiting for a withdrawal from Derive.

| Bucket (all in the vault asset, tracked internally, never `balanceOf`) | In NAV? |
|---|---|
| `idlePending`: deposits not yet processed | No |
| `reserveFunded`: owed to redeemers, held on L1 | No |
| `reserveUnfunded`: owed to redeemers, still on Derive | No (a liability) |
| `buffer`: free assets on L1 | Yes |
| `inTransitIn`: sent to Derive, not yet credited there | Yes ([02 §4](02-nav-oracle.md#4-valuation)) |

**Funding redemptions (step 5):**

```
fromBuffer = min(assetsOwed, buffer)
buffer          −= fromBuffer;   reserveFunded   += fromBuffer
reserveUnfunded += assetsOwed − fromBuffer
```

When a withdrawal from Derive lands on L1, it pays `reserveUnfunded` first, then refills the buffer.

**Rebalancing (keeper, after each round):**

| Condition | Action |
|---|---|
| `buffer > bufferMax · NAV` | Deposit `buffer − bufferTarget · NAV` to Derive through `OnchainActionManager.deposit` (lands in about 2 minutes) |
| `buffer − reserveUnfunded < bufferMin · NAV` | Ask the strategy to free and withdraw `bufferTarget · NAV − buffer + reserveUnfunded` from Derive |

Defaults:
- **Phase 1** (weekly rounds): all zero ([§2.1](#21-phase-1-weekly-rounds)).
- **Phase 2** (4-hour rounds): `bufferMin` 2.5%, `bufferTarget` 7.5%, `bufferMax` 12.5% of NAV.
- **Cost:** the buffer earns no premium, so yield is lower by roughly the buffer fraction (7.5% buffer: about 12.0% → 11.1% a year).
- **CC:** the buffer is WETH, so it keeps the vault's ETH exposure.

**How fast a redemption is paid:**
- **Up to the buffer:** at the next round (≤ 4 h).
- **Beyond it:** at the next round, plus the time to unwind positions on Derive, plus the L1 withdrawal itself. The withdrawal takes **about 10–15 minutes** ([07 Q1](07-open-questions.md)).
- **Derive's withdrawal throttle** is a global bucket of about $2M, refilling at about $1M per hour and shared by all Derive users. A redemption of several million dollars can add an hour or more.

---

## 7. Limits

| Limit | Default | Where checked |
|---|---|---|
| `minDeposit` | CC 0.01 WETH · CSP 25 USDC | `requestDeposit` |
| `minRedeem` | equivalent of `minDeposit` at the last `pps` | `requestRedeem` |
| `tvlCap` | per vault, sized to option liquidity ([03 §2](03-strategy-execution.md#2-strike-and-size-selection)) | `requestDeposit` |
| Seed shares | protocol deposits `seedAssets` (CC 1 WETH, CSP 2,000 USDC) at deployment; shares go to a dead address | deployment |

---

## 8. Rounding

Every rounding goes against whoever initiates the operation:
- **Down:** `sharesMinted`, `assetsOwed`, every claim output, every fee, `pps`, `depositPrice`, `redeemPrice`.
- **Up:** what `mint()` charges in assets and what `withdraw()` charges in shares.

Rounding dust stays in `reserveFunded`.

---

## 9. Events

| Event | Fields |
|---|---|
| ERC-7540 `DepositRequest` / `RedeemRequest` / `OperatorSet` | standard |
| `DepositRequestCanceled` / `RedeemRequestCanceled` | `controller, requestId, receiver, amount` |
| ERC-4626 `Deposit` / `Withdraw` | standard, on claims |
| `RoundClosed` | `roundId, cutoff` |
| `RoundProcessed` | `roundId, navReportId, navPre, pps, depositPrice, redeemPrice, tier, pendingAssets, sharesMinted, pendingShares, assetsOwed, feeShares, mgmtFee, perfFee, hwm` |
| `BufferRebalanced` | `direction, amount, depositId or withdrawalRef` |
| `ReserveFunded` | `amount, reserveUnfundedAfter` |
| `StateChanged` | `from, to, reason` |

---

## 10. Worked example (CC, one phase-2 round)

Phase 1 works the same way, with zero swing and no buffer: the deposits fund the new week's options, and the redemptions are withdrawn from Derive right after processing.

Assumptions:
- Last crystallization 1 day ago: `N = 1000`, `hwm = 1.0`.
- Accepted report: `navPre = 1001.2 WETH`.
- This round: deposits of 50 WETH, redemptions of 20 shares.
- Swing 10 bps each side. The net flow is 3% of NAV, below `largeFlow` = 5%, so the normal tier applies.
- Buffer before the round: 75 WETH.

| Step | Value |
|---|---|
| `f_m = 1001.2 × 2% × 1/365` | 0.05486 WETH |
| `ppsGross = (1001.2 − 0.05486) / 1000` | 1.00114514 |
| `f_p = 15% × 0.00114514 × 1000` | 0.17177 WETH |
| `feeShares = 0.22663 × 1000 / (1001.2 − 0.22663)` | 0.22641 shares |
| `pps = 1001.2 / 1000.22641` = new `hwm` | 1.00097337 |
| `depositPrice` / `redeemPrice` | 1.00197434 / 0.99997240 |
| `sharesMinted = 50 / 1.00197434` | 49.90148 |
| `assetsOwed = 20 × 0.99997240` | 19.99945 WETH, all from the buffer |
| NAV after flows | 1031.20055 WETH; supply 1030.12789; `pps` 1.00104129 |
| Benefit to staying holders from the swing | +0.68 bps (0.07 WETH), which pays for re-trading |
| Buffer after | 105.00 WETH vs target 77.34 → keeper deposits 27.66 WETH to Derive |

---

## 11. Invariants

1. `pps`, `depositPrice` and `redeemPrice` change only inside `processRound`.
2. Every request is priced with a NAV report whose timestamp is **after** the request's round cutoff.
3. `idlePending = Σ unprocessed deposit slots`.
4. `reserveFunded + reserveUnfunded ≥ Σ claimableAssets` (the difference is rounding dust).
5. Tracked L1 balance = `idlePending + reserveFunded + buffer`.
6. `totalSupply` changes only in `processRound` (fee mint, deposit mint, redemption burn).
7. `hwm` never decreases.
8. Redemptions are processed in every vault state.
9. Rounds are processed strictly in order; none is skipped once it has closed.
