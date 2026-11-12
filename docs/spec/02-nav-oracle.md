# 02 · Live NAV on L1 (`NavOracle`)

Scope: how the vault contract on Ethereum L1 learns the value of what it holds on Derive v3, often enough to process deposits and withdrawals every few hours, without any single party being able to misprice shares.

This is the hardest part of option B. A contract on L1 **cannot read a Derive account's positions**. Derive v3 settles to L1 through zk proofs of its state, but the docs publish no proof format for individual account balances ([07 Q3](07-open-questions.md)). So NAV has to be reported to the contract by someone, and the design below exists to make that report hard to get wrong.

---

## 1. Approach

**The report carries positions, not just a NAV number. The contract prices those positions itself, using feeds it can verify.**

```
attesters (k-of-n) sign:  positions + balances + Derive's own MtM + Derive-signed feeds
contract verifies:        attester signatures → feed signatures/freshness → independent spot check
contract computes:        NAV from positions × verified prices (Black-76 on Derive's SVI surface)
contract cross-checks:    its own NAV vs Derive's MtM;  new NAV vs previous NAV (continuity)
accepted report →         usable for processing a round (01), for the breaker (05), for display
```

This splits the trust:

| Input | Who can get it wrong | Check |
|---|---|---|
| Prices (spot, forward, vol, perp) | Derive's oracle signers (Block Scholes) | Derive feed signatures on L1, plus Chainlink ETH/USD as an independent spot check |
| Positions and balances | Our attesters | k-of-n signatures; consistency with Derive's MtM; continuity with the last report; public off-chain verification (§6) |
| Derive's MtM | Our attesters (they relay it) | Must agree with the contract's own valuation within `navTolerance` |

To shift NAV, attesters would have to misreport positions **and** keep both Derive's relayed MtM and the continuity bound consistent with the lie. Anyone can catch that off-chain by comparing the report with Derive's public `public/margin_watch` for our subaccount (§6).

---

## 2. Report

```
struct OptionPos { uint64 expiry; uint128 strike; bool isCall; int128 qty; }   // qty < 0 = short; 18 dp

struct NavReport {
  uint64      reportId;            // strictly increasing
  uint64      timestamp;           // when the attesters snapshotted Derive
  uint256     subaccountId;
  int256      cash;                // USDC in the subaccount, 18 dp, incl. accrued interest
  uint256     baseQty;             // ETH spot asset in the subaccount, 18 dp
  OptionPos[] options;             // at most maxStrikesPerEpoch × 2 entries
  int256      perpQty;             // ETH perp, 18 dp, + = long
  int256      perpUnsettled;       // unrealized PnL + unsettled funding, USDC
  uint64      lastCreditedDeposit; // id of the last vault→Derive deposit reflected in the balances
  uint64      lastAppliedWithdrawal; // module withdrawal nonce already debited on Derive
  uint256     deriveMtm;           // Derive risk-engine MtM of the subaccount, USDC
  bytes       feeds;               // Derive-signed spot, forward(T), SVI vol(T), perp feeds, as published by public/get_latest_signed_feeds
}
```

Attesters sign the EIP-712 hash of the report. The report is submitted with `k` distinct attester signatures.

---

## 3. Verification

`submitReport(report, signatures)` runs, in order:

| # | Check | Fails → |
|---|---|---|
| 1 | `k` distinct valid attester signatures; `reportId` > last; `timestamp` > last report's and `≥ now − navMaxAge` (default 10 min) | revert |
| 2 | Each Derive feed: 2 valid signatures from the registered Derive oracle signers, `deadline ≥ now`, feed `timestamp` within `feedMaxAge` (default 120 s) of `report.timestamp` (scheme in §3.1) | revert |
| 3 | `|S_derive / S_chainlink − 1| ≤ maxSourceDeviation` (default 2%); Chainlink round not older than its heartbeat | revert |
| 4 | Positions are well-formed: no duplicates, expiries ≥ the previous accepted report's (except settled ones), option count ≤ cap | revert |
| 5 | Compute `NAV_$` (§4) | — |
| 6 | `|NAV_$ − deriveMtm| ≤ navTolerance · NAV_$` (default 0.25%) | revert |
| 7 | Continuity (§5) | stored as **held** instead of accepted |

### 3.1 Verifying Derive feeds on L1

Derive v3 still signs feeds with the v2 `BaseLyraFeed` scheme. We checked this by recovering the signers from live `public/get_latest_signed_feeds` payloads ([07 Q2](07-open-questions.md)).

```
typehash    = keccak256("FeedData(bytes data,uint256 deadline,uint64 timestamp)")
structHash  = keccak256(abi.encode(typehash, keccak256(data), deadline, timestamp))
domain      = EIP712Domain(name, "1", chainId = 957, verifyingContract)      // the retired Derive Chain values
digest      = keccak256(0x1901 ‖ domainSeparator ‖ structHash)
```

| Feed (ETH) | `name` | `verifyingContract` (chain 957) |
|---|---|---|
| Spot | `LyraSpotFeed` | `0x727aD65db6aE99DB5Dbee8F202846DD6009bf6D5` |
| Forward | `LyraForwardFeed` | `0x791A570F5785FBdb02EA5C7a794c43111ae2f948` |
| Vol (SVI) | `LyraVolFeed` | `0xb27cb6b08e6c298C8634D73D5F6649665e90d160` |
| Perp | `LyraSpotDiffFeed` | `0x33E18F4f508d7aD3e958aA2DCf4b3eCAec38D7c6` |

