/* eslint-disable import/no-unassigned-import */
// Truffle requires babel-register for import in tests. https://github.com/trufflesuite/truffle/issues/664
require('babel-register')
require('babel-polyfill')
const assert = require('assert')

const HDWalletProvider = require('truffle-hdwallet-provider');
const secrets = require('./secrets.json');

function createWalletProviderForNet() {
  const networks = module.exports.networks;
  const name = Object.keys(networks).find(k => networks[k].network_id === this.network_id);
  const config = secrets[name];
  
  assert(config, `Network "${name}" not found in "secrets.json"`);
  assert(config.privateKeys && config.privateKeys.length, `Missing "privateKeys" from network "${name}" in "secrets.json"`);
  assert(config.url, `Missing "url" from network "${name}" in "secrets.json"`);
  
  return new HDWalletProvider(config.privateKeys, config.url);
}

module.exports = {
  networks: {
    dev: {
      host: 'localhost',
      port: 8545,
      network_id: '*'
    },
    kovan: {
      provider: createWalletProviderForNet,
      network_id: 42
    },
  },
  mocha: {
    timeout: 600000,
    reporter: process.env.GAS_REPORTER ? 'eth-gas-reporter' : 'spec',
    reporterOptions: {
      currency: 'USD',
      gasPrice: 21
    }
  }
}
