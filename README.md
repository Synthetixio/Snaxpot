# Snaxpot — On-Chain Technical Specification

> Weekly lottery driven by Synthetix perps trading fees.
> Ethereum mainnet · Solidity · Foundry · UUPS upgradeable

---

## 1. Overview

Snaxpot is an epoch-based weekly lottery whose jackpot is denominated in **USDT** on Ethereum mainnet. An off-chain **operator** derives lottery tickets from Synthetix perpetual-futures trading fees, commits a Merkle root of all tickets on-chain, and triggers a Chainlink VRF draw. Only the top-tier jackpot (5 balls + Snax ball) is settled on-chain; all smaller prize tiers are resolved off-chain.

Epochs run concurrently: a new epoch opens each week while the previous epoch's drawing and resolution pipeline completes in the background.

This repository contains **only the on-chain contracts**. The off-chain ticket engine, dashboard, and distribution service are maintained separately.

---

## 2. Contract Architecture

```
┌──────────────────────────────────────────────┐
│              Snaxpot (UUPS)               │
│  - Epoch lifecycle                            │
│  - Merkle root storage                        │
│  - Chainlink VRF integration                  │
│  - Jackpot accounting & rollover              │
│  - Small-prize event emission                 │
│  - Access control (Admin / Operator)          │
└──────────┬───────────────────┬───────────────┘
           │                   │
           ▼                   ▼
┌─────────────────┐  ┌────────────────────┐
│  JackpotClaimer   │  │  PrizeDistributor         │
│  (claiming)     │  │  (small winners)   │
│                 │  │                    │
│  Jackpot winner │  │  Standalone.       │
│  calls claim()  │  │  Distributes via   │
│  to withdraw    │  │  external deposit  │
│  USDT           │  │  contract.         │
└─────────────────┘  └────────────────────┘
```

| Contract             | Upgradeability | Purpose                                                                                                                         |
| -------------------- | -------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| **Snaxpot**          | UUPS proxy     | Main lottery logic — epochs, VRF, Merkle verification, jackpot settlement                                                       |
| **JackpotClaimer**   | UUPS proxy     | Escrow for jackpot winnings; winner calls `claim()` to withdraw USDT                                                            |
| **PrizeDistributor** | TBD            | Standalone USDT pool for small-prize distribution via external deposit contract. No interaction with Snaxpot or JackpotClaimer. |

---

## 3. Roles & Access Control

Two roles minimum, enforced via OpenZeppelin `AccessControl` (or equivalent):

| Role         | Permissions                                                                                                                                  |
| ------------ | -------------------------------------------------------------------------------------------------------------------------------------------- |
| **ADMIN**    | Upgrade contracts (UUPS), grant/revoke roles, set protocol parameters (VRF config, fee splits), pause/unpause, `rescueToken` (non-USDT only) |
| **OPERATOR** | `openEpoch`, `closeEpoch`, `commitMerkleRoot`, `drawJackpot`, `resolveJackpot`, `resolveSmallPrizes`, `logTickets`                           |

Admin is the only role that can change Operator addresses. Operator cannot self-escalate.

---

## 4. Epoch Lifecycle

An **epoch** is the fundamental time unit — one week of trading mapped to one draw. **Multiple epochs can be in-flight simultaneously**: a new epoch opens as soon as the previous one closes, while the previous epoch is still going through its drawing and resolution pipeline.

### 4.1 Per-Epoch State Machine

Each epoch progresses through its own independent state machine:

```
OPEN ──▶ CLOSED ──▶ DRAWING ──▶ RESOLVED
```

| State      | Description                                                                                                                                   |
| ---------- | --------------------------------------------------------------------------------------------------------------------------------------------- |
| `OPEN`     | Epoch is active. VRF seed generated at open. Off-chain engine uses this seed to derive tickets from trading activity during the epoch window. |
| `CLOSED`   | Operator has explicitly closed the epoch. No more trading activity counts. Operator must commit the Merkle root.                              |
| `DRAWING`  | Merkle root committed and `drawJackpot()` called. Waiting for Chainlink VRF callback with winning numbers.                                    |
| `RESOLVED` | Winning numbers posted. Jackpot either claimed or rolled over. Small prizes emitted. Epoch is finalised.                                      |

