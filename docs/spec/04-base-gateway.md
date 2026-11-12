# 04 · Base gateway (spoke)

Scope: letting users deposit and withdraw on Base while the vault lives on Ethereum L1. Base users never need to touch L1 or Derive, and they get the same round prices as everyone else.

---

## 1. Idea

Everyone in a round is priced at the same `depositPrice` / `redeemPrice`. So per-user accounting lives on Base, and the L1 vault sees **one aggregate request per batch**. On L1, `SpokeAdapter` acts as a single ERC-7540 controller for all Base users.

Users are paid **pro-rata of what actually arrived**, so a forged or wrong message can't pay out more than was delivered:

```
userShares = userDeposit · batch.sharesReceived / batch.depositAssets      (round down)
userAssets = userRedeem  · batch.assetsReceived / batch.redeemShares       (round down)
```

---

## 2. Contracts and rails

| Chain | Contract | Role |
|---|---|---|
| Base | `BaseGateway` (one per vault) | Takes assets and shares from users, groups them into batches, pays out claims |
| Base | `DVShare` (one per vault, e.g. `dvETH-CC`) | ERC-20 on Base, 18 decimals; minted and burned only by the gateway on instructions from `SpokeAdapter` |
| L1 | `SpokeAdapter` (one per vault) | Holds, in escrow, the L1 shares that back every `DVShare`; submits batches to `DeltaVault`; sends results back |

**`DVShare` is lock-and-mint.** Every `DVShare` on Base is backed one-to-one by a vault share escrowed in `SpokeAdapter` on L1. Redeeming from Base therefore needs **no share transfer between chains**, only a message: the gateway burns `DVShare`, and the adapter redeems the escrowed shares.

| What moves | Base → L1 | L1 → Base |
|---|---|---|
| USDC | Circle CCTP (fast transfer, minutes) | Circle CCTP |
| WETH | Intent bridge, e.g. Across (minutes). The canonical bridge takes 7 days, too slow | Canonical OP bridge deposit (minutes) |
| Messages | Chainlink CCIP ([07 Q8](07-open-questions.md)) | Same |

The gateway uses a small adapter interface (§6), so the rails can change before launch without touching the accounting.

---

## 3. Batches

```
cutoff_k   = the k-th cutoff of the vault's round schedule:
             phase 1: each Friday 08:00 UTC; phase 2: every 4-hour mark
spokeLead  = phase 1: 2 h; phase 2: 30 min                // time for bridging before the L1 round closes
batchOf(t) = the smallest k with t < cutoff_k − spokeLead
```

