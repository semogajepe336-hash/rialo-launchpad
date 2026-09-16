import FairLaunchAbi from "../abi/FairLaunch.json";
import TokenPoolAbi from "../abi/TokenPool.json";
import Erc20Abi from "../abi/ERC20.json";

export const ADDRESSES = {
  fairlaunch: "0xb042C7a5aB6D54F54d02ee5bDE33a63CA20C08CC",
  token: "0xB9dd17e7dcF276A59beF445b1Aa4B9844A82243D",
  quote: "0xC71FbaF27A861624F9695F9BEF12f3Ea58FbF68A",
  ownerWallet: "0x054B4108614cd044D99e8706F6286a3a70fe978c",
};

export const ABIS = {
  fairlaunch: FairLaunchAbi,
  tokenPool: TokenPoolAbi,
  erc20: Erc20Abi,
};

export const CHAIN_NAME = "Sepolia";
export const SEPOLIA_CHAIN_ID = 11155111;

// Public fallback RPCs used for read-only state. The wallet still uses its own
// injected provider for sends; this list is only for the read panel.
export const FALLBACK_RPCS = [
  "https://ethereum-sepolia-rpc.publicnode.com",
  "https://1rpc.io/sepolia",
  "https://rpc.sepolia.org",
  "https://sepolia.gateway.tenderly.co",
];