### 4.2 Concurrent Epochs

The contract tracks **each epoch's state independently** via its `epochId`. There is no global "contract state" that blocks new epochs from opening while an old one is resolving.

Typical steady-state timeline:

```
Week N                          Week N+1                        Week N+2
├──── Epoch N: OPEN ────────────┤                               │
│   trading activity counted    │                               │
│                               ├──── Epoch N+1: OPEN ─────────┤
│                               │   trading activity counted    │
│                               │                               ├── Epoch N+2: OPEN ──▶
│                               │                               │
├─ Epoch N: CLOSED ─────────────┼───────────────────────────────┤
│  (operator posts root,        │                               │
│   draws, resolves — can       │                               │
│   overlap with N+1 OPEN)      │                               │
│         ├─ DRAWING ─┤         │                               │
│                  ├─ RESOLVED  │                               │
```

**Key rules:**

- `openEpoch()` opens a new epoch immediately. It does **not** require the previous epoch to be resolved.
- Only **one** epoch can be `OPEN` at a time (the current collection window). The operator must explicitly close the current epoch before (or atomically when) opening a new one.
- Multiple epochs can be in `CLOSED`, `DRAWING`, or `RESOLVED` states simultaneously — the drawing/resolution pipeline for epoch N runs in parallel with epoch N+1 being `OPEN`.
- The contract tracks `currentEpochId` to identify which epoch is currently accepting trading activity (the `OPEN` one).

### 4.3 Flow

```
1.  Operator calls openEpoch()
      → Requires no epoch currently OPEN (operator must close the previous one first)
      → New epoch state: OPEN
      → Chainlink VRF request fires → seed stored on callback
      → event EpochOpened(epochId, vrfSeed, startTimestamp)

    [Meanwhile, prior epoch N-1 may still be in CLOSED/DRAWING/RESOLVED pipeline]

2.  [~1 week passes — off-chain engine accumulates tickets for current epoch using vrfSeed]

3.  Operator calls closeEpoch(epochId)
      → Requires epoch state == OPEN
      → Snapshots currentJackpot into epoch.jackpotAmount, resets currentJackpot to 0
      → Epoch state → CLOSED
      → event EpochClosed(epochId, closeTimestamp)

    Operator can then call openEpoch() separately, or use the convenience function:

      closeAndOpenEpoch(epochId)
        → Atomically closes current epoch + opens next epoch in one tx
        → Internally calls closeEpoch() then openEpoch()

    Both paths exist so the operator can pause between close and open if needed.

4.  Operator calls commitMerkleRoot(epochId, root)
      → Requires epoch state == CLOSED
      → Stores root for that epochId

5.  Operator calls drawJackpot(epochId)
      → Requires merkle root committed for that epochId
      → Epoch state → DRAWING
      → Requests Chainlink VRF for winning numbers
      → VRF callback stores winning balls
      → event WinningNumbersDrawn(epochId, balls[5], snaxBall)

6.  Operator calls resolveJackpot(epochId, winner, ticket, merkleProof)
      — OR —
    Operator calls resolveJackpotNoWinner(epochId)

      If winner:
        → Verifies merkle proof on-chain
        → Transfers jackpot USDT to JackpotClaimer
        → event JackpotWon(epochId, winner, amount)

      If no winner:
        → Jackpot rolls into next epoch's pool
        → event JackpotRolledOver(epochId, rolledAmount)

7.  Operator calls resolveSmallPrizes(epochId, totalAmount, winners[])
      → Emits event for off-chain distribution
      → No on-chain USDT transfer for small prizes (handled via PrizeDistributor contract)
      → event SmallPrizesResolved(epochId, totalAmount, winnerCount)
      → Epoch state → RESOLVED

    Steps 4-7 happen while the next epoch is already OPEN and collecting tickets.
```

### 4.4 Invariants

