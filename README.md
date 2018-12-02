# BitcoinHEX

## Contracts
Please see the [contracts/](contracts) directory.

## Develop
Contracts are written in Solidity. Currently using Truffle, but this will likely be replaced later. Library contracts sourced from OpenZeppelin.org.

### Dependencies

#### secrets.json
This file is **NOT** checked in. You will need to supply a secrets.json that includes a private key, and a URL for the JSON-RPC endpoint.

Sample format:
```
{
  "kovan": {
    "privateKeys": [
      "ABCD123456789012345678901234567890123456789012345678901234567890"
    ],
    "url": "http://example.com:8545"
  }
}
```

### Installation
```bash
npm install
```

### Compilation
```bash
npm run compile
```
