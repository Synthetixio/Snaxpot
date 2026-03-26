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
│              SnaxpotCore (UUPS)               │
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
│  JackpotVault   │  │  PrizePool         │
│  (claiming)     │  │  (small winners)   │
│                 │  │                    │
│  Jackpot winner │  │  Standalone.       │
│  calls claim()  │  │  Distributes via   │
│  to withdraw    │  │  external deposit  │
│  USDT           │  │  contract.         │
└─────────────────┘  └────────────────────┘
```

| Contract         | Upgradeability | Purpose                                                                                                                           |
| ---------------- | -------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| **SnaxpotCore**  | UUPS proxy     | Main lottery logic — epochs, VRF, Merkle verification, jackpot settlement                                                         |
| **JackpotVault** | UUPS proxy     | Escrow for jackpot winnings; winner calls `claim()` to withdraw USDT                                                              |
| **PrizePool**    | TBD            | Standalone USDT pool for small-prize distribution via external deposit contract. No interaction with SnaxpotCore or JackpotVault. |

---

## 3. Roles & Access Control

Two roles minimum, enforced via OpenZeppelin `AccessControl` (or equivalent):

| Role         | Permissions                                                                                                                                                 |
| ------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **ADMIN**    | Upgrade contracts (UUPS), grant/revoke roles, set protocol parameters (VRF config, fee splits, merkle window), pause/unpause, `rescueToken` (non-USDT only) |
| **OPERATOR** | `openEpoch`, `closeEpoch`, `commitMerkleRoot`, `drawJackpot`, `resolveJackpot`, `resolveSmallPrizes`, `logTickets`                                          |

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

### 4.3 Timing

| Parameter                     | Default                        | Configurable |
| ----------------------------- | ------------------------------ | ------------ |
| Merkle root submission window | Up to 1 week after epoch close | Yes (admin)  |
| VRF fulfillment timeout       | Configurable                   | Yes (admin)  |

### 4.4 Flow

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
        → Transfers jackpot USDT to JackpotVault
        → event JackpotWon(epochId, winner, amount)

      If no winner:
        → Jackpot rolls into next epoch's pool
        → event JackpotRolledOver(epochId, rolledAmount)

7.  Operator calls resolveSmallPrizes(epochId, totalAmount, winners[])
      → Emits event for off-chain distribution
      → No on-chain USDT transfer for small prizes (handled via PrizePool contract)
      → event SmallPrizesResolved(epochId, totalAmount, winnerCount)
      → Epoch state → RESOLVED

    Steps 4-7 happen while the next epoch is already OPEN and collecting tickets.
```

### 4.5 Invariants

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

Anyone (operator, protocol fee router, or external donor) can deposit USDT into `SnaxpotCore` **at any time**, including mid-epoch. This allows the jackpot to grow throughout the week as trading fees are converted and deposited.

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

**`epochJackpot[epochId]`** is set once, at the moment `drawJackpot(epochId)` is called. It snapshots `currentJackpot` at draw time and subtracts it from `currentJackpot`:

```
drawJackpot(epochId):
    epochJackpot[epochId] = currentJackpot
    currentJackpot = 0
```

Any USDT deposited _after_ the snapshot (i.e., after `drawJackpot()` but before or during the next epoch) goes into the next epoch's pot automatically since it adds to `currentJackpot` which starts fresh at 0.

### 6.3 Rollover

If `resolveJackpotNoWinner(epochId)` is called:

```
currentJackpot += epochJackpot[epochId]
epochJackpot[epochId] = 0  // or leave as historical record and track rollover separately
```

The unclaimed amount flows back into `currentJackpot`, stacking on top of any new deposits that arrived since the draw. No USDT moves — it's purely internal accounting.

### 6.4 Winner Payout

On `resolveJackpot(epochId, ...)`:

1. Verifies the winning ticket via Merkle proof (see §8).
2. Transfers `epochJackpot[epochId]` in USDT to `JackpotVault`.
3. Records the claim entitlement: `JackpotVault.credit(winner, amount)`.
4. `epochJackpot[epochId]` marked as claimed.

`currentJackpot` is unaffected — it already had the snapshot subtracted at draw time and may have new deposits accumulating for the next draw.

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
                              drawJackpot(N)         │
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

