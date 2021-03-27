import "@nomiclabs/hardhat-waffle";
import { HardhatUserConfig } from "hardhat/config";
import "solidity-coverage";
import "hardhat-typechain";

const config: HardhatUserConfig = {
  solidity: {
    version: "0.6.6",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200
      }
    }
  },
  networks: {
    hardhat: {
      forking: {
        url: "https://eth-mainnet.alchemyapi.io/v2/aBCsijxZ8P5AtVofO-IDv83xhao-63S0",
        blockNumber: 12051125
      }
    }
  },
  mocha: {
    timeout: 60000
  }
};

export default config;