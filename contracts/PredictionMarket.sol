// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./interfaces/IFloatVault.sol";

/// @title  PredictionMarket — Arc-native binary prediction market w/ FLOAT yield
/// @notice Idle USDC in the pool earns yield via FLOAT until resolution.
///         Fork this contract, change the resolution logic, ship.
///
///         FLOAT integration is exactly THREE call sites, all marked `── FLOAT ──`:
///           1. bet()      → park (100% - reserve) of incoming USDC into FloatVault
///           2. resolve()  → withdraw everything before claims open
///           3. claim()    → pays from contract's USDC balance, shortfall-safe
///
/// @dev Risk model
///   ────────────
///   USYC is NAV-based (T-bill backed), not algorithmic. Primary risk is a
///   small NAV decline, not a depeg. This contract still defends against
///   shortfall with FOUR layers:
///
///   1. RESERVE_BPS — fraction of every deposit NEVER parked. Acts as a
///      buffer against any underperformance from the parked share.
///   2. resolve() recalls before claims open — single onchain instruction,
///      wrapped in try/catch so a vault failure can't lock the market.
///   3. claim() detects shortfall (liquid < principal owed) and falls back
///      to pro-rata refund of what was recovered. Winners never extract a
///      payout from a depleted pot at the expense of underfunded losers.
///   4. Single-sided markets auto-cancel (any resolve() picking a winning
///      side that has zero stake is forced to CANCELLED). No DoS via
///      one-sided pools.
contract PredictionMarket is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /* ──────────────────────────────────────────────────────────────
       FLOAT integration — Arc Testnet addresses
       ────────────────────────────────────────────────────────────── */

    IERC20 public constant USDC =
        IERC20(0x3600000000000000000000000000000000000000);

    IFloatVault public constant FLOAT_VAULT =
        IFloatVault(0xfAe6a9D5b0835ca7e9B090eCe0f57C14899BeDA6);

    /// @dev Fraction of every deposit kept liquid (NOT parked). 500 = 5%.
    ///      Higher = safer, lower yield. Lower = riskier, more yield.
    uint256 public constant RESERVE_BPS = 500;
    uint256 public constant BPS_DENOM   = 10_000;

    /* ──────────────────────────────────────────────────────────────
       Market state
       ────────────────────────────────────────────────────────────── */

    enum Outcome { UNRESOLVED, YES, NO, CANCELLED, SHORTFALL }

    string  public  question;
    uint256 public  resolutionTime;
    address public  owner;
    Outcome public  outcome;

    uint256 public yesPool;             // total principal staked on YES
    uint256 public noPool;              // total principal staked on NO
    uint256 public recoveredAtResolve;  // liquid USDC the contract had right after resolve()
    uint256 public totalClaimed;        // running sum of payouts (for skim accounting)

    mapping(address => uint256) public yesBets;
    mapping(address => uint256) public noBets;
    mapping(address => bool)    public claimed;

    /* ──────────────────────────────────────────────────────────────
       Events
       ────────────────────────────────────────────────────────────── */

    event MarketCreated (address indexed owner, string question, uint256 resolutionTime);
    event Bet           (address indexed user, bool yes, uint256 amount, uint256 parked, uint256 reserved);
    event Resolved      (Outcome outcome, uint256 recalled, uint256 totalLiquid, bool shortfall);
    event VaultRecallFailed (string reason);
    event Claimed       (address indexed user, uint256 amount);
    event Skimmed       (address indexed to, uint256 yieldAmount);

    /* ──────────────────────────────────────────────────────────────
       Constructor
       ────────────────────────────────────────────────────────────── */

    constructor(string memory _question, uint256 _resolutionTime) {
        require(_resolutionTime > block.timestamp, "resolutionTime in the past");
        require(RESERVE_BPS <= BPS_DENOM,          "reserve > 100% (fork bug)");
        question       = _question;
        resolutionTime = _resolutionTime;
        owner          = msg.sender;
        outcome        = Outcome.UNRESOLVED;

        emit MarketCreated(msg.sender, _question, _resolutionTime);
    }

    /* ──────────────────────────────────────────────────────────────
       bet — user takes a YES or NO position
       ────────────────────────────────────────────────────────────── */

    function bet(bool yes, uint256 amount) external nonReentrant {
        require(outcome == Outcome.UNRESOLVED,     "market closed");
        require(block.timestamp < resolutionTime,  "market expired");
        require(amount > 0,                        "zero amount");

        USDC.safeTransferFrom(msg.sender, address(this), amount);

        // ─── Checks-Effects-Interactions: update state before external calls ───
        if (yes) {
            yesBets[msg.sender] += amount;
            yesPool             += amount;
        } else {
            noBets[msg.sender]  += amount;
            noPool              += amount;
        }

        // ───────────────── FLOAT ─────────────────
        // Park only (1 - RESERVE_BPS) of the deposit. The reserve stays
        // liquid in this contract as a safety buffer against any NAV
        // underperformance from the parked share.
        // Note: for CEI compliance, accounting is updated above before this block.
        uint256 parkAmount    = (amount * (BPS_DENOM - RESERVE_BPS)) / BPS_DENOM;
        uint256 reserveAmount = amount - parkAmount;

        if (parkAmount > 0) {
            USDC.forceApprove(address(FLOAT_VAULT), parkAmount);
            FLOAT_VAULT.park(parkAmount);
        }
        emit Bet(msg.sender, yes, amount, parkAmount, reserveAmount);
        // ─────────────────────────────────────────
    }

    /* ──────────────────────────────────────────────────────────────
       resolve — owner sets the outcome and recalls everything
       ──────────────────────────────────────────────────────────────
       Guards against three failure modes:
         · single-sided pool with wrong resolution  → auto-CANCEL
         · vault.withdraw() reverts                  → continue with whatever's liquid
         · liquid < principal owed                   → SHORTFALL mode
       ────────────────────────────────────────────────────────────── */

    function resolve(Outcome _outcome) external nonReentrant {
        require(msg.sender == owner,               "not owner");
        require(outcome == Outcome.UNRESOLVED,     "already resolved");
        require(
            _outcome == Outcome.YES ||
            _outcome == Outcome.NO  ||
            _outcome == Outcome.CANCELLED,
            "invalid outcome"
        );

        // CANCELLED can be called any time (event invalidated, market disputed).
        // YES / NO require the resolution window to have elapsed.
        if (_outcome != Outcome.CANCELLED) {
            require(block.timestamp >= resolutionTime, "too early");
        }

        // ───────────────── FLOAT ─────────────────
        // Recall everything before claims open. Wrapped in try/catch so a
        // transient vault failure (paused, insolvent, etc.) can't lock the
        // market. Whatever USDC is already liquid stays claimable.
        uint256 parked;
        try FLOAT_VAULT.deposits(address(this)) returns (uint256 _parked) {
            parked = _parked;
        } catch {
            parked = 0;
        }

        if (parked > 0) {
            try FLOAT_VAULT.withdraw(parked) {
                // success — funds are back in the contract
            } catch Error(string memory reason) {
                emit VaultRecallFailed(reason);
            } catch {
                emit VaultRecallFailed("unknown");
            }
        }
        // ─────────────────────────────────────────

        uint256 liquid    = USDC.balanceOf(address(this));
        uint256 principal = yesPool + noPool;

        // Single-sided market protection: if the chosen winning side has
        // zero stake, force CANCELLED so the other side can refund.
        Outcome chosen = _outcome;
        if (chosen == Outcome.YES && yesPool == 0) chosen = Outcome.CANCELLED;
        if (chosen == Outcome.NO  && noPool  == 0) chosen = Outcome.CANCELLED;

        // Shortfall trumps everything: if we can't cover the principal,
        // even CANCELLED falls into pro-rata refund mode.
        bool shortfall = liquid < principal;
        outcome = shortfall ? Outcome.SHORTFALL : chosen;
        recoveredAtResolve = liquid;

        emit Resolved(outcome, parked, liquid, shortfall);
    }

    /* ──────────────────────────────────────────────────────────────
       claim — winners pull their share. Shortfall-safe.
       ────────────────────────────────────────────────────────────── */

    function claim() external nonReentrant {
        require(outcome != Outcome.UNRESOLVED, "not resolved");
        require(!claimed[msg.sender],          "already claimed");

        uint256 payout;
        uint256 myStake = yesBets[msg.sender] + noBets[msg.sender];
        require(myStake > 0, "no stake in this market");

        if (outcome == Outcome.CANCELLED) {
            // Full refund of original stake. Pays from liquid USDC.
            payout = myStake;
        } else if (outcome == Outcome.SHORTFALL) {
            // Pro-rata refund of what was actually recovered.
            // Every bettor gets the same haircut — no winners or losers,
            // just a proportional slice of what the vault returned.
            uint256 principal = yesPool + noPool;
            payout = (myStake * recoveredAtResolve) / principal;
        } else if (outcome == Outcome.YES) {
            // yesPool > 0 is guaranteed by the single-sided guard in resolve()
            require(yesBets[msg.sender] > 0, "no winning bet");
            payout = (yesBets[msg.sender] * (yesPool + noPool)) / yesPool;
        } else {
            // noPool > 0 is guaranteed by the single-sided guard in resolve()
            require(noBets[msg.sender] > 0, "no winning bet");
            payout = (noBets[msg.sender] * (yesPool + noPool)) / noPool;
        }

        require(payout > 0, "nothing to claim");
        claimed[msg.sender] = true;
        totalClaimed       += payout;

        USDC.safeTransfer(msg.sender, payout);
        emit Claimed(msg.sender, payout);
    }

    /* ──────────────────────────────────────────────────────────────
       skim — owner sweeps the yield (only above principal owed)
       ────────────────────────────────────────────────────────────── */

    function skim(address to) external nonReentrant {
        require(msg.sender == owner,                  "not owner");
        require(to != address(0),                     "zero address");
        require(outcome != Outcome.UNRESOLVED,        "not resolved yet");
        require(outcome != Outcome.SHORTFALL,         "shortfall - no yield to skim");

        // Skim only what's above the unclaimed liability still owed to bettors.
        // unclaimedLiability = original_principal - totalClaimed_so_far
        // skimmable = max(liquid - unclaimedLiability, 0)
        //
        // This formula correctly handles:
        //   · Yield accrual (FLOAT returns more than parked → skim picks up the excess)
        //   · Direct donations (extra USDC sent to contract → skim picks it up)
        //   · Partial claim states (only skim the surplus above what's still owed)
        //   · Parimutuel rounding dust (small amounts may linger until last claim)
        uint256 liquid    = USDC.balanceOf(address(this));
        uint256 principal = yesPool + noPool;
        uint256 unclaimed = principal > totalClaimed ? principal - totalClaimed : 0;

        uint256 skimmable = liquid > unclaimed ? liquid - unclaimed : 0;
        require(skimmable > 0, "nothing to skim");

        USDC.safeTransfer(to, skimmable);
        emit Skimmed(to, skimmable);
    }

    /* ──────────────────────────────────────────────────────────────
       Views
       ────────────────────────────────────────────────────────────── */

    function totalAssets() external view returns (uint256 liquid, uint256 parked) {
        liquid = USDC.balanceOf(address(this));
        parked = FLOAT_VAULT.deposits(address(this));
    }

    function position(address user) external view returns (uint256 yes, uint256 no) {
        yes = yesBets[user];
        no  = noBets[user];
    }
}