- At most **one** epoch in `OPEN` state at any time.
- Multiple epochs may be in `CLOSED` / `DRAWING` simultaneously (abnormal but not forbidden — e.g., operator delays).
- An epoch can only transition forward: `OPEN → CLOSED → DRAWING → RESOLVED`. No backwards transitions.
- `resolveJackpot` / `resolveJackpotNoWinner` can only be called once per epoch.
- Jackpot rollover credits the **currently open** epoch (or the next one to be opened if none is open yet).

---

## 5. VRF Integration (Chainlink V2.5)

Two distinct VRF usages per epoch:

| Purpose             | When            | Output                                                                           |
| ------------------- | --------------- | -------------------------------------------------------------------------------- |
| **Epoch seed**      | `openEpoch()`   | Single `uint256` seed — published in event, used off-chain for ticket derivation |
| **Winning numbers** | `drawJackpot()` | Derives 5 standard balls + 1 Snax ball                                           |

### 5.1 Winning Number Derivation

From the VRF random word(s), derive:

```
for i in 0..5:
    balls[i] = (uint256(keccak256(abi.encode(randomWord, i))) % BALL_MAX) + 1

snaxBall = (uint256(keccak256(abi.encode(randomWord, 5))) % SNAX_BALL_MAX) + 1
```

`BALL_MAX = 32` and `SNAX_BALL_MAX = 5`. Standard balls range 1–32, Snax ball ranges 1–5. Total combinations: C(32,5) × 5 = **1,015,080**.

The 5 standard balls are **sorted ascending** after derivation to match ticket format (see §8).

### 5.2 VRF Parameters (stored in contract, admin-configurable)

- `subscriptionId`
- `keyHash`
- `callbackGasLimit`
- `requestConfirmations`
- `numWords`

---

## 6. Jackpot Accounting

### 6.1 Funding

Anyone (operator, protocol fee router, or external donor) can deposit USDT into `Snaxpot` **at any time**, including mid-epoch. This allows the jackpot to grow throughout the week as trading fees are converted and deposited.

```solidity
function fundJackpot(uint256 amount) external;
```

- Transfers `amount` USDT from caller into the contract via `SafeERC20.safeTransferFrom`.
- Adds `amount` to `currentJackpot` (the live, running total).
- Can be called multiple times per epoch — each call increases the pot.
- Emits `JackpotFunded(amount, currentJackpot)`.
- No restrictions on caller or timing (not role-gated). Permissionless deposits let the operator automate funding from a fee-splitter contract.

### 6.2 Live Balance vs Epoch Snapshot

```solidity
uint256 public currentJackpot;                        // live running total, grows with every fundJackpot() call
mapping(uint256 => uint256) public epochJackpot;       // frozen snapshot for a specific draw
```

**`currentJackpot`** is the real-time jackpot amount. It increases on every `fundJackpot()` call and on rollovers. The dashboard displays this value.

**`epochJackpot[epochId]`** is set once, at the moment `closeEpoch(epochId)` is called. It snapshots `currentJackpot` at close time and resets `currentJackpot` to 0:

```
closeEpoch(epochId):
    epochJackpot[epochId] = currentJackpot
    currentJackpot = 0
```

Any USDT deposited _after_ the snapshot (i.e., after `closeEpoch()` but before or during the next epoch) goes into the next epoch's pot automatically since it adds to `currentJackpot` which starts fresh at 0.

### 6.3 Rollover

If `resolveJackpotNoWinner(epochId)` is called:

```
currentJackpot += epochJackpot[epochId]
epochJackpot[epochId] = 0  // or leave as historical record and track rollover separately
```

The unclaimed amount flows back into `currentJackpot`, stacking on top of any new deposits that arrived since close. No USDT moves — it's purely internal accounting.

### 6.4 Winner Payout

On `resolveJackpot(epochId, ...)`:

1. Verifies the winning ticket via Merkle proof (see §8).
2. Transfers `epochJackpot[epochId]` in USDT to `JackpotClaimer`.
3. Records the claim entitlement: `JackpotClaimer.credit(winner, amount)`.
4. `epochJackpot[epochId]` marked as claimed.

`currentJackpot` is unaffected — it already had the snapshot subtracted at close time and may have new deposits accumulating for the next draw.

