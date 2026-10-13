// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice JOB #0: pass the job within 24 hours, or fail and fund all earlier workers equally.
/// @dev Designed exclusively for the standard, non-rebasing, 18-decimal LaunchToken.
/// No owner withdrawals, upgrades, pause, cancellation, or ETH entry points exist.
contract JobZero is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant OPEN_FEE = 10_000 ether;
    uint256 public constant INITIAL_HANDOFF_FEE = 1_000 ether;
    uint256 public constant ONLINE_FEE = 10 ether;
    uint256 public constant WORKER_WINDOW = 24 hours;
    uint256 public constant MAX_PAGE_SIZE = 100;
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    enum Status {
        Holding,
        HandedOff,
        Failed
    }

    struct Attempt {
        address worker;
        uint256 startedAt;
        uint256 endedAt;
        Status status;
    }

    struct Run {
        uint256 attempts;
        uint256 bounty;
        uint256 fee;
        uint256 openedAt;
        uint256 closedAt;
        address failedWorker;
        address worker;
        uint256 deadline;
        uint256 share;
        uint256 claimedCount;
        bool closed;
    }

    struct WorkerStats {
        uint256 attempts;
        uint256 handoffs;
        uint256 totalEarned;
        uint256 timesFailed;
    }

    struct QueueEntry {
        address worker;
        uint256 onlineAt;
    }

    struct QueueNode {
        address newer;
        address older;
        uint256 onlineAt;
        bool joined;
        bool active;
    }

    address public immutable owner;
    IERC20 public token;
    /// @notice Latest run ID, including after it closes. Zero means no run has ever opened.
    uint256 public currentRun;
    bool public isOpen;
    uint256 public totalBurned;
    /// @notice Open bounty plus all unclaimed shares from closed runs; excludes unsolicited transfers.
    uint256 public totalLiability;
    uint256 public biggestBounty;
    uint256 public mostHandoffs;

    mapping(uint256 => Run) private _runs;
    mapping(uint256 => Attempt[]) private _attempts;
    mapping(uint256 => mapping(address => bool)) public hasHeld;
    mapping(uint256 => mapping(address => bool)) public claimed;
    mapping(address => WorkerStats) public workerStats;
    mapping(uint256 => mapping(address => QueueNode)) private _queue;
    mapping(uint256 => address) private _queueHead;
    mapping(uint256 => uint256) private _queueSize;
    uint256 private _longestRunId;
    uint256 private _longestRunDuration;

    error InvalidOwner();
    error Unauthorized();
    error TokenAlreadySet();
    error InvalidToken();
    error TokenNotConfigured();
    error RunAlreadyOpen();
    error NoOpenRun();
    error NotWorker();
    error DeadlinePassed();
    error DeadlineNotReached();
    error InvalidRecipient();
    error AlreadyHeld();
    error AlreadyJoined();
    error NotOnline();
    error NothingToClaim();
    error PageTooLarge();
    error UnexpectedTokenAmount();

    event TokenSet(address indexed token);
    event Opened(uint256 indexed runId, address indexed worker, uint256 deadline, uint256 bounty);
    /// @param attempt The new worker's one-based attempt number, including the opener.
    event HandedOff(uint256 indexed runId, address indexed from, address indexed to, uint256 fee, uint256 attempt);
    event TimedOut(uint256 indexed runId, address indexed failedWorker, uint256 attempts, uint256 bounty);
    event Claimed(uint256 indexed runId, address indexed worker, uint256 amount);
    event Online(uint256 indexed runId, address indexed worker, uint256 onlineAt);
    event Offline(uint256 indexed runId, address indexed worker);
    event Burned(uint256 indexed runId, uint256 amount);

    /// @dev Does not call or inspect any outside contract. The manifest supplies $owner.
    constructor(address owner_) {
        if (owner_ == address(0)) revert InvalidOwner();
        owner = owner_;
    }

    /// @notice The owner's only power. Set to this launch's TEYO address from the deployment handoff.
    /// @dev Code and decimals are sanity checks, not proof of token identity. Irreversible once set.
    function setToken(address token_) external nonReentrant {
        if (msg.sender != owner) revert Unauthorized();
        if (address(token) != address(0)) revert TokenAlreadySet();
        if (token_ == address(this) || token_.code.length == 0) revert InvalidToken();
        try IERC20Metadata(token_).decimals() returns (uint8 decimals_) {
            if (decimals_ != 18) revert InvalidToken();
        } catch {
            revert InvalidToken();
        }
        token = IERC20(token_);
        emit TokenSet(token_);
    }

    /// @notice Pay 10,000 TEYO and become the first worker of a new run.
    function open() external nonReentrant {
        _requireToken();
        if (isOpen) revert RunAlreadyOpen();

        uint256 id = ++currentRun;
        isOpen = true;
        Run storage run = _runs[id];
        run.bounty = OPEN_FEE;
        run.fee = INITIAL_HANDOFF_FEE;
        run.openedAt = block.timestamp;
        totalLiability += OPEN_FEE;
        if (OPEN_FEE > biggestBounty) biggestBounty = OPEN_FEE;
        _assign(run, id, msg.sender);

        emit Opened(id, msg.sender, run.deadline, OPEN_FEE);
        _collect(msg.sender, OPEN_FEE);
    }

    /// @notice The current worker pays the fee to pass the job to a new address before expiry.
    function handoff(address to) external nonReentrant {
        _requireOpen();
        uint256 id = currentRun;
        Run storage run = _runs[id];
        if (msg.sender != run.worker) revert NotWorker();
        if (block.timestamp >= run.deadline) revert DeadlinePassed();
        if (to == address(0) || to == msg.sender) revert InvalidRecipient();
        if (hasHeld[id][to]) revert AlreadyHeld();

        uint256 fee = run.fee;
        uint256 burn = fee / 2;
        uint256 contribution = fee - burn;
        // Integer TEYO minor units: floor(1.03 * fee); an odd unit in the split stays in the bounty.
        run.fee = fee + (fee * 3) / 100;
        run.bounty += contribution;
        totalLiability += contribution;
        workerStats[msg.sender].handoffs++;
        Attempt storage previous = _attempts[id][run.attempts - 1];
        previous.endedAt = block.timestamp;
        previous.status = Status.HandedOff;
        _assign(run, id, to);
        if (run.bounty > biggestBounty) biggestBounty = run.bounty;
        if (run.attempts - 1 > mostHandoffs) mostHandoffs = run.attempts - 1;

        emit HandedOff(id, msg.sender, to, fee, run.attempts);
        _collect(msg.sender, fee);
        _burn(id, burn);
    }

    /// @notice At or after expiry anyone can close the run. No iteration over workers is required.
    function timeout() external nonReentrant {
        _requireOpen();
        uint256 id = currentRun;
        Run storage run = _runs[id];
        if (block.timestamp < run.deadline) revert DeadlineNotReached();

        isOpen = false;
        run.closed = true;
        run.closedAt = block.timestamp;
        run.failedWorker = run.worker;
        workerStats[run.worker].timesFailed++;
        Attempt storage last = _attempts[id][run.attempts - 1];
        last.endedAt = run.deadline;
        last.status = Status.Failed;

        // Delaying timeout cannot inflate the longest-run record.
        uint256 duration = run.deadline - run.openedAt;
        if (_longestRunId == 0 || duration > _longestRunDuration) {
            _longestRunId = id;
            _longestRunDuration = duration;
        }
        uint256 recipients = run.attempts - 1;
        uint256 burn = run.bounty;
        if (recipients != 0) {
            run.share = run.bounty / recipients;
            burn = run.bounty % recipients;
        }
        totalLiability -= burn;
        emit TimedOut(id, run.failedWorker, run.attempts, run.bounty);
        // Burn the entire solo bounty, or indivisible dust so every eligible worker gets exactly the same share.
        if (burn != 0) _burn(id, burn);
    }

    /// @notice Claim your equal share from a closed run, once. Claims never expire.
    function claim(uint256 runId) external nonReentrant {
        _requireToken();
        uint256 amount = claimable(runId, msg.sender);
        if (amount == 0) revert NothingToClaim();
        claimed[runId][msg.sender] = true;
        _runs[runId].claimedCount++;
        workerStats[msg.sender].totalEarned += amount;
        totalLiability -= amount;
        emit Claimed(runId, msg.sender, amount);
        token.safeTransfer(msg.sender, amount);
    }

    /// @notice Burn 10 TEYO to join this run's queue once. Leaving does not restore eligibility to join.
    function goOnline() external nonReentrant {
        _requireOpen();
        uint256 id = currentRun;
        if (block.timestamp >= _runs[id].deadline) revert DeadlinePassed();
        if (hasHeld[id][msg.sender]) revert AlreadyHeld();
        QueueNode storage node = _queue[id][msg.sender];
        if (node.joined) revert AlreadyJoined();

        address head = _queueHead[id];
        node.joined = true;
        node.active = true;
        node.onlineAt = block.timestamp;
        node.older = head;
        if (head != address(0)) _queue[id][head].newer = msg.sender;
        _queueHead[id] = msg.sender;
        _queueSize[id]++;
        emit Online(id, msg.sender, block.timestamp);
        _collect(msg.sender, ONLINE_FEE);
        _burn(id, ONLINE_FEE);
    }

    /// @notice Leave the active run's queue; no refund. Expiry alone does not prevent leaving.
    function goOffline() external nonReentrant {
        _requireOpen();
        if (!_queue[currentRun][msg.sender].active) revert NotOnline();
        _removeFromQueue(currentRun, msg.sender);
    }

    function runs(uint256 runId) external view returns (Run memory) {
        return _runs[runId];
    }

    /// @notice Current active worker; zero when no run is open. Past workers remain in runs/attempts.
    function worker() external view returns (address) {
        return isOpen ? _runs[currentRun].worker : address(0);
    }

    function deadline() external view returns (uint256) {
        return isOpen ? _runs[currentRun].deadline : 0;
    }

    function handoffFee() external view returns (uint256) {
        return isOpen ? _runs[currentRun].fee : INITIAL_HANDOFF_FEE;
    }

    function claimable(uint256 runId, address wallet) public view returns (uint256) {
        Run storage run = _runs[runId];
        if (!run.closed || !hasHeld[runId][wallet] || wallet == run.failedWorker || claimed[runId][wallet]) return 0;
        return run.share;
    }

    /// @notice Return attempts newest first. start is a zero-based offset; count must be <=100.
    function getAttempts(uint256 runId, uint256 start, uint256 count) external view returns (Attempt[] memory page) {
        if (count > MAX_PAGE_SIZE) revert PageTooLarge();
        uint256 length = _attempts[runId].length;
        if (start >= length) return new Attempt[](0);
        uint256 remaining = length - start;
        if (count > remaining) count = remaining;
        page = new Attempt[](count);
        for (uint256 i; i < count; ++i) {
            page[i] = _attempts[runId][length - start - i - 1];
        }
    }

    /// @notice Return currently online entries newest first; closed/unknown runs return empty pages.
    /// @dev Removal is O(1). Offset pagination costs O(start+count), independent of removed entries.
    function getQueue(uint256 runId, uint256 start, uint256 count) external view returns (QueueEntry[] memory page) {
        if (count > MAX_PAGE_SIZE) revert PageTooLarge();
        uint256 length = queueLength(runId);
        if (start >= length || count == 0) return new QueueEntry[](0);
        uint256 remaining = length - start;
        if (count > remaining) count = remaining;
        page = new QueueEntry[](count);
        address cursor = _queueHead[runId];
        for (uint256 i; i < start; ++i) {
            cursor = _queue[runId][cursor].older;
        }
        for (uint256 i; i < count; ++i) {
            QueueNode storage node = _queue[runId][cursor];
            page[i] = QueueEntry(cursor, node.onlineAt);
            cursor = node.older;
        }
    }

    function queueLength(uint256 runId) public view returns (uint256) {
        return _runs[runId].closed ? 0 : _queueSize[runId];
    }

    function isOnline(uint256 runId, address wallet) external view returns (bool) {
        return !_runs[runId].closed && _queue[runId][wallet].active;
    }

    function hasJoinedQueue(uint256 runId, address wallet) external view returns (bool) {
        return _queue[runId][wallet].joined;
    }

    /// @notice Longest effective elapsed duration, including the live run capped at its deadline.
    /// @dev Ties retain the earliest winning run; (0,0) before the first open.
    function longestRun() external view returns (uint256 runId, uint256 duration) {
        runId = _longestRunId;
        duration = _longestRunDuration;
        if (isOpen) {
            Run storage run = _runs[currentRun];
            uint256 end = block.timestamp < run.deadline ? block.timestamp : run.deadline;
            uint256 elapsed = end - run.openedAt;
            if (runId == 0 || elapsed > duration) return (currentRun, elapsed);
        }
    }

    function _requireToken() private view {
        if (address(token) == address(0)) revert TokenNotConfigured();
    }

    function _requireOpen() private view {
        _requireToken();
        if (!isOpen) revert NoOpenRun();
    }

    function _assign(Run storage run, uint256 id, address to) private {
        run.worker = to;
        run.deadline = block.timestamp + WORKER_WINDOW;
        run.attempts++;
        hasHeld[id][to] = true;
        workerStats[to].attempts++;
        _attempts[id].push(Attempt(to, block.timestamp, 0, Status.Holding));
        if (_queue[id][to].active) _removeFromQueue(id, to);
    }

    function _removeFromQueue(uint256 id, address wallet) private {
        QueueNode storage node = _queue[id][wallet];
        if (node.newer == address(0)) _queueHead[id] = node.older;
        else _queue[id][node.newer].older = node.older;
        if (node.older != address(0)) _queue[id][node.older].newer = node.newer;
        node.active = false;
        _queueSize[id]--;
        emit Offline(id, wallet);
    }

    function _collect(address from, uint256 amount) private {
        uint256 beforeBalance = token.balanceOf(address(this));
        token.safeTransferFrom(from, address(this), amount);
        if (token.balanceOf(address(this)) != beforeBalance + amount) revert UnexpectedTokenAmount();
    }

    function _burn(uint256 runId, uint256 amount) private {
        totalBurned += amount;
        emit Burned(runId, amount);
        token.safeTransfer(BURN_ADDRESS, amount);
    }
}
