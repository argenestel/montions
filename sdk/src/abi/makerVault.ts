import { erc20BaseAbi } from "./erc20.js";

const vaultFunctions = [
  {
    type: "function",
    name: "deposit",
    stateMutability: "nonpayable",
    inputs: [
      { name: "assets", type: "uint256" },
      { name: "receiver", type: "address" },
    ],
    outputs: [{ name: "shares", type: "uint256" }],
  },
  {
    type: "function",
    name: "withdraw",
    stateMutability: "nonpayable",
    inputs: [
      { name: "assets", type: "uint256" },
      { name: "receiver", type: "address" },
      { name: "owner_", type: "address" },
    ],
    outputs: [{ name: "shares", type: "uint256" }],
  },
  { type: "function", name: "totalAssets", stateMutability: "view", inputs: [], outputs: [{ name: "", type: "uint256" }] },
  {
    type: "function",
    name: "refresh",
    stateMutability: "nonpayable",
    inputs: [{ name: "seriesId", type: "bytes32" }],
    outputs: [],
  },
] as const;

/**
 * MakerVault ABI (handwritten from SPEC §13): ERC20 shares (mmUSDC, 6 decimals) + deposit/withdraw/totalAssets/refresh.
 * Share<->asset conversion helpers are not in SPEC §13; derive the share price as totalAssets() / totalSupply().
 */
export const makerVaultAbi = [...erc20BaseAbi, ...vaultFunctions] as const;