### 6.5 Funding Timeline Example

```
Mon     Tue     Wed     Thu     Fri     Sat     Sun  │  Mon (next week)
                                                     │
fundJackpot(100)                                     │
  currentJackpot = 100                               │
        fundJackpot(50)                              │
          currentJackpot = 150                       │
                        fundJackpot(200)             │
                          currentJackpot = 350       │
                                                     │
                              ── epoch closes ──     │
                              closeEpoch(N)          │
                                epochJackpot[N]=350  │
                                currentJackpot = 0   │
                                                     │
                                    fundJackpot(80)  │  ← already counts toward epoch N+1
                                      currentJackpot │= 80
                                                     │
                              resolveJackpotNoWinner │(N)
                                currentJackpot = 430 │  (80 new + 350 rolled over)
```

### 6.6 Token Handling

**Rejecting native ETH**: The contract has no `receive()` or `fallback()` function (or they explicitly `revert`). Any direct ETH transfer will fail.

**Non-USDT ERC-20 tokens**: There is no on-chain mechanism to prevent arbitrary ERC-20 tokens from being transferred to the contract — ERC-20 `transfer()` executes on the token contract with no receiver callback. Non-USDT tokens sent to the contract are effectively stuck. An admin-only `rescueToken(address token, address to, uint256 amount)` function allows recovering accidentally sent tokens. **Hardcoded to reject USDT** — there is no admin function that can withdraw USDT from the contract. The only way to extract USDT is through the normal lottery flow (`resolveJackpot` → `JackpotClaimer` → `claim`). If USDT recovery is ever truly needed (e.g., contract migration), it requires a UUPS upgrade to deploy new logic.

```solidity
function rescueToken(address token, address to, uint256 amount) external onlyAdmin {
    require(token != address(usdt), "cannot withdraw USDT");
    SafeERC20.safeTransfer(IERC20(token), to, amount);
}
```

**USDT reconciliation — reconciling direct transfers**: If someone sends USDT directly to the contract (via `usdt.transfer(snaxpot, amount)` instead of `fundJackpot()`), the contract has no callback to detect it. An admin-only `reconcileUSDT()` function reconciles the actual USDT balance against internal accounting and credits the difference to the jackpot:

```solidity
uint256 public totalAccountedUSDT;  // sum of all tracked USDT (jackpot + epoch snapshots + pending payouts)

function reconcileUSDT() external onlyAdmin {
    uint256 actual = usdt.balanceOf(address(this));
    uint256 surplus = actual - totalAccountedUSDT;
    if (surplus > 0) {
        currentJackpot += surplus;
        totalAccountedUSDT += surplus;
        emit JackpotFunded(surplus, currentJackpot);
    }
}
```

- Admin-only.
- `totalAccountedUSDT` is updated on every `fundJackpot()`, `closeEpoch()`, `resolveJackpot()`, and rollover to stay in sync.

**USDT quirks**:

- `transfer` / `transferFrom` do not return `bool` on mainnet.
- Use OpenZeppelin `SafeERC20` for all USDT interactions.
- Use `SafeERC20.forceApprove()` for all approvals.

---

## 7. JackpotClaimer Contract

Simple escrow allowing verified jackpot winners to claim.

```solidity
// Simplified interface
function credit(address winner, uint256 amount) external;   // only callable by Snaxpot
function claim() external;                                   // winner withdraws their USDT
function claimableBalance(address user) external view returns (uint256);
function sweepExpired(address winner) external;              // admin-only, reclaims expired credits
```

- USDT transferred in from Snaxpot on `credit()`. Each credit records a timestamp.
- Winner calls `claim()` to withdraw their USDT at any time within the claim window.
- **3-month expiry**: unclaimed credits expire after 90 days. Admin calls `sweepExpired()` to return expired funds to `Snaxpot` (credited back to `currentJackpot`).
- One active credit per winner per epoch.

---

## 8. Merkle Tree — Ticket Commitment

We use OpenZeppelin's [`@openzeppelin/merkle-tree`](https://github.com/OpenZeppelin/merkle-tree) (`StandardMerkleTree`) for both off-chain tree construction and on-chain proof verification. This means **all leaf hashing follows OZ's convention**: double-hashed with `abi.encode` (not `abi.encodePacked`).

