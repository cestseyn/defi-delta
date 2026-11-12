# 07 · Open questions: answers

Researched on 2026-11-08 from Derive's docs, the verified v3 contract source (Sourcify), live public API responses and on-chain reads. Nothing was signed or sent.

All answers and recommendations below were **confirmed by the user on 2026-11-08** (✅).

Confidence describes the evidence:
- **High:** read in source code or on-chain.
- **Medium:** docs plus inference.
- **Low:** mostly inference.

---

## Derive v3

### Q1 · How long does a withdrawal from Derive take to reach L1? ✅
- **Proposed answer:** about **10–15 minutes**. Confidence: medium-high.
- **How it works:** each batch covers a 10-minute window of operations. It lands on L1 a median of 301 s after its last operation (min 225 s, p90 409 s, max 703 s). The batch transaction pays withdrawals out in the same call (`VerifiableApp.submitBatch` → `WithdrawalOutbox.executeWithdrawals`). There is no further challenge period. We measured 107 batches over the last ~18 hours.
- **`forceBatch`:** for a higher fee it requests an immediate batch, which probably skips the window wait.
- **Limits:**
  - Payouts go through USD token buckets per recipient-and-asset, per recipient, and globally. The global bucket holds about **$2M** and refills at about **$1M per hour**. Anything over the limit queues FIFO.
  - Derive's guardian or owner can pause payouts.
- **Impact:**
  - The "few hours" promise holds.
  - The buffer could later drop from 7.5% to about 5%.
  - The global throttle is shared with every Derive user, so very large redemptions can take an hour or more.
