pragma solidity ^0.4.24;

import "./StakeableToken.sol";

contract BitcoinHEX is StakeableToken {
  constructor (
    address _originAddress,
    bytes32 _rootUTXOMerkleTreeHash,
    uint256 _maximumRedeemable,
    uint256 _UTXOCountAtFork
  ) public {
    launchTime = block.timestamp;
    origin = _originAddress;
    rootUTXOMerkleTreeHash = _rootUTXOMerkleTreeHash;
    maximumRedeemable = _maximumRedeemable;
    UTXOCountAtFork = _UTXOCountAtFork;
    /* Add all claimable coins to contract */
    _mint(this, maximumRedeemable);
  }
}
