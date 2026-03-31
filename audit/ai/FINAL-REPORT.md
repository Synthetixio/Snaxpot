# Security Audit Report -- Snaxpot Lottery Protocol

---

## Executive Summary

| | |
|---|---|
| **Protocol** | Snaxpot -- on-chain lottery with Chainlink VRF draws and USDT prize pools |
| **Scope** | `Snaxpot.sol`, `JackpotClaimer.sol`, `PrizeDistributor.sol` |
| **Chain** | Ethereum Mainnet |
| **Token** | USDT (Tether, 6 decimals) |
| **Solidity** | ^0.8.28 |
| **Audit date** | 2026-03-31 |
| **Prior audits** | None |

### Finding Summary

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 6 |
| Low | 3 |
| Informational | 2 |
| **Total** | **11** |

All 6 Medium findings were independently confirmed via Foundry proof-of-concept tests. No Critical or High severity issues were found. The protocol's core lottery mechanics (VRF ball derivation, Merkle proof verification, epoch state machine) are sound. The findings cluster around two themes: (1) insufficient defensive handling of USDT's non-standard behaviors (fee-on-transfer, blocklist), and (2) operator trust surface that exceeds the documented constraint model.

---

## Findings

---

### [M-01] Unchecked subtraction in reconcileUSDT permanently bricks surplus recovery on USDT balance deficit

**Severity:** Medium
**Contract:** `Snaxpot.sol` -- `reconcileUSDT()` (line 315)
**Bug class:** Integer underflow / Defensive programming failure

#### Root Cause

`reconcileUSDT()` computes `uint256 surplus = actual - totalAccountedUSDT` using Solidity 0.8 checked arithmetic with no preceding guard. If `usdt.balanceOf(Snaxpot)` ever drops below `totalAccountedUSDT`, the subtraction underflows and the function permanently reverts.

```solidity
function reconcileUSDT() external onlyRole(DEFAULT_ADMIN_ROLE) {
    uint256 actual = usdt.balanceOf(address(this));
    uint256 surplus = actual - totalAccountedUSDT; // reverts if actual < totalAccountedUSDT
    if (surplus > 0) {
        currentJackpot += surplus;
        totalAccountedUSDT += surplus;
        emit JackpotFunded(surplus, currentJackpot);
    }
}
```

No `if (actual >= totalAccountedUSDT)` check exists anywhere in the function.

#### Attack Path

1. USDT fee activation: Tether admin sets `basisPointsRate = 100` (1%)
2. `fundJackpot(10_000e6)` -- Snaxpot receives 9,900 USDT, credits 10,000 USDT to `totalAccountedUSDT`
3. `usdt.balanceOf(Snaxpot) = 9,900e6`, `totalAccountedUSDT = 10,000e6`
4. Admin calls `reconcileUSDT()` -- `9,900e6 - 10,000e6` -> arithmetic underflow -> **permanent revert**
5. All future calls to `reconcileUSDT()` also revert (deficit persists)

Alternative triggers: USDT contract blacklisting Snaxpot's address, or Tether confiscation.

#### Impact

The protocol's sole surplus-recovery mechanism is permanently bricked. Direct USDT transfers to the contract and division dust from `resolveJackpot` become unrecoverable through normal operations. The rest of the protocol (fundJackpot, resolveJackpot, claim) continues functioning. Admin can deploy a UUPS upgrade as a last-resort fix.

#### PoC Reference

**DeTest CONFIRMED** -- `test/detest/Snaxpot_integerUnderflow_F1.t.sol`
Trace: `fundJackpot(10,000 USDT)` with simulated fee creates deficit. `reconcileUSDT()` triggers `panic: arithmetic underflow or overflow (0x11)`.

#### Recommended Fix

```solidity
function reconcileUSDT() external onlyRole(DEFAULT_ADMIN_ROLE) {
    uint256 actual = usdt.balanceOf(address(this));
    if (actual > totalAccountedUSDT) {
        uint256 surplus = actual - totalAccountedUSDT;
        currentJackpot += surplus;
        totalAccountedUSDT += surplus;
        emit JackpotFunded(surplus, currentJackpot);
    }
}
```

---

### [M-02] USDT-blacklisted jackpot winner has no on-chain claim recovery path

