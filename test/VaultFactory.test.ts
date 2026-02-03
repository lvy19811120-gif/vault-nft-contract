import { expect } from 'chai';
import { ethers } from 'hardhat';
import { VaultFactory, VaultDeployer, Asset } from '../typechain-types';
import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers';
import { ONE_ETH, FIVE_PERCENT, TEN_PERCENT, ONE_PERCENT, HUNDRED_TOKENS, MIN_LOCK_AMOUNT } from './utils/helpers';

describe('VaultFactory', () => {
  let factory: VaultFactory;
  let deployer: VaultDeployer;
  let asset: Asset;
  let owner: SignerWithAddress;
  let partner: SignerWithAddress;
  let user: SignerWithAddress;
  let vaultAdmin: SignerWithAddress;
  let feeBeneficiary: SignerWithAddress;

  beforeEach(async () => {
    [owner, partner, user, vaultAdmin, feeBeneficiary] = await ethers.getSigners();

    // Deploy Asset token
    const Asset = await ethers.getContractFactory('Asset', owner);
    asset = await Asset.deploy() as Asset;
    await asset.waitForDeployment();

    // Deploy VaultFactory first
    const VaultFactory = await ethers.getContractFactory('VaultFactory', owner);
    factory = await VaultFactory.deploy(
      owner.address,
      ethers.ZeroAddress,
      owner.address
    ) as VaultFactory;
    await factory.waitForDeployment();

    // Deploy VaultDeployer with factory as owner
    const VaultDeployer = await ethers.getContractFactory('VaultDeployer', owner);
    deployer = await VaultDeployer.deploy(await factory.getAddress()) as VaultDeployer;
    await deployer.waitForDeployment();

    // Set deployer and implementation
    const VaultImplementation = await ethers.getContractFactory('Vault', owner);
    const vaultImpl = await VaultImplementation.deploy();
    await vaultImpl.waitForDeployment();

    await factory.setVaultDeployer(await deployer.getAddress());
    await factory.setVaultImplementation(await vaultImpl.getAddress());

    // Approve partner
    await factory.setPartnerApproval(partner.address, true);
  });

  describe('Deployment', () => {
    it('Should set correct owner', async () => {
      expect(await factory.owner()).to.equal(owner.address);
    });

    it('Should set correct fee beneficiary', async () => {
      expect(await factory.mainFeeBeneficiary()).to.equal(owner.address);
    });

    it('Should have partner whitelist active by default', async () => {
      expect(await factory.partnerWhitelistActive()).to.equal(true);
    });

    it('Should approve owner as partner', async () => {
      expect(await factory.approvedPartners(owner.address)).to.equal(true);
    });

    it('Should initialize tier configs', async () => {
      const tier0 = await factory.tierConfigs(0);
      expect(tier0.deploymentFee).to.equal(0);
      expect(tier0.performanceFeeRate).to.equal(1000); // 10%

      const tier1 = await factory.tierConfigs(1);
      expect(tier1.deploymentFee).to.equal(ethers.parseEther('0.1'));
      expect(tier1.performanceFeeRate).to.equal(500); // 5%

      const tier2 = await factory.tierConfigs(2);
      expect(tier2.deploymentFee).to.equal(ethers.parseEther('2'));
      expect(tier2.performanceFeeRate).to.equal(150); // 1.5%
    });
  });

  describe('Create Vault', () => {
    it('Should create vault with correct parameters', async () => {
      const tx = await factory.connect(partner).createVault(
        await asset.getAddress(),
        500, // 5% deposit fee
        vaultAdmin.address,
        feeBeneficiary.address,
        'test-metadata',
        1, // SPLIT_THE_SPOILS
        { value: ethers.parseEther('0.1') }
      );

      const receipt = await tx.wait();
      const event = receipt?.logs.find((log: any) => {
        try {
          const parsed = factory.interface.parseLog(log);
          return parsed?.name === 'VaultCreated';
        } catch {
          return false;
        }
      });
      const vaultAddress = event ? factory.interface.parseLog(event!).args[1] : ethers.ZeroAddress;

      expect(vaultAddress).to.not.equal(ethers.ZeroAddress);
    });

    it('Should require partner approval when whitelist is active', async () => {
      await expect(
        factory.connect(user).createVault(
          await asset.getAddress(),
          500,
          vaultAdmin.address,
          feeBeneficiary.address,
          'test-metadata',
          1
        )
      ).to.be.revertedWith('V.F.1');
    });

    it('Should allow creating vault when whitelist is disabled', async () => {
      await factory.setPartnerWhitelistActive(false);

      await expect(
        factory.connect(user).createVault(
          await asset.getAddress(),
          500,
          vaultAdmin.address,
          feeBeneficiary.address,
          'test-metadata',
          0
        )
      ).not.to.be.reverted;
    });

    it('Should reject invalid token address', async () => {
      await expect(
        factory.connect(partner).createVault(
          ethers.ZeroAddress,
          500,
          vaultAdmin.address,
          feeBeneficiary.address,
          'test-metadata',
          0
        )
      ).to.be.revertedWith('V.F.2');
    });

    it('Should reject invalid admin address', async () => {
      await expect(
        factory.connect(partner).createVault(
          await asset.getAddress(),
          500,
          ethers.ZeroAddress,
          feeBeneficiary.address,
          'test-metadata',
          0
        )
      ).to.be.revertedWith('V.F.2');
    });

    it('Should reject invalid fee beneficiary address', async () => {
      await expect(
        factory.connect(partner).createVault(
          await asset.getAddress(),
          500,
          vaultAdmin.address,
          ethers.ZeroAddress,
          'test-metadata',
          0
        )
      ).to.be.revertedWith('V.F.2');
    });



    it('Should require correct deployment fee for tier', async () => {
      await expect(
        factory.connect(partner).createVault(
          await asset.getAddress(),
          500,
          vaultAdmin.address,
          feeBeneficiary.address,
          'test-metadata',
          2 // VAULTMASTER_3000
        )
      ).to.be.revertedWith('V.F.5');
    });

    it('Should accept correct deployment fee for VAULTMASTER_3000', async () => {
      const tx = await factory.connect(partner).createVault(
        await asset.getAddress(),
        500,
        vaultAdmin.address,
        feeBeneficiary.address,
        'test-metadata',
        2,
        { value: ethers.parseEther('2') }
      );

      const receipt = await tx.wait();
      const event = receipt?.logs.find((log: any) => {
        try {
          const parsed = factory.interface.parseLog(log);
          return parsed?.name === 'VaultCreated';
        } catch {
          return false;
        }
      });
      const vaultAddress = event ? factory.interface.parseLog(event!).args[1] : ethers.ZeroAddress;

      expect(vaultAddress).to.not.equal(ethers.ZeroAddress);
    });

    it('Should reject deposit fee outside tier range', async () => {
      // Tier 0 (NO_RISK_NO_CROWN) has fixed 5% fee
      await expect(
        factory.connect(partner).createVault(
          await asset.getAddress(),
          1000, // 10%
          vaultAdmin.address,
          feeBeneficiary.address,
          'test-metadata',
          0
        )
      ).to.be.revertedWith('V.F.6');
    });

    it('Should track deployed vaults', async () => {
      const countBefore = await factory.getDeployedVaultsCount();

      const tx = await factory.connect(partner).createVault(
        await asset.getAddress(),
        500,
        vaultAdmin.address,
        feeBeneficiary.address,
        'test-metadata-1',
        0
      );
      await tx.wait();

      const countAfter = await factory.getDeployedVaultsCount();
      expect(countAfter).to.equal(countBefore + 1n);
    });

    it('Should emit VaultCreated event', async () => {
      const tx = await factory.connect(partner).createVault(
        await asset.getAddress(),
        500,
        vaultAdmin.address,
        feeBeneficiary.address,
        'test-metadata',
        0
      );

      await expect(tx).to.emit(factory, 'VaultCreated');
    });

    it('Should refund excess deployment fee', async () => {
      const balanceBefore = await ethers.provider.getBalance(partner.address);

      const tx = await factory.connect(partner).createVault(
        await asset.getAddress(),
        500,
        vaultAdmin.address,
        feeBeneficiary.address,
        'test-metadata',
        1,
        { value: ethers.parseEther('1') }
      );
      await tx.wait();

      const balanceAfter = await ethers.provider.getBalance(partner.address);
      const diff = balanceBefore - balanceAfter;
      expect(diff).to.be.lessThan(ethers.parseEther('0.2')); // Should be approx 0.1 ETH
    });
  });

  describe('Upgrade Vault Tier', () => {
    let vaultAddress: string;

    beforeEach(async () => {
      const tx = await factory.connect(partner).createVault(
        await asset.getAddress(),
        500,
        vaultAdmin.address,
        feeBeneficiary.address,
        'test-metadata',
        1,
        { value: ethers.parseEther('0.1') }
      );
      const receipt = await tx.wait();
      const event = receipt?.logs.find((log: any) => {
        try {
          const parsed = factory.interface.parseLog(log);
          return parsed?.name === 'VaultCreated';
        } catch {
          return false;
        }
      });
      vaultAddress = event ? factory.interface.parseLog(event!).args[1] : ethers.ZeroAddress;
    });

    it('Should upgrade vault to higher tier', async () => {
      const initialTier = await factory.getVaultTier(vaultAddress);
      expect(initialTier).to.equal(1);

      const upgradeCost = await factory.getTierUpgradeCost(vaultAddress, 2);
      expect(upgradeCost).to.equal(ethers.parseEther('1.9'));

      await factory.connect(vaultAdmin).upgradeVaultTier(vaultAddress, 2, {
        value: upgradeCost
      });

      const newTier = await factory.getVaultTier(vaultAddress);
      expect(newTier).to.equal(2);
    });

    it('Should require vault admin to upgrade', async () => {
      await expect(
        factory.connect(user).upgradeVaultTier(vaultAddress, 2, {
          value: ethers.parseEther('1.9')
        })
      ).to.be.revertedWith('V.F.8');
    });

    it('Should require higher tier', async () => {
      await expect(
        factory.connect(vaultAdmin).upgradeVaultTier(vaultAddress, 1, {
          value: 0
        })
      ).to.be.revertedWith('V.F.9');
    });

    it('Should require sufficient upgrade fee', async () => {
      await expect(
        factory.connect(vaultAdmin).upgradeVaultTier(vaultAddress, 2, {
          value: ethers.parseEther('1')
        })
      ).to.be.revertedWith('V.F.10');
    });

    it('Should emit VaultTierUpgraded event', async () => {
      const upgradeCost = await factory.getTierUpgradeCost(vaultAddress, 2);

      await expect(
        factory.connect(vaultAdmin).upgradeVaultTier(vaultAddress, 2, {
          value: upgradeCost
        })
      ).to.emit(factory, 'VaultTierUpgraded');
    });
  });

  describe('Fee Calculations', () => {
    it('Should calculate performance fee correctly', async () => {
      const fee = await factory.calculatePerformanceFee(
        ethers.ZeroAddress,
        HUNDRED_TOKENS
      );
      expect(fee).to.equal(HUNDRED_TOKENS / 10n); // 10% for tier 0
    });

    it('Should calculate deposit fee sharing correctly', async () => {
      const [platformShare, adminShare] = await factory.calculateDepositFeeSharing(
        ethers.ZeroAddress,
        HUNDRED_TOKENS
      );
      expect(platformShare).to.equal(HUNDRED_TOKENS / 2n); // 50%
      expect(adminShare).to.equal(HUNDRED_TOKENS / 2n);
    });
  });

  describe('Admin Functions', () => {
    it('Should allow owner to update tier config', async () => {
      await expect(
        factory.updateTierConfig(
          1,
          ethers.parseEther('0.2'),
          300, // 3%
          200, // 2%
          800, // 8%
          6000, // 60%
          true,
          'Updated Tier'
        )
      ).to.emit(factory, 'TierConfigUpdated');
    });

    it('Should reject invalid performance fee', async () => {
      await expect(
        factory.updateTierConfig(
          1,
          ethers.parseEther('0.2'),
          2500, // 25% - too high
          200,
          800,
          6000,
          true,
          'Test'
        )
      ).to.be.revertedWith('V.F.11');
    });

    it('Should reject invalid max deposit fee', async () => {
      await expect(
        factory.updateTierConfig(
          1,
          ethers.parseEther('0.2'),
          300,
          200,
          1200, // 12% - too high
          6000,
          true,
          'Test'
        )
      ).to.be.revertedWith('V.F.12');
    });

    it('Should reject min fee greater than max fee', async () => {
      await expect(
        factory.updateTierConfig(
          1,
          ethers.parseEther('0.2'),
          300,
          1000, // min > max
          200,
          6000,
          true,
          'Test'
        )
      ).to.be.revertedWith('V.F.13');
    });

    it('Should reject invalid platform share', async () => {
      await expect(
        factory.updateTierConfig(
          1,
          ethers.parseEther('0.2'),
          300,
          200,
          800,
          11000, // 110% - too high
          true,
          'Test'
        )
      ).to.be.revertedWith('V.F.14');
    });

    it('Should allow owner to set partner approval', async () => {
      await expect(factory.setPartnerApproval(user.address, true))
        .to.emit(factory, 'PartnerApprovalChanged')
        .withArgs(user.address, true);
    });

    it('Should allow owner to toggle partner whitelist', async () => {
      await expect(factory.setPartnerWhitelistActive(false))
        .to.emit(factory, 'PartnerWhitelistStatusChanged')
        .withArgs(false);
    });

    it('Should allow owner to set vault winner', async () => {
      await expect(factory.setVaultWinner(user.address, 1, true))
        .to.emit(factory, 'VaultWinnerSet');
    });

    it('Should allow owner to set main fee beneficiary', async () => {
      await expect(factory.setMainFeeBeneficiary(user.address))
        .to.emit(factory, 'FeeBeneficiaryUpdated')
        .withArgs(user.address);
    });

    it('Should reject setting same fee beneficiary', async () => {
      await expect(factory.setMainFeeBeneficiary(owner.address))
        .to.be.revertedWith('V.F.16');
    });

    it('Should allow owner to withdraw deployment fees', async () => {
      // Create vault with deployment fee
      const tx = await factory.connect(partner).createVault(
        await asset.getAddress(),
        500,
        vaultAdmin.address,
        feeBeneficiary.address,
        'test-metadata',
        1,
        { value: ethers.parseEther('0.1') }
      );
      await tx.wait();

      const balanceBefore = await ethers.provider.getBalance(owner.address);

      await expect(factory.withdrawDeploymentFees(owner.address))
        .to.emit(factory, 'DeploymentFeesWithdrawn');

      const balanceAfter = await ethers.provider.getBalance(owner.address);
      expect(balanceAfter).to.be.greaterThan(balanceBefore);
    });

    it('Should reject withdrawing with no fees', async () => {
      await expect(factory.withdrawDeploymentFees(owner.address))
        .to.be.revertedWith('V.F.17');
    });
  });
});
