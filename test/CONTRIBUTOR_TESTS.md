# Additional contract tests

These tests extend the accepted implementation's suite. They require only the already
vendored Foundry and OpenZeppelin dependencies, with no network, forks, FFI, or shared
environment mutation.

| File | Added coverage |
| --- | --- |
| `JobZeroPaymentBoundary.t.sol` | Exact one-unit balance and allowance shortfalls for open, handoff, and queue entry; 1,000 fuzzed underpayments; complete observable-state rollback and retry with exact payment. |
| `JobZeroAdversarial.t.sol` | Incoming payment succeeds, then outgoing burn or payout moves tokens and returns false; queue links, attempts, allowances, entitlement, and balances must all roll back. Includes settlement with nonzero rounding dust. |
| `JobZeroInvariant.t.sol` | Extends the participation/payment ledger with individual wallet debits, assignment and queue timestamps, closed-run fees, record maxima, and invalid transitions interleaved with successful actions. |
| `LaunchTokenBoundary.t.sol` | Zero, one unit, full supply, maximum integer, self-transfers, finite/infinite approvals, revocation, overwrite, invalid recipients, and 1,000 fuzzed balance failures that must restore allowances. |
| `LaunchTokenInvariant.t.sol` | Four-actor ledger for transfers, delegated transfers, approvals, and burn-address transfers, including expected failures. Every balance and allowance is checked against the ledger, along with fixed supply. |

Both invariant suites set 256 runs and depth 96 in Solidity inline configuration,
with unexpected handler reverts treated as failures. JobZero's initial sequence
creates a historical claim and an active run so cross-run checks start with useful
state. Successful operations update ghost records using their inputs and call
timestamps; JobZero's deadline views do not determine the model's deadlines.

JobZero's invariant teardown closes the remaining run and claims every unpaid share.
It then checks individual balances and history again, and requires zero liabilities
with only unsolicited donations left in custody. This checks payout liveness as well
as conservation. The ERC-20 model tracks all supply, including transfers to the
specified burn address; those transfers must not reduce `totalSupply`.

Run from the repository root:

```sh
forge build
forge test
```

For local checks whose build artifacts must also stay under the test directory:

```sh
forge build --out test/scratch/out --cache-path test/scratch/cache
forge test --out test/scratch/out --cache-path test/scratch/cache
```

The adversarial token is a test double for transfer failure and reentrancy handling.
It does not broaden the application's supported asset model beyond the standard
fixed-supply launch token.