**Severity:** Medium
**Contract:** `JackpotClaimer.sol` -- `claim()` (line 58)
**Bug class:** Missing recovery path for external dependency failure

#### Root Cause

`claim()` sends USDT exclusively to `msg.sender`. No `claimTo(address)` function exists. If a winner's address is added to USDT's actively-maintained blocklist after `credit()` but before `claim()`, `safeTransfer` reverts with no on-chain alternative. After 90 days, admin calls `sweepExpired()` which sends the funds to the admin address -- the winner permanently loses their prize on-chain.

```solidity
function claim() external override {
    uint256 amount = balances[msg.sender];
    if (amount == 0) revert NothingToClaim();
    balances[msg.sender] = 0;
    expiresAt[msg.sender] = 0;
    usdt.safeTransfer(msg.sender, amount); // reverts if msg.sender is USDT-blacklisted
    emit Claimed(msg.sender, amount);
}
```

Comparison: `sweepExpired()` (line 63) sends to `admin`, not to the winner. No function allows a winner to designate an alternative recipient.

#### Attack Path

1. `resolveJackpot(epoch1, ..., [Alice])` -> `credit(Alice, epoch1, 50,000 USDT)`
2. `JackpotClaimer.balances[Alice] = 50,000e6`, `expiresAt = now + 90 days`
3. Tether adds Alice to USDT blocklist (OFAC compliance action)
4. `Alice.claim()` -> `safeTransfer(Alice, 50,000e6)` -> **REVERT** (blocklist)
5. Alice has no `claimTo(altAddress)` available
6. 90 days pass -> `admin.sweepExpired(Alice)` -> 50,000 USDT -> admin address
7. Alice's jackpot prize is permanently lost on-chain

#### Impact

Winner permanently loses their jackpot prize. USDT's blocklist is actively maintained with 1000+ addresses. The admin has an off-chain workaround (sweep and manually return), but this provides no on-chain guarantee and requires trust in the admin.

#### PoC Reference

**DeTest CONFIRMED** -- `test/detest/JackpotClaimer_logicBug_F2.t.sol`
Trace: Winner credited 50,000 USDT. Address added to blocklist. `claim()` reverts with `"Blocklist: recipient blocked"`. After 90 days, `sweepExpired` sends funds to admin.

#### Recommended Fix

Add a `claimTo(address)` function that allows the winner to redirect their claim:

```solidity
function claimTo(address recipient) external {
    if (recipient == address(0)) revert ZeroAddress();
    uint256 amount = balances[msg.sender];
    if (amount == 0) revert NothingToClaim();
    balances[msg.sender] = 0;
    expiresAt[msg.sender] = 0;
    usdt.safeTransfer(recipient, amount);
    emit Claimed(msg.sender, amount);
}
```

---

### [M-03] Fee-on-transfer USDT activation breaks accounting across all three contracts

**Severity:** Medium
**Contracts:** `Snaxpot.sol` -- `fundJackpot()` (line 326), `JackpotClaimer.sol` -- `credit()` (line 43), `PrizeDistributor.sol` -- `fund()` (line 33)
**Bug class:** Accounting error under changed external conditions

#### Root Cause

All incoming USDT transfers credit the nominal `amount` parameter to internal accounting rather than the actual received balance. USDT has a deployed (currently dormant) `basisPointsRate` fee mechanism. If Tether activates it, every transfer creates a progressive deficit where internal accounting exceeds the real USDT balance.

```solidity
// Snaxpot.sol:325-329
usdt.safeTransferFrom(msg.sender, address(this), amount);
currentJackpot += amount;        // credits nominal, not received
totalAccountedUSDT += amount;    // credits nominal, not received

// JackpotClaimer.sol:43-45
usdt.safeTransferFrom(msg.sender, address(this), amount);
balances[winner] += amount;      // credits nominal, not received
```

None of the three contracts implement the `balanceBefore / balanceAfter` delta pattern.

#### Attack Path

**Snaxpot path:**
1. Tether activates `basisPointsRate = 100` (1%)
2. `fundJackpot(1,000,000e6)` -- contract receives 990,000 USDT, credits 1,000,000 USDT
3. After 100 fundings: accumulated deficit = 10,000,000 USDT
4. `reconcileUSDT()` -> underflow -> permanent revert (chains to M-01)

