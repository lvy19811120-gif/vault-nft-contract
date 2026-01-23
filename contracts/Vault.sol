// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import "./interfaces/IVaultFactory.sol";
import "./interfaces/IERC20.sol";

/**
 * @title Vault
 * @dev A contract that locks user tokens for a specified duration and provides linear decaying voting power.
 *      Users can participate in epochs to earn rewards distributed proportionally to their voting power.
 */
contract Vault is Initializable, ReentrancyGuardUpgradeable, IERC721Receiver, OwnableUpgradeable {
    IERC20 public token;
    IVaultFactory public factory;

    /// @notice Fee beneficiary address
    address public feeBeneficiaryAddress;

    /// @notice The deposit fee rate in basis points (e.g. 100 = 1%)
    uint256 public depositFeeRate;

    /// @notice Maximum fee rate allowed in basis points (e.g., 2000 = 20%)
    uint256 public constant MAX_FEE_RATE = 2000;

    /// @notice Max Epoch Duration
    uint256 public constant MAX_EPOCH_DURATION = 8 weeks;

    /// @notice Minimum duration for an epoch
    uint256 public constant MIN_EPOCH_DURATION = 1 weeks;

    /// @notice Minimum amount of tokens required to lock
    uint256 public constant MIN_LOCK_AMOUNT = 1_000 * 10 ** 18;

    /// @notice Maximum duration for which tokens can be locked (52 weeks)
    uint256 public constant MAX_LOCK_DURATION = 52 weeks;

    /// @notice Minimum duration for which tokens can be locked (1 week)
    uint256 public constant MIN_LOCK_DURATION = 1 weeks;

    /// @notice Maximum number of NFTs a user can lock (gas protection)
    uint256 public constant MAX_NFTS_PER_USER = 50;

    /// @notice Variable to track the current epoch ID
    uint256 public currentEpochId;

    /// @notice Total number of historical users
    uint256 public totalHistoricalUsers;

    /// @notice Total count of all deposit actions (deposits + extensions)
    uint256 public totalDepositsCount;

    /// @notice Sum of all lock durations (in seconds) ever created/extended
    uint256 public totalDurationSum;

    /// @notice State variable to track if the vault is paused
    bool public paused = false;

    /// @notice State variable to track if emergency withdraw is enabled
    bool public emergencyWithdrawEnabled;

    /// @notice The tier of this vault
    IVaultFactory.VaultTier public vaultTier;

    /// @notice Current top holder across all epochs (cumulative)
    address public vaultTopHolder;

    /// @notice Top holder's cumulative voting power across all epochs
    uint256 public vaultTopHolderCumulativePower;

    /// @notice Vault metadata URI or encoded JSON string
    string public metadataURI;

    /// @notice Mapping to track cumulative voting power per user across all epochs
    mapping(address => uint256) public userCumulativeVotingPower;

    /// @notice Track which epochs each user has contributed their cumulative power to (prevent double-counting)
    mapping(address => mapping(uint256 => bool)) public userEpochContributed;

    /// @notice Mapping to store NFT collection requirements and boosts
    mapping(address => NFTCollectionRequirement) public nftCollectionRequirements;

    /// @notice Mapping to track NFT counts per user per collection for efficient boost calculation.
    mapping(address => mapping(address => uint256)) public userNFTCounts;

    /// @notice Mapping to track if a user has deposited
    mapping(address => bool) private hasDeposited;

    /// @dev Struct for NFT lock information
    struct NFTLock {
        address collection; // NFT collection address
        uint256 tokenId;   // NFT token ID
    }

    /// @dev Struct for user lock information
    struct UserLock {
        uint256 amount; // Total tokens locked.
        uint256 lockStart; // Timestamp when lock started.
        uint256 lockEnd; // Timestamp when lock ends.
        uint256 peakVotingPower; // Max voting power at deposit/extension.
        uint256[] epochsToClaim; // Epochs the user can claim rewards from.
        NFTLock[] lockedNFTs; // Array of locked NFTs
    }

    /// @dev Struct for epoch information
    struct Epoch {
        uint256 startTime; // Epoch start time.
        uint256 endTime; // Epoch end time.
        uint256 totalVotingPower; // Total voting power in this epoch.
        address[] rewardTokens; // List of reward tokens.
        uint256[] rewardAmounts; // Corresponding reward amounts
        uint256[] leaderboardBonusAmounts; // Leaderboard bonus amounts
        uint256 leaderboardPercentage; // Percentage of rewards for top holder (basis points)
        bool leaderboardClaimed; // Whether leaderboard bonus has been claimed
    }

    /// @dev Struct for NFT collection requirements
    struct NFTCollectionRequirement {
        bool isActive; // Whether this collection is accepted
        uint256 requiredCount; // How many NFTs needed for the perk
        uint256 boostPercentage; // Boost percentage in basis points (e.g., 500 = 5%)
    }

    /// @notice Mapping to store user locks based on their address
    mapping(address => UserLock) private userLocks;

    /// @notice Array to store all epochs
    Epoch[] private epochs;

    /// @notice Mapping to store user's voting power in each epoch
    mapping(address => mapping(uint256 => uint256)) public userEpochVotingPower;

    /// @notice Event emitted when tokens are deposited into the vault.
    /// @param user The address of the user who deposited the tokens.
    /// @param amount The amount of tokens deposited.
    /// @param fee The fee charged for the deposit.
    /// @param duration The lock duration in seconds.
    event Deposited(address indexed user, uint256 amount, uint256 fee, uint256 duration);

    /// @notice Event emitted when a user's lock is extended.
    /// @param user The address of the user who extended the lock.
    /// @param newAmount The new total amount of tokens locked.
    /// @param newLockEnd The new lock end time.
    event ExtendedLock(
        address indexed user,
        uint256 newAmount,
        uint256 newLockEnd
    );

    /// @notice Event emitted when tokens are withdrawn from the vault.
    /// @param user The address of the user who withdrew the tokens.
    /// @param amount The amount of tokens withdrawn.
    event Withdrawn(address indexed user, uint256 amount);

    /// @notice Event emitted when a new epoch is started.
    /// @param epochId The ID of the new epoch.
    /// @param rewardTokens The list of reward tokens for the epoch.
    /// @param rewardAmounts The corresponding reward amounts for the epoch.
    /// @param endTime The end time of the epoch.
    event EpochStarted(
        uint256 indexed epochId,
        address[] rewardTokens,
        uint256[] rewardAmounts,
        uint256 endTime
    );

    /// @notice Event emitted when rewards are claimed by a user.
    /// @param user The address of the user who claimed the rewards.
    /// @param epochId The ID of the epoch from which rewards were claimed.
    event RewardsClaimed(address indexed user, uint256 indexed epochId);

    /// @notice Event emitted when a user participates in an epoch.
    /// @param user The address of the user who participated.
    /// @param epochId The ID of the epoch in which the user participated.
    /// @param votingPower The voting power of the user in the epoch.
    event Participated(
        address indexed user,
        uint256 indexed epochId,
        uint256 votingPower
    );

    /// @notice Event emitted when fee rate is updated.
    /// @param oldRate The previous fee rate in basis points.
    /// @param newRate The new fee rate in basis points.
    event DepositFeeRateUpdated(uint256 oldRate, uint256 newRate);

    /// @notice Event emitted when fee beneficiary is updated.
    /// @param oldBeneficiary The address of the previous fee beneficiary.
    /// @param newBeneficiary The address of the new fee beneficiary.
    event FeeBeneficiaryUpdated(
        address indexed oldBeneficiary,
        address indexed newBeneficiary
    );

    /// @notice Event emitted when vault is paused or unpaused.
    /// @param isPaused A boolean indicating the current status of the vault; true if paused, false if unpaused.
    event VaultStatusChanged(bool isPaused);

    /// @notice Event emitted when emergency withdraw is enabled.
    /// @param enabledBy The address of the admin who enabled emergency withdrawal.
    event EmergencyWithdrawEnabled(address indexed enabledBy);

    /// @notice Event emitted when emergency withdrawal of other tokens occurs.
    /// @param token The address of the token being withdrawn.
    /// @param amount The amount of tokens withdrawn.
    event EmergencyTokenWithdraw(address indexed token, uint256 amount);

    /// @notice Event emitted when emergency withdrawal of principal and NFTs for a user occurs.
    /// @param user The address of the user withdrawing their assets.
    /// @param amount The amount of principal tokens withdrawn.
    event EmergencyWithdrawForUser(address indexed user, uint256 amount);

    /// @notice Event emitted when additional rewards are added to an epoch.
    /// @param epochId The ID of the epoch rewards were added to.
    /// @param rewardTokens The additional reward tokens added.
    /// @param rewardAmounts The additional reward amounts added.
    event RewardsAddedToEpoch(
        uint256 indexed epochId,
        address[] rewardTokens,
        uint256[] rewardAmounts
    );

    /// @notice Event emitted when an NFT is deposited into the vault.
    /// @param user The address of the user who deposited the NFT.
    /// @param collection The address of the NFT collection.
    /// @param tokenId The token ID of the deposited NFT.
    event NFTDeposited(address indexed user, address indexed collection, uint256 indexed tokenId);

    /// @notice Event emitted when an NFT is withdrawn from the vault.
    /// @param user The address of the user who withdrew the NFT.
    /// @param collection The address of the NFT collection.
    /// @param tokenId The token ID of the withdrawn NFT.
    event NFTWithdrawn(address indexed user, address indexed collection, uint256 indexed tokenId);

    /// @notice Event emitted when NFT collection requirement is set.
    /// @param collection The address of the NFT collection.
    /// @param isActive Whether the collection is active.
    /// @param requiredCount The number of NFTs required.
    /// @param boostPercentage The boost percentage in basis points.
    event NFTCollectionRequirementSet(
        address indexed collection, 
        bool isActive, 
        uint256 requiredCount, 
        uint256 boostPercentage
    );

    /// @notice Event emitted when a new vault top holder is set (cumulative)
    /// @param newTopHolder The address of the new top holder.
    /// @param cumulativePower The cumulative voting power of the new top holder.
    event NewVaultTopHolder(
        address indexed newTopHolder, 
        uint256 cumulativePower
    );

    /// @notice Event emitted when leaderboard bonus is claimed
    /// @param epochId The ID of the epoch.
    /// @param topHolder The address of the top holder.
    /// @param cumulativePower The cumulative voting power.
    /// @param rewardTokens The reward tokens.
    /// @param bonusAmounts The bonus amounts.
    event LeaderboardBonusClaimed(
        uint256 indexed epochId,
        address indexed topHolder,
        uint256 cumulativePower,
        address[] rewardTokens,
        uint256[] bonusAmounts
    );

    /// @notice Event emitted when vault tier is updated
    /// @param oldTier The previous tier.
    /// @param newTier The new tier.
    event VaultTierUpdated(IVaultFactory.VaultTier indexed oldTier, IVaultFactory.VaultTier indexed newTier);

    /**
     * @dev Modifier to validate user lock status based on required conditions.
     * @param _requireActive Check that the user has an active token lock.
     * @param _requireEnded Check that the lock period has ended.
     */
    modifier validateLock(bool _requireActive, bool _requireEnded) {
        if (_requireActive) {
            _validateLockActive(msg.sender);
        }
        if (_requireEnded) {
            _validateLockEnded(msg.sender, true);
        } else {
            _validateLockEnded(msg.sender, false);
        }
        _;
    }

    /**
     * @dev Modifier to make a function callable only when the contract is not paused.
     */
    modifier whenNotPaused() {
        require(!paused, "V.1");
        _;
    }

    /**
     * @dev Modifier to make a function callable only when the contract is paused.
     */
    modifier whenPaused() {
        require(paused, "V.2");
        _;
    }

    /*
     * ==========  INITIALIZER  ==========
     */

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initializes the vault with necessary parameters.
     * @param _token Address of the ERC20 token to lock.
     * @param _depositFeeRate Fee rate in basis points (e.g., 100 = 1%).
     * @param _vaultAdmin Admin address for the vault.
     * @param _factory Address of the VaultFactory.
     * @param _feeBeneficiary Address for fee distribution.
     * @param _tier The tier of this vault
     */
    function initialize(
        address _token,
        uint256 _depositFeeRate,
        address _vaultAdmin,
        address _factory,
        address _feeBeneficiary,
        string memory _metadataURI,
        IVaultFactory.VaultTier _tier
    ) external initializer {
        require(_token != address(0), "V.3");
        require(_vaultAdmin != address(0), "V.4");
        require(_factory != address(0), "V.5");
        require(_feeBeneficiary != address(0), "V.6");
        require(_depositFeeRate <= MAX_FEE_RATE, "V.7");

        __Ownable_init(_vaultAdmin);
        __ReentrancyGuard_init();

        token = IERC20(_token);
        depositFeeRate = _depositFeeRate;
        factory = IVaultFactory(_factory);
        feeBeneficiaryAddress = _feeBeneficiary;
        metadataURI = _metadataURI;
        vaultTier = _tier;
    }

    /*
     * ==========  MAIN FUNCTIONS  ==========
     */

    /**
     * @dev Deposits tokens into the vault and locks them for the specified duration.
     * @param _amount Amount of tokens to deposit.
     * @param _duration Lock duration in seconds.
     */
    function deposit(
        uint256 _amount,
        uint256 _duration
    ) external nonReentrant whenNotPaused {
        UserLock storage lock = userLocks[msg.sender];
        
        require(lock.amount == 0, "V.14");
        require(_amount >= MIN_LOCK_AMOUNT, "V.8");
        require(
            _duration >= MIN_LOCK_DURATION && _duration <= MAX_LOCK_DURATION,
            "V.9"
        );
        // Check allowance before any state changes
        require(
            token.allowance(msg.sender, address(this)) >= _amount,
            "V.10"
        );

        uint256 fee = (_amount * depositFeeRate) / 10000;
        uint256 netAmount = _amount - fee;

        // All state changes are performed here, before any interactions.
        lock.amount = netAmount;
        lock.lockStart = block.timestamp;
        lock.lockEnd = block.timestamp + _duration;
        lock.peakVotingPower = netAmount;
        _updateUserEpochPower(msg.sender);

        // External calls happen last.
        require(
            token.transferFrom(msg.sender, address(this), _amount),
            "V.11"
        );
        
        _distributeDepositFee(fee);

        if (!hasDeposited[msg.sender]) {
            hasDeposited[msg.sender] = true;
            totalHistoricalUsers++;
        }

        // Update Average Stats
        totalDepositsCount++;
        totalDurationSum += _duration;

        emit Deposited(msg.sender, _amount, fee, _duration);
    }

    /**
     * @dev Extend lock time or add more tokens.
     *      newLockEnd > current lockEnd if we want a time extension,
     *      or addAmount > 0 to lock more tokens.
     * @param _additionalAmount Amount of tokens to deposit.
     * @param _duration Lock duration in seconds.
     */
    function expandLock(
        uint256 _additionalAmount,
        uint256 _duration
    ) external nonReentrant whenNotPaused {
        require(
            _additionalAmount > 0 || _duration > 0,
            "V.15"
        );
        
        if (_additionalAmount > 0) {
            // Check allowance before any state changes
            require(
                token.allowance(msg.sender, address(this)) >= _additionalAmount,
                "V.10"
            );
        }

        uint256 netAmount = 0;
        uint256 fee = 0;
        if (_additionalAmount > 0) {
            fee = (_additionalAmount * depositFeeRate) / 10000;
            netAmount = _additionalAmount - fee;
        }

        // All state changes happen before interactions.
        _expandLock(
            msg.sender,
            netAmount,
            _duration == 0 ? 0 : block.timestamp + _duration
        );
        _updateUserEpochPower(msg.sender);

        // External calls happen last.
        if (_additionalAmount > 0) {
            require(
                token.transferFrom(msg.sender, address(this), _additionalAmount),
                "V.11"
            );
            
            _distributeDepositFee(fee);
        }

        // Only update stats if duration is extended
        if (_duration > 0) {
             totalDepositsCount++;
             totalDurationSum += _duration;
        }
    }

    /**
     * @dev Withdraws tokens from the vault after the lock period has ended.
     */
    function withdraw() external nonReentrant whenNotPaused validateLock(true, true) {
        UserLock storage lock = userLocks[msg.sender];
        uint256 withdrawable = lock.amount;
        _reduceUserEpochPower(msg.sender);

        _withdrawAllUserNFTs(lock, true);

        delete userLocks[msg.sender];

        require(
            token.transfer(msg.sender, withdrawable),
            "V.11"
        );
        emit Withdrawn(msg.sender, withdrawable);
    }

    /**
     * @dev Allow the user with an active lock and voting power to take part in an epoch.
     *      The median voting power from the effective start time to the effective end time
     *      is added to the total epoch voting power and registered to the user epoch voting power.
     */
    function participate() external whenNotPaused validateLock(true, false) {
        if (epochs.length == 0) return;
        Epoch storage epoch = epochs[currentEpochId];
        require(block.timestamp < epoch.endTime, "V.19");
        require(
            userEpochVotingPower[msg.sender][currentEpochId] == 0,
            "V.20"
        );

        _updateUserEpochPower(msg.sender);

        emit Participated(
            msg.sender,
            currentEpochId,
            userEpochVotingPower[msg.sender][currentEpochId]
        );
    }

    /*
     * ==========  NFT FUNCTIONS  ==========
     */

    /**
     * @dev Withdraws a specific NFT from the vault.
     * @param _collection Address of the NFT collection.
     * @param _tokenId Token ID of the NFT to withdraw.
     */
    function withdrawNFT(address _collection, uint256 _tokenId) external nonReentrant whenNotPaused validateLock(true, true) {
        UserLock storage lock = userLocks[msg.sender];
        
        // Find and remove the NFT from user's locked NFTs
        uint256 nftCount = lock.lockedNFTs.length;
        bool nftFound = false;
        
        for (uint256 i = 0; i < nftCount; i++) {
            if (lock.lockedNFTs[i].collection == _collection && lock.lockedNFTs[i].tokenId == _tokenId) {
                // Transfer NFT back to user
                IERC721(_collection).safeTransferFrom(address(this), msg.sender, _tokenId);
                
                userNFTCounts[msg.sender][_collection]--;

                // Remove NFT from array by swapping with last element and popping
                lock.lockedNFTs[i] = lock.lockedNFTs[nftCount - 1];
                lock.lockedNFTs.pop();
                
                nftFound = true;
                emit NFTWithdrawn(msg.sender, _collection, _tokenId);
                break;
            }
        }
        
        require(nftFound, "V.26");
    }

    /**
     * @dev Withdraws all NFTs when withdrawing tokens.
     */
    function withdrawAllNFTs() external nonReentrant whenNotPaused validateLock(true, true) {
        UserLock storage lock = userLocks[msg.sender];
        
        _withdrawAllUserNFTs(lock, true);
        delete lock.lockedNFTs;
    }

    /**
     * @dev Deposits one or more NFTs from the same collection.
     * @param _collection Address of the NFT collection.
     * @param _tokenIds Array of token IDs to deposit.
     */
    function depositNFTs(address _collection, uint256[] calldata _tokenIds) external nonReentrant whenNotPaused validateLock(true, false) {
        require(_collection != address(0), "V.21");
        require(_tokenIds.length > 0, "V.26");
        
        UserLock storage lock = userLocks[msg.sender];
        require(lock.lockedNFTs.length + _tokenIds.length <= MAX_NFTS_PER_USER, "V.27");
        
        // Check collection is allowed
        NFTCollectionRequirement memory requirement = nftCollectionRequirements[_collection];
        if (requirement.requiredCount > 0 || requirement.boostPercentage > 0) {
            require(requirement.isActive, "V.22");
        }
        
        IERC721 nftContract = IERC721(_collection);
        
        // Process all NFTs
        for (uint256 i = 0; i < _tokenIds.length; i++) {
            uint256 tokenId = _tokenIds[i];
            
            // Verify ownership and approval
            require(nftContract.ownerOf(tokenId) == msg.sender, "V.23");
            require(
                nftContract.getApproved(tokenId) == address(this) || 
                nftContract.isApprovedForAll(msg.sender, address(this)),
                "V.24"
            );
            
            // Check if NFT is already locked
            require(!this.isNFTLocked(msg.sender, _collection, tokenId), "V.25");
            
            // Transfer NFT to vault
            nftContract.safeTransferFrom(msg.sender, address(this), tokenId);
            
            // Add NFT to user's lock
            lock.lockedNFTs.push(NFTLock({
                collection: _collection,
                tokenId: tokenId
            }));
            
            userNFTCounts[msg.sender][_collection]++;

            emit NFTDeposited(msg.sender, _collection, tokenId);
        }
        
        // Update user's epoch power once at the end
        _updateUserEpochPower(msg.sender);
    }

    /*
     * ==========  AUXILIARY  ==========
     */

    /**
     * @dev Distributes the deposit fee to the platform and admin beneficiaries.
     * @param _fee The total fee to be distributed.
     */
    function _distributeDepositFee(uint256 _fee) internal {
        if (_fee > 0) {
            (uint256 platformShare, uint256 adminShare) = factory.calculateDepositFeeSharing(address(this), _fee);
            
            if (platformShare > 0) {
                require(token.transfer(factory.mainFeeBeneficiary(), platformShare), "V.12");
            }
            if (adminShare > 0) {
                require(token.transfer(feeBeneficiaryAddress, adminShare), "V.13");
            }
        }
    }

    /**
     * @dev Internal function to expand the lock of a user.
     * @param _user Address of the user.
     * @param _extraAmount Additional amount of tokens to lock.
     * @param _newEnd New lock end time. Set to 0 if not used.
     */
    function _expandLock(
        address _user,
        uint256 _extraAmount,
        uint256 _newEnd
    ) internal {
        UserLock storage lockData = userLocks[_user];
        require(lockData.amount > 0, "V.28");
        if (_newEnd < block.timestamp) {
            require(
                lockData.lockEnd > block.timestamp,
                "V.29"
            );
        }
        // Refresh current voting power
        // Then we recalc the new peakVotingPower as old leftover + new deposit
        uint256 currentVotingPower = getCurrentVotingPower(_user);

        // The new peakVotingPower can be considered as the current voting power
        // "carried forward" plus the new deposit.  For simplicity, let's just set:
        lockData.peakVotingPower = currentVotingPower + _extraAmount;

        // If user wants to set a new end time that is > oldLockEnd we set new lockEnd
        // If not, we keep the old lockEnd
        if (_newEnd > lockData.lockEnd) {
            lockData.lockEnd = _newEnd;
        }

        // set start data again using peak voting power
        lockData.lockStart = block.timestamp;

        // Increase the locked amount by the extra tokens
        if (_extraAmount > 0) {
            lockData.amount += _extraAmount;
        }

        emit ExtendedLock(_user, lockData.amount, lockData.lockEnd);
    }

    /**
     * @dev Updates user's epoch voting power for the current active epoch.
     *      Called whenever user deposits, extends, withdraws.
     *      Adjusts the vault's total voting power in that epoch as well.
     *      Also updates cumulative leaderboard stats.
     * @param _user Address of the user whose epoch voting power is being updated.
     */
    function _updateUserEpochPower(address _user) internal {
        // If no active epoch, skip
        if (epochs.length == 0) return;
        UserLock storage lockData = userLocks[_user];
        Epoch storage epoch = epochs[currentEpochId];
        if (epoch.endTime <= block.timestamp) return;
        if (lockData.amount == 0) return;

        // 1. Subtract old power from epoch total
        uint256 oldUserPower = userEpochVotingPower[_user][currentEpochId];
        bool isFirstTimeInEpoch = oldUserPower == 0;

        if (oldUserPower > 0) {
            epoch.totalVotingPower = epoch.totalVotingPower > oldUserPower
                ? epoch.totalVotingPower - oldUserPower
                : 0;
        } else {
            lockData.epochsToClaim.push(currentEpochId);
        }

        uint256 effectiveStart = lockData.lockStart > epoch.startTime
            ? lockData.lockStart
            : epoch.startTime;
        uint256 effectiveEnd = lockData.lockEnd < epoch.endTime
            ? lockData.lockEnd
            : epoch.endTime;

        uint256 baseAreaUnderCurve = _calculateAreaUnderCurve(_user, effectiveStart, effectiveEnd);

        if (baseAreaUnderCurve == 0) {
            userEpochVotingPower[_user][currentEpochId] = 0;
            return;
        }
        
        // Apply NFT boost
        uint256 nftBoostPercentage = getUserNFTBoost(_user);
        uint256 boostedAreaUnderCurve = baseAreaUnderCurve;
        
        if (nftBoostPercentage > 0) {
            uint256 boostAmount = (baseAreaUnderCurve * nftBoostPercentage) / 10000;
            boostedAreaUnderCurve = baseAreaUnderCurve + boostAmount;
        }
        
        userEpochVotingPower[_user][currentEpochId] = boostedAreaUnderCurve;
        epoch.totalVotingPower += boostedAreaUnderCurve;

        // Update cumulative leaderboard stats (only once per user per epoch)
        if (isFirstTimeInEpoch && !userEpochContributed[_user][currentEpochId]) {
            userCumulativeVotingPower[_user] += boostedAreaUnderCurve;
            userEpochContributed[_user][currentEpochId] = true;
            
            // Update vault top holder if this user now has highest cumulative power
            if (userCumulativeVotingPower[_user] > vaultTopHolderCumulativePower) {
                vaultTopHolder = _user;
                vaultTopHolderCumulativePower = userCumulativeVotingPower[_user];
                emit NewVaultTopHolder(_user, userCumulativeVotingPower[_user]);
            }
        }
    }

    /**
     * @dev Reduces user's epoch voting power for the current active epoch.
     *      Called whenever user withdraws.
     *      Adjusts the vault's total voting power in that epoch as well.
     * @param _user Address of the user whose epoch voting power is being reduced.
     */
    function _reduceUserEpochPower(address _user) internal {
        // If no active epoch, skip
        if (epochs.length == 0) return;
        Epoch storage epoch = epochs[currentEpochId];
        if (epoch.endTime <= block.timestamp) return;

        UserLock storage lockData = userLocks[_user];
        if (lockData.amount == 0) return;

        // Subtract old power from epoch total
        uint256 oldUserPower = userEpochVotingPower[_user][currentEpochId];
        if (oldUserPower > 0) {
            uint256 effectiveStart = block.timestamp;
            uint256 effectiveEnd = lockData.lockEnd < epoch.endTime
                ? lockData.lockEnd
                : epoch.endTime;

            uint256 areaUnderCurve = _calculateAreaUnderCurve(_user, effectiveStart, effectiveEnd);
            
            if (areaUnderCurve == 0) {
                return;
            }

            if (areaUnderCurve > oldUserPower)
                userEpochVotingPower[_user][currentEpochId] = 0;
            userEpochVotingPower[_user][currentEpochId] =
                oldUserPower -
                areaUnderCurve;
            if (areaUnderCurve > epoch.totalVotingPower)
                epoch.totalVotingPower = 0;
            epoch.totalVotingPower -= areaUnderCurve;
            if (userEpochVotingPower[_user][currentEpochId] == 0) {
                uint256 epochsToClaimLength = lockData.epochsToClaim.length;
                for (uint256 i = 0; i < epochsToClaimLength; i++) {
                    if (lockData.epochsToClaim[i] == currentEpochId) {
                        lockData.epochsToClaim[i] = lockData.epochsToClaim[
                            epochsToClaimLength - 1
                        ];
                        lockData.epochsToClaim.pop();
                        break;
                    }
                }
            }
        }
    }

    /*
     * ==========  EPOCH LOGIC  ==========
     *
     * Each epoch is started by the vault admin, specifying reward tokens and amounts.
     * Users' voting power is aggregated. When epoch ends, distribution is done.
     */

    /**
     * @dev Starts a new epoch for reward distribution with optional leaderboard.
     * @param _rewardTokens List of reward token addresses.
     * @param _rewardAmounts List of reward token amounts.
     * @param _endTime Epoch end time.
     * @param _leaderboardPercentage Percentage of rewards for top holder (basis points, 0-1000 = 0-10%).
     */
    function startEpoch(
        address[] calldata _rewardTokens,
        uint256[] calldata _rewardAmounts,
        uint256 _endTime,
        uint256 _leaderboardPercentage
    ) external onlyOwner whenNotPaused {
        require(_rewardTokens.length == _rewardAmounts.length, "V.30");
        require(_endTime > block.timestamp, "V.31");
        require(
            _endTime - block.timestamp >= MIN_EPOCH_DURATION && 
            _endTime - block.timestamp <= MAX_EPOCH_DURATION,
            "V.32"
        );
        require(_leaderboardPercentage <= 1000, "V.33"); // Max 10%

        // Calculate performance fees and net amounts
        address[] memory netRewardTokens = new address[](_rewardTokens.length);
        uint256[] memory netRewardAmounts = new uint256[](_rewardAmounts.length);
        uint256[] memory leaderboardBonusAmounts = new uint256[](_rewardTokens.length);
        
        for (uint256 i = 0; i < _rewardTokens.length; i++) {
            (uint256 regularReward, uint256 leaderboardBonus) = _processRewardToken(
                _rewardTokens[i],
                _rewardAmounts[i],
                _leaderboardPercentage
            );
            
            netRewardTokens[i] = _rewardTokens[i];
            netRewardAmounts[i] = regularReward;
            leaderboardBonusAmounts[i] = leaderboardBonus;
        }

        if (epochs.length > 0) {
            Epoch storage prevEpoch = epochs[currentEpochId];
            require(
                prevEpoch.endTime <= block.timestamp,
                "V.35"
            );
        }

        epochs.push(Epoch({
            startTime: block.timestamp,
            endTime: _endTime,
            totalVotingPower: 0,
            rewardTokens: netRewardTokens,
            rewardAmounts: netRewardAmounts, // Regular rewards only
            leaderboardBonusAmounts: leaderboardBonusAmounts, // Separate leaderboard pool
            leaderboardPercentage: _leaderboardPercentage,
            leaderboardClaimed: false
        }));

        currentEpochId = epochs.length - 1;
        emit EpochStarted(currentEpochId, netRewardTokens, netRewardAmounts, _endTime);
    }

    /**
     * @dev Adds additional rewards to an existing active epoch.
     * @param _epochId The ID of the epoch to add rewards to.
     * @param _rewardTokens List of additional reward token addresses.
     * @param _rewardAmounts List of additional reward token amounts.
     */
    function addRewardsToEpoch(
        uint256 _epochId,
        address[] calldata _rewardTokens,
        uint256[] calldata _rewardAmounts
    ) external onlyOwner whenNotPaused {
        require(_epochId < epochs.length, "V.36");
        require(
            _rewardTokens.length == _rewardAmounts.length,
            "V.30"
        );

        Epoch storage epoch = epochs[_epochId];
        require(block.timestamp < epoch.endTime, "V.19");

        // Transfer the additional reward tokens and apply performance fees
        uint256 rewardTokensLength = _rewardTokens.length;
        for (uint256 i = 0; i < rewardTokensLength; i++) {
            require(
                _rewardAmounts[i] > 0,
                "V.37"
            );
            
            (uint256 regularRewardAmount, uint256 leaderboardBonus) = _processRewardToken(
                _rewardTokens[i],
                _rewardAmounts[i],
                epoch.leaderboardPercentage
            );
            
            bool tokenExists = false;
            // Check if token already exists in epoch
            for (uint256 j = 0; j < epoch.rewardTokens.length; j++) {
                if (epoch.rewardTokens[j] == _rewardTokens[i]) {
                    epoch.rewardAmounts[j] += regularRewardAmount;
                    epoch.leaderboardBonusAmounts[j] += leaderboardBonus;
                    tokenExists = true;
                    break;
                }
            }

            // If token doesn't exist, add it as new reward
            if (!tokenExists) {
                epoch.rewardTokens.push(_rewardTokens[i]);
                epoch.rewardAmounts.push(regularRewardAmount);
                epoch.leaderboardBonusAmounts.push(leaderboardBonus);
            }
        }

        emit RewardsAddedToEpoch(_epochId, _rewardTokens, _rewardAmounts);
    }

    /**
     * @dev Claims rewards for a specific epoch.
     * @param _epochId Epoch ID to claim rewards from.
     */
    function claimEpochRewards(
        uint256 _epochId
    ) external nonReentrant whenNotPaused {
        require(_epochId < epochs.length, "V.36");

        Epoch storage epoch = epochs[_epochId];
        require(epoch.endTime <= block.timestamp, "V.38");
        UserLock storage userLock = userLocks[msg.sender];
        bool epochFound = false;
        uint256 i = 0;
        uint256 epochsToClaimLength = userLock.epochsToClaim.length;
        for (i; i < epochsToClaimLength; i++) {
            if (userLock.epochsToClaim[i] == _epochId) {
                epochFound = true;
                break;
            }
        }
        require(epochFound, "V.39");

        uint256 userPower = userEpochVotingPower[msg.sender][_epochId];
        uint256 totalPower = epoch.totalVotingPower;

        require(
            userPower != 0 && totalPower != 0,
            "V.40"
        );
        
        // Remove the epochID from the list of epochs to claim BEFORE transfers.
        userLock.epochsToClaim[i] = userLock.epochsToClaim[
            epochsToClaimLength - 1
        ];
        userLock.epochsToClaim.pop();

        uint256 rewardLength = epoch.rewardTokens.length;
        for (uint256 j = 0; j < rewardLength; j++) {
            IERC20 rewardToken = IERC20(epoch.rewardTokens[j]);
            uint256 totalReward = epoch.rewardAmounts[j];
            uint256 userShare = (totalReward * userPower) / totalPower;
            if (userShare > 0) {
                require(
                    rewardToken.balanceOf(address(this)) >= userShare,
                    "V.41"
                );
                rewardToken.transfer(msg.sender, userShare);
            }
        }

        emit RewardsClaimed(msg.sender, _epochId);
    }

    /**
     * @dev Claims the leaderboard bonus for being the vault top holder (cumulative across epochs).
     * @param _epochId Epoch ID to claim leaderboard bonus from.
     */
    function claimLeaderboardBonus(uint256 _epochId) external nonReentrant whenNotPaused {
        require(_epochId < epochs.length, "V.36");
        
        Epoch storage epoch = epochs[_epochId];
        require(epoch.endTime <= block.timestamp, "V.38");
        require(vaultTopHolder == msg.sender, "V.42");
        require(!epoch.leaderboardClaimed, "V.43");
        require(epoch.leaderboardPercentage > 0, "V.44");
        
        epoch.leaderboardClaimed = true;
        
        // Transfer pre-calculated leaderboard bonus amounts
        address[] memory rewardTokens = epoch.rewardTokens;
        uint256[] memory bonusAmounts = epoch.leaderboardBonusAmounts;
        
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            if (bonusAmounts[i] > 0) {
                require(
                    IERC20(rewardTokens[i]).transfer(msg.sender, bonusAmounts[i]),
                    "V.45"
                );
            }
        }
        
        emit LeaderboardBonusClaimed(_epochId, msg.sender, vaultTopHolderCumulativePower, rewardTokens, bonusAmounts);
    }

    /**
     * @dev Emergency withdrawal of a user's entire position (principal and NFTs).
     *      This can only be called by the user themselves after the owner has enabled it.
     */
    function emergencyWithdrawForUser() external nonReentrant whenPaused {
        require(
            emergencyWithdrawEnabled,
            "V.49"
        );
        UserLock storage lock = userLocks[msg.sender];
        require(lock.amount > 0 || lock.lockedNFTs.length > 0, "V.16");

        // 1. Withdraw Principal
        if (lock.amount > 0) {
             require(
                token.transfer(msg.sender, lock.amount),
                "V.11"
            );
        }

        // 2. Withdraw all locked NFTs
        _withdrawAllUserNFTs(lock, false);

        emit EmergencyWithdrawForUser(msg.sender, lock.amount);

        // 3. Optional: Reset user's lock state if you want to prevent re-entry issues.
        // This is good practice to prevent the user from having a "zombie" lock state.
        delete userLocks[msg.sender];
    }

    /*
     * ==========  READ FUNCTIONS  ==========
     */

    /**
     * @dev Gets the user's current voting power at the current block timestamp.
     *      The voting power decays linearly from lockStart to lockEnd.
     * @param _user The address of the user.
     * @return The current voting power of the user.
     */
    function getCurrentVotingPower(
        address _user
    ) public view returns (uint256) {
        return getVotingPowerAtTime(_user, block.timestamp);
    }

    /**
     * @dev Gets the user's voting power at a specific future timestamp.
     * @param _user The address of the user.
     * @param _time The future timestamp to check the voting power at.
     * @return The voting power of the user at the specified time.
     */
    function getVotingPowerAtTime(
        address _user,
        uint256 _time
    ) public view returns (uint256) {
        UserLock memory lockData = userLocks[_user];
        if (lockData.amount == 0) {
            return 0;
        }
        if (_time >= lockData.lockEnd) {
            // fully decayed
            return 0;
        }
        uint256 lockDuration = lockData.lockEnd - lockData.lockStart;
        uint256 timeSinceLock = _time - lockData.lockStart;
        if (timeSinceLock > lockDuration) {
            return 0;
        }
        // linear decay
        return
            (lockData.peakVotingPower * (lockDuration - timeSinceLock)) /
            lockDuration;
    }

    /**
     * @dev Returns the user information including locked NFTs.
     * @param _user Address of the user.
     * @return amount The amount of tokens locked.
     * @return lockStart The timestamp when the lock started.
     * @return lockEnd The timestamp when the lock ends.
     * @return peakVotingPower The peak voting power of the user.
     * @return epochsToClaim The epochs the user can claim rewards from.
     * @return lockedNFTs The array of locked NFTs.
     */
    function getUserInfo(
        address _user
    )
        external
        view
        returns (
            uint256 amount,
            uint256 lockStart,
            uint256 lockEnd,
            uint256 peakVotingPower,
            uint256[] memory epochsToClaim,
            NFTLock[] memory lockedNFTs
        )
    {
        UserLock storage lock = userLocks[_user];
        return (
            lock.amount,
            lock.lockStart,
            lock.lockEnd,
            lock.peakVotingPower,
            lock.epochsToClaim,
            lock.lockedNFTs
        );
    }

    /**
     * @dev Internal function to withdraw all of a user's NFTs.
     * @param lock The user's lock storage pointer.
     * @param shouldEmit True to emit NFTWithdrawn events, false otherwise.
     */
    function _withdrawAllUserNFTs(UserLock storage lock, bool shouldEmit) internal {
        uint256 nftCount = lock.lockedNFTs.length;
        if (nftCount > 0) {
            for (uint256 i = 0; i < nftCount; i++) {
                NFTLock memory nftLock = lock.lockedNFTs[i];
                userNFTCounts[msg.sender][nftLock.collection]--;
                IERC721(nftLock.collection).safeTransferFrom(address(this), msg.sender, nftLock.tokenId);
                if (shouldEmit) {
                    emit NFTWithdrawn(msg.sender, nftLock.collection, nftLock.tokenId);
                }
            }
        }
    }

    /**
     * @dev Checks if a specific NFT is locked by a user.
     * @param _user Address of the user.
     * @param _collection Address of the NFT collection.
     * @param _tokenId Token ID of the NFT.
     * @return True if the NFT is locked by the user, false otherwise.
     */
    function isNFTLocked(address _user, address _collection, uint256 _tokenId) external view returns (bool) {
        UserLock storage lock = userLocks[_user];
        uint256 nftCount = lock.lockedNFTs.length;
        
        for (uint256 i = 0; i < nftCount; i++) {
            if (lock.lockedNFTs[i].collection == _collection && lock.lockedNFTs[i].tokenId == _tokenId) {
                return true;
            }
        }
        
        return false;
    }

    /**
     * @dev Returns the number of epochs.
     * @return The total number of epochs.
     */
    function getEpochCount() external view returns (uint256) {
        return epochs.length;
    }

    /**
     * @dev Returns details of a specific epoch including leaderboard info.
     * @param _epochId Epoch ID.
     * @return startTime The start time of the epoch.
     * @return endTime The end time of the epoch.
     * @return totalVotingPower The total voting power in the epoch.
     * @return rewardTokens The reward tokens for the epoch.
     * @return rewardAmounts The reward amounts for the epoch.
     * @return leaderboardBonusAmounts The leaderboard bonus amounts.
     * @return leaderboardPercentage The leaderboard percentage.
     * @return leaderboardClaimed Whether the leaderboard bonus has been claimed.
     */
    function getEpochInfo(
        uint256 _epochId
    )
        external
        view
        returns (
            uint256 startTime,
            uint256 endTime,
            uint256 totalVotingPower,
            address[] memory rewardTokens,
            uint256[] memory rewardAmounts,
            uint256[] memory leaderboardBonusAmounts,
            uint256 leaderboardPercentage,
            bool leaderboardClaimed
        )
    {
        require(_epochId < epochs.length, "V.36");
        Epoch memory epoch = epochs[_epochId];
        return (
            epoch.startTime,
            epoch.endTime,
            epoch.totalVotingPower,
            epoch.rewardTokens,
            epoch.rewardAmounts,
            epoch.leaderboardBonusAmounts,
            epoch.leaderboardPercentage,
            epoch.leaderboardClaimed
        );
    }

    /**
     * @notice Calculates the total NFT boost for a user based on their locked NFTs and collection requirements.
     * @param _user The address of the user.
     * @return totalBoost The total boost percentage in basis points.
     */
    function getUserNFTBoost(address _user) public view returns (uint256 totalBoost) {
        UserLock storage lock = userLocks[_user];
        uint256 nftCount = lock.lockedNFTs.length;
        
        if (nftCount == 0) {
            return 0;
        }
        
        // Use an array to track collections we have already calculated boosts for.
        address[] memory processedCollections = new address[](nftCount);
        uint256 processedCount = 0;
        
        // Iterate through all locked NFTs to find the unique collections.
        for (uint256 i = 0; i < nftCount; i++) {
            address collection = lock.lockedNFTs[i].collection;
            
            bool alreadyProcessed = false;
            for (uint256 j = 0; j < processedCount; j++) {
                if (processedCollections[j] == collection) {
                    alreadyProcessed = true;
                    break;
                }
            }
            
            if (!alreadyProcessed) {
                // For each unique collection, read its count directly from storage.
                uint256 collectionCount = userNFTCounts[_user][collection];
                
                NFTCollectionRequirement memory requirement = nftCollectionRequirements[collection];
                if (requirement.isActive && collectionCount >= requirement.requiredCount) {
                    totalBoost += requirement.boostPercentage;
                }
                
                // Mark this collection as processed for this function call.
                processedCollections[processedCount] = collection;
                processedCount++;
            }
        }
        
        return totalBoost;
    }

    /**
     * @notice Returns the average lock duration across all historical deposits.
     * @return The average duration in seconds.
     */
    function getAverageLockDuration() external view returns (uint256) {
        if (totalDepositsCount == 0) return 0;
        return totalDurationSum / totalDepositsCount;
    }

    /**
     * @dev Calculates the area under the voting power curve between two timestamps.
     * @param _user The address of the user.
     * @param _startTime The start time for the calculation.
     * @param _endTime The end time for the calculation.
     * @return The area under the curve, representing integrated voting power.
     */
    function _calculateAreaUnderCurve(
        address _user,
        uint256 _startTime,
        uint256 _endTime
    ) internal view returns (uint256) {
        if (_startTime >= _endTime) {
            return 0;
        }

        uint256 vpStart = getVotingPowerAtTime(_user, _startTime);
        uint256 vpEnd = getVotingPowerAtTime(_user, _endTime);

        return ((vpStart + vpEnd) * (_endTime - _startTime)) / 2;
    }

    /**
     * @dev Internal function to validate if a user's lock is active.
     * @param _user The address of the user to check.
     */
    function _validateLockActive(address _user) internal view {
        require(userLocks[_user].amount > 0, "V.16");
    }

    /**
     * @dev Internal function to validate if a user's lock has ended or not.
     * @param _user The address of the user to check.
     * @param _shouldBeEnded True to check if the lock has ended, false to check if it has not.
     */
    function _validateLockEnded(address _user, bool _shouldBeEnded) internal view {
        if (_shouldBeEnded) {
            require(block.timestamp >= userLocks[_user].lockEnd, "V.17");
        } else {
            require(block.timestamp < userLocks[_user].lockEnd, "V.18");
        }
    }

    /*
     * ==========  ADMIN FUNCTIONS  ==========
     */

    /**
     * @dev Set the deposit fee rate with a maximum limit of 20%.
     * @param _newFeeRate The new deposit fee rate in basis points (e.g., 2000 = 20%).
     */
    function setDepositFeeRate(uint256 _newFeeRate) external onlyOwner {
        IVaultFactory.TierConfig memory tierConfig = factory.getVaultTierConfig(address(this));
        
        require(tierConfig.canAdjustDepositFee, "V.46");
        require(
            _newFeeRate >= tierConfig.minDepositFeeRate && 
            _newFeeRate <= tierConfig.maxDepositFeeRate, 
            "V.47"
        );
        
        uint256 oldRate = depositFeeRate;
        depositFeeRate = _newFeeRate;
        emit DepositFeeRateUpdated(oldRate, _newFeeRate);
    }

    /**
     * @dev Set the fee beneficiary address.
     * @param _newFeeBeneficiary The new fee beneficiary address.
     */
    function setFeeBeneficiaryAddress(
        address _newFeeBeneficiary
    ) external onlyOwner {
        require(
            _newFeeBeneficiary != address(0),
            "V.48"
        );
        address oldBeneficiary = feeBeneficiaryAddress;
        feeBeneficiaryAddress = _newFeeBeneficiary;
        emit FeeBeneficiaryUpdated(oldBeneficiary, _newFeeBeneficiary);
    }

    /**
     * @dev Enables emergency withdrawal for all users
     */
    function enableEmergencyWithdraw() external onlyOwner whenPaused {
        require(
            !emergencyWithdrawEnabled,
            "V.49"
        );
        emergencyWithdrawEnabled = true;
        emit EmergencyWithdrawEnabled(msg.sender);
    }

    /**
     * @dev Sets the vault pause status.
     * @param _paused True to pause the vault, false to unpause it.
     */
    function setPauseStatus(bool _paused) external onlyOwner {
        // This check ensures the vault is not already in the requested state,
        // using a ternary operator to provide the correct original error code.
        require(paused != _paused, _paused ? "V.1" : "V.2");

        // The additional check for unpausing remains.
        if (!_paused) {
            require(!emergencyWithdrawEnabled, "V.50");
        }

        paused = _paused;
        emit VaultStatusChanged(_paused);
    }

    /**
     * @dev Emergency token withdrawal by the admin.
     * @param _token Address of the token to withdraw.
     * @param _amount Amount of tokens to withdraw.
     */
    function emergencyWithdraw(
        address _token,
        uint256 _amount
    ) external onlyOwner whenPaused {
        require(
            emergencyWithdrawEnabled,
            "V.51"
        );
        require(_token != address(token), "V.52");
        require(_amount > 0, "V.53");
        require(
            IERC20(_token).balanceOf(address(this)) >= _amount,
            "V.54"
        );
        require(
            IERC20(_token).transfer(owner(), _amount),
            "V.11"
        );
        emit EmergencyTokenWithdraw(_token, _amount);
    }

    /**
     * @dev Sets NFT collection requirements and boost for voting power.
     * @param _collection Address of the NFT collection.
     * @param _isActive Whether this collection is accepted (ACTIVATE/DEACTIVATE).
     * @param _requiredCount The number of NFTs required.
     * @param _boostPercentage The boost percentage in basis points.
     */
    function setNFTCollectionRequirement(
        address _collection,
        bool _isActive,
        uint256 _requiredCount,
        uint256 _boostPercentage
    ) external onlyOwner {
        require(_collection != address(0), "V.21");
        require(_boostPercentage <= 10000, "V.55"); // Max 100%
        
        nftCollectionRequirements[_collection] = NFTCollectionRequirement({
            isActive: _isActive,
            requiredCount: _requiredCount,
            boostPercentage: _boostPercentage
        });
        
        emit NFTCollectionRequirementSet(_collection, _isActive, _requiredCount, _boostPercentage);
    }

    /*
     * ==========  SYSTEM-CALLED FUNCTIONS  ==========
     */

    /**
     * @dev Updates the vault tier (only callable by factory during upgrades).
     * @param _newTier The new tier for this vault.
     */
    function updateVaultTier(IVaultFactory.VaultTier _newTier) external {
        require(msg.sender == address(factory), "V.56");
        
        IVaultFactory.VaultTier oldTier = vaultTier;
        vaultTier = _newTier;
        
        emit VaultTierUpdated(oldTier, _newTier);
    }

    /*
     * ==========  MISC  ==========
     */

    /**
     * @dev Always returns `IERC721Receiver.onERC721Received.selector`.
     */
    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    /**
    * @dev Processes a single reward token by calculating fees, performing transfers,
    *      and returning the regular and leaderboard reward amounts.
    * @param _rewardToken The address of the reward token.
    * @param _grossAmount The gross amount of the reward token.
    * @param _leaderboardPercentage The percentage for the leaderboard bonus.
    * @return regularReward The amount for regular distribution.
    * @return leaderboardBonus The amount for the leaderboard.
    */
   function _processRewardToken(
       address _rewardToken,
       uint256 _grossAmount,
       uint256 _leaderboardPercentage
   ) internal returns (uint256 regularReward, uint256 leaderboardBonus) {
       uint256 performanceFee = factory.calculatePerformanceFee(address(this), _grossAmount);
       uint256 netAmount = _grossAmount - performanceFee;

       require(IERC20(_rewardToken).allowance(msg.sender, address(this)) >= _grossAmount, "V.10");
       require(IERC20(_rewardToken).transferFrom(msg.sender, address(this), _grossAmount), "V.11");

       if (performanceFee > 0) {
           require(IERC20(_rewardToken).transfer(factory.mainFeeBeneficiary(), performanceFee), "V.35");
       }

       leaderboardBonus = (netAmount * _leaderboardPercentage) / 10000;
       regularReward = netAmount - leaderboardBonus;
   }

    /*
     * ==========  ERROR CODES  ==========
     * V.1: Vault: paused
     * V.2: Vault: not paused
     * V.3: Vault: invalid token
     * V.4: Vault: invalid admin
     * V.5: Vault: invalid factory
     * V.6: Vault: invalid beneficiary
     * V.7: Vault: fee rate too high
     * V.8: Vault: amount too small
     * V.9: Vault: invalid duration
     * V.10: Vault: insufficient allowance
     * V.11: Vault: transfer failed
     * V.12: Vault: platform fee transfer failed
     * V.13: Vault: admin fee transfer failed
     * V.14: Vault: lock already active
     * V.15: Vault: either one should be positive
     * V.16: Vault: no active lock
     * V.17: Vault: lock not ended
     * V.18: Vault: lock has ended
     * V.19: Vault: epoch is ended
     * V.20: Vault: already registered for this epoch
     * V.21: Vault: invalid collection address
     * V.22: Vault: collection not allowed
     * V.23: Vault: not NFT owner
     * V.24: Vault: NFT not approved
     * V.25: Vault: NFT already locked
     * V.26: Vault: no token IDs provided
     * V.27: Vault: too many NFTs
     * V.28: Vault: no existing lock
     * V.29: Vault: current lock expired extend it first
     * V.30: Vault: mismatched arrays
     * V.31: Vault: invalid end time
     * V.32: Vault: invalid epoch duration
     * V.33: Vault: leaderboard percentage too high
     * V.34: Vault: performance fee transfer failed
     * V.35: Vault: previous epoch not ended
     * V.36: Vault: invalid epoch ID
     * V.37: Vault: reward amount must be positive
     * V.38: Vault: epoch not ended
     * V.39: Vault: epoch not claimable by user
     * V.40: Vault: no rewards available
     * V.41: Vault: insufficient reward balance
     * V.42: Vault: not the vault top holder
     * V.43: Vault: leaderboard bonus already claimed
     * V.44: Vault: no leaderboard bonus for this epoch
     * V.45: Vault: leaderboard bonus transfer failed
     * V.46: Vault: tier doesn't allow fee adjustment
     * V.47: Vault: fee rate outside tier limits
     * V.48: Vault: invalid fee beneficiary address
     * V.49: Vault: emergency withdraw already enabled
     * V.50: Vault: cannot unpause after emergency withdraw enabled
     * V.51: Vault: emergency withdraw not enabled
     * V.52: Vault: cannot withdraw vault token
     * V.53: Vault: amount must be greater than 0
     * V.54: Vault: insufficient balance
     * V.55: Vault: boost percentage too high
     * V.56: Vault: only factory can update tier
     */
}
