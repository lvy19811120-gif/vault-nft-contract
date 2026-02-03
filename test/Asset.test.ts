import { expect } from 'chai';
import { ethers } from 'hardhat';
import { Asset } from '../typechain-types';
import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers';
import { ONE_TOKEN, TEN_TOKENS, HUNDRED_TOKENS, THOUSAND_TOKENS, FIVE_PERCENT } from './utils/helpers';

describe('Asset Token', () => {
  let asset: Asset;
  let owner: SignerWithAddress;
  let user1: SignerWithAddress;
  let user2: SignerWithAddress;

  beforeEach(async () => {
    [owner, user1, user2] = await ethers.getSigners();
    const Asset = await ethers.getContractFactory('Asset', owner);
    asset = await Asset.deploy() as Asset;
    await asset.waitForDeployment();
  });

  describe('Deployment', () => {
    it('Should set the correct name and symbol', async () => {
      expect(await asset.name()).to.equal('Lock Token');
      expect(await asset.symbol()).to.equal('LOCK');
    });

    it('Should mint initial supply to owner', async () => {
      const ownerBalance = await asset.balanceOf(owner.address);
      const expectedBalance = ethers.parseEther('1000000000');
      expect(ownerBalance).to.equal(expectedBalance);
    });

    it('Should set the correct owner', async () => {
      expect(await asset.owner()).to.equal(owner.address);
    });
  });

  describe('Minting', () => {
    it('Should allow owner to mint tokens', async () => {
      await asset.mint(user1.address, HUNDRED_TOKENS);
      const balance = await asset.balanceOf(user1.address);
      expect(balance).to.equal(HUNDRED_TOKENS);
    });

    it('Should mint to multiple addresses', async () => {
      await asset.mint(user1.address, HUNDRED_TOKENS);
      await asset.mint(user2.address, THOUSAND_TOKENS);

      expect(await asset.balanceOf(user1.address)).to.equal(HUNDRED_TOKENS);
      expect(await asset.balanceOf(user2.address)).to.equal(THOUSAND_TOKENS);
    });

    it('Should update total supply after minting', async () => {
      const initialSupply = await asset.totalSupply();
      const mintAmount = HUNDRED_TOKENS;
      await asset.mint(user1.address, mintAmount);

      const newSupply = await asset.totalSupply();
      expect(newSupply).to.equal(initialSupply + mintAmount);
    });

    it('Should fail if non-owner tries to mint', async () => {
      await expect(
        asset.connect(user1).mint(user2.address, ONE_TOKEN)
      ).to.be.revertedWithCustomError(asset, 'OwnableUnauthorizedAccount');
    });

    it('Should emit Transfer event on mint', async () => {
      await expect(asset.mint(user1.address, HUNDRED_TOKENS))
        .to.emit(asset, 'Transfer')
        .withArgs(ethers.ZeroAddress, user1.address, HUNDRED_TOKENS);
    });
  });

  describe('Transfer', () => {
    beforeEach(async () => {
      await asset.mint(user1.address, HUNDRED_TOKENS);
    });

    it('Should transfer tokens between accounts', async () => {
      await asset.connect(user1).transfer(user2.address, ONE_TOKEN);
      expect(await asset.balanceOf(user2.address)).to.equal(ONE_TOKEN);
      expect(await asset.balanceOf(user1.address)).to.equal(HUNDRED_TOKENS - ONE_TOKEN);
    });

    it('Should fail if sender has insufficient balance', async () => {
      await expect(
        asset.connect(user1).transfer(user2.address, HUNDRED_TOKENS + ONE_TOKEN)
      ).to.be.revertedWithCustomError(asset, 'ERC20InsufficientBalance');
    });

    it('Should fail if transferring to zero address', async () => {
      await expect(
        asset.connect(user1).transfer(ethers.ZeroAddress, ONE_TOKEN)
      ).to.be.revertedWithCustomError(asset, 'ERC20InvalidReceiver');
    });

    it('Should emit Transfer event', async () => {
      await expect(asset.connect(user1).transfer(user2.address, ONE_TOKEN))
        .to.emit(asset, 'Transfer')
        .withArgs(user1.address, user2.address, ONE_TOKEN);
    });
  });

  describe('Allowance', () => {
    beforeEach(async () => {
      await asset.mint(user1.address, HUNDRED_TOKENS);
    });

    it('Should approve and use allowance', async () => {
      await asset.connect(user1).approve(user2.address, TEN_TOKENS);
      const allowance = await asset.allowance(user1.address, user2.address);
      expect(allowance).to.equal(TEN_TOKENS);

      await asset.connect(user2).transferFrom(user1.address, user2.address, ONE_TOKEN);
      const newAllowance = await asset.allowance(user1.address, user2.address);
      expect(newAllowance).to.equal(TEN_TOKENS - ONE_TOKEN);
    });
  });
});
