/**
 * Deploys a single PredictionMarket contract to Arc Testnet.
 *
 * Edit the QUESTION + RESOLUTION_HOURS constants below before running.
 *
 * Run:
 *   npx hardhat run scripts/deploy.ts --network arcTestnet
 */
import { ethers } from "hardhat";

const QUESTION          = "Will BTC close above $100k on Dec 31, 2026?";
const RESOLUTION_HOURS  = 72;   // resolution window from deploy time

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log(`Deployer: ${await deployer.getAddress()}`);
  console.log(`Network:  ${(await ethers.provider.getNetwork()).chainId}`);

  const resolutionTime = Math.floor(Date.now() / 1000) + (RESOLUTION_HOURS * 3600);

  const Factory = await ethers.getContractFactory("PredictionMarket");
  const market  = await Factory.deploy(QUESTION, resolutionTime);
  await market.waitForDeployment();

  const address = await market.getAddress();
  console.log("");
  console.log(`✅ PredictionMarket deployed at: ${address}`);
  console.log(`   Question:        ${QUESTION}`);
  console.log(`   Resolves at:     ${new Date(resolutionTime * 1000).toISOString()}`);
  console.log(`   Reserve buffer:  5% (RESERVE_BPS = 500)`);
  console.log("");
  console.log("Next steps:");
  console.log(`  1. Verify on Arc explorer: https://explorer.testnet.arc.network/address/${address}`);
  console.log(`  2. Approve USDC and call bet(true, amount) to place your first stake`);
  console.log(`  3. After resolutionTime passes, call resolve(Outcome.YES | NO | CANCELLED)`);
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
