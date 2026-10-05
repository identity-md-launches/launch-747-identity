// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IdentityToken} from "src/IdentityToken.sol";
import {IdentityTokenHandler} from "./helpers/IdentityTokenHandler.sol";

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract IdentityTokenInvariantTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000e18;
    IdentityTokenHandler private handler;
    IdentityToken private token;

    function setUp() public {
        handler = new IdentityTokenHandler();
        token = handler.token();
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.transferFrom.selector;
        selectors[2] = handler.approve.selector;
        selectors[3] = handler.changeFeeRecipient.selector;
        selectors[4] = handler.changeDistributor.selector;
        selectors[5] = handler.rejectOverdraw.selector;
        selectors[6] = handler.rejectDelegatedTransfer.selector;
        selectors[7] = handler.rejectUnauthorizedPull.selector;
        selectors[8] = handler.rejectInvalidAdministration.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @dev Checked after every random action, including expected failures and role changes.
    function invariant_supplyBalancesAllowancesAndRolesMatchIndependentModel() public view {
        assertEq(token.totalSupply(), SUPPLY, "supply must never mint or burn");
        assertEq(token.feeRecipient(), handler.expectedRecipient(), "only an authorized handoff changes the role");
        assertEq(token.distributor(), handler.expectedDistributor());
        assertEq(token.factory(), address(handler.factory()));
        assertEq(token.poolManager(), handler.actors(1));
        assertEq(token.launchNumber(), 7);
        uint256 held;
        for (uint256 i; i < 8; ++i) {
            address actor = handler.actors(i);
            uint256 balance = token.balanceOf(actor);
            held += balance;
            assertEq(balance, handler.expectedBalance(actor), "unexpected balance change or fee");
            for (uint256 j; j < 8; ++j) {
                address spender = handler.actors(j);
                assertEq(token.allowance(actor, spender), handler.expectedAllowance(actor, spender), "approval drift");
            }
            assertEq(token.allowance(actor, handler.OUTSIDER()), 0);
            assertEq(token.allowance(actor, address(0)), 0);
        }
        assertEq(held, SUPPLY, "sum every distinct holder exactly once");
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(handler.OUTSIDER()), 0);
        assertEq(token.balanceOf(address(token)), 0);
    }

    /// @dev After each sequence every holder can still sell its entire balance into the pool.
    function afterInvariant() public {
        for (uint256 i; i < 8; ++i) {
            if (i == 1) continue;
            handler.transfer(i, 1, 0, 2);
            assertEq(token.balanceOf(handler.actors(i)), 0, "holder could not exit completely");
        }
        assertEq(token.balanceOf(handler.actors(1)), SUPPLY, "pool settlement arrived short");
        invariant_supplyBalancesAllowancesAndRolesMatchIndependentModel();
    }

    function test_handlerExercisesTaxedExemptSelfDelegatedAndRejectedCalls() public {
        handler.transfer(4, 5, 100, 3);
        assertEq(token.balanceOf(handler.actors(5)), SUPPLY / 10 + 92);
        handler.approve(5, 6, 100, 2);
        handler.transferFrom(5, 6, 5, 100, 3);
        assertEq(token.allowance(handler.actors(5), handler.actors(6)), 0);
        handler.changeDistributor(2);
        handler.transfer(3, 4, 100, 3);
        handler.changeFeeRecipient(6);
        handler.transfer(4, 5, 100, 3);
        handler.rejectOverdraw(4, 5, type(uint256).max);
        handler.rejectDelegatedTransfer(4, 5, 0);
        handler.rejectDelegatedTransfer(4, 5, 1);
        handler.rejectDelegatedTransfer(4, 5, 2);
        handler.rejectUnauthorizedPull(4, 1);
        handler.rejectInvalidAdministration(7, false);
        handler.rejectInvalidAdministration(7, true);
        invariant_supplyBalancesAllowancesAndRolesMatchIndependentModel();
        afterInvariant();
    }
}
