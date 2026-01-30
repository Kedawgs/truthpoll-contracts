# Truth Poll Smart Contracts

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.20-blue.svg)](https://soliditylang.org/)
[![OpenZeppelin](https://img.shields.io/badge/OpenZeppelin-5.4.0-blue.svg)](https://openzeppelin.com/contracts/)
[![Polygon](https://img.shields.io/badge/Network-Polygon-purple.svg)](https://polygon.technology/)

Secure, gas-efficient smart contracts for incentivized polling with KYC verification on Polygon.

## Overview

Truth Poll enables verified users to participate in polls and receive instant USDC rewards. The contracts implement:

- **Sybil resistance** via on-chain KYC attestations
- **Instant rewards** - USDC distributed immediately upon voting
- **Progressive pricing** - Lower fees at scale
- **Emergency controls** - Pausable with timelocked admin functions

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         PollFactory                              │
│  - Deploys Poll contracts via CREATE2                           │
│  - Collects platform fees (tiered pricing)                      │
│  - Manages trusted relayer for gasless voting                   │
└─────────────────────┬───────────────────────────────────────────┘
                      │ creates
                      ▼
┌─────────────────────────────────────────────────────────────────┐
│                            Poll                                  │
│  - Holds USDC rewards pool                                      │
│  - Distributes rewards on vote                                  │
│  - Tracks votes per choice                                      │
│  - Supports EIP-2612 permit for gasless UX                      │
└─────────────────────┬───────────────────────────────────────────┘
                      │ checks
                      ▼
┌─────────────────────────────────────────────────────────────────┐
│                      VeriffAttester                              │
│  - Stores KYC attestations on-chain                             │
│  - Revokable with audit trail                                   │
│  - Privacy-safe verification commitments                        │
└─────────────────────────────────────────────────────────────────┘
```

## Contracts

| Contract | Description |
|----------|-------------|
| [`VeriffAttester.sol`](contracts/VeriffAttester.sol) | On-chain KYC attestation registry |
| [`PollFactory.sol`](contracts/PollFactory.sol) | Factory for deploying polls with tiered fees |
| [`Poll.sol`](contracts/Poll.sol) | Individual poll with instant USDC rewards |
| [`Timelocked.sol`](contracts/base/Timelocked.sol) | Base contract for 24-hour admin timelocks |

## Fee Structure

Progressive pricing based on maximum votes:

| Votes | Fee per Vote | Example: 100 votes |
|-------|--------------|-------------------|
| 1-10 | $0.10 | $1.00 (first 10) |
| 11-100 | $0.05 | + $4.50 (next 90) |
| 101-1000 | $0.02 | - |
| 1001+ | $0.01 | - |

**Total for 100 votes: $5.50** (not $10.00 flat rate)

## Quick Start

### Prerequisites

- Node.js 18+
- npm or yarn

### Installation

```bash
git clone https://github.com/Kedawgs/truthpoll-contracts.git
cd truthpoll-contracts
npm install
```

### Configuration

```bash
cp .env.example .env
```

Edit `.env` with your values:

```env
POLYGON_RPC_URL=https://polygon-mainnet.g.alchemy.com/v2/YOUR_KEY
PRIVATE_KEY=your_deployer_private_key
POLYGONSCAN_API_KEY=your_api_key
```

### Compile

```bash
npm run compile
```

### Test

```bash
npm test

# With gas reporting
REPORT_GAS=true npm test

# With coverage
npx hardhat coverage
```

## Deployment

### Deploy to Polygon Mainnet

```bash
npx hardhat run scripts/deploy.ts --network polygon
```

### Verify on Polygonscan

```bash
npx hardhat verify --network polygon <VERIFF_ATTESTER_ADDRESS> "<BACKEND_ATTESTER>"
npx hardhat verify --network polygon <POLL_FACTORY_ADDRESS> "<USDC>" "<VERIFF_ATTESTER>" "<TREASURY>"
```

## Security

### Implemented Protections

| Protection | Implementation |
|------------|----------------|
| Reentrancy | OpenZeppelin `ReentrancyGuard` on all external calls |
| Overflow | Solidity 0.8.20 built-in checks |
| Access Control | `Ownable` + custom `onlyAuthorized` modifiers |
| Safe Transfers | `SafeERC20` for all USDC operations |
| Emergency Stop | `Pausable` with instant pause, unpause |
| Admin Timelock | 24-hour delay on treasury/relayer changes |
| CEI Pattern | Checks-Effects-Interactions throughout |

### What We Don't Use (By Design)

- No `tx.origin` authentication
- No `delegatecall`
- No unbounded loops (max 200 batch size, 2-10 choices)
- No external contract calls in constructors

### Audit Status

These contracts have not been formally audited. Use at your own risk.

If you're interested in auditing these contracts, please see [SECURITY.md](SECURITY.md).

## Deployed Addresses

### Polygon Mainnet

| Contract | Address |
|----------|---------|
| VeriffAttester | [`0x430cb575B7E83203BFecaA353A5A42fAD7734078`](https://polygonscan.com/address/0x430cb575B7E83203BFecaA353A5A42fAD7734078) |
| PollFactory | [`0xfde6B7453003a0220882baB1bBFd08A9a2b23C20`](https://polygonscan.com/address/0xfde6B7453003a0220882baB1bBFd08A9a2b23C20) |
| USDC (Native) | [`0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359`](https://polygonscan.com/address/0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359) |

## Development

### Project Structure

```
├── contracts/
│   ├── base/
│   │   └── Timelocked.sol      # Timelock base contract
│   ├── interfaces/
│   │   └── IVeriffAttester.sol # Interface for attestation checks
│   ├── mocks/
│   │   └── MockERC20.sol       # Test token
│   ├── Poll.sol                # Individual poll contract
│   ├── PollFactory.sol         # Factory with tiered fees
│   └── VeriffAttester.sol      # KYC attestation registry
├── scripts/
│   ├── deploy.ts               # Main deployment script
│   └── ...                     # Utility scripts
├── test/
│   ├── PollFactory.calculateFee.test.ts
│   ├── Timelocked.test.ts
│   └── VeriffAttester.test.ts
├── hardhat.config.ts
└── package.json
```

### Running Local Node

```bash
# Start local node with Polygon mainnet fork
npx hardhat node

# In another terminal, deploy to local
npx hardhat run scripts/deploy.ts --network localhost
```

### Gas Optimization

The contracts are optimized with:
- Solidity optimizer (200 runs)
- `viaIR` compilation pipeline
- Minimal storage operations
- Batch operations where applicable

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

MIT License - see [LICENSE](LICENSE) for details.

## Links

- [Truth Poll Website](https://truthpoll.com)
- [Documentation](https://docs.truthpoll.com)
- [Security Policy](SECURITY.md)
