/* eslint-disable camelcase */
import { ethers, run, network } from "hardhat";
import { configs } from "@pancakeswap/common/config";
import { tryVerify } from "@pancakeswap/common/verify";
import { writeFileSync } from "fs";

async function main() {
  // Get network data from Hardhat config (see hardhat.config.ts).
  const networkName = network.name;
  // Check if the network is supported.
  console.log(`Deploying to ${networkName} network...`);

  // Compile contracts.
  await run("compile");
  console.log("Compiled contracts...");

  const config = configs[networkName as keyof typeof configs];
  if (!config) {
    throw new Error(`No config found for network ${networkName}`);
  }

  const v3PeripheryDeployedContracts = await import(`@pancakeswap/v3-periphery/deployments/${networkName}.json`);
  const positionManager_address = v3PeripheryDeployedContracts.NonfungiblePositionManager;

  const MasterChefV3 = await ethers.getContractFactory("AMMStake");
  const masterChefV3 = await MasterChefV3.deploy('0x5172F91AaB93446580c12853667c8827EAeBfa56', '0xa5d1a07031c15c928c6c425f9de447ebf54ccede', '0xc5f15624b4256c1206e4bb93f2ccc9163a75b703');

  console.log("masterChefV3 deployed to:", masterChefV3.address);
  // await tryVerify(masterChefV3, [config.cake, positionManager_address]);

  // Write the address to a file.
  // writeFileSync(
  //   `./deployments/${networkName}.json`,
  //   JSON.stringify(
  //     {
  //       MasterChefV3: masterChefV3.address,
  //     },
  //     null,
  //     2
  //   )
  // );
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