### 8.1 Leaf Format (OZ double-hash)

Each ticket is one leaf. The leaf value stored in the tree is:

```
leaf = keccak256(bytes.concat(keccak256(abi.encode(
    trader,          // address — ticket owner
    epochId,         // uint256 — epoch identifier
    balls[0],        // uint8 — sorted ascending
    balls[1],        // uint8
    balls[2],        // uint8
    balls[3],        // uint8
    balls[4],        // uint8
    snaxBall,        // uint8
    ticketIndex      // uint256 — unique index within trader's tickets for this epoch
))))
```

**Why double-hash?** OpenZeppelin double-hashes leaves (`keccak256(bytes.concat(keccak256(...)))`) so that leaf hashes can never collide with internal node hashes (second preimage resistance). The inner hash produces the raw digest; the outer hash domain-separates it from branch nodes.

**Why `abi.encode` (not `abi.encodePacked`)?** `abi.encode` pads each value to 32 bytes, eliminating ambiguity when adjacent dynamic-length or small-width types are packed together. This matches what `StandardMerkleTree` does internally.

**Ball ordering**: The 5 standard balls MUST be sorted in ascending order before hashing. This ensures the same set of numbers always produces the same leaf hash regardless of selection order. The contract enforces sorted order when verifying.

**One leaf per ticket**: If Alice has 3 tickets, the tree contains 3 separate leaves (each with different numbers and a unique `ticketIndex`). A trader with 500 tickets produces 500 leaves.

### 8.2 Tree Construction (off-chain)

The operator builds the tree using `StandardMerkleTree` from `@openzeppelin/merkle-tree`:

```js
import { StandardMerkleTree } from "@openzeppelin/merkle-tree";

const leaves = tickets.map(t => [
  t.trader,       // address
  t.epochId,      // uint256
  t.balls[0],     // uint8
  t.balls[1],     // uint8
  t.balls[2],     // uint8
  t.balls[3],     // uint8
  t.balls[4],     // uint8
  t.snaxBall,     // uint8
  t.ticketIndex,  // uint256
]);

const tree = StandardMerkleTree.of(leaves, [
  "address", "uint256",
  "uint8", "uint8", "uint8", "uint8", "uint8",
  "uint8", "uint256"
]);

// tree.root   — bytes32 to commit on-chain
// tree.getProof(i) — proof for leaf i
```

`StandardMerkleTree` handles the double-hashing and sorted-pair internal hashing automatically. Do **not** manually hash leaves before passing them in — the library does it for you.

### 8.2.1 Algorithm Specification (language-agnostic)

If you are **not** using `@openzeppelin/merkle-tree` (e.g. building the tree in Go, Rust, Python), you must replicate the exact algorithm. Three things must match or proofs will fail on-chain.

#### Step 1 — ABI-encode each leaf value into a 288-byte buffer

`abi.encode` pads every value to exactly 32 bytes, big-endian, left-padded with zeroes:

```
Offset  Type      Encoding (32 bytes each)
------  --------  -----------------------------------------------
  0     address   0x000000000000000000000000 ++ <20-byte address>
 32     uint256   <32-byte big-endian epochId>
 64     uint8     0x00...00 ++ <1-byte balls[0]>          (31 zero bytes + 1)
 96     uint8     0x00...00 ++ <1-byte balls[1]>
128     uint8     0x00...00 ++ <1-byte balls[2]>
160     uint8     0x00...00 ++ <1-byte balls[3]>
192     uint8     0x00...00 ++ <1-byte balls[4]>
224     uint8     0x00...00 ++ <1-byte snaxBall>
256     uint256   <32-byte big-endian ticketIndex>
------
Total: 9 × 32 = 288 bytes
```

#### Step 2 — Double-hash to get the leaf node

```
innerHash = keccak256(encodedBuffer)          // 32 bytes
leafHash  = keccak256(innerHash)              // 32 bytes — this is the leaf node in the tree
```

#### Step 3 — Build the tree with sorted-pair hashing

