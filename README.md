# `float-arc-template`

**A binary prediction market on Arc that earns USYC yield on idle stakes.**
Fork this repo, change three things, ship.

```solidity
function bet(bool yes, uint256 amount) external {
    USDC.safeTransferFrom(msg.sender, address(this), amount);

    // ───────────────── FLOAT ─────────────────
    uint256 parkAmount = (amount * 9_500) / 10_000;   // 95% parked
    USDC.forceApprove(address(FLOAT_VAULT), parkAmount);
    FLOAT_VAULT.park(parkAmount);
    // ─────────────────────────────────────────

    // … your market accounting …
}
```

That's the whole integration. Three call sites total — `bet()` parks,
`resolve()` recalls, `claim()` pays out. Everything else is your market logic.

---

## Why this exists

The Arc ecosystem has two reference codebases shipped by Circle:

| Repo | Layer |
|---|---|
| `circlefin/arc-commerce` | Checkout + commerce flows |
| `circlefin/arc-p2p-payments` | P2P USDC transfers |

This template covers the **layer in between**: what USDC does when it's *not*
being spent. For prediction markets that means days or weeks of idle stake
between bet and resolution. With this template, that stake earns USYC yield
until the moment it's needed for payout.

---

## Risk model — read this before you ship

USYC is a NAV-based product backed by short-dated US Treasuries (managed by
Hashnote). "Depeg" risk is closer to a money market fund moving 0.05% in a
stress event than to UST/USDC-style breakage. On Arc the recall is a single
onchain instruction — no AMM slippage, no cross-chain bridge risk.

Residual risk is still non-zero. This contract defends against it with
**four layers** of protection:

### Layer 1 — Liquid reserve buffer

```solidity
uint256 public constant RESERVE_BPS = 500;   // 5%
```

Every deposit splits into two parts: 95% goes into FLOAT, 5% stays liquid in
the contract. Yield from the parked 95% has to underperform by more than the
buffer to even threaten principal.

### Layer 2 — Recall-first, pay-second (fault-tolerant)

`resolve()` calls `FLOAT_VAULT.withdraw(deposits[address(this)])` *before*
claims open. <5s on Arc. The call is wrapped in `try/catch`, so a transient
vault failure (paused, insolvent, etc.) can't lock the market — it just
forces SHORTFALL mode below.

### Layer 3 — Shortfall mode

If the recalled amount is less than the principal owed, the contract forces
the outcome to `SHORTFALL`. In that mode, **every bettor — winner or loser —
gets a pro-rata refund of what was actually recovered**. Winners never
extract a full payout from a depleted pool.

### Layer 4 — Single-sided auto-cancel

If `resolve()` picks a winning side that has zero stake (no one bet that way),
the outcome is forced to `CANCELLED` and the losing side's stakes are
refunded in full. Prevents fund-lock DoS on one-sided markets.

Result: the contract degrades to "everyone gets their stake back, minus a
small haircut" before it ever degrades to "winners get nothing."

---

## Three things to change after forking

1. **`question` and `resolutionTime`** — set in the constructor.
2. **`resolve()` permissioning** — currently owner-only. Wire it to an oracle
   (UMA, Reality.eth, Chainlink) or a multisig if you don't want unilateral
   resolution power.
3. **Payout math** — the default is `winnerShare = stake × totalPool / winnerPool`.
   Change to LMSR, parimutuel-with-fee, or anything else.

Optional fourth: adjust `RESERVE_BPS` to your risk tolerance. Lower = more
yield, higher = safer.

---

## Deployment

Set up env:

```bash
cp .env.example .env
# fill in:
#   PRIVATE_KEY=        (your deployer key)
#   ARC_TESTNET_RPC=    (https://rpc.testnet.arc.network or your provider)
```

Install + compile:

```bash
npm install
npx hardhat compile
```

Deploy:

```bash
npx hardhat run scripts/deploy.ts --network arcTestnet
```

You'll get back a contract address. That's your market.

---

## Demo flow (end-to-end)

```bash
npx hardhat run scripts/demo.ts --network arcTestnet
```

This script:

1. Deploys a new prediction market with a 2-minute resolution window
2. Places a YES bet and a NO bet from the deployer wallet (1 USDC each)
3. Shows the parked / liquid balance split (~95% in FLOAT, ~5% liquid reserve)
4. Waits for resolution time, resolves YES, checks for shortfall
5. Claims the winning payout
6. Skims any residual yield / donations to the owner

Watch the console output — you'll see `Bet`, `Resolved`, and `Claimed` events
fire as USDC flows in and out of FLOAT.

The deployer wallet needs ≥ 2 USDC on Arc Testnet (grab some from
[the Circle faucet](https://faucet.circle.com)).

---

## Contracts

| Contract | Address (Arc Testnet) |
|---|---|
| USDC | `0x3600000000000000000000000000000000000000` |
| FloatVault | `0xfAe6a9D5b0835ca7e9B090eCe0f57C14899BeDA6` |

Your `PredictionMarket` contract address gets printed after `deploy.ts` runs.

---

## What this is *not*

- Not a Polymarket clone — no AMM, no LMSR, no order book. Pure parimutuel.
- Not production-grade by itself — needs an oracle, KYC if your jurisdiction
  requires it, fee logic, and a frontend.
- Not the only way to integrate FLOAT — agent-side integration (off-chain
  via `@floatrouter/sdk`) is also supported. See
  [the SDK repo](https://github.com/ronkenx9/floatrouter-sdk) for that path.

This is the **smart-contract integration template** for any Arc app that
holds USDC and waits. Markets, escrow, vesting, payroll buffers, treasury
modules — all the same pattern.

---

## License

MIT
