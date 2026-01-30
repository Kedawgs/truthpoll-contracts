# Contributing to Truth Poll Contracts

Thank you for your interest in contributing to Truth Poll smart contracts!

## Ways to Contribute

- **Bug Reports**: Found an issue? Open a GitHub issue with reproduction steps
- **Security Issues**: See [SECURITY.md](SECURITY.md) - do NOT open public issues
- **Documentation**: Improvements to README, NatSpec comments, or guides
- **Test Coverage**: Additional test cases, especially edge cases
- **Gas Optimizations**: Measurable improvements with benchmarks

## Development Setup

### Prerequisites

- Node.js 18+
- Git

### Getting Started

```bash
# Clone the repository
git clone https://github.com/Kedawgs/truthpoll-contracts.git
cd truthpoll-contracts

# Install dependencies
npm install

# Copy environment template
cp .env.example .env

# Run tests
npm test
```

### Running Tests

```bash
# All tests
npm test

# Specific test file
npx hardhat test test/PollFactory.calculateFee.test.ts

# With gas reporting
REPORT_GAS=true npm test

# With coverage
npx hardhat coverage
```

## Pull Request Process

### Before Submitting

1. **Run all tests**: `npm test` must pass
2. **Check compilation**: `npm run compile` must succeed
3. **Run static analysis**: `npx hardhat compile --force`
4. **Test on local fork**: Verify against mainnet state if relevant

### PR Guidelines

1. **One feature per PR**: Keep changes focused
2. **Descriptive title**: `fix: prevent double voting` not `update Poll.sol`
3. **Include tests**: New features need test coverage
4. **Update docs**: If changing behavior, update NatSpec and README

### Commit Messages

Follow [Conventional Commits](https://www.conventionalcommits.org/):

```
feat: add batch refund function
fix: prevent reentrancy in withdraw
docs: update deployment instructions
test: add edge case for zero votes
refactor: extract fee calculation
```

## Code Style

### Solidity

- Follow [Solidity Style Guide](https://docs.soliditylang.org/en/latest/style-guide.html)
- Use NatSpec comments for all public/external functions
- Include `@custom:security-contact` in all contracts
- Prefer explicit over implicit (no magic numbers)

Example:

```solidity
/**
 * @notice Calculate platform fee for a poll
 * @dev Uses tiered pricing: $0.10 (1-10), $0.05 (11-100), $0.02 (101-1000), $0.01 (1001+)
 * @param maxVotes Maximum number of votes the poll will accept
 * @return fee Total fee in USDC (6 decimals)
 */
function calculateFee(uint256 maxVotes) public pure returns (uint256 fee) {
    // Implementation
}
```

### TypeScript (Tests/Scripts)

- Use TypeScript strict mode
- Prefer `const` over `let`
- Use descriptive test names: `"Should revert if user already voted"`

## Security Considerations

When contributing, consider:

1. **Reentrancy**: Use `nonReentrant` modifier for external calls
2. **Access Control**: Who can call this function?
3. **Input Validation**: Check all parameters
4. **Integer Overflow**: Solidity 0.8+ handles this, but be aware
5. **Gas Limits**: Avoid unbounded loops

### Security Review Checklist

Before submitting security-sensitive changes:

- [ ] No use of `tx.origin`
- [ ] No `delegatecall` to untrusted contracts
- [ ] Follows Checks-Effects-Interactions pattern
- [ ] Uses `SafeERC20` for token transfers
- [ ] Bounded loops with reasonable limits
- [ ] Access control on state-changing functions

## Questions?

- **General**: Open a GitHub Discussion
- **Bugs**: Open a GitHub Issue
- **Security**: Email security@truthpoll.com

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