- The domain separators are **constants** in our verifier. They must not be derived from `block.chainid`, which is 1 on L1, so OpenZeppelin's `EIP712` can't be inherited as is.
- **Signers:** currently `0xe920…4f18` and `0xee68…e763`, both required. No on-chain registry of Derive's signers exists, so `NavOracle` keeps its own set.
  - Adding a signer goes through the timelock. The guardian can remove one instantly.
  - **Key rotation by Derive will stop reports until we update the set.** The monitor alerts on the first unknown signer.
- `data` is decoded with v2's `encodeFeedData` layout (1e18-scaled values).
- Funding feeds use a different single signer and aren't needed for NAV.

---

## 4. Valuation

```
τ_i      = (expiry_i − timestamp) / 365 days
σ_i      = SVI(a, b, ρ, m, s; k = ln(K_i / F_i), τ_i)            // Derive's raw SVI, with its k_min/k_max clamp
V_opt    = Σ q_i · Black76(F_i, K_i, σ_i, τ_i)                     // zero discounting, as Derive marks them
V_base   = baseQty · S
NAV_der  = cash + V_base + V_opt + perpUnsettled                   // value inside Derive, USD

NAV_$    = NAV_der
         + buffer · S_unit                                         // assets held by the vault on L1 (exact, on-chain)
         + inTransitIn · S_unit                                    // vault→Derive deposits with id > lastCreditedDeposit
         + inFlightOut · S_unit                                    // debited on Derive (nonce ≤ lastAppliedWithdrawal), not yet received on L1; computed on-chain from the module's cumulative withdrawals and the vault's cumulative receipts
NAV      = NAV_$ / S_unit        (S_unit = S for CC, 1 for CSP)
```

Liabilities (unclaimed redemption assets, accrued management fee) are subtracted by the vault ([01 §4](01-vault-accounting.md#4-processing-a-round)), not here.

**Options inside the last 30 minutes before expiry** are marked by Derive against a blend of forward and the running TWAP ([03 §3](03-strategy-execution.md#3-pricing-and-delta)). Rounds don't process during that time ([01 §2](01-vault-accounting.md#2-rounds)), so the contract never needs to reproduce that blend. Reports in that window are accepted for the breaker using `deriveMtm` alone, and flagged as `pricedByDerive`.

---

## 5. Continuity

> **Implemented (phase 1):** the continuity check compares *flow-adjusted* value, `navAsset − cumulative deposits credited + cumulative withdrawals debited`, so moving assets between the vault and Derive doesn't look like a jump. It uses `|x| ≤ 1` (no separate theta allowance) and divides by the larger of the two NAVs. Phase 1 values open options at the attested Derive mark (with the haircut); valuing them on-chain with Black-76 and SVI comes with phase 2.


A report is **held** rather than accepted if NAV moved more than the market can explain since the last accepted report:

```
x        = exposure in the vault unit at the last report  (CC: δ − 1; CSP: δ)
allowed  = |x| · |S / S_prev − 1|  +  thetaAllowance  +  navJumpTolerance
held if  | NAV / NAV_prev − 1 | > allowed
```

| Parameter | Default | Meaning |
|---|---|---|
| `thetaAllowance` | premium sold this epoch ÷ NAV | Lets premium decay and settlement show up |
| `navJumpTolerance` | 0.5% | Gamma, vol moves, fees, rounding |

A held report is not used for processing. It becomes accepted if:
- a second report signed by a different attester quorum, at least `confirmDelay` (default 15 min) later, is consistent with it under the same rule, or
- the guardian confirms it.

Otherwise the next round waits for a report that passes continuity. Requests aren't lost, only delayed.

A sudden move that the bound can't explain, such as an exchange incident, therefore pauses processing instead of pricing shares off a possibly wrong number.

---

## 6. Public verification

Each accepted report is emitted in full. Anyone can recompute it:
- **positions and MtM:** Derive's public `public/margin_watch` returns MtM, margins and per-position breakdowns for any subaccount, from live feeds;
- **prices:** the feed payloads in the report are Derive-signed;
- **valuation:** the formulas in §4.

The reporter service ([06](06-offchain-services.md)) publishes a diff of every report against `margin_watch`. A mismatch beyond `navTolerance` pages the guardian, who can pause the vault ([05 §1](05-risk-and-governance.md#1-roles)).

---

## 7. Cadence

| Purpose | When | Freshness required |
|---|---|---|
| Round processing | Right after each round's cutoff | The oracle's latest accepted report, with `timestamp ≥ cutoff`: **forward pricing**, so no request ever knows its price in advance |
| Breaker | Every `checkpointInterval` (default 1 h), and on demand | ≤ `navMaxAge` |
| Display | Every 15 min | — |

---

## 8. Trust summary

| If … | Then … |
|---|---|
| One attester is compromised | Nothing: `k`-of-`n` (default 2-of-3) |
| `k` attesters collude | They can shift NAV by at most `allowed` per report, and only while hiding it from the public `margin_watch` diff; the guardian pauses |
| Derive's oracle signers are wrong | Chainlink spot check catches spot; vol/forward errors are bounded by `navTolerance` against Derive's own MtM (same feeds, so not independent) |
| Chainlink is stale or down | Reports revert; processing waits ([05 §7](05-risk-and-governance.md#7-failure-modes) F3) |

If Derive publishes account-state proofs against the root anchored on L1 ([07 Q3](07-open-questions.md)), the attested positions can be replaced by proven ones. Attesters then become simple relayers, and only the oracle trust remains. The report format above is designed so that only check 1 would change.
