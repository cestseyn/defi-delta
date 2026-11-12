# 03 · Strategy and execution on Derive v3

Scope: how the vault's Derive account is set up and controlled from L1, which keys can do what, how options are chosen and sold, how delta is measured and hedged, and what happens at each weekly expiry. Parameter names refer to the registry in [05 §3](05-risk-and-governance.md#3-parameter-registry).

---

## 1. The Derive account and its keys

### 1.1 Ownership

Each vault owns exactly one Derive v3 account. The owner is `DeriveAccountModule`, a small contract that belongs to the vault on Ethereum L1. A contract can't produce the off-chain signatures Derive uses for trading, so the module does only three things, all as L1 calls to Derive's `OnchainActionManager`:

| Call | Used for |
|---|---|
| `depositToNewSubaccount(...)` / `deposit(...)` | Creating the subaccount (Standard Manager for CC and CSP) and sending buffer surplus to Derive |
| `submit(SET_SESSION_KEY = 51, abi.encode(key, expiry, scopes, subaccountIds))` | Granting a session key its protocol scopes, always bound to the vault's single subaccount ID |
| The same with `expiry = 0` | Revoking a key, instantly and from L1 |
| `withdraw(WithdrawalParams{subaccountId, protocolAsset, maxFeeUsdE18, recipient, amountInUnderlying, forceBatch})` with `msg.value = 0.002 ETH` | Pulling assets back to L1. **`recipient` is hard-coded to `DeltaVault`** in the module |

The owner's L1 `withdraw` is applied by Derive's sequencer about 76 s after L1 inclusion. It is paid out in the next proven batch (batches cover 10-minute windows and land about 5 minutes later), so the funds arrive in **about 10–15 minutes**. Payouts pass through Derive's withdrawal throttle, a global bucket of about $2M that refills at about $1M per hour, shared by all Derive users.

Funds can leave the Derive account in only one way: this L1 withdrawal to `DeltaVault`. No session key ever gets `withdraw`, `transfer` or `admin`.

### 1.2 Session keys

| Key | Held by | Protocol scopes | Job |
|---|---|---|---|
| `K_hedge` | Strategy service (hot) | `trade:orderbook:perp` | Delta hedging |
| `K_option` | **2-of-3 threshold key** (MPC) shared by the three independent signers | `trade:orderbook:option`, `trade:rfq:option` | Selling options; buy-to-close |
| `K_spot` | Rollover runner | `trade:orderbook:spot` | CC cash leg: USDC ↔ ETH |
| — | nobody | `withdraw`, `transfer:*`, `admin`, `set_session_key`, `liquidate`, `vault:*` | Never granted |

Trade scopes on Derive are per venue and instrument only. They allow both buying and selling; there is no sell-only or reduce-only scope. That is why `K_option` is a threshold key.