Batch `k` is flushed at `cutoff_k − spokeLead`. It normally reaches L1 well before `cutoff_k` and joins the L1 round that closes then. If it lands later, for example during the Friday blackout or because a bridge is slow, it simply joins whatever round is open on arrival ([01 §2](01-vault-accounting.md#2-rounds)). The L1 side reports the actual `roundId` back. A late batch costs time, not money.

---

## 4. `BaseGateway`

### 4.1 Storage

```
enum BatchStatus { OPEN, FLUSHED, SETTLED }
struct Batch {
  BatchStatus status;
  uint128 depositAssets;   uint128 redeemShares;
  uint32  roundId;         uint128 depositPrice;  uint128 redeemPrice;    // informational
  uint128 sharesReceived;  uint128 assetsReceived;
  bool    depositSettled;  bool    redeemSettled;
}
mapping(uint32 k => Batch) batches;
mapping(address => mapping(uint32 => uint128)) userDeposit;   // assets
mapping(address => mapping(uint32 => uint128)) userRedeem;    // DVShare
```

### 4.2 Functions

| Function | Who | Rules |
|---|---|---|
| `deposit(assets, receiver)` | anyone | `assets ≥ minDepositBase`; pulls USDC or WETH; `userDeposit[receiver][batchOf(now)] += assets` |
| `cancelDeposit(k, receiver)` | the user | while batch `k` is `OPEN`; returns the assets |
| `requestRedeem(shares, receiver)` | anyone | pulls `DVShare` into the gateway; `userRedeem[receiver][batchOf(now)] += shares` |
| `cancelRedeem(k, receiver)` | the user | while batch `k` is `OPEN`; returns the shares |
| `flush(k)` | anyone (keeper by default) | `now ≥ cutoff_k − spokeLead`, status `OPEN`. Bridges `depositAssets` with `DepositBatch`; burns `redeemShares` of `DVShare` and sends `RedeemBatch`. Status → `FLUSHED` |
| `onDepositSettled(msg)` | messaging endpoint only | Mints `msg.shares` of `DVShare` to the gateway; records `sharesReceived`, `roundId`, price |
| `onRedeemSettled(msg)` | messaging endpoint only | Records `assetsReceived` once the assets have actually arrived on Base |
| `claimShares(k, user)` / `claimAssets(k, user)` | anyone, paid to `user` | Pro-rata (§1); zeroes the entry |

### 4.3 Batch cap

`batchCap` limits each direction of a batch, sized to the rails' fast liquidity. At `flush`, anything over the cap moves **pro-rata across users** into batch `k+1`.

---

## 5. Invariants

| # | Invariant |
|---|---|
| I1 | `Σ claimable shares of batch k ≤ sharesReceived_k` |
| I2 | `Σ claimable assets of batch k ≤ assetsReceived_k`, and `assetsReceived_k` is only recorded for assets that actually arrived |
| I3 | Each batch is flushed once; each settlement message is accepted once per side (replay protection on both chains) |
| I4 | Gateway asset balance ≥ open deposits + unclaimed settled assets |
| I5 | Gateway `DVShare` balance ≥ open redemptions + unclaimed settled shares |
| I6 | `DVShare.totalSupply()` on Base ≤ vault shares escrowed by `SpokeAdapter` on L1, at all times (mint only after the L1 escrow; burn before the L1 release) |

I6 is what makes a `DVShare` worth a vault share. Minting happens only after `SpokeAdapter` holds the shares. Burning happens on Base before the adapter releases them. Messages in flight can therefore only make `DVShare` supply *lower* than the escrow, never higher.

---

## 6. Interfaces

```
interface IAssetRail {      // CCTP for USDC; Across or canonical for WETH
  function send(address token, uint256 amount, address peer, bytes calldata hookData) external payable returns (bytes32 ref);
  function quote(address token, uint256 amount) external view returns (uint256 nativeFee, uint256 minReceived);
}
interface IMessenger {      // Chainlink CCIP (Q8); kept as an interface so it can change
  function send(bytes calldata payload) external payable returns (bytes32 msgId);
  function quote(bytes calldata payload) external view returns (uint256 nativeFee);
}
```

Every message is ABI-encoded with a version byte and carries `(sourceChainId, vault, k)`.

| Message | Direction | Payload |
|---|---|---|
| `DepositBatch` | Base → L1 | `k, assets, assetRef` |
| `RedeemBatch` | Base → L1 | `k, shares` |
| `DepositSettled` | L1 → Base | `k, roundId, depositPrice, shares` |
| `RedeemSettled` | L1 → Base | `k, roundId, redeemPrice, assets, assetRef` |

---

## 7. `SpokeAdapter` (L1)

| Step | Trigger | Action |
|---|---|---|
| `DepositBatch` + assets arrived | messenger + rail | `vault.requestDeposit(assets, this, this)`; record `k → roundId` |
| `RedeemBatch` | messenger | Take `shares` from escrow; `vault.requestRedeem(shares, this, this)`; record `k → roundId` |
| `settleDeposit(k)` | anyone, after the round is processed | Claim **everything** claimable; attribute each batch `sharesFor(assetsIn_k, depositPrice_round)` shares, rounded down; keep them in escrow; send `DepositSettled` |
| `settleRedeem(k)` | anyone, after processing **and** `vault.maxRedeem(this)` covers the adapter's full claim | Claim everything; attribute `assetsFor(sharesIn_k, redeemPrice_round)`, rounded down, to each batch; bridge the assets with `RedeemSettled` |

**Why claim everything.** A vault claim is pro-rata over the controller's aggregate counters ([01 §5](01-vault-accounting.md#5-requests-and-claims-erc-7540)). Claiming everything returns exactly the sum of per-round amounts. Attributing each batch at its own round price, rounded down, never exceeds that sum. The rounding dust stays in the adapter.

---

## 8. Timeline of a normal round (phase 2)

In phase 1 the same steps happen once a week: `flush` on Friday at 06:00, the L1 round closes at 08:00, processing at about 08:15, and the settlements and claims follow by about 08:45.

| Time (UTC) | Base | L1 |
|---|---|---|
| … → 11:30 | Users deposit and redeem into batch `k` | Round `r` open |
| 11:30 | `flush(k)` | — |
| 11:31–11:45 | — | Assets and messages arrive; adapter requests into round `r` |
| 12:00 | — | Round `r` closes |
| ≈ 12:10 | — | NAV report accepted; `processRound(r)` |
| ≈ 12:12 | — | `settleDeposit(k)`; `settleRedeem(k)` if the buffer covered it |
| ≈ 12:15–12:25 | Shares minted; assets arrive; keeper pushes claims | — |

**Longest wait for a Base user:** phase 1 about 7 days plus 2 hours; phase 2 about 4.5 hours, the same as on L1 plus `spokeLead`. Redemptions larger than the vault's buffer also wait for the Derive withdrawal ([01 §6](01-vault-accounting.md#6-liquidity-buffer-and-reserves)).

---

## 9. Costs

Batching means one bridge transfer and one message per direction per batch, whatever the number of users. The keeper pays them in native gas. Whether they are recovered through a small fixed gateway fee is open ([07 Q10](07-open-questions.md)).

---

## 10. Failure handling

| Failure | Effect | Handling |
|---|---|---|
| Batch arrives after the L1 cutoff | Joins the next round | Nothing to do |
| Messenger delays a settlement | Users can't claim yet | Funds are safe; claims open on arrival |
| Asset rail delivers less than sent (fees) | `assetsReceived` is lower | Pro-rata absorbs it |
| Message lost | Batch stuck in `FLUSHED` | Messenger-specific retry; a guardian-gated refund path is open ([07 Q8](07-open-questions.md)) |
| Messenger or rail hacked | At most one batch per direction in flight, plus a forged mint attempt | I1, I2, I6; `batchCap`; guardian pauses `flush` |
| L1 vault in `REDUCE_ONLY` / `PAUSED` | Deposits queue; redemptions still processed | Nothing changes on Base |
