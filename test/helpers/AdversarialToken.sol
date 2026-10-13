// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Test-only token to exercise rollback and callbacks. Never a launch artifact.
contract AdversarialToken is ERC20 {
    enum ReturnMode {
        Normal,
        False,
        Empty
    }

    uint8 private immutable _decimals;
    ReturnMode public mode;
    address public rejectTo;
    address public falseReturnTo;
    bool public taxed;
    address public callbackTarget;
    bytes public callbackData;
    bool public callbackSuccess;
    bytes public callbackResult;
    uint256 public callbacks;
    bool private _inCallback;

    error TransferRejected();

    constructor(uint8 decimals_) ERC20("Adversarial test token", "TEST") {
        _decimals = decimals_;
        _mint(msg.sender, 1e27);
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function configure(ReturnMode mode_, address rejectTo_, bool taxed_) external {
        mode = mode_;
        rejectTo = rejectTo_;
        taxed = taxed_;
    }

    function setCallback(address target, bytes calldata data) external {
        callbackTarget = target;
        callbackData = data;
    }

    /// @dev Move the tokens first, then report failure on outgoing transfers only.
    /// This distinguishes a failed burn/payout from a failed incoming payment.
    function setFalseReturnTo(address recipient) external {
        falseReturnTo = recipient;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (to == rejectTo) revert TransferRejected();
        super.transfer(to, amount);
        return _afterTransfer() && to != falseReturnTo;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (to == rejectTo) revert TransferRejected();
        super.transferFrom(from, to, amount);
        return _afterTransfer();
    }

    function _afterTransfer() private returns (bool) {
        if (callbackTarget != address(0) && !_inCallback) {
            _inCallback = true;
            (callbackSuccess, callbackResult) = callbackTarget.call(callbackData);
            callbacks++;
            _inCallback = false;
        }
        if (mode == ReturnMode.Empty) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        return mode != ReturnMode.False;
    }

    function _update(address from, address to, uint256 amount) internal override {
        uint256 tax = taxed && from != address(0) && to != address(0) ? amount / 100 : 0;
        if (tax != 0) super._update(from, address(0), tax);
        super._update(from, to, amount - tax);
    }
}

contract NoMetadataToken {}
