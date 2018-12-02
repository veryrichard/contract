pragma solidity ^0.4.24;

import "../node_modules/openzeppelin-solidity/contracts/token/ERC20/ERC20.sol";
import "../node_modules/openzeppelin-solidity/contracts/math/SafeMath.sol";

contract GlobalsAndUtility is ERC20 {
  using SafeMath for uint256;

  /* Define events */
  event Claim(
    uint256 claimValue,
    uint256 amount,
    bool referred
  );

  event StartStake(
    uint256 amount,
    uint256 periods
  );

  event EndStake(
    uint256 principal,
    uint256 payout,
    uint256 periodsServed,
    uint256 penalty,
    uint256 shares,
    uint256 periodsCommitted
  );

  event GoodAccounting(
    uint256 shares,
    uint256 stakeEndTimeCommit
  );
  
  /* Origin Address */
  address internal origin;

  /* ERC20 Constants */
  string public constant name = "BitcoinHEX"; 
  string public constant symbol = "BHX";
  uint public constant decimals = 18;

  /* Store time of launch for contract */
  uint256 internal launchTime;

  /* Total tokens redeemed so far. */
  uint256 public totalRedeemed = 0;
  uint256 public redeemedCount = 0;

  /* Root hash of the UTXO Merkle tree */
  bytes32 public rootUTXOMerkleTreeHash;

  /* Redeemed UTXOs. */
  mapping(bytes32 => bool) internal redeemedUTXOs;

  /* Store last week storeWeeklyData() ran */
  uint256 internal lastUpdatedWeek = 0;

  /* Store last period storePeriodData() ran */
  uint256 internal lastUpdatedPeriod = 0;

  /* Weekly data */
  struct WeeklyDataStuct {
    uint256 unclaimedCoins;
    uint256 totalStaked;
  }
  mapping(uint256 => WeeklyDataStuct) internal weeklyData;

  /* Accumulated Emergency unstake pool to go into next period pool */
  uint256 internal emergencyAndLateUnstakePool;

  /* Period data */
  struct PeriodDataStuct {
    uint256 payoutRoundAmount;
    uint256 totalStakeShares;
  }
  mapping(uint256 => PeriodDataStuct) internal periodData;

  /* Total number of UTXO's at fork */
  uint256 internal UTXOCountAtFork;

  /* Maximum redeemable coins at fork */
  uint256 internal maximumRedeemable;

  /* Stakes Storage */
  struct StakeStruct {
    uint256 amount;
    uint256 shares;
    uint256 lockTime;
    uint256 endStakeCommitTime;
    uint256 periods;
    bool isInGlobalPool;
    uint256 timeRemovedFromGlobalPool;
    uint256 latePenaltyAlreadyPooled;
  }
  mapping(address => StakeStruct[]) public staked;
  uint256 public totalStakedCoins;
  uint256 internal totalStakeShares;

  /* Stake timing parameters */
  uint256 internal constant maxStakingTime = 365 days * 50;
  uint256 internal constant oneInterestPeriod = 10 days;

  /** 
    @dev Moves last item in array to location of item to be removed,
    overwriting array item. Shortens array length by 1, removing now
    duplicate item at end of array.
    @param _staker staker address for accessing array
    @param _stakeIndex index of the item to delete
  */
  function removeStake(
    address _staker,
    uint256 _stakeIndex
  ) internal {
    /* Set last item to index of item we want to get rid of */
    staked[_staker][_stakeIndex] = staked[_staker][staked[_staker].length.sub(1)];

    /* Remove last item in array now that safely copied to index of deleted item */
    staked[_staker].length = staked[_staker].length.sub(1);
  }

  /**
   * @dev Calculates difference between 2 timestamps in periods
   * @param _start first timestamp
   * @param _end second timestamp
   * @return difference between timestamps in periods
   */
  function differenceInPeriods(
    uint256 _start,
    uint256 _end
  ) internal pure returns (uint256){
    return (_end.sub(_start).div(10 days));
  }


  /**
   * @dev Converts timestamp to number of weeks into contract
   * @param _timestamp timestamp to convert
   * @return number of weeks into contract
   */
  function timestampToWeeks(
    uint256 _timestamp
  ) internal view returns (uint256) {
    return (_timestamp.sub(launchTime).div(7 days));
  }

  /**
   * @dev Checks number of weeks since launch of contract
   * @return number of weeks since launch
   */
  function weeksSinceLaunch() internal view returns (uint256) {
    return (timestampToWeeks(block.timestamp));
  }

  /**
   * @dev Converts timestamp to number of periods into contract
   * @param _timestamp timestamp to convert
   * @return number of periods into contract
   */
  function timestampToPeriods(
    uint256 _timestamp
  ) internal view returns (uint256) {
    return (_timestamp.sub(launchTime).div(10 days));
  }

  /**
  * @dev Checks number of periods since launch of contract
  * @return number of periods since launch
  */
  function periodsSinceLaunch() internal view returns (uint256) {
    return (timestampToPeriods(block.timestamp));
  }

  /**
   * @dev PUBLIC FACING: Checks if we're still in claims period
   * @return true/false is in claims period
   */
  function isClaimsPeriod() public view returns (bool) {
    return (weeksSinceLaunch() < 50);
  }

  /**
   * @dev PUBLIC FACING: Store weekly coin data,
   * call at start of function so data is populated for operations
   */
  function storeWeeklyData() public {
    for (lastUpdatedWeek; weeksSinceLaunch() > lastUpdatedWeek.add(1); lastUpdatedWeek++) {
      uint256 _unclaimedCoins = maximumRedeemable.sub(totalRedeemed);
      weeklyData[lastUpdatedWeek.add(1)] = WeeklyDataStuct(
          _unclaimedCoins,
          totalStakedCoins
      );
      _mint(origin, _unclaimedCoins.div(50));
    }
  }

  /**
   * @dev PUBLIC FACING: Store period coin data,
   * call at start of function so data is populated for operations
   */
  function storePeriodData() public {
    for (lastUpdatedPeriod; periodsSinceLaunch() > lastUpdatedPeriod.add(1); lastUpdatedPeriod++) {

      /* Calculate payout round */
      uint256 _payoutRound = totalSupply().div(993);
      /* Gives approximately 0.10070493% inflation per period, 
      which equals 3.69% inflation per 36 periods (360 days) */

      /* Calculate Viral and Crit rewards */
      if (isClaimsPeriod()) {
        _payoutRound = _payoutRound.add(
          /* VIRAL REWARDS: Add bonus percentage to _rewards from 0-10% based on adoption */
          _payoutRound.mul(redeemedCount).div(UTXOCountAtFork).div(10)
        ).add (
          /* CRIT MASS REWARDS: Add bonus percentage to _rewards from 0-10% based on adoption */
          _payoutRound.mul(totalRedeemed).div(maximumRedeemable).div(10)
        );

        /* Pay crit and viral to origin */
        _mint(origin, _payoutRound.mul(redeemedCount).div(UTXOCountAtFork).div(10)); // VIRAL
        _mint(origin, _payoutRound.mul(totalRedeemed).div(maximumRedeemable).div(10)); // CRIT
      }

      /* Add emergency unstake pool to payout round */
      _payoutRound = _payoutRound.add(emergencyAndLateUnstakePool);
      emergencyAndLateUnstakePool = 0;

      /* Add _payoutRound to contract's balance */
      _mint(this, _payoutRound);

      /* Store data */
      periodData[lastUpdatedPeriod.add(1)] = PeriodDataStuct(
        _payoutRound,
        totalStakedCoins
      );
    }
  }

  /**
   * @dev PUBLIC FACING: A convenience function to get supply and staked (true supply).
   * @return True Supply
  */
  function circulatingSupply() external view returns (uint256) {
    return totalSupply().sub(totalStakedCoins);
  }
}
