// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

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
///   shortfall with three layers:
///
///   1. RESERVE_BPS — fraction of every deposit NEVER parked. Acts as a
///      buffer against any underperformance from the parked share.
///   2. resolve() recalls before claims open — single onchain instruction.
///   3. claim() detects shortfall (liquid < principal owed) and falls back
///      to pro-rata refund of what was recovered. Winners never extract a
///      payout from a depleted pot at the expense of underfunded losers.
contract PredictionMarket {
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

    uint256 public yesPool;          // total principal staked on YES
    uint256 public noPool;           // total principal staked on NO
    uint256 public recoveredAtResolve;  // liquid USDC the contract had right after resolve()

    mapping(address => uint256) public yesBets;
    mapping(address => uint256) public noBets;
    mapping(address => bool)    public claimed;

    /* ──────────────────────────────────────────────────────────────
       Events
       ────────────────────────────────────────────────────────────── */

    event Bet      (address indexed user, bool yes, uint256 amount, uint256 parked, uint256 reserved);
    event Resolved (Outcome outcome, uint256 recalled, uint256 totalLiquid, bool shortfall);
    event Claimed  (address indexed user, uint256 amount);
    event Skimmed  (address indexed to, uint256 yieldAmount);

    /* ──────────────────────────────────────────────────────────────
       Constructor
       ────────────────────────────────────────────────────────────── */

    constructor(string memory _question, uint256 _resolutionTime) {
        require(_resolutionTime > block.timestamp, "resolutionTime in the past");
        question       = _question;
        resolutionTime = _resolutionTime;
        owner          = msg.sender;
        outcome        = Outcome.UNRESOLVED;
    }

    /* ──────────────────────────────────────────────────────────────
       bet — user takes a YES or NO position
       ────────────────────────────────────────────────────────────── */

    function bet(bool yes, uint256 amount) external {
        require(outcome == Outcome.UNRESOLVED,     "market closed");
        require(block.timestamp < resolutionTime,  "market expired");
        require(amount > 0,                        "zero amount");

        USDC.safeTransferFrom(msg.sender, address(this), amount);

        // ───────────────── FLOAT ─────────────────
        // Park only (1 - RESERVE_BPS) of the deposit. The reserve stays
        // liquid as a safety buffer against any NAV underperformance.
        uint256 parkAmount    = (amount * (BPS_DENOM - RESERVE_BPS)) / BPS_DENOM;
        uint256 reserveAmount = amount - parkAmount;

        if (parkAmount > 0) {
            USDC.forceApprove(address(FLOAT_VAULT), parkAmount);
            FLOAT_VAULT.park(parkAmount);
        }
        emit Bet(msg.sender, yes, amount, parkAmount, reserveAmount);
        // ─────────────────────────────────────────

        if (yes) {
            yesBets[msg.sender] += amount;
            yesPool             += amount;
        } else {
            noBets[msg.sender]  += amount;
            noPool              += amount;
        }
    }

    /* ──────────────────────────────────────────────────────────────
       resolve — owner sets the outcome and recalls everything
       ────────────────────────────────────────────────────────────── */

    function resolve(Outcome _outcome) external {
        require(msg.sender == owner,               "not owner");
        require(outcome == Outcome.UNRESOLVED,     "already resolved");
        require(
            _outcome == Outcome.YES ||
            _outcome == Outcome.NO  ||
            _outcome == Outcome.CANCELLED,
            "invalid outcome"
        );
        require(block.timestamp >= resolutionTime, "too early");

        // ───────────────── FLOAT ─────────────────
        // Recall everything before claims open. <5s on Arc.
        // Use vault.deposits() as source of truth — never a cached value.
        uint256 parked = FLOAT_VAULT.deposits(address(this));
        if (parked > 0) {
            FLOAT_VAULT.withdraw(parked);
        }
        // ─────────────────────────────────────────

        uint256 liquid    = USDC.balanceOf(address(this));
        uint256 principal = yesPool + noPool;
        bool    shortfall = liquid < principal;

        // If we somehow recovered less than the principal owed (NAV decline,
        // vault loss, anything), force the market into SHORTFALL mode.
        // Winners can't drain a depleted pot — everyone gets pro-rata.
        outcome             = shortfall ? Outcome.SHORTFALL : _outcome;
        recoveredAtResolve  = liquid;

        emit Resolved(outcome, parked, liquid, shortfall);
    }

    /* ──────────────────────────────────────────────────────────────
       claim — winners pull their share. Shortfall-safe.
       ────────────────────────────────────────────────────────────── */

    function claim() external {
        require(outcome != Outcome.UNRESOLVED, "not resolved");
        require(!claimed[msg.sender],          "already claimed");

        uint256 payout;
        uint256 myStake = yesBets[msg.sender] + noBets[msg.sender];

        if (outcome == Outcome.CANCELLED) {
            payout = myStake;
        } else if (outcome == Outcome.SHORTFALL) {
            // Pro-rata refund of what was actually recovered.
            // Every bettor gets the same haircut, no winners/losers.
            uint256 principal = yesPool + noPool;
            require(principal > 0, "no principal");
            payout = (myStake * recoveredAtResolve) / principal;
        } else if (outcome == Outcome.YES) {
            require(yesBets[msg.sender] > 0, "no winning bet");
            payout = (yesBets[msg.sender] * (yesPool + noPool)) / yesPool;
        } else {
            require(noBets[msg.sender] > 0, "no winning bet");
            payout = (noBets[msg.sender] * (yesPool + noPool)) / noPool;
        }

        require(payout > 0, "nothing to claim");
        claimed[msg.sender] = true;

        USDC.safeTransfer(msg.sender, payout);
        emit Claimed(msg.sender, payout);
    }

    /* ──────────────────────────────────────────────────────────────
       skim — owner sweeps the yield (only above principal owed)
       ────────────────────────────────────────────────────────────── */

    function skim(address to) external {
        require(msg.sender == owner,                  "not owner");
        require(outcome != Outcome.UNRESOLVED,        "not resolved yet");
        require(outcome != Outcome.SHORTFALL,         "shortfall — no yield to skim");

        uint256 liquid    = USDC.balanceOf(address(this));
        uint256 principal = yesPool + noPool;

        // Skim only what's above the principal-still-owed-to-bettors.
        uint256 skimmable = liquid > principal ? liquid - principal : 0;
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
