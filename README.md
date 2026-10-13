# JOB #0 — Teyo

The job no agent could finish. One worker holds JOB #0 at a time. They have 24 hours to hand it to an address that has never held it in that run. Every handoff grows the bounty; when the deadline expires, the final worker fails and every earlier worker can claim an equal share.

This contribution delivers the contracts, tests, and ABI exports for the contract implementation stage. Source publication, the separately generated and independently reviewed `launch.json`, attestation, admission, deployment, and the subsequent website/IPFS release are handled by the launch services and their assigned contributors. No transactions have been broadcast.

## Build and test

Run from the repository root:

```sh
forge build
forge test
forge fmt --check
python3 scripts/export_abi.py --check
```

`foundry.toml` pins Solidity **0.8.26**, Cancun, optimizer enabled with 200 runs, and `bytecode_hash = "none"`. There is no FFI, filesystem permission grant, external library linking, proxy, or compiler path override. Dependencies are vendored as ordinary source files: OpenZeppelin Contracts **v5.1.0** (only the required import closure) and forge-std **v1.9.7**. Their source archive hashes and licenses are in `lib/`. With Foundry and the pinned compiler installed, building and testing need no network, environment secrets, or dependency installation.

Regenerate ABI exports with `python3 scripts/export_abi.py`. See [the ABI guide](docs/ABI.md), [test and review notes](docs/VERIFICATION.md), and the machine-readable [LaunchToken](docs/abi/LaunchToken.json) and [JobZero](docs/abi/JobZero.json) ABIs.

## Deployment parameters

| Contract | Source | Constructor arguments | Configuration |
| --- | --- | --- | --- |
| `LaunchToken` | `src/LaunchToken.sol` | None | Name `Teyo`, symbol `TEYO`, 18 decimals, exactly `1000000000000000000000000000` minor units minted once to its deploying factory. |
| `JobZero` | `src/JobZero.sol` | `address owner_` | Manifest value **`$owner`**, resolving to the supplied launch owner `0xe8bff6587b2481008ae36b26599b9b9530669c35`. |

The target is **Ethereum, chain ID 1**. Deploy `LaunchToken` and `JobZero` as ordinary, nonpayable contracts. Neither constructor calls an outside contract or requires another address to have code. `JobZero` holds no launch allocation and receives TEYO only through later user payments or unsolicited transfers. Its sole privileged address is the explicit immutable `owner`; the deploying factory and `tx.origin` receive no application authority.

The launch factory handles the full token distribution: **10%** to the launch's MerkleDistributor for the swarm, **88%** to the pool, and **2%** to the paying wallet (or the chain treasury when no wallet pays). No application contract reserves, mints, or distributes this allocation. `LaunchToken` has no mint, owner, pause, fee, blocklist, or upgrade methods after construction. A transfer to the specified burn address does **not** reduce ERC-20 `totalSupply()`.

For the separate manifest contributor, the supplied pool parameters are: paired currency IMD at `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`, fee **12500 (1.25%)**, tick spacing **60**, and manifest initial price **`"79228162514264337593543950336"`**. The service derives the effective opening price from the policy's **2,500 IMD** opening market cap and actual token ordering. The factory supplies the distributor and initialization guard. Neither belongs among this contribution's application contracts. These are launch parameters, not JobZero constructor arguments or token transfer fees. Policy and signed artifact linkage belong to the services; source, constructor, and authorization conflicts remain review findings.

## After launch

The supplied owner must call **`JobZero.setToken(address)` once**, passing **this launch's deployed `LaunchToken` address from the verified deployment handoff**. `TokenSet` records the choice. This operation checks that the target has code and reports 18 decimals, then permanently locks the address. It cannot prove that a token is the authentic TEYO; the owner must compare the address and source against the deployment handoff before signing. This is the owner's only power: there is no owner transfer, renunciation, parameter change, treasury, rescue, pause, forced settlement, or withdrawal function.

Until configured, every gameplay mutation reverts with `TokenNotConfigured`. Read-only views remain available. No guessed token address or postdeployment service subscription is required. Setting the wrong token, or losing access to the owner before configuration, has no administrative recovery path.

The frontend should then display the verified chain and contract addresses, require Ethereum, request the exact TEYO allowance for each payment, submit gameplay transactions, and index the events described in the ABI guide. Anyone may submit timeout transactions when eligible; the contract does not execute itself. A timeout caller pays gas and receives no reward. Each beneficiary submits their own claim. Final source/manifest review, explorer verification, and release publication remain responsibilities of the independent review and launch services.

## Rules and documented interpretations

All amounts below use 18-decimal TEYO minor units internally; `ether` in Solidity is used only as the `10**18` multiplier. All contract functions are nonpayable and ordinary ETH transfers and unknown selectors revert.

