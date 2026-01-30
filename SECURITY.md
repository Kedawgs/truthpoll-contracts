# Security Policy

## Reporting a Vulnerability

**Please do NOT report security vulnerabilities through public GitHub issues.**

If you discover a security vulnerability in the Truth Poll smart contracts, please report it responsibly:

### Option 1: GitHub Security Advisory (Preferred)

1. Go to the [Security Advisories](https://github.com/Kedawgs/truthpoll-contracts/security/advisories) page
2. Click "New draft security advisory"
3. Fill in the details and submit

### Option 2: Direct Contact

Email: daniel@truthpoll.com

Include:
- Description of the vulnerability
- Steps to reproduce
- Potential impact assessment
- Suggested fix (if any)

## Response Timeline

| Stage | Timeline |
|-------|----------|
| Initial acknowledgment | 24 hours |
| Assessment and triage | 7 days |
| Fix development | 30 days |
| Public disclosure | 60 days (coordinated) |

## Scope

### In Scope

- `contracts/Poll.sol`
- `contracts/PollFactory.sol`
- `contracts/VeriffAttester.sol`
- `contracts/base/Timelocked.sol`
- Deployment scripts that could affect contract security

### Out of Scope

- Issues in dependencies (report to OpenZeppelin directly)
- Issues already reported
- Theoretical attacks without proof of concept
- Social engineering attacks
- DoS attacks requiring unrealistic gas costs

## Bug Bounty

Currently, Truth Poll does not offer a formal bug bounty program. However, we appreciate responsible disclosure and may offer recognition or rewards on a case-by-case basis for:

- Critical vulnerabilities (fund loss, unauthorized access)
- High severity issues (griefing, denial of service)

## Security Measures

### Smart Contract Security

| Category | Implementation |
|----------|----------------|
| **Reentrancy** | `ReentrancyGuard` on all external calls |
| **Overflow** | Solidity 0.8.20 built-in protection |
| **Access Control** | `Ownable` + role-based modifiers |
| **Safe Transfers** | `SafeERC20` for all token operations |
| **Emergency Stop** | `Pausable` pattern |
| **Admin Safety** | 24-hour timelock on sensitive changes |

### Known Limitations

1. **Centralized Attester**: The backend service controls attestation creation. This is intentional for KYC compliance but represents a trust assumption.

2. **Factory Owner**: Can pause the factory and propose treasury/relayer changes (with 24-hour timelock). Consider multi-sig for production.

3. **Poll Creator**: Can end polls early. Funds return to creator, not lost.

### Audit History

| Date | Auditor | Status |
|------|---------|--------|
| - | - | Not yet audited |

We welcome security researchers interested in reviewing these contracts.

## Security Checklist for Deployers

Before deploying to mainnet:

- [ ] Use hardware wallet or multi-sig for owner account
- [ ] Verify constructor arguments match intended configuration
- [ ] Test on testnet first (Polygon Amoy)
- [ ] Verify contract source on Polygonscan
- [ ] Set up monitoring for admin function calls
- [ ] Document emergency response procedures
- [ ] Secure private keys (never in code or .env files in production)

## Contact

- **Security Issues**: daniel@truthpoll.com
- **General Questions**: GitHub Discussions
- **Updates**: Follow releases for security patches
