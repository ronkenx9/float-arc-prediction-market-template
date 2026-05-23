/**
 * End-to-end demo flow on Arc Testnet:
 *   1. Deploy a 2-minute prediction market
 *   2. Place a YES bet and a NO bet from the deployer
 *   3. Show the parked/liquid split (FLOAT is holding ~95%)
 *   4. Fast-forward, resolve YES
 *   5. Claim the winning payout
 *   6. Skim any accrued yield
 *
 * Requires the deployer wallet to hold at least 2 USDC on Arc Testnet.
 *
 * Run:
 *   npx hardhat run scripts/demo.ts --network arcTestnet
 */
import { ethers } from "hardhat";

const USDC_ADDRESS = "0x3600000000000000000000000000000000000000";
const ONE_USDC     = 1_000_000n;  // USDC is 6 decimals

async function main() {
  const [user] = await ethers.getSigners();
  const userAddr = await user.getAddress();
  console.log(`Demo wallet: ${userAddr}\n`);

  /* ─── 1. Deploy a market that resolves in 2 minutes ─── */
  const resolutionTime = Math.floor(Date.now() / 1000) + 120;
  const Factory = await ethers.getContractFactory("PredictionMarket");
  const market  = await Factory.deploy("Will this demo succeed?", resolutionTime);
  await market.waitForDeployment();
  const marketAddr = await market.getAddress();
  console.log(`✅ Market deployed: ${marketAddr}`);
  console.log(`   resolves in 2 minutes\n`);

  /* ─── 2. Approve USDC + place bets ─── */
  const usdc = await ethers.getContractAt("IERC20", USDC_ADDRESS);
  console.log("Approving 2 USDC to market…");
  await (await usdc.approve(marketAddr, ONE_USDC * 2n)).wait();

  console.log("Placing 1 USDC on YES…");
  await (await market.bet(true,  ONE_USDC)).wait();
  console.log("Placing 1 USDC on NO…");
  await (await market.bet(false, ONE_USDC)).wait();

  /* ─── 3. Show the parked/liquid split ─── */
  const [liquid, parked] = await market.totalAssets();
  console.log(`\nMarket holdings after bets:`);
  console.log(`  Liquid in contract: ${formatUsdc(liquid)} USDC`);
  console.log(`  Parked in FLOAT:    ${formatUsdc(parked)} USDC`);
  console.log(`  → ~95% earning USYC yield, ~5% liquid reserve\n`);

  /* ─── 4. Wait for resolution + resolve YES ─── */
  console.log("Waiting for resolution time…");
  await sleep(125_000);

  console.log("Resolving YES…");
  await (await market.resolve(1)).wait();  // 1 = Outcome.YES

  /* ─── 5. Claim ─── */
  console.log("Claiming winnings…");
  const tx = await market.claim();
  const receipt = await tx.wait();

  const claimedEvent = receipt?.logs
    .map((log) => { try { return market.interface.parseLog(log); } catch { return null; } })
    .find((parsed) => parsed?.name === "Claimed");

  if (claimedEvent) {
    console.log(`  → claimed ${formatUsdc(claimedEvent.args.amount)} USDC\n`);
  }

  /* ─── 6. Skim accrued yield (if any) ─── */
  const finalLiquid = await usdc.balanceOf(marketAddr);
  if (finalLiquid > 0n) {
    console.log(`Skimming residual yield (${formatUsdc(finalLiquid)} USDC)…`);
    await (await market.skim(userAddr)).wait();
    console.log("✅ done\n");
  } else {
    console.log("No yield to skim (demo period too short for measurable accrual).\n");
  }
}

function formatUsdc(amount: bigint): string {
  return (Number(amount) / 1_000_000).toFixed(6);
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