**JackpotClaimer path:**
1. `resolveJackpot()` -> `credit(Alice, 500,000e6)` -- JackpotClaimer receives 495,000 USDT, credits 500,000
2. `Alice.claim()` -> attempts `safeTransfer(Alice, 500,000e6)` -> **REVERT** (insufficient balance)

#### Impact

Protocol-wide insolvency. `totalAccountedUSDT` exceeds real balance (bricking `reconcileUSDT` via M-01). JackpotClaimer credits exceed holdings (making `claim()` revert). PrizeDistributor `distribute()` fails (total exceeds actual balance). Every USDT-using function is affected.

USDT's fee has never been activated in 8+ years, but the capability is deployed and functional on mainnet.

#### PoC Reference

**DeTest CONFIRMED** -- `test/detest/Snaxpot_feeOnTransfer_F3.t.sol`
Both paths demonstrated: Snaxpot deficit triggers `reconcileUSDT` panic, JackpotClaimer claim triggers `ERC20InsufficientBalance`.

#### Recommended Fix

Apply the balance-delta pattern to all incoming USDT transfers:

```solidity
function fundJackpot(uint256 amount) external whenNotPaused {
    uint256 before = usdt.balanceOf(address(this));
    usdt.safeTransferFrom(msg.sender, address(this), amount);
    uint256 received = usdt.balanceOf(address(this)) - before;
    currentJackpot += received;
    totalAccountedUSDT += received;
    emit JackpotFunded(received, currentJackpot);
}
```

Apply the same pattern to `JackpotClaimer.credit()` and `PrizeDistributor.fund()`.

---

### [M-04] VRF liveness failure permanently locks epoch jackpot with no recovery mechanism

**Severity:** Medium
**Contract:** `Snaxpot.sol` -- `commitMerkleRootAndDraw()` (line 147), `fulfillRandomWords()` (line 350)
**Bug class:** Missing liveness recovery for async external dependency

#### Root Cause

After `commitMerkleRootAndDraw` transitions an epoch to DRAWING, the only exit is `fulfillRandomWords` (the VRF callback). No timeout, retry, or cancellation mechanism exists. If Chainlink VRF fails to fulfill -- VRF subscription out of LINK, callback gas limit too low, coordinator issues -- the epoch is permanently stuck in DRAWING.

```
State machine:
  commitMerkleRootAndDraw -> epoch.state = DRAWING
  fulfillRandomWords      -> epoch.state = DRAWN    (ONLY exit from DRAWING)
  resolveJackpot          -> requires DRAWN -> reverts
  resolveJackpotNoWinner  -> requires DRAWN -> reverts
  No admin override or timeout exists
```

The epoch's `jackpotAmount` was removed from `currentJackpot` during `_closeEpoch` but can never be resolved or rolled over.

#### Attack Path

1. `openEpoch()` -> epoch 1 OPEN
2. `fundJackpot(100,000 USDT)` -> `currentJackpot = 100,000e6`
3. `closeEpoch(1)` -> `epoch.jackpotAmount = 100,000e6`, `currentJackpot = 0`
4. `commitMerkleRootAndDraw(1, root)` -> epoch 1 enters DRAWING state
5. VRF callback fails (gas limit too low for 6-word response) -- Chainlink VRF V2.5 does not retry
6. `resolveJackpotNoWinner(1)` -> **REVERT** `InvalidEpochState(1, 3, 4)` (state=DRAWING, expected=DRAWN)
7. `resolveJackpot(1, ...)` -> **REVERT** `InvalidEpochState(1, 3, 4)`
8. 100,000 USDT locked -- requires UUPS upgrade to recover

#### Impact

Epoch jackpot funds become inaccessible without a full UUPS contract upgrade. The protocol can continue with new epochs (new jackpots can be funded), but the stuck epoch's funds are lost to normal operations. A UUPS upgrade requires a new implementation, audit, and governance action -- significant operational cost and risk.

#### PoC Reference

**DeTest CONFIRMED** -- `test/detest/Snaxpot_vrfLiveness_F4.t.sol`
Trace: Epoch advanced to DRAWING. After `vm.warp(365 days)`, both `resolveJackpotNoWinner` and `resolveJackpot` revert with `InvalidEpochState(1, 3, 4)`.

#### Recommended Fix

Add a timeout-based admin escape hatch:

```solidity
uint256 public constant VRF_TIMEOUT = 1 days;

function cancelDrawing(uint256 epochId) external onlyRole(DEFAULT_ADMIN_ROLE) {
    EpochData storage epoch = epochs[epochId];
    if (epoch.state != EpochState.DRAWING) revert InvalidEpochState(...);
    if (block.timestamp < epoch.closeTimestamp + VRF_TIMEOUT) revert TooEarly();

    epoch.state = EpochState.CLOSED;
    delete epoch.merkleRoot;
}
```

---

### [M-05] resolveJackpotNoWinner accepts operator claim without any on-chain verification

**Severity:** Medium
**Contract:** `Snaxpot.sol` -- `resolveJackpotNoWinner()` (line 164)
**Bug class:** Operator trust assumption gap

#### Root Cause

`resolveJackpotNoWinner` only checks `epoch.state == DRAWN`. No on-chain verification proves that zero matching tickets exist. A malicious or compromised operator can call this function to deny legitimate winners and roll the jackpot to the next epoch.

```solidity
function resolveJackpotNoWinner(uint256 epochId)
    external onlyRole(OPERATOR_ROLE) whenNotPaused
{
    EpochData storage epoch = epochs[epochId];
    if (epoch.state != EpochState.DRAWN) {
        revert InvalidEpochState(epochId, epoch.state, EpochState.DRAWN);
    }
    epoch.state = EpochState.RESOLVED; // terminal state
    uint256 rolled = epoch.jackpotAmount;
    currentJackpot += rolled;
    emit JackpotRolledOver(epochId, rolled);
}
```

Comparison: `resolveJackpot` verifies winning balls via `_ballsMatch` and individual winners via Merkle proof. The no-winner path has no equivalent verification. RESOLVED is a terminal state -- once called, `resolveJackpot` can never be invoked for that epoch.

#### Attack Path

1. Epoch reaches DRAWN state with winning numbers `[11, 21, 31, 9, 19]` snaxBall `4`
2. Legitimate winner Alice holds a matching ticket in the committed Merkle tree
3. Operator calls `resolveJackpotNoWinner(1)` -- function only checks state == DRAWN
4. Epoch transitions to RESOLVED (terminal). `jackpotClaimed = false`. 500,000 USDT rolled to `currentJackpot`
5. `resolveJackpot(1, ...)` -> **REVERT** `InvalidEpochState(1, 5, 4)` -- Alice permanently denied

#### Impact

Operator can deny any legitimate jackpot winner. The operator trust model is documented as "constrained by on-chain Merkle verification," but this constraint only applies to `resolveJackpot`. On the no-winner path, the operator is completely unconstrained. Detection is possible via on-chain `TicketAdded` events, but `logTickets` data is operator-submitted and unvalidated.

#### PoC Reference

**DeTest CONFIRMED** -- `test/detest/Snaxpot_operatorTrust_LD.t.sol`
Trace: Epoch funded with 500,000 USDT, advanced to DRAWN with winning numbers. Operator calls `resolveJackpotNoWinner` -- succeeds without any verification. Subsequent `resolveJackpot` reverts.

#### Recommended Fix

Option A -- Add a timelock and challenge period:

```solidity
function resolveJackpotNoWinner(uint256 epochId)
    external onlyRole(OPERATOR_ROLE) whenNotPaused
{
    EpochData storage epoch = epochs[epochId];
    if (epoch.state != EpochState.DRAWN) revert InvalidEpochState(...);
    epoch.state = EpochState.PENDING_NO_WINNER;
    epoch.noWinnerTimestamp = uint40(block.timestamp);
}

function finalizeNoWinner(uint256 epochId)
    external onlyRole(OPERATOR_ROLE) whenNotPaused
{
    EpochData storage epoch = epochs[epochId];
    if (epoch.state != EpochState.PENDING_NO_WINNER) revert InvalidEpochState(...);
    if (block.timestamp < epoch.noWinnerTimestamp + CHALLENGE_PERIOD) revert TooEarly();
    epoch.state = EpochState.RESOLVED;
    currentJackpot += epoch.jackpotAmount;
}
```

Option B -- Require a Merkle non-existence proof or admin co-signature.

---

### [M-06] PrizeDistributor.distribute() gives operator fully unverified control over prize distribution