1. Compute `leafHash` for every ticket.
2. **Sort** all leaf hashes in ascending byte order.
3. Build the tree bottom-up. For each pair of sibling nodes `(a, b)`:
   - If `a <= b` (byte comparison): `parent = keccak256(a ++ b)` (64-byte input)
   - If `a > b`: `parent = keccak256(b ++ a)`
   - i.e. always sort the pair before hashing.
4. If a level has an odd number of nodes, the last node is promoted to the next level without hashing.
5. The final single node is the **Merkle root**.

**Proof generation**: for a given leaf at index `i`, the proof is the list of sibling hashes from bottom to top. The verifier walks the proof, sorted-pair hashing at each level, and checks that the result equals the root.

#### Implementation notes

- **Go**: `go-ethereum/accounts/abi` — use `Arguments.Pack(...)` which produces identical output to Solidity `abi.encode`. Use `sha3.NewLegacyKeccak256()` from `golang.org/x/crypto/sha3` for keccak256.
- **Rust**: `alloy` or `ethabi` crate for ABI encoding; `tiny-keccak` or `sha3` crate for hashing.
- **Python**: `eth_abi.encode(...)` + `Web3.keccak(...)`.

In all cases, verify your implementation against the JS `StandardMerkleTree` on a small test set before deploying.

### 8.3 Publication and Verification

- The operator publishes the full tree data (all leaves + proofs) via IPFS or API. The `StandardMerkleTree` can be serialized with `tree.dump()` and restored with `StandardMerkleTree.load(...)`.
- Any user can verify their tickets are in the tree by recomputing their leaf hash and checking the proof against the on-chain root.
- The dashboard shows per-user tickets with Merkle proofs of inclusion.
- During jackpot settlement, the contract verifies winning tickets on-chain using `MerkleProof.verify()`.

### 8.4 Tree Size

| Scenario     | Traders | Avg tickets/trader | Total leaves | Proof depth |
| ------------ | ------- | ------------------ | ------------ | ----------- |
| Small epoch  | 500     | 5                  | 2,500        | ~12 hashes  |
| Medium epoch | 2,000   | 10                 | 20,000       | ~15 hashes  |
| Large epoch  | 5,000   | 20                 | 100,000      | ~17 hashes  |

### 8.5 On-Chain Verification (jackpot only)

The on-chain leaf hash **must** mirror the OZ double-hash so proofs validate correctly:

```solidity
function _verifyTicket(
    uint256 epochId,
    address trader,
    uint8[5] calldata balls,    // must be sorted ascending
    uint8 snaxBall,
    uint256 ticketIndex,
    bytes32[] calldata proof
) internal view returns (bool) {
    require(balls[0] <= balls[1] && balls[1] <= balls[2] &&
            balls[2] <= balls[3] && balls[3] <= balls[4], "unsorted");

    bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(
        trader, epochId,
        balls[0], balls[1], balls[2], balls[3], balls[4],
        snaxBall, ticketIndex
    ))));
    return MerkleProof.verify(proof, epochMerkleRoots[epochId], leaf);
}
```

> **Critical**: both sides must use `abi.encode` + double `keccak256`. If either the off-chain tree or the on-chain verifier uses a different encoding (`abi.encodePacked`) or a single hash, proofs will fail.

---

## 9. Small Prize Resolution

Small prizes (fewer than 5+Snax matching balls) are **not settled on-chain** within Snaxpot. The flow:

1. Operator computes all small-prize winners off-chain.
2. Operator calls `resolveSmallPrizes(epochId, ...)` on Snaxpot — emits event only, no USDT moves.
3. Distribution is handled via the **PrizeDistributor** contract (see §9.1).

### 9.1 PrizeDistributor Contract

Standalone contract. **No on-chain interaction with Snaxpot or JackpotClaimer.** Holds a USDT pool that the operator draws from to distribute small prizes via an external deposit contract.

**Roles:**

| Role                   | Permissions               |
| ---------------------- | ------------------------- |
| **ADMIN / Treasury**   | `fund()`, `recoverUSDT()` |
| **OPERATOR (relayer)** | `distribute()`            |

