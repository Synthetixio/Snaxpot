# Merkle Tree Construction Guide

This document describes how the off-chain service must construct the Merkle tree
whose root is committed on-chain via `commitMerkleRootAndDraw()`. The on-chain
contract uses this root to verify jackpot claims in `resolveJackpot()`.

---

## 1. Leaf Schema

Each ticket becomes one leaf. A leaf is produced by **double-hashing** four
ABI-encoded fields:

```
leaf = keccak256(bytes.concat(keccak256(abi.encode(wallet, balls, snaxBall, ticketIndex))))
```

| Field         | Solidity Type | Description                                     |
| ------------- | ------------- | ----------------------------------------------- |
| `wallet`      | `address`     | Ticket holder's Ethereum address                |
| `balls`       | `uint8[5]`    | The 5 chosen ball numbers, **sorted ascending** |
| `snaxBall`    | `uint8`       | The Snax Ball number (1–5)                      |
| `ticketIndex` | `uint256`     | Zero-based ticket index within the epoch        |

### Critical rules

- **Balls must be sorted ascending** before hashing. The contract calls
  `_sortBalls()` before verification, so `[19, 9, 31, 11, 21]` must be stored
  as `[9, 11, 19, 21, 31]`.
- **Double keccak256** is mandatory. This is the OpenZeppelin standard leaf
  format that prevents second-preimage attacks. The inner hash uses
  `keccak256(abi.encode(...))` and the outer hash wraps it with
  `keccak256(bytes.concat(...))`.
- `abi.encode` is used, **not** `abi.encodePacked`. The `abi.encode` function
  pads each value to 32 bytes, which avoids collisions between adjacent
  variable-length fields.

### ABI encoding layout (256 bytes total)

```
Offset  Bytes  Value
0x00    32     wallet     (address, left-padded to 32 bytes)
0x20    32     balls[0]   (uint8, left-padded to 32 bytes)
0x40    32     balls[1]
0x60    32     balls[2]
0x80    32     balls[3]
0xA0    32     balls[4]
0xC0    32     snaxBall   (uint8, left-padded to 32 bytes)
0xE0    32     ticketIndex (uint256)
```

---

## 2. Tree Construction

### Hashing algorithm

Internal nodes use **commutative keccak256** (OpenZeppelin `Hashes.commutativeKeccak256`).
This means the two children are **sorted** (lower value first) before being
concatenated and hashed:

```
parent = keccak256(abi.encodePacked(min(left, right), max(left, right)))
```

Because the hash is commutative, sibling order does not matter. This matches
OpenZeppelin's `MerkleProof.verify` which uses the same sorted-pair approach
when walking up the proof.

### Building the tree

