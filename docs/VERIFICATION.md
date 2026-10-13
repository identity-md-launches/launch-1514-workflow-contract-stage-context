# Builder verification and review notes

This is the implementation contributor's test record and source review, **not an independent audit or launch approval**. The separate independent reviewer must inspect the accepted source and generated manifest, including the owner argument and any concrete policy/authorization conflicts. Signed artifacts and service policy linkage are supplied by the launch services.

## Reproducible checks

```sh
forge build
forge test
forge fmt --check
python3 scripts/export_abi.py --check
```

The build uses Solidity **0.8.26** with the committed root configuration. Tests use local deployments and synthetic actors, with no RPC, fork, environment reads/writes, filesystem access, signing keys, or broadcasts. All dependencies needed for the offline build are delivered in `lib/`, with their licenses and archive SHA-256 hashes. The deployable sources are only `src/LaunchToken.sol` and `src/JobZero.sol`; helper/mock contracts under `test/` are not deployment targets.

The full suite consists of **43 unit/fuzz tests plus a stateful invariant suite containing three invariants**. The default fuzz count is 256 per fuzz test; the invariant profile runs 128 sequences at depth 64, totaling 8,192 handler calls. Foundry 1.8.3 groups the three invariant checks into one reported suite test. At each randomized step the suite checks the state against a separate participation/payment ledger; its `afterInvariant` hook closes the remaining run and claims every eligible share to confirm that all accounted funds can exit without an administrator.

| Area | Meaningful success and failure coverage |
| --- | --- |
| Launch token | Exact name/symbol/18 decimals/`10**27` supply, factory receives all supply, exact fuzzed transfers, allowance consumption, insufficient balance/allowance, zero recipient, unavailable mint/admin selectors, ETH rejection. |
| Deployment floor | Actual CREATE2 deployments; explicit application owner; no token configured in constructor; factory balance and supply preserved; both runtimes present and below EIP-170; instruction-aware scan rejects DELEGATECALL, CALLCODE, SELFDESTRUCT. |
| Setup | All gameplay actions fail before token configuration; only owner sets token; locked after one set; zero, EOA, self, missing metadata, and incorrect decimals rejected. |
| Runs/handoffs | Open fee custody, one open run, only worker, no zero/self/repeat recipient, fee growth and rounding, fresh deadline, timestamps/statuses, failed deposits fully roll back, new-run eligibility resets. |
| Settlement/claims | Last-second handoff, exact-deadline timeout, early timeout and expired handoff rejection, late timeout record semantics, failed worker excluded, equal shares, double/early/outsider claim rejection, dust and solo burns, claims across simultaneous old/new liabilities. |
| Queue | Join fee burn, eligibility and one lifetime join, offline without refund, oldest/middle/newest removal, automatic removal, failed handoff restores membership, expiry/closure behavior, historical eligibility, pagination boundaries including 100-entry pages. |
| Transfers/callbacks | No-return ERC-20 transfers supported; false return and transfer failures revert; taxed inbound transfers rejected; failed burn restores handoff/queue/stats; failed solo settlement can retry; failed claim retains entitlement and does not prevent another worker's claim. |
| Reentrancy | Every mutator attempted from a token callback; callbacks on open, queue payment/burn, handoff payment/burn, timeout burn, and payout rejected. A callback token itself participates as an eligible claimant to check double-payment protection without relying on identity rejection. |
| Accounting/records | Fuzzed 1–120 handoffs with independent fee/split calculations, exact burn/bounty balances, all shares paid, fixed supply, donated tokens excluded, no admin withdrawal, longest-run record and live cap, wallet lifetime totals. |
| Stateful sequences | Interleaved opens, handoffs, joins, leaves, time advances, timeouts, donations and claims; exact liabilities, conservation, claim eligibility, stats, reverse queue order, and final exit of all obligations. |

With the pinned production settings, runtime sizes are **1,722 bytes for LaunchToken** and **8,286 bytes for JobZero**, below 24,576 bytes. Initcode sizes are 2,603 and 8,461 bytes respectively. There are no unresolved library links. ABI exports are checked against `forge inspect` results.

The supplied protected checks were read as the deployment/token baseline. Their service environment-dependent harnesses were not altered, run with fabricated launch environment values, or imported into the delivered test suite. `Deployment.t.sol` and `LaunchToken.t.sol` exercise the corresponding local properties without needing the later manifest, attestation, or service environment. The independent verifier supplies and executes its own protected harness after this contribution.

## Source review observations

- **Authority:** `owner` is immutable and supplied explicitly. `setToken` is the only owner action. No factory or origin privileges, token mint path, rescue, withdrawal, cancellation, pause, proxy, or upgrade path exist.
- **Custody:** only fees received through normal methods create liabilities. Handoff accounting retains `fee - floor(fee/2)`; timeout reserves `share * recipients` and burns the remainder. Claims reduce both the obligation and balance by their exact share. Closed-run claims are not affected by subsequent runs.
- **External interactions:** OpenZeppelin SafeERC20 handles optional transfer returns. Every state-changing entry point has a reentrancy guard; gameplay effects precede token interactions. An exact incoming balance delta rejects common transfer-tax behavior. This does not authenticate a malicious token or support rebasing/taxed outbound behavior.
- **Liveness:** timeout and claims have no participant-sized loop. Queue removal is constant-time. Queue reads cost `O(start+count)` over active nodes, and returned pages are at most 100 entries. Unclaimed funds never expire, so a lost beneficiary key can leave its own share held indefinitely without blocking other workers.
- **Time:** handoff/join require `timestamp < deadline`; timeout requires `timestamp >= deadline`. Failure duration is capped at the deadline regardless of timeout delay. Timestamp dependence is intentional and does not provide randomness. Transaction inclusion before a deadline is the worker's responsibility.
- **Queue scope:** one lifetime join per wallet per run, only in a live unexpired run. Queue membership is optional for receiving the job. Closure invalidates remaining entries logically, avoiding unbounded cleanup. Consumers must process `TimedOut` accordingly.
- **Identity/economics:** eligibility is per address, not per human. A caller can use multiple addresses; any fresh nonzero address can be assigned the job without consent. No economic return, anti-sybil property, or protection from malicious recipient selection is claimed.
- **Rounding:** fee growth rounds down each time, an odd handoff minor unit remains in the bounty, and payout dust is burned to maintain equal claims. These explicit interpretations are in the README for review.

Foundry's built-in lint reports intentional timestamp comparisons, the exact inbound balance-delta comparison, and a queue-pointer mutation warning. The timestamp checks implement the requested deadline; equality checks a transaction-local delta rather than a global target balance; queue pointer changes are accompanied by `Offline` in the same function. These were reviewed in context. The tests use `vm.getBlockTimestamp()` around time warps to avoid optimizer assumptions about timestamp stability.

Slither, Mythril, fork/mainnet testing, live deployment, and an external security audit were **not** performed. No funds or network contracts are needed for local testing. The remaining operational actions are the separately authorized launch process, independent source/manifest review, and the owner's one-time configuration of the authentic deployed TEYO address.