**Severity:** Medium
**Contract:** `PrizeDistributor.sol` -- `distribute()` (line 37)
**Bug class:** Operator trust assumption gap (variant of M-05)

#### Root Cause

The operator provides `winners`, `amounts`, and `subAccountIds` arrays to `distribute()` with zero on-chain verification. No Merkle proof, no signature, no commitment scheme, no cap on amounts. A malicious or compromised operator can redirect the entire PrizeDistributor balance to arbitrary addresses in a single call.

```solidity
function distribute(
    address[] calldata winners,
    uint256[] calldata amounts,
    uint256[] calldata subAccountIds
) external onlyRole(OPERATOR_ROLE) {
    IDepositContract.DepositEntry[] memory entries =
        new IDepositContract.DepositEntry[](winners.length);
    uint256 total;
    for (uint256 i; i < winners.length; i++) {
        entries[i].token = address(usdt);
        entries[i].amount = amounts[i];
        entries[i].beneficiary = winners[i];
        entries[i].subAccountId = subAccountIds[i];
        total += amounts[i];
        emit PrizeDistributed(winners[i], amounts[i]);
    }
    usdt.forceApprove(address(depositContract), total);
    depositContract.deposit(entries);
}
```

Comparison: `Snaxpot.resolveJackpot` verifies winners via Merkle proof against a committed root. `PrizeDistributor.distribute` has no equivalent constraint.

#### Attack Path

1. PrizeDistributor funded with 200,000 USDT via `fund()`
2. Operator calls `distribute([attackerAddr], [200_000e6], [0])`
3. Entire balance deposited to attacker-controlled address via `depositContract`
4. No on-chain evidence distinguishes this from a legitimate distribution

#### Impact

Operator can drain the entire PrizeDistributor balance, redirect prizes to arbitrary addresses, inflate prize amounts, or exclude legitimate winners. This is arguably more exploitable than M-05 because: (a) `distribute()` is called more frequently (every epoch for small prizes), (b) small discrepancies are harder to detect, and (c) there is no Merkle commitment to audit against.

#### Recommended Fix

Add a commitment scheme -- operator commits a distribution root in advance, then distribution is verified against it. Alternatively, add an admin co-signature requirement for distributions above a threshold.

---

### [L-01] Immutable admin in JackpotClaimer has no migration path if USDT-blacklisted

**Severity:** Low
**Contract:** `JackpotClaimer.sol` -- `admin` (line 16), `sweepExpired()` (line 63)

#### Root Cause

`admin` is `immutable` -- set in the constructor with no setter. `sweepExpired()` sends USDT to `admin` via `safeTransfer`. If the admin address is added to USDT's blocklist, `sweepExpired` permanently fails. No admin migration mechanism exists.

```solidity
address public immutable admin;

function sweepExpired(address winner) external override onlyAdmin {
    // ...
    usdt.safeTransfer(admin, amount); // fails if admin is blacklisted
}
```

#### Impact

If the admin address is USDT-blacklisted, expired unclaimed balances become permanently unrecoverable through `sweepExpired`. Winners can still call `claim()` (sends to their own address). Only expired, unclaimed balances are affected. Likelihood is extremely low -- admin is presumably a multisig.

#### Recommended Fix

Make `admin` mutable with a migration function, or add a `sweepExpiredTo(address winner, address recipient)` function.

---

### [L-02] Batched deposit in PrizeDistributor.distribute() -- one failed recipient blocks all winners

**Severity:** Low
**Contract:** `PrizeDistributor.sol` -- `distribute()` (line 56)

#### Root Cause

All prize recipients are batched into a single `depositContract.deposit(entries)` call. If the deposit contract rejects any individual entry (restricted sub-account, internal validation failure), the entire batch reverts and all winners in that distribution lose their prizes.

```solidity
usdt.forceApprove(address(depositContract), total);
depositContract.deposit(entries); // one bad entry reverts the entire batch
```

Comparison: `JackpotClaimer.claim()` handles each winner independently -- one failure does not affect others.

#### Impact

All winners in a distribution batch are blocked if any single recipient fails. The operator can retry with a filtered batch excluding the problematic recipient. Admin can `recoverUSDT()` to withdraw funds and `setDepositContract()` to change the deposit target. These are operational workarounds, not on-chain guarantees.

#### Recommended Fix

Consider try/catch around individual deposit entries, or split into per-recipient calls with failure tracking.

