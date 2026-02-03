import { ethers } from 'hardhat';
import { expect } from 'chai';
import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers';
import { Asset } from '../typechain-types';

export async function deployToken(signer: SignerWithAddress): Promise<Asset> {
  const Token = await ethers.getContractFactory('Asset', signer);
  const token = await Token.deploy() as Asset;
  await token.waitForDeployment();
  return token;
}

export async function deployNFTCollection(name: string, symbol: string, signer: SignerWithAddress) {
  const NFT = await ethers.getContractFactory('TestNFT', signer);
  const nft = await NFT.deploy(name, symbol);
  await nft.waitForDeployment();
  return nft;
}

export const SECONDS_IN_DAY = 86400;
export const SECONDS_IN_WEEK = 7 * SECONDS_IN_DAY;
export const SECONDS_IN_MONTH = 30 * SECONDS_IN_DAY;

export function increaseTime(seconds: number) {
  return ethers.provider.send('evm_increaseTime', [seconds]);
}

export function mineBlock() {
  return ethers.provider.send('evm_mine', []);
}

export async function getTimestamp() {
  const block = await ethers.provider.getBlock('latest');
  return block!.timestamp;
}

export const ONE_ETH = ethers.parseEther('1');
export const ONE_TOKEN = ethers.parseEther('1');
export const TEN_TOKENS = ethers.parseEther('10');
export const HUNDRED_TOKENS = ethers.parseEther('100');
export const THOUSAND_TOKENS = ethers.parseEther('1000');

export const BASIS_POINTS = 10000;
export const ONE_PERCENT = BASIS_POINTS / 100; // 100
export const FIVE_PERCENT = 5 * ONE_PERCENT; // 500
export const TEN_PERCENT = 10 * ONE_PERCENT; // 1000

export const MIN_LOCK_DURATION = SECONDS_IN_WEEK;
export const MAX_LOCK_DURATION = 52 * SECONDS_IN_WEEK;
export const MIN_LOCK_AMOUNT = ethers.parseEther('1000');
export const MAX_NFTS_PER_USER = 50;