**Interface:**

```solidity
function fund(uint256 amount) external;
function recoverUSDT(address to, uint256 amount) external onlyAdmin;
function distribute(address[] calldata winners, uint256[] calldata amounts) external onlyOperator;
```

**`fund(uint256 amount)`**

- Transfers USDT into the PrizeDistributor from caller. Permissionless (anyone can fund) or admin-only — TBD.
- Emits `PrizeDistributorFunded(amount)`.

**`recoverUSDT(address to, uint256 amount)`**

- Admin/treasury can withdraw USDT from the pool at any time (unlike Snaxpot, this pool is explicitly recoverable).

**`distribute(address[] winners, uint256[] amounts)`**

- Operator-only. For each winner, approves and deposits their USDT amount into an external **deposit contract** (address stored as config, details TBD).
- Does **not** send USDT directly to winners — it calls the deposit contract on their behalf.
- Emits `PrizeDistributed(winner, amount)` per winner.

```solidity
address public depositContract;  // external contract, set by admin

function distribute(address[] calldata winners, uint256[] calldata amounts) external onlyOperator {
    for (uint256 i = 0; i < winners.length; i++) {
        SafeERC20.forceApprove(usdt, depositContract, amounts[i]);
        IDepositContract(depositContract).deposit(winners[i], amounts[i]);
        emit PrizeDistributed(winners[i], amounts[i]);
    }
}
```

**Key properties:**

- Fully siloed — no calls to/from Snaxpot or JackpotClaimer.
- Admin can recover all USDT (this is a funded pool, not user escrow).
- Distribution goes through an external deposit contract, not direct transfers to winners.
- Deposit contract interface details TBD.

---

## 10. Ticket Log (event-only, no state change)

An optional operator function that emits an event for each ticket. **This is purely informational — it modifies no state, holds no funds, and has no effect on the lottery logic.** It exists solely to put ticket data on-chain as indexed events for off-chain consumers / block explorers.

```solidity
struct TicketLog {
    address trader;
    uint8[5] balls;       // sorted ascending
    uint8 snaxBall;
    uint256 ticketIndex;
}

function logTickets(uint256 epochId, TicketLog[] calldata tickets) external onlyOperator {
    for (uint256 i = 0; i < tickets.length; i++) {
        emit TicketAdded(
            epochId,
            tickets[i].trader,
            tickets[i].balls,
            tickets[i].snaxBall,
            tickets[i].ticketIndex
        );
    }
}
```

- Operator-only. Can be called at any time for any epoch.
- Does **not** write to storage — the only side effect is event emission.
- The Merkle tree remains the authoritative ticket commitment; these events are a convenience layer.
- Gas cost scales linearly with array length (event emission only, no SSTOREs).

---

## 11. Events

```solidity
event EpochOpened(uint256 indexed epochId, uint256 vrfSeed, uint256 startTimestamp);
event EpochClosed(uint256 indexed epochId, uint256 closeTimestamp);
event MerkleRootCommitted(uint256 indexed epochId, bytes32 root);
event WinningNumbersDrawn(uint256 indexed epochId, uint8[5] balls, uint8 snaxBall, uint256 vrfRequestId);
event JackpotWon(uint256 indexed epochId, address indexed winner, uint256 amount);
event JackpotRolledOver(uint256 indexed epochId, uint256 rolledAmount);
event SmallPrizesResolved(uint256 indexed epochId, uint256 totalAmount, uint256 winnerCount);
event JackpotFunded(uint256 amount, uint256 newTotal);
event TicketAdded(uint256 indexed epochId, address indexed trader, uint8[5] balls, uint8 snaxBall, uint256 ticketIndex);
```

---

## 12. Storage Layout (Snaxpot)

Key state variables (UUPS-safe, no storage collisions with proxy):