1. Collect all `TicketLog` entries for the epoch (from `TicketAdded` events or
   the operator's local database).
2. Compute each leaf using the double-hash formula above.
3. Build a standard binary Merkle tree bottom-up using the commutative hash for
   each pair of siblings.
4. If the number of leaves is odd at any level, promote the unpaired node to
   the next level (standard OpenZeppelin behavior).
5. The final single hash at the top is the **Merkle root** to commit on-chain.

---

## 3. TypeScript / JavaScript Reference

Using **ethers v6** and **@openzeppelin/merkle-tree**:

### Option A: Using @openzeppelin/merkle-tree (recommended)

```typescript
import { StandardMerkleTree } from "@openzeppelin/merkle-tree";

// Each entry: [wallet, balls (sorted), snaxBall, ticketIndex]
const values: [string, number[], number, number][] = [
  ["0x328809Bc894f92807417D2dAD6b7C998c1aFdac6", [9, 11, 19, 21, 31], 4, 0],
  ["0x1D96F2f6BeF1202E4Ce1Ff6Dad0c2CB002861d3e", [9, 11, 19, 21, 31], 4, 1],
  // ... all tickets for the epoch
];

const tree = StandardMerkleTree.of(values, [
  "address", // wallet
  "uint8[5]", // balls (sorted ascending)
  "uint8", // snaxBall
  "uint256", // ticketIndex
]);

// Root to commit on-chain
console.log("Merkle Root:", tree.root);

// Generate proof for a specific entry (by index)
const proof = tree.getProof(0);
console.log("Proof for entry 0:", proof);

// Persist the full tree for later proof generation
const treeJson = tree.dump();
```

> `StandardMerkleTree` uses the same double-keccak leaf encoding and
> commutative internal hashing that the contract expects.

### Option B: Manual construction with ethers

```typescript
import { AbiCoder, keccak256, solidityPacked } from "ethers";

function computeLeaf(
  wallet: string,
  balls: [number, number, number, number, number],
  snaxBall: number,
  ticketIndex: bigint,
): string {
  // Sort balls ascending
  const sorted = [...balls].sort((a, b) => a - b);

  const innerHash = keccak256(
    AbiCoder.defaultAbiCoder().encode(
      ["address", "uint8[5]", "uint8", "uint256"],
      [wallet, sorted, snaxBall, ticketIndex],
    ),
  );

  return keccak256(solidityPacked(["bytes32"], [innerHash]));
}

function commutativeHash(a: string, b: string): string {
  const [lo, hi] = BigInt(a) < BigInt(b) ? [a, b] : [b, a];
  return keccak256(solidityPacked(["bytes32", "bytes32"], [lo, hi]));
}
```

---

## 4. Proof Format for `resolveJackpot()`

The on-chain function expects a `JackpotWinner[]` array:

```solidity
struct JackpotWinner {
    address winner;
    uint256 ticketIndex;
    bytes32[] merkleProof;
}
```

Each `merkleProof` is an ordered array of sibling hashes from the leaf up to
(but not including) the root. `MerkleProof.verify` walks the proof bottom-up,
applying `commutativeKeccak256` at each step, and checks that the result equals
the stored `epoch.merkleRoot`.

---

## 5. Worked Example

Using the test fixtures from `GenerateMerkleForTests.s.sol`:

```
Wallets:
  alice = 0x328809Bc894f92807417D2dAD6b7C998c1aFdac6
  bob   = 0x1D96F2f6BeF1202E4Ce1Ff6Dad0c2CB002861d3e

Tickets (4 leaves):
  [0] alice | [9,11,19,21,31] | snaxBall=4 | idx=0
  [1] bob   | [9,11,19,21,31] | snaxBall=4 | idx=0
  [2] alice | [5,9,13,17,21]  | snaxBall=3 | idx=1
  [3] bob   | [1,7,12,20,28]  | snaxBall=2 | idx=1

Tree structure:
          root
         /    \
       h01    h23
       / \    / \
      L0  L1 L2  L3

  h01  = commutativeKeccak256(L0, L1)
  h23  = commutativeKeccak256(L2, L3)
  root = commutativeKeccak256(h01, h23)

Proof for L0 (alice, ticket 0): [L1, h23]
Proof for L1 (bob,   ticket 0): [L0, h23]
Proof for L2 (alice, ticket 1): [L3, h01]
Proof for L3 (bob,   ticket 1): [L2, h01]
```

---

## 6. Checklist

- [ ] Balls are sorted ascending before hashing
- [ ] Using `abi.encode` (not `abi.encodePacked`)
- [ ] Double keccak256 applied (inner hash wrapped in `bytes.concat` then hashed again)
- [ ] Internal nodes use commutative (sorted-pair) keccak256
- [ ] Merkle root matches what `commitMerkleRootAndDraw()` will store
- [ ] Proofs verified locally before submitting `resolveJackpot()` tx

---

---

<!-- SEPOLIA-TEST-ROOTS -->

## Sepolia Test Roots

> Auto-generated by `script/merkle/sepolia-merkle.mjs` on 2026-04-01 03:11:08 UTC

### No-winner epoch (organic tree)

Paste this into `commitMerkleRootAndDraw` → `root`:

```
0x5272f2f52a15a5e83b78b525bd0817fdafaedee9615235d88eed804cd56d6818
```

100 random tickets across 20 random wallets. Virtually impossible to match
any VRF draw. After draw, call `resolveJackpotNoWinner(epochId)`.

### Guaranteed-winner epoch (all-tickets tree)

Paste this into `commitMerkleRootAndDraw` → `root`:

```
0xe65e756598085b796317b2ef3f476fe72e830e3b294a725debde3446221852d5
```

Winner wallet: `0x0d3DABaF73BE51E2C4b7BA17C1106Fb52b6C74B4`

1,006,880 leaves covering every possible ball + snaxBall combination,
all assigned to the wallet above. No matter what VRF draws, a matching
ticket exists.