**Non-USDT ERC-20 tokens**: There is no on-chain mechanism to prevent arbitrary ERC-20 tokens from being transferred to the contract — ERC-20 `transfer()` executes on the token contract with no receiver callback. Non-USDT tokens sent to the contract are effectively stuck. An admin-only `rescueToken(address token, address to, uint256 amount)` function allows recovering accidentally sent tokens. **Hardcoded to reject USDT** — there is no admin function that can withdraw USDT from the contract. The only way to extract USDT is through the normal lottery flow (`resolveJackpot` → `JackpotVault` → `claim`). If USDT recovery is ever truly needed (e.g., contract migration), it requires a UUPS upgrade to deploy new logic.

```solidity
function rescueToken(address token, address to, uint256 amount) external onlyAdmin {
    require(token != address(usdt), "cannot withdraw USDT");
    SafeERC20.safeTransfer(IERC20(token), to, amount);
}
```

**USDT sweep — reconciling direct transfers**: If someone sends USDT directly to the contract (via `usdt.transfer(snaxpotCore, amount)` instead of `fundJackpot()`), the contract has no callback to detect it. A `sweepUSDT()` function reconciles the actual USDT balance against internal accounting and credits the difference to the jackpot:

```solidity
uint256 public totalAccountedUSDT;  // sum of all tracked USDT (jackpot + epoch snapshots + pending payouts)

function sweepUSDT() external {
    uint256 actual = usdt.balanceOf(address(this));
    uint256 surplus = actual - totalAccountedUSDT;
    if (surplus > 0) {
        currentJackpot += surplus;
        totalAccountedUSDT += surplus;
        emit JackpotFunded(surplus, currentJackpot);
    }
}
```

- Permissionless — anyone can call it (operator bot calls it routinely).
- `totalAccountedUSDT` is updated on every `fundJackpot()`, `drawJackpot()`, `resolveJackpot()`, and rollover to stay in sync.
- Ensures no USDT is silently lost if sent outside the `fundJackpot()` path.

**USDT quirks**:

- `transfer` / `transferFrom` do not return `bool` on mainnet.
- Use OpenZeppelin `SafeERC20` for all USDT interactions.
- Use `SafeERC20.forceApprove()` for all approvals.

---

## 7. JackpotVault Contract

Simple escrow allowing verified jackpot winners to claim.

```solidity
// Simplified interface
function credit(address winner, uint256 amount) external;   // only callable by SnaxpotCore
function claim() external;                                   // winner withdraws their USDT
function claimableBalance(address user) external view returns (uint256);
function sweepExpired(address winner) external;              // admin-only, reclaims expired credits
```

- USDT transferred in from SnaxpotCore on `credit()`. Each credit records a timestamp.
- Winner calls `claim()` to withdraw their USDT at any time within the claim window.
- **3-month expiry**: unclaimed credits expire after 90 days. Admin calls `sweepExpired()` to return expired funds to `SnaxpotCore` (credited back to `currentJackpot`).
- One active credit per winner per epoch.

---

## 8. Merkle Tree — Ticket Commitment

### 8.1 Leaf Format

Each ticket is one leaf:

```
leaf = keccak256(abi.encodePacked(
    trader,          // address — ticket owner
    epochId,         // uint256 — epoch identifier
    balls[0],        // uint8 — sorted ascending
    balls[1],        // uint8
    balls[2],        // uint8
    balls[3],        // uint8
    balls[4],        // uint8
    snaxBall,        // uint8
    ticketIndex      // uint256 — unique index within trader's tickets for this epoch
))
```

**Ball ordering**: The 5 standard balls MUST be sorted in ascending order before hashing. This ensures the same set of numbers always produces the same leaf hash regardless of selection order. The contract enforces sorted order when verifying.

**One leaf per ticket**: If Alice has 3 tickets, the tree contains 3 separate leaves (each with different numbers and a unique `ticketIndex`). A trader with 500 tickets produces 500 leaves.

### 8.2 Tree Construction

The operator builds a standard binary Merkle tree (OpenZeppelin-compatible) over all ticket leaves for the epoch:

- Leaves are sorted.
- Uses the leaf-pair hashing scheme from OpenZeppelin's `MerkleProof` library.

### 8.3 Publication and Verification