```solidity
// Epoch tracking
uint256 public currentEpochId;
mapping(uint256 => Epoch) public epochs;

struct Epoch {
    EpochState state;
    uint256 startTimestamp;
    uint256 closeTimestamp;       // set when operator calls closeEpoch()
    uint256 vrfSeed;              // from openEpoch VRF callback
    bytes32 merkleRoot;
    uint8[5] winningBalls;        // sorted ascending
    uint8 winningSnaxBall;
    uint256 jackpotAmount;        // snapshot at draw time
    uint256 vrfRequestId;         // for winning numbers request
    bool jackpotClaimed;
}

enum EpochState { OPEN, CLOSED, DRAWING, RESOLVED }

// Jackpot
uint256 public currentJackpot;

// VRF
mapping(uint256 => uint256) public vrfRequestToEpoch;  // requestId → epochId

// Config
address public usdt;
address public jackpotClaimer;
```

---

## 13. Upgradeability (UUPS)

`Snaxpot` inherits `UUPSUpgradeable`. Only `ADMIN` role can call `upgradeTo()` / `upgradeToAndCall()`.

Storage layout must follow OpenZeppelin's upgradeable contract patterns:

- Use `@openzeppelin-contracts-upgradeable`.
- Storage gaps in base contracts.
- No constructors; use `initialize()`.
- `_disableInitializers()` in constructor of implementation.

---

## 14. Security Considerations

| Risk                                  | Mitigation                                                                                                                                                                                                                                                                                                                                                                                   |
| ------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Operator posts fraudulent Merkle root | Off-chain monitoring; root published to IPFS for public audit; consider commit-reveal or dispute window                                                                                                                                                                                                                                                                                      |
| VRF manipulation                      | Chainlink VRF V2.5 provides tamper-proof randomness; `requestConfirmations` ≥ 3                                                                                                                                                                                                                                                                                                              |
| USDT blocklist                        | Winner's address could be USDT-blocklisted; `claim()` should handle transfer failure gracefully                                                                                                                                                                                                                                                                                              |
| Re-entrancy on claim                  | Use checks-effects-interactions; SafeERC20; USDT is not a re-entrant token but guard anyway                                                                                                                                                                                                                                                                                                  |
| Stale epoch (operator goes offline)   | Admin can force-resolve or pause; consider timeout-based fallback                                                                                                                                                                                                                                                                                                                            |
| Storage collision on upgrade          | Follow OZ upgrade-safe patterns; use storage gaps; run `forge inspect`                                                                                                                                                                                                                                                                                                                       |
| Front-running `resolveJackpot`        | Only operator can call; no MEV advantage since winner is deterministic from Merkle proof                                                                                                                                                                                                                                                                                                     |
| Compromised operator key / exploit    | Admin calls `pause()` — all operator functions (`openEpoch`, `closeEpoch`, `commitMerkleRoot`, `drawJackpot`, `resolveJackpot`, `resolveSmallPrizes`, `logTickets`) and `fundJackpot` are gated with `whenNotPaused`. Admin can still `unpause()`, upgrade, or recover funds while paused. `claim()` on JackpotClaimer remains callable while paused so existing winners can still withdraw. |

---

## 15. Dependencies

| Dependency                         | Version       | Purpose                                                |
| ---------------------------------- | ------------- | ------------------------------------------------------ |
| OpenZeppelin Contracts Upgradeable | latest stable | AccessControl, UUPSUpgradeable, MerkleProof, SafeERC20 |
| Chainlink VRF V2.5                 | latest stable | On-chain verifiable randomness                         |
| Foundry (forge, cast, anvil)       | latest        | Build, test, deploy                                    |

---

## 16. Repository Structure (planned)

```
├── src/
│   ├── Snaxpot.sol          # Main lottery logic (UUPS)
│   ├── JackpotClaimer.sol         # Jackpot claim escrow
│   ├── PrizeDistributor.sol         # Small prize distribution
│   └── interfaces/
│       ├── ISnaxpot.sol
│       ├── IJackpotClaimer.sol
│       └── IPrizeDistributor.sol
├── script/
│   ├── Deploy.s.sol
│   └── Upgrade.s.sol
├── test/
│   ├── Snaxpot.t.sol
│   ├── JackpotClaimer.t.sol
│   └── mocks/
│       ├── MockVRFCoordinator.sol
│       └── MockUSDT.sol
├── foundry.toml
└── README.md                    # ← you are here
```
