// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IdentityToken} from "src/IdentityToken.sol";

contract IdentityInvariantFactory {
    mapping(uint64 => address) public distributorOf;

    function deploy(address manager) external returns (IdentityToken) {
        return new IdentityToken(address(this), manager, 7, address(0));
    }

    function setDistributor(address distributor) external {
        distributorOf[7] = distributor;
    }
}

/// @dev Only the explicitly selected actions are fuzz targets. All destinations and fee
/// recipients belong to this closed actor set, so exact conservation is measurable.
/// Ghost state comes from authorized inputs, never from token.feeFor/isFeeExempt/balanceOf.
contract IdentityTokenHandler is Test {
    uint256 public constant SUPPLY = 1_000_000_000e18;
    address public constant OUTSIDER = address(0xBAD);
    IdentityInvariantFactory public immutable factory;
    IdentityToken public immutable token;
    address[8] public actors;
    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;
    address public expectedRecipient;
    address public expectedDistributor;

    constructor() {
        factory = new IdentityInvariantFactory();
        actors = [
            address(factory),
            address(0x9001),
            address(0xD157),
            address(0xD158),
            address(0xA11CE),
            address(0xB0B),
            address(0xCA201),
            address(0xDA7E)
        ];
        token = factory.deploy(actors[1]);
        expectedRecipient = address(factory);
        expectedDistributor = actors[2];
        factory.setDistributor(expectedDistributor);
        expectedBalance[address(factory)] = SUPPLY;

        // Real transfers seed every actor; no storage writes or token-balance cheatcodes.
        for (uint256 i = 1; i < actors.length; ++i) {
            vm.prank(address(factory));
            require(token.transfer(actors[i], SUPPLY / 10), "initial funding failed");
            expectedBalance[address(factory)] -= SUPPLY / 10;
            expectedBalance[actors[i]] = SUPPLY / 10;
        }
        // Exercise delegated transfers immediately, then let random approvals replace/revoke these.
        for (uint256 i; i < actors.length; ++i) {
            _approve(actors[i], actors[(i + 1) % actors.length], i % 2 == 0 ? SUPPLY : type(uint256).max);
        }
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 rawAmount, uint8 mode) public {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 amount = _amount(rawAmount, expectedBalance[from], mode);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        _recordTransfer(from, to, amount);
    }

    function transferFrom(uint256 fromSeed, uint256 spenderSeed, uint256 toSeed, uint256 rawAmount, uint8 mode) public {
        address from = _actor(fromSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 approved = expectedAllowance[from][spender];
        uint256 limit = expectedBalance[from] < approved ? expectedBalance[from] : approved;
        uint256 amount = _amount(rawAmount, limit, mode);
        vm.prank(spender);
        assertTrue(token.transferFrom(from, to, amount));
        if (approved != type(uint256).max) expectedAllowance[from][spender] = approved - amount;
        _recordTransfer(from, to, amount);
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 rawAmount, uint8 mode) public {
        uint256 amount;
        if (mode % 4 == 1) amount = type(uint256).max;
        else if (mode % 4 == 2) amount = bound(rawAmount, 0, SUPPLY);
        else if (mode % 4 == 3) amount = rawAmount;
        _approve(_actor(ownerSeed), _actor(spenderSeed), amount);
    }

    function changeFeeRecipient(uint256 recipientSeed) public {
        address next = _actor(recipientSeed);
        vm.prank(expectedRecipient);
        token.setFeeRecipient(next);
        expectedRecipient = next;
    }

    function changeDistributor(uint256 seed) public {
        uint256 choice = seed % 3;
        expectedDistributor = choice == 0 ? address(0) : actors[choice + 1];
        factory.setDistributor(expectedDistributor);
    }

    function rejectOverdraw(uint256 fromSeed, uint256 toSeed, uint256 rawAmount) public {
        address from = _actor(fromSeed);
        uint256 balance = expectedBalance[from];
        uint256 amount = bound(rawAmount, balance + 1, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IdentityToken.ERC20InsufficientBalance.selector, from, balance, amount));
        vm.prank(from);
        token.transfer(_actor(toSeed), amount);
        // No ghost update: every invariant must still hold after the rejected call.
    }

    function rejectDelegatedTransfer(uint256 ownerSeed, uint256 spenderSeed, uint8 failure) public {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 kind = failure % 3;
        uint256 amount = kind == 0 ? expectedBalance[owner] + 1 : 1;
        address to = kind == 1 ? address(0) : actors[4];
        _approve(owner, spender, kind == 2 ? 0 : amount);
        if (kind == 0) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IdentityToken.ERC20InsufficientBalance.selector, owner, expectedBalance[owner], amount
                )
            );
        } else if (kind == 1) {
            vm.expectRevert(abi.encodeWithSelector(IdentityToken.ERC20InvalidReceiver.selector, address(0)));
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(IdentityToken.ERC20InsufficientAllowance.selector, spender, 0, amount)
            );
        }
        vm.prank(spender);
        token.transferFrom(owner, to, amount);
        // In particular, a failure after _spendAllowance must restore the finite approval.
    }

    function rejectUnauthorizedPull(uint256 ownerSeed, uint256 rawAmount) public {
        address owner = _actor(ownerSeed);
        uint256 amount = bound(rawAmount, 1, SUPPLY);
        vm.expectRevert(abi.encodeWithSelector(IdentityToken.ERC20InsufficientAllowance.selector, OUTSIDER, 0, amount));
        vm.prank(OUTSIDER);
        token.transferFrom(owner, OUTSIDER, amount);
    }

    function rejectInvalidAdministration(uint256 nextSeed, bool zeroRecipient) public {
        if (zeroRecipient) {
            vm.expectRevert(IdentityToken.InvalidFeeRecipient.selector);
            vm.prank(expectedRecipient);
            token.setFeeRecipient(address(0));
        } else {
            vm.expectRevert(abi.encodeWithSelector(IdentityToken.NotFeeRecipient.selector, OUTSIDER));
            vm.prank(OUTSIDER);
            token.setFeeRecipient(_actor(nextSeed));
        }
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[seed % actors.length];
    }

    function _amount(uint256 raw, uint256 limit, uint8 mode) private pure returns (uint256) {
        // Explicit zero, dust, entire balance/allowance, and general bounded amounts.
        if (mode % 4 == 0) return 0;
        if (mode % 4 == 1) return bound(raw, 0, limit < 26 ? limit : 26);
        if (mode % 4 == 2) return limit;
        return bound(raw, 0, limit);
    }

    function _approve(address owner, address spender, uint256 amount) private {
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        expectedAllowance[owner][spender] = amount;
    }

    function _recordTransfer(address from, address to, uint256 amount) private {
        bool exempt = from == actors[0] || to == actors[0] || from == actors[1] || to == actors[1]
            || from == expectedRecipient || to == expectedRecipient
            || (expectedDistributor != address(0) && (from == expectedDistributor || to == expectedDistributor));
        // 8% = 2/25. Split quotient/remainder to avoid using the contract's multiply-first formula.
        uint256 fee = exempt ? 0 : (amount / 25) * 2 + ((amount % 25) * 2) / 25;
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount - fee;
        expectedBalance[expectedRecipient] += fee;
    }
}
