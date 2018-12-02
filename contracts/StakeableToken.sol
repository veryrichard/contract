pragma solidity ^0.4.24;

import "./UTXORedeemableToken.sol";
import "../node_modules/openzeppelin-solidity/contracts/math/SafeMath.sol";

contract StakeableToken is UTXORedeemableToken {
  using SafeMath for uint256;

  /**
   * @dev PUBLIC FACING: Calculates weareallsatoshi bonus for a given stake
   * @param _amount param of stake to calculate bonuses for
   * @param _lockTime param of stake to calculate bonuses for
   * @param _endTime param of stake to calculate bonuses for
   * @return bonus amount
   */
  function calculateWeAreAllSatoshiRewards(
    uint256 _amount,
    uint256 _lockTime,
    uint256 _endTime
  ) public view returns (uint256) {
    uint256 _bonus = 0;

    /* Only calculate for stakes that were active in the first 50 weeks */
    if (timestampToWeeks(_lockTime) < 50) {
      /* Convert lockTime from timestamp to week number */
      uint256 _startWeekCandidate = timestampToWeeks(_lockTime);

      /* Bonuses are not deducted nor given before end of first week of contract launching */
      uint256 _startWeek = _startWeekCandidate == 0 ? 1 : _startWeekCandidate;

      /* Convert endStakeCommitTime from timestamp to week number */
      uint256 _endWeek = timestampToWeeks(_endTime);

      uint256 _rewardableEndWeek = _endWeek > 50 ? 50 : _endWeek;

      /* Award 2% of unclaimed coins at end of every week.
      We intentionally overshoot to compensate for reduction from late claim scaling */
      for (uint256 _i = _startWeek; _i < _rewardableEndWeek; _i++) {
        /* Calculate what proportion of unclaimed coins stake is entitled to,
        and calculate 2% of it (div 50) */
        uint256 _satoshiRewardWeek = weeklyData[_i].unclaimedCoins.mul(_amount).div(50);

        /* Add to tally */
        _bonus = _bonus.add(_satoshiRewardWeek);
      }
    }

    return _bonus;
  }

  /**
   * @dev PUBLIC FACING: Calculates stake payouts for a given stake
   * @param _stakeShares param of stake to calculate bonuses for
   * @param _lockTime param of stake to calculate bonuses for
   * @param _endTime param of stake to calculate bonuses for
   * @return payout amount
   */
  function calculatePayout(
    uint256 _stakeShares,
    uint256 _lockTime,
    uint256 _endTime
  ) public view returns (uint256) {
    uint256 _payout = 0;

    /* Calculate what period stake was opened */
    uint256 _startPeriod = timestampToPeriods(_lockTime);

    /* Calculate what period stake was closed */
    uint256 _endPeriod = timestampToPeriods(_endTime);

    /* Loop though each period and tally payout */
    for (uint256 _i = _startPeriod; _i < _endPeriod; _i++) {
      /* Calculate payout from period */
      uint256 _periodPayout = periodData[_i].payoutRoundAmount.mul(_stakeShares)
        .div(periodData[_i].totalStakeShares);

      /* Add to tally */
      _payout = _payout.add(_periodPayout);
    }

    return _payout;
  }

  /**
   * @dev PUBLIC FACING: Open a stake
   * @param _satoshis Amount of satoshi to stake
   * @param _periods Number of 10 day periods to stake
   */
  function startStake(
    uint256 _satoshis,
    uint256 _periods
  ) external {
    /* Calculate Unlock time */
    uint256 _endStakeCommitTime = block.timestamp.add(_periods.mul(oneInterestPeriod));

    /* Make sure staker has enough funds */
    require(balanceOf(msg.sender) >= _satoshis);

    /* Make sure stake is a non-zero amount */
    require(_satoshis > 0);
    
    /* ensure that unlock time is not more than max stake time set in globals */
    require(_endStakeCommitTime <= block.timestamp.add(maxStakingTime));

    /* ensure that unlock time is more than min stake time set in globals */
    require(_endStakeCommitTime >= block.timestamp.add(oneInterestPeriod));

    /* Check if log data needs to be updated */
    storeWeeklyData();
    storePeriodData();

    /* Calculate stake shares */
    uint256 _sharesModifier = _periods.mul(200).div(360);
    /* 0.55% bonus shares for each extra period staked */
    uint256 _stakeShares = _satoshis.add(_satoshis.mul(_sharesModifier).div(100));

    /* Create Stake */
    staked[msg.sender].push(
      StakeStruct(
        _satoshis, // amount
        _stakeShares, // shares
        block.timestamp, // lockTime
        _endStakeCommitTime, // endStakeCommitTime
        _periods, // periods
        true, // isInGlobalPool
        0, // timeRemovedFromGlobalPool
        0 // latePenaltyAlreadyPooled
      )
    );

    emit StartStake(
      _satoshis,
      _periods
    );

    /* Add staked coins to global stake counter */
    totalStakedCoins = totalStakedCoins.add(_satoshis);

    /* Add staked shares to global stake counter */
    totalStakeShares = totalStakeShares.add(_stakeShares);

    /* Transfer staked coins to contract */
    _transfer(msg.sender, this, _satoshis);
  }

  /**
   * @dev PUBLIC FACING: Caluclates penalty for claiming late
   * and adds penalty to payout pool
   * @param _endStakeCommitTime param of stake
   * @param _timeRemovedFromGlobalPool param of stake
   * @param _payout param of stake
   * @return penalty amount
   */
  function calculateLatePenalty(
    uint256 _endStakeCommitTime,
    uint256 _timeRemovedFromGlobalPool,
    uint256 _payout
  ) public pure returns (uint256) {
    uint256 _penalty = 0;

    if (_timeRemovedFromGlobalPool.add(20 days) > _endStakeCommitTime) {
      /* Calculate penalty percent, 2 grace periods, then penalise 1% per period */
      uint256 _penaltyPercent = differenceInPeriods(_endStakeCommitTime, _timeRemovedFromGlobalPool.sub(10 days));
      /* Since solidity rounds down in differenceInPeriods(),
      subtracting 10 days gives 20 day grace period */

      /* Calculate penalty */
      _penalty = _payout.mul(_penaltyPercent).div(100);
    }

    /* No negative balances from penalty */
    if (_penalty > _payout) {
      _penalty = _payout;
    }

    return _penalty;
  }

  /**
   * @dev PUBLIC FACING: Calculates penalty for early unstake
   * @param _endStakeCommitTime param of stake
   * @param _periods param of stake
   * @param _payout calculated for share
   * @param _lockTime param of stake
   * @param _amount param of stake
   * @param _shares param of stake
   * @return penalty amount
   */
  function calculateEarlyPenalty(
    uint256 _endStakeCommitTime,
    uint256 _periods,
    uint256 _payout,
    uint256 _lockTime,
    uint256 _amount,
    uint256 _shares
  ) public view returns (uint256) {
    uint256 _penalty = 0;

    if (block.timestamp < _endStakeCommitTime) {
      /* Calculate periods to penalise for early unstaking */
      uint256 _penaltyPeriods = _periods.div(2);

      /* Round odd periods penalty up */
      if (_penaltyPeriods.mul(2) != _periods) {
        _penaltyPeriods++;
      }

      /* Minimum 9 periods penalty */
      if (_penaltyPeriods < 9) {
        _penaltyPeriods = 9;
      }

      uint256 _penaltyStart;
      uint256 _penaltyEnd;

      /* Check if not enough periods have been served for penalty */
      if (_penaltyPeriods > differenceInPeriods(_lockTime, block.timestamp)) {
        /* If penalty periods is longer than served stake,
        use average of periods that do have to up-fill */
        _penaltyStart = timestampToPeriods(_lockTime);
        _penaltyEnd = timestampToPeriods(block.timestamp);

        /* Calculate penalty amount */
        _penalty = calculatePayout(
          _shares,
          _penaltyStart,
          _penaltyEnd
        ).add(calculateWeAreAllSatoshiRewards(
          _amount,
          _penaltyStart,
          _penaltyEnd
        )).div(
          _penaltyEnd.sub(_penaltyStart).add(1) // Add one since most recent period is also used
        ).mul(_penaltyPeriods);
      } else {
        /* If penalty periods is shorter than served stake,
        use periods at start of stake to calculate penalty */
        _penaltyStart = timestampToPeriods(_lockTime);
        _penaltyEnd = _penaltyStart.add(_penaltyPeriods);

        /* Calculate penalty amount */
        _penalty = calculatePayout(
          _shares,
          _penaltyStart,
          _penaltyEnd
        ).add(calculateWeAreAllSatoshiRewards(
          _amount,
          _penaltyStart,
          _penaltyEnd
        ));
      }
    }

    /* No negative balances from penalty */
    if (_penalty > _payout) {
      _penalty = _payout;
    }

    return _penalty;
  }

  /**
   * @dev PUBLIC FACING: Removes completed stake from global pool
   * and adds penalty to payout pool
   * @param _staker Address of staker
   * @param _stakeIndex Index of stake
   */
  function goodAccounting(
    address _staker,
    uint256 _stakeIndex
  ) external {
    /* Stake must be matured */
    require(block.timestamp > staked[_staker][_stakeIndex].endStakeCommitTime);

    /* Check if log data needs to be updated */
    storeWeeklyData();
    storePeriodData();

    /* If stake is in global pool, remove it */
    if (staked[_staker][_stakeIndex].isInGlobalPool) {
      /* Remove staked coins from global stake coin counter */
      totalStakedCoins = totalStakedCoins.sub(staked[_staker][_stakeIndex].amount);

      /* Remove staked shares from global stake share counter */
      totalStakeShares = totalStakeShares.sub(staked[_staker][_stakeIndex].shares);

      /* Log time stake is removed from global pool */
      staked[_staker][_stakeIndex].timeRemovedFromGlobalPool = block.timestamp;

      /* Mark stake as being removed from global pool */
      staked[_staker][_stakeIndex].isInGlobalPool = false;

      emit GoodAccounting(
        staked[_staker][_stakeIndex].shares,
        staked[_staker][_stakeIndex].endStakeCommitTime
      );
    }

    /* Calculate what payout would be for stake */
    uint256 _payout = calculatePayout(
      staked[_staker][_stakeIndex].shares,
      staked[_staker][_stakeIndex].lockTime,
      staked[_staker][_stakeIndex].endStakeCommitTime
    ).add(calculateWeAreAllSatoshiRewards(
      staked[_staker][_stakeIndex].amount,
      staked[_staker][_stakeIndex].lockTime,
      staked[_staker][_stakeIndex].endStakeCommitTime
    )).add(staked[_staker][_stakeIndex].amount);

    /* Calculate late penlaty */
    uint256 _penalty = calculateLatePenalty(
      staked[_staker][_stakeIndex].endStakeCommitTime,
      staked[_staker][_stakeIndex].timeRemovedFromGlobalPool,
      _payout
    );

    /* Don't payout penalty amount that has already been paid out */
    _penalty = _penalty.sub(staked[_staker][_stakeIndex].latePenaltyAlreadyPooled);

    /* Split penalty 50/50 with origin and emergencyAndLateUnstakePool */
    emergencyAndLateUnstakePool = emergencyAndLateUnstakePool.add(_penalty.div(2));
    _transfer(this, origin, _penalty.div(2));

    /* Log penalty amount already paid out */
    staked[_staker][_stakeIndex].latePenaltyAlreadyPooled = 
      staked[_staker][_stakeIndex].latePenaltyAlreadyPooled.add(_penalty);
  }

  /**
   * @dev PUBLIC FACING: Closes a stake
   * @notice SafeMath prevents any cases where these calculations go below 0,
   * effectively disabling emergency unstaking for these cases
   * @param _stakeIndex Index of stake to close
   */
  function endStake(
    uint256 _stakeIndex
  ) external {
    /* Get stake */
    StakeStruct memory _stake = staked[msg.sender][_stakeIndex];

    /* Check if log data needs to be updated */
    storeWeeklyData();
    storePeriodData();

    uint256 _endTime = block.timestamp > _stake.endStakeCommitTime ? _stake.endStakeCommitTime : block.timestamp;
    
    /* Calculate Payout */
    uint256 _payout = calculatePayout(
      _stake.shares,
      _stake.lockTime,
      _endTime
    ).add(calculateWeAreAllSatoshiRewards(
      _stake.amount,
      _stake.lockTime,
      _endTime
    )).add(_stake.amount);

    /* Remove from global pool if needed */
    if (_stake.isInGlobalPool) {
      /* Remove staked coins from global stake coin counter */
      totalStakedCoins = totalStakedCoins.sub(_stake.amount);

      /* Remove staked shares from global stake share counter */
      totalStakeShares = totalStakeShares.sub(_stake.shares);

      /* Log time stake is removed from global pool (now, used in later math) */
      _stake.timeRemovedFromGlobalPool = block.timestamp;
    }

    /* Calculate penalties if any */
    uint256 _penalty;
    _penalty = calculateEarlyPenalty(
      _stake.endStakeCommitTime,
      _stake.periods,
      _payout,
      _stake.lockTime,
      _stake.amount,
      _stake.shares
    );
    _penalty = calculateLatePenalty(
      _stake.endStakeCommitTime,
      _stake.timeRemovedFromGlobalPool,
      _payout
    );

    /* Don't payout penalty amount that has already been paid out
       this will be 0 unless late unless good accounting has been called with late penalty */
    _penalty = _penalty.sub(_stake.latePenaltyAlreadyPooled);

    /* Split penalty 50/50 with origin and emergencyAndLateUnstakePool */
    emergencyAndLateUnstakePool = emergencyAndLateUnstakePool.add(_penalty.div(2));
    _transfer(this, origin, _penalty.div(2));

    /* Remove penalty from this stake's payout */
    _payout = _payout.sub(_penalty);

    /* Calculate periods served */
    uint256 _periodsServed = block.timestamp < _stake.endStakeCommitTime ? differenceInPeriods(_stake.lockTime, block.timestamp) : _stake.periods;

    emit EndStake(
      _stake.amount,
      _payout,
      _periodsServed,
      _penalty,
      _stake.shares,
      _stake.periods
    );

    /* Payout staked coins from contract */
    _transfer(this, msg.sender, _payout);

    /* Remove stake */
    removeStake(msg.sender, _stakeIndex);
  }
}
