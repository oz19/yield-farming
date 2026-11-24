// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";


contract YieldFarmingPool is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Pool {
        address token;
        uint256 totalStaked;
        uint256 rewardRate;
        uint256 lastUpdateTime;
        uint256 rewardPerTokenStored;
        bool isActive;
    }

    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt;
        uint256 lastClaimTime;
    }

    IERC20 public immutable rewardToken;

    mapping(bytes32 => Pool) public pools;
    mapping(bytes32 => mapping(address => UserInfo)) public userInfo;
    bytes32[] public activePools;

    event PoolCreated(bytes32 indexed poolId, address indexed token, uint256 rewardRate);
    event Staked(bytes32 indexed poolId, address indexed user, uint256 amount);
    event Withdrawn(bytes32 indexed poolId, address indexed user, uint256 amount);
    event RewardClaimed(bytes32 indexed poolId, address indexed user, uint256 amount);
    event PoolUpdated(bytes32 indexed poolId, uint256 newRewardRate);

    constructor(address rewardToken_) Ownable(msg.sender) {
        require(rewardToken_ != address(0), "Invalid reward token");
        rewardToken = IERC20(rewardToken_);
    }

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

    function updatePoolRewardRate(bytes32 poolId, uint256 newRewardRate) external onlyOwner {
        Pool storage pool = pools[poolId];
        require(pool.isActive, "Pool is not active");

        _updatePool(poolId);
        pool.rewardRate = newRewardRate;

        emit PoolUpdated(poolId, newRewardRate);
    }

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

    function getUserHash(bytes32 poolId, address user) external pure returns(bytes32 userHash) {
        userHash = keccak256(abi.encodePacked(poolId, user, "YIELD_FARMING_USER"));
    }

    function getActivePoolsCount() external view returns(uint256) {
        return activePools.length;
    }

    function getActivePools() external view returns(bytes32[] memory) {
        return activePools;
    }

    function emergencyWithdraw(address token, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(owner(), amount);
    }

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

    function _safeRewardTransfer(address to, uint256 amount) internal {
        uint256 rewardBalance = rewardToken.balanceOf(address(this));
        if (amount > rewardBalance) {
            amount = rewardBalance;
        }
        if (amount > 0) {
            rewardToken.safeTransfer(to, amount);
        }
    }

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