Key lifetimes are at most 30 days.
- **New keys or new scopes** go through the owner and the timelock.
- **Renewal** of a key the owner already approved, with the same scopes, can be done by the keeper through `DeriveAccountModule.renew(key)`. It adds no new power, so it doesn't wait.
- **Revoking** is instant and available to the guardian ([05 §1](05-risk-and-governance.md#1-roles)).

### 1.3 Withdrawing from Derive

The vault never needs a withdraw-capable session key, and never needs Derive's recipient whitelist. Withdrawals are always the owner's own L1 call from §1.1, with `recipient = DeltaVault` fixed in code.
- `DeriveAccountModule.withdrawToVault(amount, forceBatch)` is callable by the keeper.
- The module caps `amount` at `reserveUnfunded + max(0, bufferTarget·NAV − buffer)`, per [01 §6](01-vault-accounting.md#6-liquidity-buffer-and-reserves).
- It pays the 0.002 ETH fee from a small ETH float.
- `forceBatch` (a higher Derive fee, an immediate batch) is used only when `reserveUnfunded` is older than 1 h.

If Derive's risk gate rejects the withdrawal, for example because margin would be insufficient, the action is consumed without paying out. The keeper must first free collateral by closing options pro-rata and resizing the hedge, then retry.

### 1.4 What enforces what

On Derive v3 there is **no way for our contract to validate an individual trade**: trades are signed off-chain by session keys. Enforcement is layered instead:

| Layer | Enforces | Bypassable by |
|---|---|---|
| Derive protocol | Each key's scopes; margin; price banding (orders and RFQ quotes must sit inside a spot/vol-shocked range: ETH options ±1.5% spot and ±20% vol, perps ±2%); only the owner contract can withdraw | Nobody but Derive |
| Threshold signing of `K_option` | Every option trade is checked against the policy in §6 by at least 2 of 3 independent signers | 2 compromised signers |
| Monitoring | Every fill compared with policy within one cycle; breaches page the guardian | — |
| L1 contracts | Revoke keys instantly; the breaker revokes `K_option` automatically ([05 §4](05-risk-and-governance.md#4-breaker)); no path for assets except to `DeltaVault` | Owner via timelock |

So the brief's "hard limits in the contract" become **hard limits on what each key can do at all**, plus a published policy for how the keys use that freedom. Every breach is visible.

---

## 2. Strike and size selection

### 2.1 Candidates

When the epoch opens after expiry, the candidates are the listed Derive options of the vault's type (CC: calls, CSP: puts) expiring at `T_e`, normally next Friday 08:00 UTC. For each strike `K`, the service reads the Derive feeds for `F_T` and the SVI surface, computes `Δ(K)` and the model price (§3), and reads the book.

A strike is **eligible** if:

| Check | Rule |
|---|---|
| Delta | `optionDeltaMin ≤ |Δ(K)| ≤ optionDeltaMax` |
| Floor | `floor(K) = max(price(σ · volFactorSell), minPremium · notional)`; notional is `S` for calls, `K` for puts |
| Market | `mid(K) ≥ floor(K)` and `ask − bid ≤ maxSpread · mid` |

### 2.2 Choice

```
eligible = strikes passing 2.1, sorted by |Δ − optionDeltaTarget|
if empty: try higher |Δ| (closer to ATM) up to optionDeltaMax that pass the floor
if still empty: no sale this epoch; delta engine off (D9)
```

**Size.**
- CC: `floor(B)` contracts. `B` is the ETH inside the Derive subaccount. The L1 buffer is not sold against.
- CSP: `floor((C − margin_perp) / K)` contracts.

The rest spills to the next eligible strike, up to `maxStrikesPerEpoch`. Whatever still doesn't fill stays unsold.

**Mid-epoch deposits.** When the buffer surplus reaches Derive after a round, the service sells extra contracts of the same expiry against it if `T_e − now ≥ minSellTimeLeft` (default 2 days). Otherwise the new assets stay unsold until rollover.

**Capacity.** Keep `tvlCap` under about 25% of the resting size at eligible strikes in the hour after expiry, and raise it from observed fills.

### 2.3 Execution

1. **RFQ first.** `send_rfq` for the full size, sell direction, with `min_total_cost = floor × size`. Take the best quote if it clears the floor.
2. **Then the order book.** Post-only limit orders on a ladder:
   ```
   start = mid(K);  step = max(tick, ladderStep · mid)          // ladderStep 2%
   every ladderInterval (10 min) while unfilled and inside sellWindow (6 h):
       price = max(price − step, floor(K))
   ```
3. Unfilled size is cancelled when the sell window closes.

---

## 3. Pricing and delta

Black-76 with zero discounting, on Derive's own inputs:

```
τ    = (T − t) / 365 days
σ    = SVI(a, b, ρ, m, s; k = ln(K/F), τ)        // Derive's raw SVI, k clamped to ±4·√(a + b·s)
d1   = [ln(F/K) + σ²τ/2] / (σ√τ);   d2 = d1 − σ√τ
call = F·N(d1) − K·N(d2)            Δ_call = N(d1)
put  = K·N(−d2) − F·N(−d1)          Δ_put  = N(d1) − 1
```

| Use | σ |
|---|---|
| Delta | SVI σ, unscaled |
| Sale floor | σ · `volFactorSell` (< 1) |
| Buy-back cap | σ · `volFactorBuy` (> 1) |

**Last 30 minutes before expiry.** Derive marks options against `n/30 · F + (30−n)/30 · S_avg`, the running settlement TWAP. Their delta decays accordingly. The engine uses this blended underlying in that window. Rounds don't process then ([01 §2](01-vault-accounting.md#2-rounds)).

Approximate weekly call premium at zero rates:

| IV | Δ 0.10 | Δ 0.15 | Δ 0.20 |
|---|---|---|---|
| 40% | 0.26% (K ≈ 1.075F) | 0.42% (1.061F) | 0.60% (1.049F) |
| 60% | 0.38% (1.116F) | 0.62% (1.094F) | 0.89% (1.076F) |
| 80% | 0.50% (1.160F) | 0.82% (1.129F) | 1.18% (1.105F) |

---

## 4. Fund delta

### 4.1 Definition

```
Δ_ETH = B + Σ q_i·Δ_i + P  +  (buffer + inTransitIn + withdrawalsInFlight)_ETH      // CC only: L1 WETH counts
NAV_$ = as in 02 §4
δ     = Δ_ETH · S / NAV_$
```

In the vault's own unit, exposure is `δ − 1` for CC (unit ETH) and `δ` for CSP (unit USDC). The L1 buffer is part of the position. For CC it is ETH exposure, so it raises `δ`, and the band accounts for it.

### 4.2 Delta engine

```
every cycle (5 min; 1 min while fastMove):
    if the strategy holds no option of the current expiry:          // D9
        if P ≠ 0: unwind P toward 0, then stop
        stop
    compute δ, NAV_$, S
    fastMove = |S / S_5minAgo − 1| > 4%
    τeff     = fastMove ? τFast (0.02) : τ (0.05)
    if L − τeff ≤ δ ≤ U + τeff: stop
    target   = fundingAgainst > fundingCap ? nearest band edge : c
    ΔP       = (target − δ) · NAV_$ / S
    clip ΔP by maxHedgePerTx · NAV_ETH,  perpCap,  hedgeRatePerHour / dailyTurnoverCap budget
    child    = min(|ΔP|, 10% of book depth within hedgeSlippage of the index)
    IOC limit order for `child` at index ± hedgeSlippage, signed by K_hedge
```

- **After every round** the service recomputes `δ` immediately. Deposits and redemptions change `B`, the buffer, or both.
- **Funding.** When funding runs against the hedge by more than `fundingCap`, the engine hedges back only to the nearest band edge, keeping `|P|` small. Switching to spot doesn't work: CC can't sell ETH without breaking call coverage, and CSP holds no ETH.

---

## 5. Weekly rollover on Derive

| Time (Fri, UTC) | Step | Key |
|---|---|---|
| 07:30 | Blackout starts: no round processing. Hedging continues, on the TWAP-blended delta | `K_hedge` |
| 08:00 | Options expire; Derive settles them to the 30-minute TWAP into USDC | (Derive) |
| ≈ 08:05 | Service confirms settlement through `private/get_option_settlement_history`; attesters post a NAV report | — |
| ≈ 08:10 | CC cash leg: bring USDC back to `cashBuffer` (buy ETH with the excess; sell ETH to cover a negative balance), within `spotSlippage` of index | `K_spot` |
| ≈ 08:15 | Strike selection (§2); RFQ, then the ladder, until the sell window closes (14:15) | `K_option` |
| after the first fill | Delta engine back on | `K_hedge` |
| ≈ 08:15 | **Phase 1:** the weekly round is processed on the post-settlement NAV report (before any new option is sold); redemptions are withdrawn to L1 right after | — |
| 12:00 | **Phase 2:** first round after the blackout is processed; weekly fees crystallize if no earlier round did | — |

Blackout ends at the first accepted NAV report after settlement.
- **Phase 1:** the weekly round closes at 08:00 and is processed then. Strike selection waits until processing is done, so the week's size includes the new deposits and excludes the redemptions.
- **Phase 2:** the 08:00 cutoff is skipped, and the next cutoff (12:00) is used.

---

## 6. Action policy

Each row is what the signers (for `K_option`) and the monitor (for all keys) check. The **Derive** column is what the protocol enforces on its own.

| Action | Key | Derive enforces | Policy (signers / monitor) |
|---|---|---|---|
| Sell option | `K_option` | scope, margin, price band | type = vault's; expiry = `T_e`; `|Δ|` in range; price ≥ floor; total sold ≤ coverage; within the sell window, or a mid-epoch top-up per §2.2 |
| Buy-to-close | `K_option` | scope, margin, price band | reduces `|q|` only; price ≤ buy-back cap; only in `REDUCE_ONLY`, or in the last `pinWindow` with `|S−K|/K < pinBand` |
| Hedge | `K_hedge` | scope, margin, price band | moves `δ` toward `c` without crossing it; size, perp cap, slippage, rate and turnover limits |
| Cash leg | `K_spot` | scope, margin, price band | only at rollover; only toward `cashBuffer`; within `spotSlippage` |
| Withdraw | none: L1 call by `DeriveAccountModule` | owner-only; recipient fixed to `DeltaVault` in code | amount cap enforced by the module (§1.3) |

A breach found by the monitor (for example a hedge that increased `|δ − c|`) pages the guardian, who revokes the key. A breach by `K_option` would need 2 of 3 signers to have signed it, so it is treated as a signer compromise ([05 §7](05-risk-and-governance.md#7-failure-modes) F9).

---

## 7. Performance attribution

Each epoch report splits the change in NAV into components, in USD first and then converted at the index price at the time each amount occurred:

| Component | Definition |
|---|---|
| `premium` | Σ fill price × contracts sold |
| `optionPnL` | −(settlement payout + buy-back cost) |
| `hedgePnL` | Price PnL of the perp, excluding funding and fees |
| `executionCost` | Trading fees + slippage vs index at decision time + funding paid + interest on negative cash + Derive withdrawal fees |
| `swingIncome` | Swing proceeds retained from deposits and redemptions |
| `baseRevaluation` | CC: change in the ETH value of USDC cash. CSP: zero |
| `residual` | `ΔNAV − flows − Σ above`. Must stay within 0.01% of NAV, otherwise it's a reporting bug and raises an alert |

Strategy edge = `premium + optionPnL + hedgePnL`. It is positive when realized volatility is below implied. The brief's "hedge cost below 25% of premium" target applies to `executionCost` only.

---

## 8. Records

Trades happen on Derive, so the trade record is Derive's own history (`private/get_trade_history`, settlement, funding and interest history) for the vault subaccount, mirrored by the reporter ([06](06-offchain-services.md)). The L1 contracts emit:

| Event | Contract |
|---|---|
| `SessionKeySet(key, scopes, expiry)` / `SessionKeyRevoked(key, reason)` | `DeriveAccountModule` |
| `DepositedToDerive(depositId, amount)` | `DeriveAccountModule` |
| `WithdrawalReceived(amount)` | `DeltaVault` |
| `NavReportAccepted(reportId, nav, navUsd, spot)` / `NavReportHeld(reportId, reason)` | `NavOracle` |
