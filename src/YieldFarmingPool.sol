// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

/**
 * @title YieldFarmingPool
 * @notice ERC20 staking contract that distributes a reward token continuously at a
 *         configurable rate per pool. Users stake tokens, earn rewards over time, and
 *         claim or unstake at any point.
 * @dev Uses `abi.encodePacked` to derive deterministic pool identifiers.
 *      Reward accumulation follows the standard per-token reward accounting pattern:
 *      `rewardPerTokenStored` accumulates reward per staked token; each user's
 *      pending amount is `amount * rewardPerTokenStored / 1e18 - rewardDebt`.
 */
contract YieldFarmingPool is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /**
     * @notice On-chain state for a staking pool.
     * @param token Staked token address.
     * @param totalStaked Total tokens currently staked in this pool.
     * @param rewardRate Reward tokens emitted per second (18 decimals).
     * @param lastUpdateTime Timestamp of the last rewardPerTokenStored update.
     * @param rewardPerTokenStored Accumulated reward per staked token (scaled by 1e18).
     * @param isActive Whether the pool accepts new stakes.
     */
    struct Pool {
        address token;
        uint256 totalStaked;
        uint256 rewardRate;
        uint256 lastUpdateTime;
        uint256 rewardPerTokenStored;
        bool isActive;
    }

    /**
     * @notice Per-user staking state for a given pool.
     * @param amount Tokens currently staked.
     * @param rewardDebt Snapshot of `amount * rewardPerTokenStored / 1e18` at last interaction.
     * @param lastClaimTime Timestamp of the user's last reward claim or stake update.
     */
    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt;
        uint256 lastClaimTime;
    }

    /// @notice Token distributed as staking reward.
    IERC20 public immutable rewardToken;

    /// @notice Pool data keyed by pool identifier.
    mapping(bytes32 => Pool) public pools;

    /// @notice User staking state keyed by pool id then user address.
    mapping(bytes32 => mapping(address => UserInfo)) public userInfo;

    /// @notice Ordered list of all pool identifiers ever created.
    bytes32[] public activePools;

    /**
     * @notice Emitted when a new pool is created.
     * @param poolId Unique pool identifier.
     * @param token Staked token address.
     * @param rewardRate Reward tokens per second.
     */
    event PoolCreated(bytes32 indexed poolId, address indexed token, uint256 rewardRate);

    /**
     * @notice Emitted when a user stakes tokens.
     * @param poolId Pool identifier.
     * @param user Staker address.
     * @param amount Amount staked.
     */
    event Staked(bytes32 indexed poolId, address indexed user, uint256 amount);

    /**
     * @notice Emitted when a user withdraws staked tokens.
     * @param poolId Pool identifier.
     * @param user Staker address.
     * @param amount Amount withdrawn.
     */
    event Withdrawn(bytes32 indexed poolId, address indexed user, uint256 amount);

    /**
     * @notice Emitted when a user receives reward tokens.
     * @param poolId Pool identifier.
     * @param user Recipient address.
     * @param amount Reward amount transferred.
     */
    event RewardClaimed(bytes32 indexed poolId, address indexed user, uint256 amount);

    /**
     * @notice Emitted when the owner changes a pool's reward rate.
     * @param poolId Pool identifier.
     * @param newRewardRate New reward tokens per second.
     */
    event PoolUpdated(bytes32 indexed poolId, uint256 newRewardRate);

    /**
     * @notice Deploys the yield farming pool with the given reward token.
     * @param rewardToken_ Address of the ERC20 token distributed as rewards.
     */
    constructor(address rewardToken_) Ownable(msg.sender) {
        require(rewardToken_ != address(0), "Invalid reward token");
        rewardToken = IERC20(rewardToken_);
    }

    /**
     * @notice Creates a new staking pool for `token` with the given reward rate.
     * @dev The pool identifier is derived from token, rewardRate, block.timestamp and
     *      block.chainid so the same token can have multiple pools with different rates
     *      or created at different times.
     * @param token ERC20 token users will stake.
     * @param rewardRate Reward tokens emitted per second (must be > 0).
     * @return poolId Unique identifier for the new pool.
     */
    function createPool(
        address token,
        uint256 rewardRate
    ) external onlyOwner returns(bytes32 poolId) {
        require(token != address(0), "Invalid token");
        require(rewardRate > 0, "Reward rate must be positive");

        poolId = keccak256(abi.encodePacked(
            token,
            rewardRate,
            block.timestamp,
            block.chainid
        ));

        require(pools[poolId].token == address(0), "Pool already exists");

        pools[poolId] = Pool({
            token: token,
            totalStaked: 0,
            rewardRate: rewardRate,
            lastUpdateTime: block.timestamp,
            rewardPerTokenStored: 0,
            isActive: true
        });

        activePools.push(poolId);

        emit PoolCreated(poolId, token, rewardRate);
    }

    /**
     * @notice Stakes `amount` tokens into `poolId`.
     * @dev Any pending rewards for an existing position are auto-claimed before the
     *      new stake is recorded. Caller must approve this contract for `amount` of
     *      the pool's staked token.
     * @param poolId Pool to stake into.
     * @param amount Token amount to stake (must be > 0).
     */
    function stake(bytes32 poolId, uint256 amount) external nonReentrant {
        Pool storage pool = pools[poolId];
        require(pool.isActive, "Pool must be active");
        require(amount > 0, "Amount must be positive");

        UserInfo storage user = userInfo[poolId][msg.sender];
        if (user.amount > 0) {
            uint256 pending = _calculatePendingRewards(poolId, msg.sender);
            if (pending > 0) {
                _safeRewardTransfer(msg.sender, pending);
                emit RewardClaimed(poolId, msg.sender, pending);
            }
        }

        IERC20(pool.token).safeTransferFrom(msg.sender, address(this), amount);

        user.amount += amount;
        user.rewardDebt = user.amount * pool.rewardPerTokenStored / 1e18;
        user.lastClaimTime = block.timestamp;

        pool.totalStaked += amount;

        emit Staked(poolId, msg.sender, amount);
    }

    /**
     * @notice Withdraws `amount` staked tokens from `poolId` and auto-claims pending rewards.
     * @param poolId Pool to unstake from.
     * @param amount Token amount to withdraw (must be <= staked balance).
     */
    function unstake(bytes32 poolId, uint256 amount) external nonReentrant {
        Pool storage pool = pools[poolId];
        require(pool.isActive, "Pool must be active");
        require(amount > 0, "Amount must be positive");

        UserInfo storage user = userInfo[poolId][msg.sender];
        require(user.amount >= amount, "Insufficient staked amount");

        _updatePool(poolId);

        uint256 pending = _calculatePendingRewards(poolId, msg.sender);
        if (pending > 0) {
            _safeRewardTransfer(msg.sender, pending);
            emit RewardClaimed(poolId, msg.sender, pending);
        }

        user.amount -= amount;
        user.rewardDebt = user.amount * pool.rewardPerTokenStored / 1e18;

        pool.totalStaked -= amount;

        IERC20(pool.token).safeTransfer(msg.sender, amount);

        emit Withdrawn(poolId, msg.sender, amount);
    }

    /**
     * @notice Claims all pending rewards for the caller in `poolId`.
     * @param poolId Pool to claim rewards from.
     */
    function claimRewards(bytes32 poolId) external nonReentrant {
        _updatePool(poolId);

        uint256 pending = _calculatePendingRewards(poolId, msg.sender);
        require(pending > 0, "No rewards to claim");

        UserInfo storage user = userInfo[poolId][msg.sender];
        user.rewardDebt = user.amount * pools[poolId].rewardPerTokenStored / 1e18;
        user.lastClaimTime = block.timestamp;

        _safeRewardTransfer(msg.sender, pending);

        emit RewardClaimed(poolId, msg.sender, pending);
    }

    /**
     * @notice Updates the reward rate for `poolId`. Flushes pending rewards first.
     * @param poolId Pool to update.
     * @param newRewardRate New reward tokens per second.
     */
    function updatePoolRewardRate(bytes32 poolId, uint256 newRewardRate) external onlyOwner {
        Pool storage pool = pools[poolId];
        require(pool.isActive, "Pool is not active");

        _updatePool(poolId);
        pool.rewardRate = newRewardRate;

        emit PoolUpdated(poolId, newRewardRate);
    }

    /**
     * @notice Returns the packed encoding of all pool state fields.
     * @param poolId Pool identifier.
     * @return encodedData `abi.encodePacked` of token, totalStaked, rewardRate,
     *         lastUpdateTime, rewardPerTokenStored and isActive.
     */
    function getPoolEncodedData(bytes32 poolId) external view returns(bytes memory encodedData) {
        Pool storage pool = pools[poolId];
        encodedData = abi.encodePacked(
            pool.token,
            pool.totalStaked,
            pool.rewardRate,
            pool.lastUpdateTime,
            pool.rewardPerTokenStored,
            pool.isActive
        );
    }

    /**
     * @notice Returns a unique hash identifying a user's participation in a pool.
     * @param poolId Pool identifier.
     * @param user User address.
     * @return userHash keccak256 of poolId, user and the "YIELD_FARMING_USER" tag.
     */
    function getUserHash(bytes32 poolId, address user) external pure returns(bytes32 userHash) {
        userHash = keccak256(abi.encodePacked(poolId, user, "YIELD_FARMING_USER"));
    }

    /**
     * @notice Returns the number of pools ever created.
     * @return Length of the activePools array.
     */
    function getActivePoolsCount() external view returns(uint256) {
        return activePools.length;
    }

    /**
     * @notice Returns all pool identifiers.
     * @return Array of pool ids in creation order.
     */
    function getActivePools() external view returns(bytes32[] memory) {
        return activePools;
    }

    /**
     * @notice Transfers `amount` of `token` to the owner. Emergency use only.
     * @param token Token to withdraw.
     * @param amount Amount to withdraw.
     */
    function emergencyWithdraw(address token, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(owner(), amount);
    }

    /**
     * @notice Updates `rewardPerTokenStored` and `lastUpdateTime` for `poolId`.
     * @dev No-op for the reward calculation if `totalStaked == 0`.
     * @param poolId Pool to update.
     */
    function _updatePool(bytes32 poolId) internal {
        Pool storage pool = pools[poolId];
        uint256 currentTime = block.timestamp;
        if (pool.totalStaked > 0) {
            uint256 timeElapsed = currentTime - pool.lastUpdateTime;
            uint256 reward = timeElapsed * pool.rewardRate;
            pool.rewardPerTokenStored += reward * 1e18 / pool.totalStaked;
        }
        pool.lastUpdateTime = currentTime;
    }

    /**
     * @notice Transfers up to `amount` reward tokens to `to`, capped at the contract balance.
     * @param to Recipient.
     * @param amount Requested reward amount.
     */
    function _safeRewardTransfer(address to, uint256 amount) internal {
        uint256 rewardBalance = rewardToken.balanceOf(address(this));
        if (amount > rewardBalance) {
            amount = rewardBalance;
        }
        if (amount > 0) {
            rewardToken.safeTransfer(to, amount);
        }
    }

    /**
     * @notice Calculates the pending reward for `user` in `poolId` without mutating state.
     * @param poolId Pool identifier.
     * @param user User address.
     * @return Pending reward tokens (18 decimals).
     */
    function _calculatePendingRewards(bytes32 poolId, address user) internal view returns(uint256) {
        Pool storage pool = pools[poolId];
        UserInfo storage userInfoData = userInfo[poolId][user];

        uint256 rewardPerTokenStored = pool.rewardPerTokenStored;
        if (pool.totalStaked > 0) {
            uint256 timeElapsed = block.timestamp - pool.lastUpdateTime;
            uint256 rewards = timeElapsed * pool.rewardRate;
            rewardPerTokenStored += rewards * 1e18 / pool.totalStaked;
        }
        return userInfoData.amount * rewardPerTokenStored / 1e18 - userInfoData.rewardDebt;
    }

}