---

### [L-03] Residual USDT allowance to depositContract persists between distribute() calls

**Severity:** Low
**Contract:** `PrizeDistributor.sol` -- `distribute()` (line 55)

#### Root Cause

`distribute()` calls `forceApprove(depositContract, total)` before `depositContract.deposit(entries)` with no post-call allowance reset. If the deposit contract does not consume the full allowance, the residual persists until the next `distribute()` call.

```solidity
usdt.forceApprove(address(depositContract), total);
depositContract.deposit(entries);
// Missing: usdt.forceApprove(address(depositContract), 0);
```

#### Impact

Marginal incremental risk. A compromised or upgraded deposit contract could drain PrizeDistributor's USDT up to the residual during the inter-call window. However, a compromised deposit contract already receives the full `total` during the call itself -- the residual adds only marginal additional exposure. The next `forceApprove` resets the allowance.

#### Recommended Fix

Reset allowance after the deposit call:

```solidity
usdt.forceApprove(address(depositContract), total);
depositContract.deposit(entries);
usdt.forceApprove(address(depositContract), 0);
```

---

### [I-01] Division dust permanently stranded in totalAccountedUSDT -- code comment incorrect

**Severity:** Informational
**Contract:** `Snaxpot.sol` -- `resolveJackpot()` (lines 208-211)

#### Root Cause

When `epoch.jackpotAmount % winners.length != 0`, integer division produces a remainder:

```solidity
// Integer division may leave dust; reconcileUSDT() sweeps it later.  <-- INCORRECT
uint256 share = epoch.jackpotAmount / winners.length;
uint256 paid = share * winners.length;
totalAccountedUSDT -= paid;
```

The dust (`epoch.jackpotAmount - paid`) remains in both the contract's USDT balance and in `totalAccountedUSDT`. Since `reconcileUSDT` computes `actual - totalAccountedUSDT`, it sees zero surplus -- the dust is invisible to reconciliation. The comment on line 208 is incorrect.

#### Impact

Negligible. Dust per epoch is bounded to `winners.length - 1` minimal USDT units (less than $0.000005 per resolution). Over thousands of epochs, total stranded dust remains under $0.01. The primary issue is the misleading code comment.

#### Recommended Fix

Correct the comment and optionally add the dust to `currentJackpot`:

```solidity
uint256 share = epoch.jackpotAmount / winners.length;
uint256 paid = share * winners.length;
uint256 dust = epoch.jackpotAmount - paid;
totalAccountedUSDT -= paid;
if (dust > 0) {
    currentJackpot += dust;
}
```

---

### [I-02] SEED VRF callback failure silently leaves vrfSeed at zero

**Severity:** Informational
**Contract:** `Snaxpot.sol` -- `_openEpoch()` (line 127), `fulfillRandomWords()` (lines 355-357)

#### Root Cause

The SEED VRF request in `_openEpoch()` does not gate any state transition. If the callback never arrives, `epoch.vrfSeed` stays at its default value of 0. The epoch proceeds through its full lifecycle (OPEN -> CLOSED -> DRAWING -> DRAWN -> RESOLVED) without any on-chain error.

```solidity
function _openEpoch() internal {
    // ...
    epoch.state = EpochState.OPEN;
    _requestVrf(epochId, VrfRequestType.SEED);
    // No state depends on seed callback arriving
}
```

The DRAW VRF (which determines winning numbers) is independent and unaffected.

#### Impact

Off-chain data quality only. The `EpochOpened` event (which carries `vrfSeed`) is never emitted if the callback fails. Off-chain systems using the seed for ticket randomization would receive zero or no seed. No on-chain fund lock, no state machine block.

#### Recommended Fix

Add a `vrfSeed != 0` check before `_closeEpoch` or `commitMerkleRootAndDraw`:

```solidity
function _closeEpoch(uint256 epochId) internal {
    EpochData storage epoch = epochs[epochId];
    if (epoch.vrfSeed == 0) revert SeedNotReceived(epochId);
    // ...
}
```

---

## Disclaimer

This report was produced as part of an independent security review. It does not constitute a guarantee of security. The findings represent the reviewer's assessment at the time of the audit. Smart contract security is an ongoing process -- team security reviews, bug bounty programs, and on-chain monitoring are strongly recommended.