- The operator publishes the full tree data (all leaves + proofs) via IPFS or API.
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

    bytes32 leaf = keccak256(abi.encodePacked(
        trader, epochId,
        balls[0], balls[1], balls[2], balls[3], balls[4],
        snaxBall, ticketIndex
    ));
    return MerkleProof.verify(proof, epochMerkleRoots[epochId], leaf);
}
```

---

## 9. Small Prize Resolution

Small prizes (fewer than 5+Snax matching balls) are **not settled on-chain** within SnaxpotCore. The flow:

1. Operator computes all small-prize winners off-chain.
2. Operator calls `resolveSmallPrizes(epochId, ...)` on SnaxpotCore — emits event only, no USDT moves.
3. Distribution is handled via the **PrizePool** contract (see §9.1).

### 9.1 PrizePool Contract

Standalone contract. **No on-chain interaction with SnaxpotCore or JackpotVault.** Holds a USDT pool that the operator draws from to distribute small prizes via an external deposit contract.

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

- Transfers USDT into the PrizePool from caller. Permissionless (anyone can fund) or admin-only — TBD.
- Emits `PrizePoolFunded(amount)`.

**`recoverUSDT(address to, uint256 amount)`**

- Admin/treasury can withdraw USDT from the pool at any time (unlike SnaxpotCore, this pool is explicitly recoverable).

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

- Fully siloed — no calls to/from SnaxpotCore or JackpotVault.
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
event MerkleWindowUpdated(uint256 merkleWindow);
```

---

## 12. Storage Layout (SnaxpotCore)

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
address public jackpotVault;
uint256 public merkleSubmissionWindow;
```

---

## 13. Upgradeability (UUPS)

`SnaxpotCore` inherits `UUPSUpgradeable`. Only `ADMIN` role can call `upgradeTo()` / `upgradeToAndCall()`.

Storage layout must follow OpenZeppelin's upgradeable contract patterns:

- Use `@openzeppelin-contracts-upgradeable`.
- Storage gaps in base contracts.
- No constructors; use `initialize()`.
- `_disableInitializers()` in constructor of implementation.

---

## 14. Security Considerations

| Risk                                  | Mitigation                                                                                                                                                                                                                                                                                                                                                                                 |
| ------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Operator posts fraudulent Merkle root | Off-chain monitoring; root published to IPFS for public audit; consider commit-reveal or dispute window                                                                                                                                                                                                                                                                                    |
| VRF manipulation                      | Chainlink VRF V2.5 provides tamper-proof randomness; `requestConfirmations` ≥ 3                                                                                                                                                                                                                                                                                                            |
| USDT blocklist                        | Winner's address could be USDT-blocklisted; `claim()` should handle transfer failure gracefully                                                                                                                                                                                                                                                                                            |
| Re-entrancy on claim                  | Use checks-effects-interactions; SafeERC20; USDT is not a re-entrant token but guard anyway                                                                                                                                                                                                                                                                                                |
| Stale epoch (operator goes offline)   | Admin can force-resolve or pause; consider timeout-based fallback                                                                                                                                                                                                                                                                                                                          |
| Storage collision on upgrade          | Follow OZ upgrade-safe patterns; use storage gaps; run `forge inspect`                                                                                                                                                                                                                                                                                                                     |
| Front-running `resolveJackpot`        | Only operator can call; no MEV advantage since winner is deterministic from Merkle proof                                                                                                                                                                                                                                                                                                   |
| Compromised operator key / exploit    | Admin calls `pause()` — all operator functions (`openEpoch`, `closeEpoch`, `commitMerkleRoot`, `drawJackpot`, `resolveJackpot`, `resolveSmallPrizes`, `logTickets`) and `fundJackpot` are gated with `whenNotPaused`. Admin can still `unpause()`, upgrade, or recover funds while paused. `claim()` on JackpotVault remains callable while paused so existing winners can still withdraw. |

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
│   ├── SnaxpotCore.sol          # Main lottery logic (UUPS)
│   ├── JackpotVault.sol         # Jackpot claim escrow
│   ├── PrizePool.sol            # Small prize pool (TBD)
│   └── interfaces/
│       ├── ISnaxpotCore.sol
│       ├── IJackpotVault.sol
│       └── IPrizePool.sol
├── script/
│   ├── Deploy.s.sol
│   └── Upgrade.s.sol
├── test/
│   ├── SnaxpotCore.t.sol
│   ├── JackpotVault.t.sol
│   └── mocks/
│       ├── MockVRFCoordinator.sol
│       └── MockUSDT.sol
├── foundry.toml
└── README.md                    # ← you are here
```

---

## 17. Open Questions
