## Dyson Migration

Vault-style swap contract for migrating the old Dyson token to the new Dyson token at a fixed rate within a defined time window. The contract never mints; it only takes in old tokens and sends out pre-funded new tokens. After the window ends, the owner can withdraw any remaining old or new tokens.

### Contract

- Main file: `src/DysonMigration.sol`
- Immutable parameters: `owner`, `oldToken`, `newToken`, rate numerator/denominator, `startTime`, `endTime`
- Events: `Swapped(user, oldAmount, newAmount)`, `WithdrawOld(amount)`, `WithdrawNew(amount)`
- Safety: built-in `nonReentrant`; no cross-chain or minting logic

### Testing

```bash
forge test
```

Coverage focus: time window enforcement, rate calculation, no-liquidity revert, post-deadline owner withdrawals, and reentrancy protection.

### Deployment

Constructor parameters:
```
DysonMigration(
  address owner,
  address oldToken,
  address newToken,
  uint256 rateNumerator,   // e.g. 1
  uint256 rateDenominator, // e.g. 1
  uint256 startTime,
  uint256 endTime
)
```

After deployment, pre-fund the contract with new Dyson tokens for swaps. Once the migration window ends, the owner may withdraw leftover old/new tokens as needed.