1. **Open:** when no run is open, `open()` collects **10,000 TEYO**, puts it entirely in the new bounty, and records the caller as attempt 1. Run IDs start at 1. A run remains open after expiry until someone calls `timeout()`; another `open()` cannot bypass settlement.
2. **Handoff:** only the current worker can call `handoff(to)` at a timestamp **strictly below** their deadline. The recipient must be nonzero, different from the current worker, and absent from this run's worker history. The sender pays the whole fee. The first fee is **1,000 TEYO**, and the next is `floor(previousFee * 103 / 100)`. Half, rounded down, is transferred to `0x000000000000000000000000000000000000dEaD`; the remainder enters the bounty. Every new worker receives a deadline of the transaction timestamp plus **86,400 seconds**. The receiver pays nothing to receive the job, and queue membership or consent is not required.
3. **Timeout:** anyone can call at **`timestamp >= deadline`**. This boundary leaves no gap between handoff and timeout. The final worker is marked failed and receives no share. With `n` earlier workers, each receives `floor(bounty / n)`; the indivisible remainder, less than `n` minor units, is burned immediately. With no earlier workers, the entire bounty is burned. `bounty` remains the historical gross bounty in the run record. Settlement does not loop over participants or send their shares.
4. **Claim:** `claim(runId)` pays the caller's share once, after closure. Claims have no expiry, are independent of other claims, and remain available during later runs. No refund or cancellation path exists. `workerStats.totalEarned` counts successful claims, not pending entitlements.

Fee rounding is performed on integer minor units on every handoff. There is no fee cap, and an unaffordable handoff may lead to timeout. Burns are transfers to the explicitly requested dead address; the launch token's fixed total supply is unchanged. Accounting only credits payments collected by the contract. Direct donations do not increase a bounty or anyone's share and cannot be recovered by an administrator.

## Queue and history

`goOnline()` is available only while a run is open and unexpired, to wallets that have not held the job in that run. It collects and burns **10 TEYO**. “One entry per wallet per run” means one **lifetime join** for that run: leaving does not allow another join. `goOffline()` is free, gives no refund, and may be called after expiry while the run still awaits timeout. The worker may hand the job to an offline or never-queued address.

Receiving the job removes an online wallet immediately and emits `Offline`. Queue removal does constant work using a doubly linked list. Closure makes the whole remaining queue inactive without iterating or emitting an `Offline` per entry; indexers must handle `TimedOut` as closing that run's queue. Queue eligibility starts fresh in each new run. There is no queue before the first open or between closed and newly opened runs.

`getQueue(runId,start,count)` returns active entries newest first, including their join timestamps. Closed and unknown runs return an empty list. `getAttempts` returns all historical attempts newest first. For both, `start` is an offset into the newest-first result, `count` must be at most **100**, and zero count or an offset past the end gives an empty list. Queue reads cost `O(start + count)` over active entries, not departed entries. Use modest offsets and a fixed block tag for stable pagination while new events arrive.

`currentRun()` retains the latest ID after closure; use `isOpen()` to tell whether it is active. `worker()` and `deadline()` return zero without an open run; `handoffFee()` then returns the initial fee. `runs(id)` preserves each run's worker, deadline, times, next fee, gross bounty, share, and claim count. These zero values are read-state sentinels, not deployment inputs.

`longestRun()` reports effective duration from opening until failure at the deadline, including the elapsed part of the live run capped at its deadline. Waiting to submit timeout cannot inflate it. `closedAt` separately records the timeout transaction timestamp; the failed attempt's `endedAt` records its deadline. Ties retain the earliest run. `biggestBounty()` and `mostHandoffs()` track the maximum gross bounty and completed handoff count of a **single run**. Wallet leaderboards and the failed-worker wall can be indexed from `HandedOff`, `TimedOut`, and `Claimed`, and verified with `workerStats`.

## Custody and trust

`JobZero` holds the active bounty and all unclaimed shares. `totalLiability()` accounts for precisely these obligations; with authentic TEYO, its token balance must be at least that amount, with any excess being unsolicited donations. Every token movement uses OpenZeppelin `SafeERC20`; all external mutations use its `ReentrancyGuard`. Effects precede transfers, and failed transfers revert the entire action, including claims, statistics, queue removal, or settlement. Deposits additionally require the exact expected balance increase.

Only the fixed-supply, ordinary 18-decimal TEYO is supported. Decimal/code checks and inbound balance checks do not make malicious, rebasing, taxed, upgradeable, or blocklisting tokens safe; the one-time owner selection is a trust assumption. No external randomness or oracle is involved. Deadlines use chain timestamps and require transaction inclusion: sending a transaction near expiry does not guarantee a timely handoff. Workers are **addresses**, not verified humans. Multiple addresses controlled by one person can participate, and unsolicited handoffs can assign failure to arbitrary recipients. These are consequences of the approved rules, not prevented identities or economic guarantees.

ETH can be forced into any EVM contract outside its normal entry points; such ETH and unsupported tokens have no recovery path here. Unclaimed shares remain claimable indefinitely. The tests and builder review notes are not an independent audit. The independently assigned source/manifest review must complete before services release contracts holding user funds.
