pragma solidity ^0.4.24;

import "./GlobalsAndUtility.sol";
import "../node_modules/openzeppelin-solidity/contracts/cryptography/MerkleProof.sol";

contract UTXOClaimValidation is GlobalsAndUtility {
  /**
   * @dev Takes an ethereum address and converts it to a hex string
   * @param _addr Address to convert
   * @return Hex string of address
   */
  function addressToString(address _addr) public pure returns(bytes25, bytes23, bytes) {
    bytes20 addrBytes = bytes20(_addr);
    bytes16 hexDigits = "0123456789abcdef";
    bytes25 prefix1 = bytes25("\x18Bitcoin Signed Message:\n");
    bytes23 prefix2 = bytes23("\x3EClaim_BitcoinHEX_to_0x");
    bytes memory addrHex = new bytes(40);    
    uint offset = 0;
    
    for (uint i = 0; i < 20; i++) {
        addrHex[offset++] = hexDigits[uint(addrBytes[i] >> 4)];
        addrHex[offset++] = hexDigits[uint(addrBytes[i] & 0x0f)];
    }
    return (prefix1, prefix2, addrHex);
  }

  /**
   * @dev Validate that a provided ECSDA signature was signed by the specified address
   * @param _hash Hash of signed data
   * @param _v v parameter of ECDSA signature
   * @param _r r parameter of ECDSA signature
   * @param _s s parameter of ECDSA signature
   * @param _expected Address claiming to have created this signature
   * @return Whether or not the signature was valid
   */
  function validateSignature(
    bytes32 _hash,
    uint8 _v,
    bytes32 _r,
    bytes32 _s,
    address _expected
  ) public pure returns (bool) {
    return ecrecover(
      _hash, 
      _v, 
      _r, 
      _s
    ) == _expected;
  }

  /**
   * @dev Validate that the hash of a provided address was signed by the
   * ECDSA public key associated with the specified Ethereum address
   * @param _claimToAddr Address within signed message
   * @param _pubKeyX First  half of uncompressed ECDSA public key claiming to have created this signature
   * @param _pubKeyY Second half of uncompressed ECDSA public key claiming to have created this signature
   * @param _v v parameter of ECDSA signature
   * @param _r r parameter of ECDSA signature
   * @param _s s parameter of ECDSA signature
   * @return Whether or not the signature was valid
   */
  function ecdsaVerify(
    address _claimToAddr, 
    bytes32 _pubKeyX,
    bytes32 _pubKeyY,
    uint8 _v, 
    bytes32 _r, 
    bytes32 _s
  ) public pure returns (bool) {
    /* Check hex string for match */
    (bytes25 prefix1, bytes23 prefix2, bytes memory addrHex) = addressToString(_claimToAddr);
    return validateSignature(
      sha256(abi.encodePacked(sha256(abi.encodePacked(prefix1, prefix2, addrHex)))),  // hash
      _v, 
      _r, 
      _s, 
      pubKeyToEthereumAddress(_pubKeyX, _pubKeyY) // expected
    );
  }

  /**
   * @dev Convert an uncompressed ECDSA public key into an Ethereum address
   * @param _pubKeyX First  half of uncompressed ECDSA public key to convert
   * @param _pubKeyY Second half of uncompressed ECDSA public key to convert
   * @return Ethereum address generated from the ECDSA public key
   */
  function pubKeyToEthereumAddress(
    bytes32 _pubKeyX,
    bytes32 _pubKeyY
  ) public pure returns (address) {
    return address(uint160(keccak256(abi.encodePacked(_pubKeyX, _pubKeyY))));
  }

  /**
   * @dev Calculate the Bitcoin-style address associated with an ECDSA public key
   * @param _pubKeyX First  half of uncompressed ECDSA public key to convert
   * @param _pubKeyY Second half of uncompressed ECDSA public key to convert
   * @param _isCompressed Whether or not the Bitcoin address was generated from a compressed key
   * @return Raw Bitcoin address (no base58-check encoding)
   */
  function pubKeyToBitcoinAddress(
    bytes32 _pubKeyX,
    bytes32 _pubKeyY,
    bool _isCompressed
  ) public pure returns (bytes20) {
    /* Helpful references:
       - https://en.bitcoin.it/wiki/Technical_background_of_version_1_Bitcoin_addresses 
       - https://github.com/cryptocoinjs/ecurve/blob/master/lib/point.js
    */

    uint8 _startingByte;
    if (_isCompressed) {
      /* Hash the compressed public key format. */
      _startingByte = (_pubKeyY & 1) == 0 ? 0x02 : 0x03;
      return ripemd160(
        abi.encodePacked(sha256(abi.encodePacked(_startingByte, _pubKeyX)))
      );
    } else {
      /* Hash the uncompressed public key format. */
      _startingByte = 0x04;
      return ripemd160(
        abi.encodePacked(sha256(abi.encodePacked(_startingByte, _pubKeyX, _pubKeyY)))
      );
    }
  }

  /**
   * @dev Verify a Merkle proof using the UTXO Merkle tree
   * @param _proof Generated Merkle tree proof
   * @param _merkleLeafHash Hash asserted to be present in the Merkle tree
   * @return Whether or not the proof is valid
   */
  function verifyProof(
    bytes32[] memory _proof, 
    bytes32 _merkleLeafHash
  ) public view returns (bool) {
    return MerkleProof.verify(_proof, rootUTXOMerkleTreeHash, _merkleLeafHash);
  }

  /**
   * @dev PUBLIC FACING: Verify that a UTXO with the specified Merkle leaf hash can be redeemed
   * @param _merkleLeafHash Merkle tree hash of the UTXO to be checked
   * @param _proof Merkle tree proof
   * @return Whether or not the UTXO with the specified hash can be redeemed
   */
  function canRedeemUTXOHash(
    bytes32 _merkleLeafHash, 
    bytes32[] memory _proof
  ) public view returns (bool) {
    /* Check that the UTXO has not yet been redeemed and that it exists in the Merkle tree. */
    return(
      (redeemedUTXOs[_merkleLeafHash] == false) && 
      verifyProof(_proof, _merkleLeafHash)
    );
  }

  /**
   * @dev PUBLIC FACING: Convenience helper function to check if a UTXO can be redeemed
   * @param _originalAddress Raw Bitcoin address (no base58-check encoding)
   * @param _satoshis Amount of UTXO in satoshis
   * @param _proof Merkle tree proof
   * @return Whether or not the UTXO can be redeemed
   */
  function canRedeemUTXO(
    bytes20 _originalAddress,
    uint256 _satoshis,
    bytes32[] memory _proof
  ) public view returns (bool) {
    /* Calculate the hash of the Merkle leaf associated with this UTXO. */
    bytes32 merkleLeafHash = keccak256(
      abi.encodePacked(
        _originalAddress, 
        _satoshis
      )
    );
  
    /* Verify the proof. */
    return canRedeemUTXOHash(merkleLeafHash, _proof);
  }
}