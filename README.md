# Vault & Factory Staking System

A robust, multi-tenant smart contract system for token locking with linear decay voting power, NFT boosts, a competitive leaderboard, and a tiered, factory-based deployment model.

---

## Overview

The system consists of two main components:

-   **`Vault.sol`**: The core contract where users lock ERC20 tokens and NFTs to gain voting power. This power decays over time, and users participate in reward "epochs" to earn a share of token distributions.
-   **`VaultFactory.sol`**: A factory that deploys new `Vault` instances as gas-efficient clones. It manages a multi-tier system, allowing vault creators to choose a fee structure that suits their community.

---

## Core Mechanics

### 1. Voting Power Mechanism

-   **Linear Decay**: A user's base voting power is proportional to their locked token amount and decays linearly to zero from the moment of deposit until their lock period ends.
-   **Lock Extension**: Users can extend their lock duration or add more tokens at any time to reset their voting power decay, keeping them competitive in reward epochs.
-   **NFT Boosts**: Users can lock NFTs from approved collections to receive a percentage-based boost on their voting power, increasing their share of rewards.

### 2. Epoch and Reward System

-   **Reward Epochs**: Admins can start time-bound reward periods ("epochs") by funding them with any ERC20 token.
-   **Participation**: Users with active locks can participate in an epoch to become eligible for its rewards.
-   **Proportional Rewards**: Rewards are distributed based on each user's total voting power (including NFT boosts) calculated as an "area under the curve" for the duration of the epoch.

### 3. Leaderboard Competition

-   **Vault Top Holder**: The system tracks the user with the highest cumulative voting power across all epochs.
-   **Bonus Rewards**: A portion of each epoch's reward pool is reserved as a bonus for the current top holder, adding a competitive element.

### 4. Tiered Fee Structure

-   The `VaultFactory` offers three deployment tiers, each with a different economic model for deployment costs, deposit fees, and performance fees on rewards.
-   This allows vault creators to choose a model that aligns with their project's maturity and goals.

---

## Features

### Vault Contract (`Vault.sol`)

-   **Token & NFT Locking**: Locks ERC20 tokens and ERC721 NFTs to generate time-weighted voting power.
-   **Epoch-Based Rewards**: Manages reward distribution for multiple, distinct reward periods.
-   **Leaderboard Tracking**: Identifies and rewards the top community contributor.
-   **Security**: Built with OpenZeppelin contracts for security best practices (Reentrancy Guard, Ownable) and is upgradeable via the factory.
-   **Emergency Features**: Includes admin-controlled pause and emergency withdrawal mechanisms to protect user funds.

### Vault Factory (`VaultFactory.sol`)

-   **Gas-Efficient Deployment**: Uses a clone factory pattern to deploy new `Vault` instances cheaply.
-   **Tier Management**: Manages the three distinct vault tiers and their associated fee structures.
-   **Permissioned Creation**: Can be configured to allow only approved partners to create new vaults.
-   **System Configuration**: The owner can set key addresses, such as the `Vault` implementation and the main fee beneficiary.

---

## Getting Started

### Prerequisites

-   Node.js >=18.x
-   Yarn or npm
-   A testnet RPC URL and private key with test ETH (e.g., from [Infura](https://infura.io) on Sepolia)

### Installation

1.  Clone the repository:
    ```bash
    git clone https://github.com/lvy19811120-gif/vault-nft-contract.git
    ```
2.  Install dependencies:
    ```bash
    npm install
    ```
3.  Create a `.env` file in the root directory and populate it with your credentials:
    ```
    SEPOLIA_RPC_URL="YOUR_RPC_URL_HERE"
    PRIVATE_KEY="YOUR_PRIVATE_KEY_HERE"
    ETHERSCAN_API_KEY="YOUR_ETHERSCAN_API_KEY_HERE"
    ```

### Deployment

The entire system, including all core contracts, a test ERC20 token, and a sample vault, can be deployed with a single command.

1.  Run the deployment script for your target network (e.g., `sepolia`):
    ```bash
    npx hardhat run deployments/deploy_all.ts --network sepolia
    ```
2.  The script will log the addresses of all deployed contracts and automatically attempt to verify them on Etherscan.

---

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
