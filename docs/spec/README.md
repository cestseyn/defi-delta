# Delta-managed option vaults: core specification

Draft v0.5 · 2026-11-08 (phase 1 settles weekly)

This spec turns the product brief (`delta manage vault - bp.pdf`: "Introducing the delta-managed option vault platform in DeFi", Oct 19, 2026, and "Competitors and benchmarks", Oct 22, 2026) into something code can be written from. Where they disagree, this spec wins; §5 lists every difference. Values marked "default" are parameters to be finalized by backtest ([07 Q16](07-open-questions.md)).

**Architecture in one paragraph.** Each vault is an ERC-7540 contract on **Ethereum L1** that owns a **Derive v3** account. Users deposit on L1 or on Base. Requests are processed in **rounds**: weekly at each option expiry in phase 1, every 4 hours with swing pricing in phase 2. NAV is computed live either way. The NAV is built from positions attested by independent operators and valued by the contract itself with Derive-signed and Chainlink prices. The strategy sells weekly options and delta-hedges on Derive through **session keys with least-privilege scopes**. The only key that can trade options is a 2-of-3 threshold key held by the same independent operators. Funds can leave Derive only through the vault contract's own L1 withdrawal, to itself.

## Documents

| File | Covers |
|---|---|
| [01-vault-accounting.md](01-vault-accounting.md) | `DeltaVault`: rounds, ERC-7540 requests and claims, pricing with swing, fees, buffer and reserves, rounding, invariants |
| [02-nav-oracle.md](02-nav-oracle.md) | Live NAV on L1: report format, verification, valuation, continuity checks, public verification, trust model |
| [03-strategy-execution.md](03-strategy-execution.md) | The Derive account and session keys, strike selection, pricing and delta, the delta engine, the weekly rollover, action policy |
| [04-base-gateway.md](04-base-gateway.md) | Deposits and withdrawals from Base: batches, rails, `DVShare`, invariants, failure handling |
| [05-risk-and-governance.md](05-risk-and-governance.md) | Roles, hard limits, the parameter registry, policy hashing, breaker, upgrades, failure modes |
| [06-offchain-services.md](06-offchain-services.md) | Strategy service, operators (signers and attesters), round processor, reports, monitoring |
| [07-open-questions.md](07-open-questions.md) | What is unknown or undecided, and what each answer blocks |

Reading order: this file, then 01 → 02 → 03 → 05. 04 and 06 can be read on their own.

---

## 1. Decisions

| # | Decision | Rationale | Where |
|---|---|---|---|
| D1 | Vault contracts on **Ethereum L1**; trading on **Derive v3** through an account the vault owns; Base as a spoke | Derive v3 settles to L1, and Derive Chain (v2) is retired. Our own vault keeps ERC-20 shares and our own accounting (option B) | all |
| D2 | Build order **CC → CSP → Strangle** | CC is simplest; Strangle has two assets and the most risk | 03 |
| D3 | **ERC-7540**, with `requestId` = processing round | Requests are priced after they are made (forward pricing) | 01 §2, §5 |
| D4 | NAV unit = each vault's **deposit asset** (CC: WETH, CSP: USDC) | The breaker and reported returns use the unit users entered with | 01 §1, 05 §4 |
| D5 | Fees **minted as shares**; performance fee after management fee; both crystallize at every round with flows and at least weekly | Entrants and leavers transact at a post-fee price, so no equalization is needed (alternative: [07 Q9](07-open-questions.md)) | 01 §4 |
| D6 | **Phase 1: weekly rounds** at each option expiry, priced on the post-settlement NAV. **Phase 2: rounds every 4 h** on live NAV. The same contracts serve both; only `roundSchedule` changes | Launch on the simplest, most robust NAV (no open options); move to hour-scale processing once operations are proven | 01 §2 |
| D7 | **Swing pricing**: zero in phase 1; in phase 2, 10 bps each side normally and 30 bps for large net flows | Whoever enters or leaves pays the trading cost they cause, so remaining holders aren't diluted | 01 §4 |
| D8 | **L1 liquidity buffer**: none in phase 1; 7.5% of NAV in phase 2 | Phase 1 redeems when collateral is free anyway; phase 2 needs it so redemptions don't wait for Derive | 01 §6 |
| D9 | No options sold in an epoch → **delta engine off** | Hedging without premium is pure cost | 03 §4 |
| D10 | Vault, oracle and policy registry upgradeable only after **180 days**, then timelocked; `DeriveAccountModule` **immutable** | The brief's "6 months without upgrade"; the account owner can't be replaced | 05 §6 |
| D11 | Base users accounted **on Base**, paid **pro-rata of what arrived**; `DVShare` is lock-and-mint against shares escrowed on L1 | One request per batch; forged messages can't overpay; redemptions need only a message | 04 |
| D12 | **Redemptions are processed in every vault state** | Users can always exit | 01 §3 |
| D13 | **Least-privilege session keys**: hedge, options (2-of-3 threshold), spot, all bound to the vault's subaccount; no key can withdraw, transfer or act as admin. Withdrawals are the owner contract's own L1 call to itself | Derive v3 doesn't let a contract validate trades, so key scopes become the hard limits | 03 §1 |
| D14 | **Attested positions, valued on-chain**; cross-checked against Derive's MtM, Chainlink and continuity | Puts trust in independent operators within tight, public bounds instead of in a single NAV number | 02 |
| D15 | Strategy policy is a document whose **hash is committed on L1** and changed only through the timelock | Signers refuse any other policy, so the rules can't change quietly | 05 §3.6 |

