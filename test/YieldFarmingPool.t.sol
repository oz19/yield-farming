// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "forge-std/Test.sol";
import "src/YieldFarmingPool.sol";
import "src/MockToken.sol";


contract TestYieldFarmingPool is Test {

    YieldFarmingPool private farm;
    MockToken        private stakeToken;
    MockToken        private rewardToken;

    address private owner  = address(this);
    address private user1  = vm.addr(1);
    address private user2  = vm.addr(2);

    bytes32 private poolId;

    uint256 private constant REWARD_RATE    = 1e15;  // 0.001 reward token / second
    uint256 private constant REWARD_SUPPLY  = 100_000e18;
    uint256 private constant STAKE_AMOUNT   = 100e18;

    function setUp() public {
        stakeToken  = new MockToken("Stake",  "STK", 0);
        rewardToken = new MockToken("Reward", "RWD", 0);

        farm = new YieldFarmingPool(address(rewardToken));

        rewardToken.mint(address(farm), REWARD_SUPPLY);

        poolId = farm.createPool(address(stakeToken), REWARD_RATE);

        stakeToken.mint(user1, STAKE_AMOUNT * 10);
        stakeToken.mint(user2, STAKE_AMOUNT * 10);
    }

    // ── constructor ───────────────────────────────────────────────────────────

    function testConstructorSetsRewardToken() public view {
        assertEq(address(farm.rewardToken()), address(rewardToken));
    }

    function testConstructorRevertsOnZeroAddress() public {
        vm.expectRevert("Invalid reward token");
        new YieldFarmingPool(address(0));
    }

    // ── createPool ────────────────────────────────────────────────────────────

    function testCreatePoolStoresCorrectData() public view {
        (address token,, uint256 rr,,, bool isActive) = farm.pools(poolId);
        assertEq(token, address(stakeToken));
        assertEq(rr, REWARD_RATE);
        assertTrue(isActive);
    }

    function testCreatePoolIncrementsCount() public view {
        assertEq(farm.getActivePoolsCount(), 1);
    }

    function testCreatePoolRevertsOnZeroToken() public {
        vm.expectRevert("Invalid token");
        farm.createPool(address(0), REWARD_RATE);
    }

    function testCreatePoolRevertsOnZeroRewardRate() public {
        vm.expectRevert("Reward rate must be positive");
        farm.createPool(address(stakeToken), 0);
    }

    function testCreatePoolRevertsForNonOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        farm.createPool(address(stakeToken), REWARD_RATE);
    }

    function testCreatePoolRevertsOnDuplicatePool() public {
        vm.expectRevert("Pool already exists");
        farm.createPool(address(stakeToken), REWARD_RATE);
    }

    // ── stake ─────────────────────────────────────────────────────────────────

    function testStakeNewPosition() public {
        vm.startPrank(user1);
        stakeToken.approve(address(farm), STAKE_AMOUNT);

        vm.expectEmit(true, true, false, true);
        emit YieldFarmingPool.Staked(poolId, user1, STAKE_AMOUNT);
        farm.stake(poolId, STAKE_AMOUNT);
        vm.stopPrank();

        (uint256 amount,,) = farm.userInfo(poolId, user1);
        assertEq(amount, STAKE_AMOUNT);

        (,uint256 totalStaked,,,,) = farm.pools(poolId);
        assertEq(totalStaked, STAKE_AMOUNT);
    }

    function testStakeTransfersTokens() public {
        uint256 balBefore = stakeToken.balanceOf(user1);

        vm.startPrank(user1);
        stakeToken.approve(address(farm), STAKE_AMOUNT);
        farm.stake(poolId, STAKE_AMOUNT);
        vm.stopPrank();

        assertEq(stakeToken.balanceOf(user1), balBefore - STAKE_AMOUNT);
        assertEq(stakeToken.balanceOf(address(farm)), STAKE_AMOUNT);
    }

    function testStakeWithExistingPositionAndPendingRewards() public {
        vm.startPrank(user1);
        stakeToken.approve(address(farm), STAKE_AMOUNT * 2);
        farm.stake(poolId, STAKE_AMOUNT);

        vm.warp(block.timestamp + 1000);

        uint256 rewardBefore = rewardToken.balanceOf(user1);

        vm.expectEmit(true, true, false, false);
        emit YieldFarmingPool.RewardClaimed(poolId, user1, 0);
        farm.stake(poolId, STAKE_AMOUNT);
        vm.stopPrank();

        assertGt(rewardToken.balanceOf(user1), rewardBefore);
    }

    function testStakeWithExistingPositionNoPendingRewards() public {
        vm.startPrank(user1);
        stakeToken.approve(address(farm), STAKE_AMOUNT * 2);
        farm.stake(poolId, STAKE_AMOUNT);

        uint256 rewardBefore = rewardToken.balanceOf(user1);
        farm.stake(poolId, STAKE_AMOUNT);
        vm.stopPrank();

        assertEq(rewardToken.balanceOf(user1), rewardBefore);
    }

    function testStakeRevertsOnInactivePool() public {
        bytes32 badPool = keccak256("nonexistent");
        vm.startPrank(user1);
        stakeToken.approve(address(farm), STAKE_AMOUNT);
        vm.expectRevert("Pool must be active");
        farm.stake(badPool, STAKE_AMOUNT);
        vm.stopPrank();
    }

    function testStakeRevertsOnZeroAmount() public {
        vm.startPrank(user1);
        stakeToken.approve(address(farm), STAKE_AMOUNT);
        vm.expectRevert("Amount must be positive");
        farm.stake(poolId, 0);
        vm.stopPrank();
    }

    // ── unstake ───────────────────────────────────────────────────────────────

    function testUnstakeWithPendingRewards() public {
        vm.startPrank(user1);
        stakeToken.approve(address(farm), STAKE_AMOUNT);
        farm.stake(poolId, STAKE_AMOUNT);

        vm.warp(block.timestamp + 1000);

        uint256 stakeBalBefore  = stakeToken.balanceOf(user1);
        uint256 rewardBalBefore = rewardToken.balanceOf(user1);

        vm.expectEmit(true, true, false, true);
        emit YieldFarmingPool.Withdrawn(poolId, user1, STAKE_AMOUNT);
        farm.unstake(poolId, STAKE_AMOUNT);
        vm.stopPrank();

        assertEq(stakeToken.balanceOf(user1), stakeBalBefore + STAKE_AMOUNT);
        assertGt(rewardToken.balanceOf(user1), rewardBalBefore);
    }

    function testUnstakeWithNoPendingRewards() public {
        vm.startPrank(user1);
        stakeToken.approve(address(farm), STAKE_AMOUNT);
        farm.stake(poolId, STAKE_AMOUNT);

        uint256 rewardBalBefore = rewardToken.balanceOf(user1);
        farm.unstake(poolId, STAKE_AMOUNT);
        vm.stopPrank();

        assertEq(rewardToken.balanceOf(user1), rewardBalBefore);
    }

    function testUnstakePartialAmount() public {
        vm.startPrank(user1);
        stakeToken.approve(address(farm), STAKE_AMOUNT);
        farm.stake(poolId, STAKE_AMOUNT);
        farm.unstake(poolId, STAKE_AMOUNT / 2);
        vm.stopPrank();

        (uint256 amount,,) = farm.userInfo(poolId, user1);
        assertEq(amount, STAKE_AMOUNT / 2);
    }

    function testUnstakeRevertsOnInsufficientAmount() public {
        vm.startPrank(user1);
        stakeToken.approve(address(farm), STAKE_AMOUNT);
        farm.stake(poolId, STAKE_AMOUNT);

        vm.expectRevert("Insufficient staked amount");
        farm.unstake(poolId, STAKE_AMOUNT + 1);
        vm.stopPrank();
    }

    function testUnstakeRevertsOnZeroAmount() public {
        vm.startPrank(user1);
        stakeToken.approve(address(farm), STAKE_AMOUNT);
        farm.stake(poolId, STAKE_AMOUNT);

        vm.expectRevert("Amount must be positive");
        farm.unstake(poolId, 0);
        vm.stopPrank();
    }

    function testUnstakeRevertsOnInactivePool() public {
        bytes32 badPool = keccak256("nonexistent");
        vm.startPrank(user1);
        vm.expectRevert("Pool must be active");
        farm.unstake(badPool, STAKE_AMOUNT);
        vm.stopPrank();
    }

    // ── claimRewards ──────────────────────────────────────────────────────────

    function testClaimRewardsTransfersCorrectAmount() public {
        vm.startPrank(user1);
        stakeToken.approve(address(farm), STAKE_AMOUNT);
        farm.stake(poolId, STAKE_AMOUNT);

        uint256 elapsed = 1000;
        vm.warp(block.timestamp + elapsed);

        uint256 expectedReward = elapsed * REWARD_RATE; // 1e18 tokens

        vm.expectEmit(true, true, false, true);
        emit YieldFarmingPool.RewardClaimed(poolId, user1, expectedReward);
        farm.claimRewards(poolId);
        vm.stopPrank();

        assertEq(rewardToken.balanceOf(user1), expectedReward);
    }

    function testClaimRewardsRevertsOnNoPending() public {
        vm.prank(user1);
        vm.expectRevert("No rewards to claim");
        farm.claimRewards(poolId);
    }

    function testClaimRewardsAfterFullUnstakeReverts() public {
        vm.startPrank(user1);
        stakeToken.approve(address(farm), STAKE_AMOUNT);
        farm.stake(poolId, STAKE_AMOUNT);
        vm.warp(block.timestamp + 1000);
        farm.unstake(poolId, STAKE_AMOUNT);

        vm.expectRevert("No rewards to claim");
        farm.claimRewards(poolId);
        vm.stopPrank();
    }

    // ── _safeRewardTransfer capped path ───────────────────────────────────────

    function testSafeRewardTransferCapsToBalance() public {
        MockToken stakeToken2 = new MockToken("S2", "S2", 0);
        stakeToken2.mint(user1, STAKE_AMOUNT);

        MockToken rewardToken2 = new MockToken("R2", "R2", 0);
        YieldFarmingPool farm2 = new YieldFarmingPool(address(rewardToken2));

        uint256 smallBalance = 1e15; // only 0.001 reward tokens available
        rewardToken2.mint(address(farm2), smallBalance);

        uint256 highRate = 1e18; // 1 token/second — will exceed balance quickly
        bytes32 pid2 = farm2.createPool(address(stakeToken2), highRate);

        vm.startPrank(user1);
        stakeToken2.approve(address(farm2), STAKE_AMOUNT);
        farm2.stake(pid2, STAKE_AMOUNT);
        vm.warp(block.timestamp + 10); // earns 10 tokens but only 0.001 available

        farm2.claimRewards(pid2);
        vm.stopPrank();

        assertEq(rewardToken2.balanceOf(user1), smallBalance);
        assertEq(rewardToken2.balanceOf(address(farm2)), 0);
    }

    function testSafeRewardTransferSkipsOnZeroBalance() public {
        MockToken stakeToken3 = new MockToken("S3", "S3", 0);
        stakeToken3.mint(user1, STAKE_AMOUNT);

        MockToken rewardToken3 = new MockToken("R3", "R3", 0);
        YieldFarmingPool farm3 = new YieldFarmingPool(address(rewardToken3));

        bytes32 pid3 = farm3.createPool(address(stakeToken3), REWARD_RATE);

        vm.startPrank(user1);
        stakeToken3.approve(address(farm3), STAKE_AMOUNT);
        farm3.stake(pid3, STAKE_AMOUNT);
        vm.warp(block.timestamp + 1000);

        farm3.claimRewards(pid3);
        vm.stopPrank();

        assertEq(rewardToken3.balanceOf(user1), 0);
    }

    // ── _updatePool with totalStaked == 0 ────────────────────────────────────

    function testUpdatePoolSkipsAccumulationWhenEmpty() public {
        vm.startPrank(user1);
        stakeToken.approve(address(farm), STAKE_AMOUNT);
        farm.stake(poolId, STAKE_AMOUNT);
        vm.warp(block.timestamp + 1000);
        farm.unstake(poolId, STAKE_AMOUNT);
        vm.stopPrank();

        // After full unstake, totalStaked == 0.
        // updatePoolRewardRate calls _updatePool — should not accumulate.
        (,,,, uint256 rptsBefore,) = farm.pools(poolId);
        farm.updatePoolRewardRate(poolId, REWARD_RATE * 2);
        (,,,, uint256 rptsAfter,) = farm.pools(poolId);

        assertEq(rptsBefore, rptsAfter);
    }

    // ── updatePoolRewardRate ──────────────────────────────────────────────────

    function testUpdatePoolRewardRate() public {
        uint256 newRate = REWARD_RATE * 2;

        vm.expectEmit(true, false, false, true);
        emit YieldFarmingPool.PoolUpdated(poolId, newRate);
        farm.updatePoolRewardRate(poolId, newRate);

        (,, uint256 rr,,,) = farm.pools(poolId);
        assertEq(rr, newRate);
    }

    function testUpdatePoolRewardRateRevertsForNonOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        farm.updatePoolRewardRate(poolId, REWARD_RATE * 2);
    }

    function testUpdatePoolRewardRateRevertsOnInactivePool() public {
        bytes32 badPool = keccak256("nonexistent");
        vm.expectRevert("Pool is not active");
        farm.updatePoolRewardRate(badPool, REWARD_RATE * 2);
    }

    // ── view helpers ─────────────────────────────────────────────────────────

    function testGetPoolEncodedData() public {
        (address token, uint256 totalStaked, uint256 rr, uint256 lastUpdate, uint256 rpts, bool isActive)
            = farm.pools(poolId);

        bytes memory expected = abi.encodePacked(token, totalStaked, rr, lastUpdate, rpts, isActive);
        assertEq(farm.getPoolEncodedData(poolId), expected);
    }

    function testGetUserHash() public view {
        bytes32 expected = keccak256(abi.encodePacked(poolId, user1, "YIELD_FARMING_USER"));
        assertEq(farm.getUserHash(poolId, user1), expected);
    }

    function testGetActivePoolsCount() public view {
        assertEq(farm.getActivePoolsCount(), 1);
    }

    function testGetActivePools() public view {
        bytes32[] memory list = farm.getActivePools();
        assertEq(list.length, 1);
        assertEq(list[0], poolId);
    }

    // ── emergencyWithdraw ─────────────────────────────────────────────────────

    function testEmergencyWithdraw() public {
        uint256 balBefore = rewardToken.balanceOf(owner);
        farm.emergencyWithdraw(address(rewardToken), REWARD_SUPPLY);
        assertEq(rewardToken.balanceOf(owner), balBefore + REWARD_SUPPLY);
        assertEq(rewardToken.balanceOf(address(farm)), 0);
    }

    function testEmergencyWithdrawRevertsForNonOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        farm.emergencyWithdraw(address(rewardToken), 1);
    }

    // ── two-user reward isolation ─────────────────────────────────────────────

    function testTwoUsersEarnProportionalRewards() public {
        vm.startPrank(user1);
        stakeToken.approve(address(farm), STAKE_AMOUNT);
        farm.stake(poolId, STAKE_AMOUNT);
        vm.stopPrank();

        vm.startPrank(user2);
        stakeToken.approve(address(farm), STAKE_AMOUNT * 2);
        farm.stake(poolId, STAKE_AMOUNT * 2);
        vm.stopPrank();

        vm.warp(block.timestamp + 3000);

        vm.prank(user1);
        farm.claimRewards(poolId);

        vm.prank(user2);
        farm.claimRewards(poolId);

        uint256 r1 = rewardToken.balanceOf(user1);
        uint256 r2 = rewardToken.balanceOf(user2);

        // user2 staked 2× as much so earns roughly 2× the rewards
        assertApproxEqRel(r2, r1 * 2, 0.001e18); // within 0.1%
    }

}
