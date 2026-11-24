# Yield Farming

ERC20 staking contract that distributes a reward token continuously at a configurable per-second rate. Multiple independent staking pools can share a single reward token. Reward accounting uses the standard per-token accumulation pattern to allow any number of users to stake and claim without iterating over all stakers.

## Contracts

### `YieldFarmingPool.sol`

| Function | Description |
|---|---|
| `createPool(token, rewardRate)` | Creates a new staking pool. `poolId` is derived from token, rate and timestamp. Owner only. |
| `stake(poolId, amount)` | Stakes tokens into a pool. Auto-claims any pending rewards for existing positions. |
| `unstake(poolId, amount)` | Withdraws staked tokens and auto-claims pending rewards. |
| `claimRewards(poolId)` | Claims all pending rewards for the caller. |
| `updatePoolRewardRate(poolId, newRate)` | Changes a pool's reward rate after flushing accrued rewards. Owner only. |
| `getPoolEncodedData(poolId)` | Returns `abi.encodePacked` of all pool state fields. |
| `getUserHash(poolId, user)` | Returns a unique hash identifying a user's participation in a pool. |
| `getActivePoolsCount()` | Returns the number of pools ever created. |
| `getActivePools()` | Returns all pool identifiers. |
| `emergencyWithdraw(token, amount)` | Transfers tokens to the owner. Emergency use only. |

### `MockToken.sol`

Minimal ERC20 with owner-controlled `mint` and public `burn`. Used in tests to simulate staked and reward tokens.

## Reward math

Rewards accumulate using the per-token stored value pattern:

```
rewardPerTokenStored += (timeElapsed × rewardRate × 1e18) / totalStaked
pending = amount × rewardPerTokenStored / 1e18 − rewardDebt
```

Each user's `rewardDebt` is a snapshot of `amount × rewardPerTokenStored / 1e18` taken at their last interaction. The difference between the current value and the snapshot is the pending reward.

## Staking flow

```
User                       YieldFarmingPool
 │                                │
 │── approve(farm, amount) ──────>│ (ERC20)
 │── stake(poolId, amount) ───────│
 │                                │── safeTransferFrom(user, farm, amount)
 │                                │── update userInfo + pool.totalStaked
 │                                │
 │   ... time passes ...          │
 │                                │
 │── claimRewards(poolId) ────────│
 │                                │── _updatePool (accumulate rewardPerTokenStored)
 │                                │── _calculatePendingRewards
 │                                │── _safeRewardTransfer(user, pending)
 │<─ reward tokens ───────────────│
 │                                │
 │── unstake(poolId, amount) ─────│
 │                                │── auto-claim pending rewards
 │                                │── safeTransfer(user, amount)
 │<─ staked tokens + rewards ─────│
```

## Security notes

- **Reentrancy**: all state-changing functions use `nonReentrant`.
- **Reward cap**: `_safeRewardTransfer` caps transfers to the contract's actual reward token balance; users cannot drain more than what is funded.
- **Integer precision**: reward math uses 1e18 scaling. With a 1 token/second rate and 1 staker, rewards accrue at exactly 1 token per second.
- **Pool uniqueness**: pool IDs include `block.timestamp` and `block.chainid`, so the same token can have multiple pools with different rates or created at different times.
- **No pool deactivation**: pools remain active indefinitely. Owner access changes (Ownable) are out of scope for this didactic contract.

## Usage

```shell
forge build
forge test
forge coverage
```