---

## 2. Conventions

| Topic | Convention |
|---|---|
| Ratios, deltas, fees, factors | 18-decimal fixed point (`1e18` = 1.0) |
| Share price `pps` | 18-decimal value of one whole share in whole asset units; `k = 10^(36 − assetDecimals)` ([01 §1](01-vault-accounting.md#1-units-and-share-price)) |
| Shares | 18 decimals in every vault |
| Signed quantities | `int256`: option quantity (negative = short), perp size (positive = long), `δ` |
| Time | `uint64` Unix seconds, UTC; 1 year = 365 days |
| Rounding | Against whoever initiates the operation; fees round down ([01 §8](01-vault-accounting.md#8-rounding)) |
| Math | Full-precision `mulDiv` for every product of two scaled numbers |
| Options | 1 contract = 1 ETH; European, cash-settled in USDC to a 30-minute TWAP; weekly expiry Friday 08:00 UTC |

## 3. Notation

| Symbol | Meaning | Unit |
|---|---|---|
| `S`, `F_T` | ETH index price; forward for expiry `T` | USD |
| `σ(K,T)` | Implied volatility from Derive's SVI surface | per year |
| `B`, `C` | ETH and USDC in the Derive subaccount | ETH, USDC |
| `q_i`, `Δ_i`, `M_i` | Option quantity (negative = short), Black-76 delta, mark | contracts, —, USDC |
| `P`, `perpUnsettled` | Perp size (positive = long); its unrealized PnL and funding | ETH, USDC |
| `buffer` | Free vault assets held on L1 | asset |
| `NAV_$`, `NAV` | NAV in USD, and in the vault's unit | USD, asset |
| `N` | Total shares | shares |
| `δ` | Fund delta: fraction of NAV exposed to the ETH price ([03 §4](03-strategy-execution.md#4-fund-delta)) | — |
| `T_e` | Option expiry of epoch `e` | timestamp |
| `cutoff_r` | Close of processing round `r` | timestamp |

## 4. Glossary

| Term | Meaning |
|---|---|
| Round | A 4-hour request queue, priced at the NAV measured after it closes |
| Epoch | One weekly option cycle, ending at `T_e`; only the strategy uses it |
| Blackout | `[T_e − 30 min, first NAV report after settlement]`: no round is processed |
| Swing | The small premium on deposits and discount on redemptions that pays for the trading they cause |
| Buffer | Vault assets kept on L1 to pay redemptions quickly |
| Band | Target range `[L, U]` for `δ`, with center `c` |
| Operators | Three independent parties; each runs one attester key and one share of the threshold option key |
| Policy | The published rules for strike selection, hedging and limits; its hash is on L1 |

---

## 5. Changes from the product brief

| In the brief | In this spec |
|---|---|
| Vault (ERC-4626) on the options venue's chain | ERC-7540 on Ethereum L1 owning a Derive v3 account (D1, D3) |
| Periodic NAV; deposits and withdrawals only at the epoch boundary | **Kept for phase 1** (weekly rounds at expiry, priced after settlement). Phase 2 moves to live NAV with rounds every 4 h, swing pricing and a buffer (D6–D8); there, forward pricing replaces periodic NAV as the protection against arbitrage |
| Fund delta not defined | `δ` = USD ETH exposure ÷ USD NAV ([03 §4](03-strategy-execution.md#4-fund-delta)) |
| NAV unit not defined; 5–8% daily drawdown breaker | NAV in the deposit asset; breaker in that unit (D4, [05 §4](05-risk-and-governance.md#4-breaker)) |
| "Hard limits in the contract; the strategy contract can only do three things" | Not possible on Derive v3: trades are signed off-chain. Replaced by session-key scopes, a 2-of-3 threshold key for options, withdrawals only by the owner contract to itself and an on-chain policy hash (D13, D15) |
| CSP as "gradual ETH entry", CC as "giving up upside" | Not true with hedging and cash settlement. CSP is a low-delta USDC vault; CC is about 0.8 ETH delta plus the variance risk premium |
| "Hedge cost < 25% of premium" | Applies to execution cost only ([03 §7](03-strategy-execution.md#7-performance-attribution)) |
| Performance fee before management fee (0.48 ETH in the example) | After it ([01 §4](01-vault-accounting.md#4-processing-a-round)) |
| 1% instant withdrawal | Rounds every 4 h with 10–30 bps swing instead |
| 2-of-3 keeper for every action | Only option trades need 2-of-3 (threshold key); hedges use a scoped hot key |
| Oracle: two sources, max delay 30 minutes | Derive-signed feeds + Chainlink on L1; 120 s freshness; settlement at Derive's TWAP |
| `P_received` as a separate NAV term | Already inside the cash balance |
| Hedge with perp or spot | Perps only: spot would break CC coverage, and CSP holds no ETH |
| "Can move between Derive and Rysk" | The same vault core could own an account on another venue; positions don't move |
