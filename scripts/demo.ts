/**
 * End-to-end demo flow on Arc Testnet:
 *   1. Deploy a 2-minute prediction market
 *   2. Place a YES bet and a NO bet from the deployer wallet
 *   3. Show the parked / liquid split (FLOAT holds ~95%)
 *   4. Wait for resolution window, resolve YES
 *   5. Claim the winning payout
 *   6. Skim any accrued yield
 *
 * Requires the deployer wallet to hold at least 2 USDC on Arc Testnet.
 * Get testnet USDC from the Circle faucet: https://faucet.circle.com
 *
 * Run:
 *   npx hardhat run scripts/demo.ts --network arcTestnet
 */
import { ethers } from "hardhat";

const USDC_ADDRESS = "0x3600000000000000000000000000000000000000";
const ONE_USDC     = 1_000_000n;  // USDC has 6 decimals

// Minimal ERC20 ABI — avoids relying on the compiled IERC20 artifact
const ERC20_ABI = [
  "function approve(address spender, uint256 amount) returns (bool)",
  "function balanceOf(address account) view returns (uint256)",
  "function allowance(address owner, address spender) view returns (uint256)",
];

async function main() {
  const [user] = await ethers.getSigners();
  const userAddr = await user.getAddress();

  const balance = await ethers.provider.getBalance(userAddr);
  console.log(`Demo wallet: ${userAddr}`);
  console.log(`Gas balance: ${ethers.formatEther(balance)} ETH\n`);

  /* ─── 1. Deploy a market that resolves in 2 minutes ─── */
  const RESOLUTION_SECONDS = 120;
  const resolutionTime = Math.floor(Date.now() / 1000) + RESOLUTION_SECONDS;

  const Factory = await ethers.getContractFactory("PredictionMarket");
  const market  = await Factory.deploy("Will this demo succeed?", resolutionTime);
  await market.waitForDeployment();
  const marketAddr = await market.getAddress();

  console.log(`✅ Market deployed:  ${marketAddr}`);
  console.log(`   Resolves in:      ${RESOLUTION_SECONDS}s\n`);

  /* ─── 2. Approve USDC + place bets ─── */
  const usdc = new ethers.Contract(USDC_ADDRESS, ERC20_ABI, user);

  console.log("Approving 2 USDC to market…");
  await (await usdc.approve(marketAddr, ONE_USDC * 2n)).wait();

  console.log("Placing 1 USDC on YES…");
  await (await market.bet(true,  ONE_USDC)).wait();
  console.log("Placing 1 USDC on NO…\n");
  await (await market.bet(false, ONE_USDC)).wait();

  /* ─── 3. Show the parked / liquid split ─── */
  const [liquid, parked] = await market.totalAssets();
  console.log("Market holdings after bets:");
  console.log(`  Liquid in contract: ${formatUsdc(liquid)} USDC  (${RESERVE_PCT(liquid)}% reserve)`);
  console.log(`  Parked in FLOAT:    ${formatUsdc(parked)} USDC  (~95% earning USYC yield)\n`);

  /* ─── 4. Wait for resolution ─── */
  await countdown(RESOLUTION_SECONDS + 5);

  console.log("\nResolving market → YES…");
  await (await market.resolve(1)).wait();  // 1 = Outcome.YES

  /* ─── 5. Check for shortfall ─── */
  const [liquidAfter] = await market.totalAssets();
  const yesPool = await market.yesPool();
  const noPool  = await market.noPool();
  const principal = yesPool + noPool;
  if (liquidAfter < principal) {
    console.log(`⚠️  SHORTFALL detected: recovered ${formatUsdc(liquidAfter)} < ${formatUsdc(principal)} owed`);
    console.log("   Market switched to pro-rata refund mode.");
  } else {
    const yield_ = liquidAfter - principal;
    console.log(`✅ Resolved cleanly — ${formatUsdc(liquidAfter)} liquid`);
    if (yield_ > 0n) {
      console.log(`   Yield earned during lock: ${formatUsdc(yield_)} USDC`);
    }
  }

  /* ─── 6. Claim winnings ─── */
  console.log("\nClaiming…");
  const claimTx = await market.claim();
  const receipt  = await claimTx.wait();

  const claimedEvent = receipt?.logs
    .map((log) => {
      try {
        return market.interface.parseLog({
          topics: Array.from(log.topics),
          data: log.data,
        });
      } catch { return null; }
    })
    .find((parsed) => parsed?.name === "Claimed");

  if (claimedEvent) {
    console.log(`  → claimed ${formatUsdc(claimedEvent.args.amount as bigint)} USDC`);
  }

  /* ─── 7. Skim residual yield ─── */
  const residual = await usdc.balanceOf(marketAddr);
  if (residual > 0n) {
    console.log(`\nSkimming residual (${formatUsdc(residual)} USDC)…`);
    await (await market.skim(userAddr)).wait();
    console.log("✅ done");
  } else {
    console.log("\nNo yield to skim (2-minute window too short for measurable accrual).");
    console.log("On mainnet with real USYC, longer markets accumulate meaningful yield.");
  }
}

/* ─── Helpers ─── */

function formatUsdc(amount: bigint): string {
  return (Number(amount) / 1_000_000).toFixed(6);
}

function RESERVE_PCT(liquid: bigint): string {
  // liquid should be ~5% of 2 USDC = 0.1 USDC
  return ((Number(liquid) / 2_000_000) * 100).toFixed(1);
}

async function countdown(seconds: number): Promise<void> {
  process.stdout.write(`Waiting ${seconds}s for resolution window`);
  for (let i = 0; i < seconds; i++) {
    await new Promise((r) => setTimeout(r, 1000));
    if (i % 10 === 9) process.stdout.write(` ${seconds - i - 1}s`);
    else process.stdout.write(".");
  }
  process.stdout.write("\n");
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