- Written into [01 §6](01-vault-accounting.md#6-liquidity-buffer-and-reserves) and [05 §7](05-risk-and-governance.md#7-failure-modes) F5.

### Q2 · Can an L1 contract verify Derive's signed feeds? ✅
- **Proposed answer:** **yes**. Confidence: high.
- **Evidence:**
  - v3 still signs feeds with the v2 `BaseLyraFeed` EIP-712 scheme, using the retired chain 957 and the v2 feed addresses as the domain.
  - We recovered both signers from live spot, forward, vol and perp payloads. Two signatures are required.
  - No L1 contract stores or verifies these feeds today.
- **Impact:**
  - `NavOracle` hard-codes the domains and keeps its own signer set, with additions through the timelock and instant removal by the guardian.
  - If Derive rotates its keys, reports stop until we update the set.
- Written into [02 §3.1](02-nav-oracle.md#31-verifying-derive-feeds-on-l1).

### Q3 · Can account positions be proven against the root anchored on L1? ✅
- **Proposed answer:** **no**. Confidence: high.
- **Evidence:**
  - `VAPP` stores only a `stateRoot`. Batches carry an SP1 proof, and state diffs go to Celestia.
  - No API or contract offers account-inclusion proofs, and the state-tree format is undocumented.
- **Impact:** attested positions ([02](02-nav-oracle.md)) remain the design. Nothing changes for v1.

### Q4 · Can the owner update the withdrawal whitelist from L1? ✅
- **Proposed answer:** **no**, and **we don't need it**. Confidence: high.
- **Evidence:**
  - `OnchainActionManager` accepts only Deposit (1), DepositToNewSubaccount (2), Withdrawal (3, through `withdraw()`) and SetSessionKey (51).
  - However, the owner contract can call `OnchainActionManager.withdraw()` **itself**, to any recipient, for 0.002 ETH. The sequencer applies it about 76 s after L1 inclusion.
- **Impact:** the temporary-admin ceremony and the withdraw session key are gone. The module withdraws only to `DeltaVault`, which is fixed in code. Written into [03 §1.3](03-strategy-execution.md#13-withdrawing-from-derive).

### Q5 · Are expired options settled automatically? ✅
- **Proposed answer:** **yes**, by the sequencer, within about a minute of expiry. The result is proven on L1 in the next batch, 5–15 minutes later. Confidence: medium.
- **Evidence:** the API describes projected margin as "a minute past … expiry, once the options expiring by then settle into cash". Today's expiry already shows its settlement price.
- **Impact:** the Friday schedule in [03 §5](03-strategy-execution.md#5-weekly-rollover-on-derive) holds.

### Q6 · Can a Derive account's owner be changed? ✅
- **Proposed answer:** **no**. Confidence: medium-high.
- **Evidence:** there is no owner-transfer action, API or L1 action type.
- **Workaround:** move funds and positions to a new account. That needs either a transfer scope we never grant, or an L1 withdrawal and re-deposit.
- **Impact:** `DeriveAccountModule` stays immutable and tiny ([05 §6](05-risk-and-governance.md#6-upgrades-d10)).

### Q7 · What is the escape hatch? ✅
- **Proposed answer:** the owner's L1 `withdraw()` is the normal path and works while Derive operates.
  - If Derive's batch submitter stalls an L1 action for **28 days**, anyone can replace the submitter.
  - But submitting a batch still needs an SP1 proof of Derive's program. That program and prover aren't public.
  - So there is **no practical trustless exit today**.
  - Confidence: high on the mechanism, medium on the prover not being available.
- **Additional finding:**
  - Derive's contracts can be upgraded, and their verifier and state root changed, by a **1-of-2 Safe with no timelock**.
  - Pausing is done by a 2-of-7 guardian Safe.
- **Impact:** this is now the largest single risk to user funds. It is stated in [05 §7](05-risk-and-governance.md#7-failure-modes) F14–F15. It also argues for a conservative `tvlCap` at launch, and for asking Derive about adding a timelock.

### Q11 · What are Derive's fees? ✅
- **Proposed answer** (confidence: high for trading fees):

| Instrument | Taker | Maker |
|---|---|---|
| Options | $0.5 + min(0.03% notional, 12.5% premium) | min(0.01% notional, 12.5% premium) |
| Perps | $0.01 + 0.03% notional | 0.01% notional |
| Spot | 0 | 0 |

- **RFQ:** both sides pay the taker rate.
- **Withdrawals:** the off-chain fee is small (about $1 by default). An L1 owner withdrawal costs 0.002 ETH.
- **Deposits:** about free. Deposits under $10 are forfeited.
- **Impact:**
  - 1,000 ETH of weekly calls costs about $670 a week as taker or RFQ, and about $220 as maker. That fits inside `executionCost`.
  - Base and gateway minimum deposits must stay well above $10.

### Q12 · How narrow can session-key scopes be? ✅
- **Proposed answer** (confidence: high):
  - **Can be bound to one subaccount:** yes. Always pass the vault's subaccount ID explicitly; the docs disagree on what an empty list means.
  - **Direction:** trade scopes allow both buying and selling; there is no sell-only or reduce-only scope.
- **Impact:** confirms why `K_option` is a 2-of-3 threshold key ([03 §1.2](03-strategy-execution.md#12-session-keys)).

### Q13 · Is the option market deep enough, and are the limits workable? ✅
- **Proposed answer:** yes for about **1,000 ETH a week**. Confidence: medium.
- **Market** (snapshot of 2026-11-08):
  - Spreads are about 1–1.5 vol points.
  - About 380–520 ETH of bids sit within 20 levels at strikes of delta 0.10–0.21.
  - Over 7 days there were at least 87k ETH option contracts traded, 38k of them via RFQ, with RFQ prints of 330–1,000 lots.
  - Open interest is about 367k ETH.
- **Execution cost:** selling through the order book across 2–3 strikes would cost about 7–12% of premium against the mark. RFQ is likely tighter.
- **Price bands** are wide (options ±1.5% spot and ±20% vol; perps ±2%) and won't bind.
- **Rate limits:** the trader tier allows 1 matching TPS, which is enough for us; the market-maker tier is higher.
- **Impact:**
  - Starting `tvlCap` of about 1,000–1,500 ETH for CC.
  - RFQ first, as in [03 §2.3](03-strategy-execution.md#23-execution).
  - Budget about 10% of premium for execution in backtests.

---

## Our own decisions (recommendations)

| # | Question | Recommendation | Why |
|---|---|---|---|
| Q8 ✅ | Messaging between Base and L1; refund path for lost messages | **Chainlink CCIP**, with a guardian-gated refund after 7 days for a batch stuck in `FLUSHED` | One audited network with independent risk monitoring and built-in rate limits; simpler to reason about than configuring LayerZero verifiers. LayerZero v2 with two independent verifiers is the alternative |
| Q9 ✅ | When performance fees crystallize | **Every round with flows** (current) | Exact for people entering and leaving, with no equalization accounting. The cost is small fee leakage in volatile weeks |
| Q10 ✅ | Who pays bridge and message costs for Base batches | **The keeper, at launch**; add a fixed gateway fee only if costs per batch become material | Batching keeps it to two bridge transfers and two messages per 4 hours |
| Q14 ✅ | Threshold signing for `K_option` | **v1: a managed MPC provider with a policy engine**, with the three operators as approvers. **Later: self-hosted threshold ECDSA**, one share per operator | Self-hosted threshold signing is a large engineering and audit effort; a managed provider gets the 2-of-3 rule live quickly. The trade-off is a dependency on the provider |
| Q15 | Strangle: unit of account and margin type | Deferred to phase 3 | — |
| Q16 | Default numbers (band, `τ`, `pinBand`, breaker, swing, buffer) | Backtest on 2019–2026 ETH data, including the March 2020 crash; execution cost at about 10% of premium (Q13) | Values in [05 §3](05-risk-and-governance.md#3-parameter-registry) are placeholders |

## Still to ask Derive

These weren't answerable from public data:
1. Will they add a timelock to the admin Safe? Is the prover going to be published?
2. Are per-recipient withdrawal throttles configured, and can a vault get a dedicated bucket?
3. What is the process and notice period for rotating the oracle signers?
