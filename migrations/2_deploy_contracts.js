const fs = require('fs');
const BitcoinHEX = artifacts.require('BitcoinHEX')

const merkleTreeJson = require('../test_utxo_set/merkleTree.json');
const utxoListJson = require('../test_utxo_set/utxo.json');

function writeJsonFile(path, json) {
  fs.writeFileSync(path, JSON.stringify(json, null, 2), { flag: 'w' });
}

module.exports = function(deployer, network, accounts) {
  const _originAddress = accounts[0];
  const _rootUTXOMerkleTreeHash = merkleTreeJson.root;
  const _maximumRedeemable = utxoListJson.reduce((total, utxo) => (total += utxo.satoshis), 0);
  const _UTXOCountAtFork = utxoListJson.length;

  deployer.deploy(
    BitcoinHEX,
    _originAddress, _rootUTXOMerkleTreeHash, _maximumRedeemable, _UTXOCountAtFork
  ).then(() => {
    writeJsonFile('BitcoinHEX-ABI.json', BitcoinHEX.abi);
  });
}
