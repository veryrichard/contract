pragma solidity ^0.4.24;

import "./UTXOClaimValidation.sol";
import "../node_modules/openzeppelin-solidity/contracts/math/SafeMath.sol";

contract UTXORedeemableToken is UTXOClaimValidation {
  using SafeMath for uint256;
  
  /**
  * @dev Calculates speed bonus for claiming early
  * @param _satoshis Amount of UTXO in satoshis
  * @return Speed bonus amount
  */
  function getSpeedBonus(uint256 _satoshis) internal view returns (uint256) {
    uint256 hundred = 100;
    /* This math breaks after 50 weeks, claims disabled after 50 weeks, no issue */
    uint256 scalar = hundred.sub(weeksSinceLaunch().mul(2));
    return (_satoshis.sub(_satoshis.mul(scalar).div(1000)));
  }

  /**
  * @dev Returns adjusted claim amount based on weeks passed since launch
  * @param _satoshis Amount of UTXO in satoshis
  * @return Adjusted claim amount
  */
  function getLateClaimAdjustedAmount(uint256 _satoshis) internal view returns (uint256) {
    /* This math breaks after 50 weeks, claims disabled after 50 weeks, no issue */
    return _satoshis.sub(_satoshis.mul(weeksSinceLaunch().mul(2)).div(100));
  }

  /**
  * @dev PUBLIC FACING: Get post-adjustment redeem amount if claim of x satoshis redeemed
  * @param _satoshis Amount of UTXO in satoshis
  * @return 1: Adjusted claim amount; 2: Total claim bonuses
  */
  function getRedeemAmount(uint256 _satoshis) public view returns (uint256, uint256) {
    uint256 _amount = getLateClaimAdjustedAmount(_satoshis);
    uint256 _bonus = getSpeedBonus(_amount);
    return (_amount, _bonus);
  }

  /**
   * @dev Verify a UTXO proof and signature, and mark it as redeemed
   * @param _satoshis Amount of UTXO in satoshis
   * @param _proof Merkle tree proof
   * @param _claimToAddr Address within signed message
   * @param _pubKeyX First  half of uncompressed ECDSA public key to which the UTXO was sent
   * @param _pubKeyY Second half of uncompressed ECDSA public key to which the UTXO was sent
   * @param _isCompressed Whether the Bitcoin address was generated from a compressed public key
   * @param _v v parameter of ECDSA signature
   * @param _r r parameter of ECDSA signature
   * @param _s s parameter of ECDSA signature
   * @return The number of tokens redeemed, if successful
   */
  function verifyUTXOProofAndSigThenMarkRedeemed(
    uint256 _satoshis,
    bytes32[] memory _proof,
    address _claimToAddr,
    bytes32 _pubKeyX,
    bytes32 _pubKeyY,
    bool _isCompressed,
    uint8 _v,
    bytes32 _r,
    bytes32 _s
  ) internal {
    /* Calculate the UTXO Merkle leaf hash with the original UTXO BTC address. */
    bytes32 _merkleLeafHash = keccak256(
      abi.encodePacked(
        pubKeyToBitcoinAddress(_pubKeyX, _pubKeyY, _isCompressed), 
        _satoshis
      )
    );

     /* Verify that the UTXO can be redeemed. */
    require(canRedeemUTXOHash(_merkleLeafHash, _proof));

    /* Claimant must sign the Ethereum address to which they wish to remit the redeemed tokens. */
    require(
      ecdsaVerify(
        _claimToAddr, 
        _pubKeyX,
        _pubKeyY, 
        _v, 
        _r, 
        _s
      )
    );

    /* Mark the UTXO as redeemed. */
    redeemedUTXOs[_merkleLeafHash] = true;
  }  

  /**
   * @dev PUBLIC FACING: Redeem a UTXO,
   * crediting a proportional amount of tokens (if valid) to the sending address
   * @param _satoshis Amount of UTXO in satoshis
   * @param _proof Merkle tree proof
   * @param _claimToAddr The destination Eth address for the claimed BHX tokens to be sent to
   * @param _pubKeyX First  half of uncompressed ECDSA public key to which the UTXO was sent
   * @param _pubKeyY Second half of uncompressed ECDSA public key to which the UTXO was sent
   * @param _isCompressed Whether the Bitcoin address was generated from a compressed public key
   * @param _v v parameter of ECDSA signature
   * @param _r r parameter of ECDSA signature
   * @param _s s parameter of ECDSA signature
   * @param _referrer (optional, send 0x0 for no referrer) addresss of referring persons
   * @return The number of tokens redeemed, if successful
   */
  function redeemUTXO(
    uint256 _satoshis,
    bytes32[] memory _proof,
    address _claimToAddr,
    bytes32 _pubKeyX,
    bytes32 _pubKeyY,
    bool _isCompressed,
    uint8 _v,
    bytes32 _r,
    bytes32 _s,
    address _referrer
  ) public returns (uint256) {
    /* Disable claims after 50 weeks */
    require(isClaimsPeriod());

    verifyUTXOProofAndSigThenMarkRedeemed(
      _satoshis,
      _proof,
      _claimToAddr,
      _pubKeyX,
      _pubKeyY,
      _isCompressed,
      _v,
      _r,
      _s
    );

    /* Check if log data needs to be updated */
    storeWeeklyData();
    storePeriodData();

    /* Sanity check. */
    require(totalRedeemed.add(_satoshis) <= maximumRedeemable);

    /* Track total redeemed tokens. This needs to be logged before scaling */
    totalRedeemed = totalRedeemed.add(_satoshis);

    /* Fetch value of claim */
    (uint256 _tokensRedeemed, uint256 _bonuses) = getRedeemAmount(_satoshis);

    /* Claim coins from contract balance */
    _transfer(this, _claimToAddr, _tokensRedeemed);

    /* Award bonuses to redeemer and origin. */ 
    _mint(_claimToAddr, _bonuses);
    _mint(origin, _bonuses);

    /* Increment Redeem Count to track viral rewards */
    redeemedCount = redeemedCount.add(1);

    bool _wasReferred = _referrer != address(0);

    /* Check if non-zero referral address has been passed */
    if (_wasReferred) {
      /* Credit referrer and origin */
      _mint(_referrer, _tokensRedeemed.div(20));
      _mint(origin, _tokensRedeemed.div(20));
    }

    emit Claim(
      _satoshis,
      _tokensRedeemed.add(_bonuses),
      _wasReferred
    );
    
    /* Return the number of tokens redeemed. */
    return _tokensRedeemed.add(_bonuses);
  }
}