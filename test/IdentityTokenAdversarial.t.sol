// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IdentityToken} from "src/IdentityToken.sol";

/// @dev Covers direct deployment: all fees initially belong to the constructor caller.
/// forge-config: default.fuzz.runs = 1000
contract IdentityTokenAdversarialTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000e18;
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    address private constant SPENDER = address(0x5EED);
    IdentityToken private token;

    function setUp() public {
        token = new IdentityToken(address(0), address(0), 0, address(0));
    }

    function test_roundingEdgesIncludingWholeSupply() public {
        uint256[10] memory amounts = [uint256(0), 1, 12, 13, 24, 25, 26, 99, 100, SUPPLY];
        uint256[10] memory fees = [uint256(0), 0, 0, 1, 1, 2, 2, 7, 8, 80_000_000e18];
        for (uint256 i; i < amounts.length; ++i) {
            IdentityToken fresh = new IdentityToken(address(0), address(0), 0, address(0));
            fresh.transfer(ALICE, amounts[i]);
            uint256 before = fresh.balanceOf(address(this));
            vm.prank(ALICE);
            assertTrue(fresh.transfer(BOB, amounts[i]));
            assertEq(fresh.balanceOf(ALICE), 0);
            assertEq(fresh.balanceOf(BOB), amounts[i] - fees[i]);
            assertEq(fresh.balanceOf(address(this)), before + fees[i]);
            assertEq(fresh.totalSupply(), SUPPLY);
        }
    }

    function test_fullSupplySelfTransferCountsHolderOnce() public {
        token.transfer(ALICE, SUPPLY);
        vm.prank(ALICE);
        assertTrue(token.transfer(ALICE, SUPPLY));
        assertEq(token.balanceOf(ALICE), 920_000_000e18);
        assertEq(token.balanceOf(address(this)), 80_000_000e18);
        assertEq(token.balanceOf(ALICE) + token.balanceOf(address(this)), SUPPLY);
    }

    function test_zeroAndOneWeiTransfersEmitTransferWithoutFee() public {
        token.transfer(ALICE, 1);
        for (uint256 amount; amount <= 1; ++amount) {
            vm.recordLogs();
            vm.prank(ALICE);
            assertTrue(token.transfer(BOB, amount));
            Vm.Log[] memory logs = vm.getRecordedLogs();
            assertEq(logs.length, 1, "no fee events for zero or dust");
            assertEq(logs[0].emitter, address(token));
            assertEq(logs[0].topics.length, 3);
            assertEq(logs[0].topics[0], keccak256("Transfer(address,address,uint256)"));
            assertEq(logs[0].topics[1], bytes32(uint256(uint160(ALICE))));
            assertEq(logs[0].topics[2], bytes32(uint256(uint160(BOB))));
            assertEq(abi.decode(logs[0].data, (uint256)), amount);
        }
        assertEq(token.balanceOf(BOB), 1);
        assertEq(token.balanceOf(address(this)), SUPPLY - 1);
    }

    function test_zeroTransferFromNeedsNoAllowanceAndChangesNoBalances() public {
        bytes32 before = _state();
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(ALICE, BOB, 0));
        assertEq(_state(), before);
    }

    function test_zeroTransferStillRejectsZeroReceiver() public {
        bytes32 before = _state();
        vm.expectRevert(abi.encodeWithSelector(IdentityToken.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(ALICE);
        token.transfer(address(0), 0);
        assertEq(_state(), before);
    }

    function test_zeroTransferFromRejectsZeroSender() public {
        bytes32 before = _state();
        vm.expectRevert(abi.encodeWithSelector(IdentityToken.ERC20InvalidSender.selector, address(0)));
        vm.prank(SPENDER);
        token.transferFrom(address(0), BOB, 0);
        assertEq(_state(), before);
        assertEq(token.allowance(address(0), SPENDER), 0);
    }

    function test_zeroTransferFromRejectsZeroReceiver() public {
        bytes32 before = _state();
        vm.expectRevert(abi.encodeWithSelector(IdentityToken.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(SPENDER);
        token.transferFrom(ALICE, address(0), 0);
        assertEq(_state(), before);
    }

    function test_zeroApprovalStillRejectsZeroSpender() public {
        bytes32 before = _state();
        vm.expectRevert(abi.encodeWithSelector(IdentityToken.ERC20InvalidSpender.selector, address(0)));
        vm.prank(ALICE);
        token.approve(address(0), 0);
        assertEq(_state(), before);
        assertEq(token.allowance(ALICE, address(0)), 0);
    }

    function test_transferFromInsufficientBalanceRestoresFiniteAllowance() public {
        token.transfer(ALICE, 100);
        vm.prank(ALICE);
        token.approve(SPENDER, 101);
        bytes32 before = _state();
        vm.expectRevert(abi.encodeWithSelector(IdentityToken.ERC20InsufficientBalance.selector, ALICE, 100, 101));
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, 101);
        assertEq(_state(), before, "a failed transfer must roll back the allowance debit too");
    }

    function test_transferFromInvalidReceiverRestoresAllowance() public {
        token.transfer(ALICE, 100);
        vm.prank(ALICE);
        token.approve(SPENDER, 100);
        bytes32 before = _state();
        vm.expectRevert(abi.encodeWithSelector(IdentityToken.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(SPENDER);
        token.transferFrom(ALICE, address(0), 100);
        assertEq(_state(), before);
    }

    function test_maximumTransferFailsWithBalanceErrorAndNoChanges() public {
        bytes32 before = _state();
        vm.expectRevert(
            abi.encodeWithSelector(
                IdentityToken.ERC20InsufficientBalance.selector, address(this), SUPPLY, type(uint256).max
            )
        );
        token.transfer(BOB, type(uint256).max);
        assertEq(_state(), before);
    }

    function test_maximumTransferFromPreservesInfiniteApprovalOnFailure() public {
        token.transfer(ALICE, 100);
        vm.prank(ALICE);
        token.approve(SPENDER, type(uint256).max);
        bytes32 before = _state();
        vm.expectRevert(
            abi.encodeWithSelector(IdentityToken.ERC20InsufficientBalance.selector, ALICE, 100, type(uint256).max)
        );
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, type(uint256).max);
        assertEq(_state(), before);
    }

    function test_allowanceCoversGrossAmountIncludingFee() public {
        token.transfer(ALICE, 100);
        vm.prank(ALICE);
        token.approve(SPENDER, 92);
        bytes32 before = _state();
        vm.expectRevert(abi.encodeWithSelector(IdentityToken.ERC20InsufficientAllowance.selector, SPENDER, 92, 100));
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, 100);
        assertEq(_state(), before);
    }

    function test_spentAllowanceCannotBeReused() public {
        token.transfer(ALICE, 200);
        vm.prank(ALICE);
        token.approve(SPENDER, 100);
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, 100);
        assertEq(token.allowance(ALICE, SPENDER), 0);
        bytes32 before = _state();
        vm.expectRevert(abi.encodeWithSelector(IdentityToken.ERC20InsufficientAllowance.selector, SPENDER, 0, 1));
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, 1);
        assertEq(_state(), before);
    }

    function test_revocationOverwritesInfiniteAllowanceImmediately() public {
        token.transfer(ALICE, 100);
        vm.startPrank(ALICE);
        token.approve(SPENDER, type(uint256).max);
        token.approve(SPENDER, 0);
        vm.stopPrank();
        bytes32 before = _state();
        vm.expectRevert(abi.encodeWithSelector(IdentityToken.ERC20InsufficientAllowance.selector, SPENDER, 0, 1));
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, 1);
        assertEq(_state(), before);
    }

    function test_delegatedSelfTransferSpendsGrossAllowanceAndOnlyFeeFromBalance() public {
        token.transfer(ALICE, 100);
        vm.prank(ALICE);
        token.approve(SPENDER, 100);
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(ALICE, ALICE, 100));
        assertEq(token.allowance(ALICE, SPENDER), 0);
        assertEq(token.balanceOf(ALICE), 92);
        assertEq(token.balanceOf(address(this)), SUPPLY - 92);
    }

    function test_repeatedInfiniteAllowanceTransfersDoNotConsumeApproval() public {
        token.transfer(ALICE, 200);
        vm.prank(ALICE);
        token.approve(SPENDER, type(uint256).max);
        vm.startPrank(SPENDER);
        token.transferFrom(ALICE, BOB, 100);
        token.transferFrom(ALICE, BOB, 100);
        vm.stopPrank();
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB), 184);
        assertEq(token.balanceOf(address(this)), SUPPLY - 184);
        assertEq(token.allowance(ALICE, SPENDER), type(uint256).max);
    }

    function test_feeRecipientHandoffPreservesHoldingsAndRevokesOldAuthority() public {
        token.transfer(ALICE, 100);
        token.setFeeRecipient(BOB);
        assertEq(token.balanceOf(ALICE), 100);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY - 100);
        bytes32 before = _state();
        vm.expectRevert(abi.encodeWithSelector(IdentityToken.NotFeeRecipient.selector, address(this)));
        token.setFeeRecipient(SPENDER);
        assertEq(_state(), before);

        // In a direct deployment the old recipient has no other exemption.
        vm.prank(ALICE);
        token.transfer(address(this), 100);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY - 8);
        assertEq(token.balanceOf(BOB), 8);
        vm.prank(BOB);
        token.setFeeRecipient(SPENDER);
        assertEq(token.feeRecipient(), SPENDER);
        assertEq(token.balanceOf(BOB), 8, "handoff does not move past fees");
    }

    function test_feeRecipientCannotSetZeroOrStealUsingTransferFrom() public {
        token.transfer(ALICE, 100);
        bytes32 before = _state();
        vm.expectRevert(IdentityToken.InvalidFeeRecipient.selector);
        token.setFeeRecipient(address(0));
        assertEq(_state(), before);
        vm.expectRevert(abi.encodeWithSelector(IdentityToken.ERC20InsufficientAllowance.selector, address(this), 0, 1));
        token.transferFrom(ALICE, address(this), 1);
        assertEq(_state(), before);
    }

    function testFuzz_transferFromConservesBalancesAndSpendsGrossAllowance(uint256 amount, uint256 extra) public {
        amount = bound(amount, 0, SUPPLY);
        extra = bound(extra, 0, SUPPLY);
        token.transfer(ALICE, SUPPLY);
        vm.prank(ALICE);
        token.approve(SPENDER, amount + extra);
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(ALICE, BOB, amount));
        uint256 paid = token.balanceOf(address(this));
        // Independent floor characterization: paid <= 8% < paid + one wei.
        assertLe(paid * 100, amount * 8);
        assertGt((paid + 1) * 100, amount * 8);
        assertEq(token.balanceOf(ALICE), SUPPLY - amount);
        assertEq(token.balanceOf(BOB) + paid, amount);
        assertEq(token.allowance(ALICE, SPENDER), extra);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_failedTransferFromPreservesEverything(uint256 held, uint256 requested) public {
        held = bound(held, 0, SUPPLY);
        requested = bound(requested, held + 1, type(uint256).max - 1);
        token.transfer(ALICE, held);
        vm.prank(ALICE);
        token.approve(SPENDER, requested);
        bytes32 before = _state();
        vm.expectRevert(abi.encodeWithSelector(IdentityToken.ERC20InsufficientBalance.selector, ALICE, held, requested));
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, requested);
        assertEq(_state(), before);
    }

    function testFuzz_feeRoundingAndPeriodOnTransferableDomain(uint256 amount) public view {
        amount = bound(amount, 0, SUPPLY - 25);
        uint256 fee = token.feeFor(amount);
        assertLe(fee * 100, amount * 8);
        assertGt((fee + 1) * 100, amount * 8);
        assertEq(token.feeFor(amount + 25), fee + 2, "each 25 wei adds exactly 2 wei of fee");
    }

    function testFuzz_roundTripLossEqualsDeployerFees(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        token.transfer(ALICE, amount);
        uint256 deployerBefore = token.balanceOf(address(this));
        vm.prank(ALICE);
        token.transfer(BOB, amount);
        uint256 received = token.balanceOf(BOB);
        vm.prank(BOB);
        token.transfer(ALICE, received);
        uint256 returned = token.balanceOf(ALICE);
        uint256 fees = token.balanceOf(address(this)) - deployerBefore;
        assertLe(returned, amount, "a round trip cannot create tokens");
        assertEq(returned + fees, amount);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function _state() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                token.totalSupply(),
                token.feeRecipient(),
                token.balanceOf(address(this)),
                token.balanceOf(ALICE),
                token.balanceOf(BOB),
                token.balanceOf(SPENDER),
                token.balanceOf(address(0)),
                token.allowance(ALICE, SPENDER)
            )
        );
    }
}
