// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IdentityToken} from "../src/IdentityToken.sol";
import {DeployIdentityToken} from "../script/DeployIdentityToken.s.sol";

/// @dev Answers `distributorOf` the way the launch factory does.
contract MockFactory {
    mapping(uint64 => address) public distributorOf;

    function setDistributor(uint64 launchNumber, address distributor) external {
        distributorOf[launchNumber] = distributor;
    }

    function deployToken(address poolManager, uint64 launchNumber, address feeRecipient)
        external
        returns (IdentityToken)
    {
        return new IdentityToken(address(this), poolManager, launchNumber, feeRecipient);
    }

    function move(IdentityToken token, address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }
}

/// @dev A factory whose lookup reverts: the token must keep working, just without the exemption.
contract RevertingFactory {
    function distributorOf(uint64) external pure returns (address) {
        revert("down");
    }
}

/// @dev A factory whose lookup returns garbage: same requirement.
contract MalformedFactory {
    fallback() external {
        assembly {
            return(0, 0)
        }
    }
}

contract IdentityTokenTest is Test {
    uint256 constant SUPPLY = 1_000_000_000e18;
    uint64 constant LAUNCH = 7;

    MockFactory factory;
    IdentityToken token;

    address constant POOL_MANAGER = address(0x9001);
    address constant DISTRIBUTOR = address(0xD157);
    address constant REQUESTER = address(0xA11CE);
    address constant ALICE = address(0xA1);
    address constant BOB = address(0xB0B);
    address constant CAROL = address(0xCA201);

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event FeePaid(address indexed from, address indexed to, uint256 fee);
    event FeeRecipientChanged(address indexed previousRecipient, address indexed newRecipient);

    function setUp() public {
        factory = new MockFactory();
        token = factory.deployToken(POOL_MANAGER, LAUNCH, REQUESTER);
        factory.setDistributor(LAUNCH, DISTRIBUTOR);
    }

    // ---------------------------------------------------------------------------------------------
    // Metadata and supply
    // ---------------------------------------------------------------------------------------------

    function test_metadata() public view {
        assertEq(token.name(), "Identity");
        assertEq(token.symbol(), "ID");
        assertEq(token.decimals(), 18);
        assertEq(token.FEE_BPS(), 800);
    }

    function test_supplyMintedOnceToDeployer() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.TOTAL_SUPPLY(), SUPPLY);
        assertEq(token.balanceOf(address(factory)), SUPPLY);
    }

    function test_constructorEmitsMintAndFeeRecipient() public {
        vm.expectEmit(true, true, true, true);
        emit FeeRecipientChanged(address(0), REQUESTER);
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(0), address(this), SUPPLY);
        new IdentityToken(address(0), address(0), 0, REQUESTER);
    }

    function test_launchPartiesRecorded() public view {
        assertEq(token.factory(), address(factory));
        assertEq(token.poolManager(), POOL_MANAGER);
        assertEq(token.launchNumber(), LAUNCH);
        assertEq(token.feeRecipient(), REQUESTER);
        assertEq(token.distributor(), DISTRIBUTOR);
    }

    function test_feeRecipientDefaultsToDeployer() public {
        IdentityToken direct = new IdentityToken(address(0), address(0), 0, address(0));
        assertEq(direct.feeRecipient(), address(this));
        assertEq(direct.balanceOf(address(this)), SUPPLY);
    }

    function test_noMintSurface() public {
        string[4] memory signatures = ["mint(address,uint256)", "mint(uint256)", "burn(uint256)", "pause()"];
        for (uint256 i; i < signatures.length; ++i) {
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], ALICE, 1));
            assertFalse(ok, signatures[i]);
        }
        assertEq(token.totalSupply(), SUPPLY);
    }

    // ---------------------------------------------------------------------------------------------
    // The 8% fee on ordinary transfers
    // ---------------------------------------------------------------------------------------------

    function test_ordinaryTransferPaysEightPercentToFeeRecipient() public {
        _fund(ALICE, 1_000e18);
        uint256 recipientBefore = token.balanceOf(REQUESTER);

        vm.expectEmit(true, true, true, true);
        emit Transfer(ALICE, BOB, 920e18);
        vm.expectEmit(true, true, true, true);
        emit Transfer(ALICE, REQUESTER, 80e18);
        vm.expectEmit(true, true, true, true);
        emit FeePaid(ALICE, REQUESTER, 80e18);
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 1_000e18));

        assertEq(token.balanceOf(ALICE), 0, "sender pays the full amount");
        assertEq(token.balanceOf(BOB), 920e18, "recipient gets 92%");
        assertEq(token.balanceOf(REQUESTER) - recipientBefore, 80e18, "fee recipient gets 8%");
        assertEq(token.totalSupply(), SUPPLY, "fee does not change supply");
    }

    function test_transferFromPaysFeeAndSpendsAllowance() public {
        _fund(ALICE, 500e18);
        vm.prank(ALICE);
        token.approve(CAROL, 300e18);

        vm.expectEmit(true, true, true, true);
        emit Approval(ALICE, CAROL, 100e18);
        vm.prank(CAROL);
        assertTrue(token.transferFrom(ALICE, BOB, 200e18));

        assertEq(token.allowance(ALICE, CAROL), 100e18);
        assertEq(token.balanceOf(ALICE), 300e18);
        assertEq(token.balanceOf(BOB), 184e18);
        assertEq(token.balanceOf(REQUESTER), 16e18);
    }

    function test_infiniteAllowanceIsNotDecremented() public {
        _fund(ALICE, 100e18);
        vm.prank(ALICE);
        token.approve(CAROL, type(uint256).max);
        vm.prank(CAROL);
        token.transferFrom(ALICE, BOB, 100e18);
        assertEq(token.allowance(ALICE, CAROL), type(uint256).max);
    }

    function test_feeRoundsDownForDustAmounts() public {
        _fund(ALICE, 100);
        assertEq(token.feeFor(12), 0);
        assertEq(token.feeFor(13), 1);
        vm.prank(ALICE);
        token.transfer(BOB, 12);
        assertEq(token.balanceOf(BOB), 12, "amounts below 13 wei pay no fee");
        vm.prank(ALICE);
        token.transfer(BOB, 13);
        assertEq(token.balanceOf(BOB), 24);
        assertEq(token.balanceOf(REQUESTER), 1);
    }

    function test_selfTransferPaysFee() public {
        _fund(ALICE, 100e18);
        vm.prank(ALICE);
        token.transfer(ALICE, 100e18);
        assertEq(token.balanceOf(ALICE), 92e18);
        assertEq(token.balanceOf(REQUESTER), 8e18);
    }

    function test_zeroAmountTransferSucceedsWithoutFee() public {
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 0));
        assertEq(token.balanceOf(REQUESTER), 0);
    }

    function testFuzz_feeConservesSupply(address from, address to, uint256 funded, uint256 amount) public {
        vm.assume(from != address(0) && to != address(0));
        vm.assume(!token.isFeeExempt(from, to));
        funded = bound(funded, 0, SUPPLY);
        amount = bound(amount, 0, funded);
        _fund(from, funded);
        uint256 feeBefore = token.balanceOf(REQUESTER);
        uint256 toBefore = token.balanceOf(to);
        uint256 fromBefore = token.balanceOf(from);

        vm.prank(from);
        token.transfer(to, amount);

        uint256 fee = (amount * 800) / 10_000;
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(REQUESTER) - feeBefore, fee, "fee recipient receives exactly 8%");
        if (from != to) {
            assertEq(token.balanceOf(to) - toBefore, amount - fee, "recipient receives exactly 92%");
            assertEq(fromBefore - token.balanceOf(from), amount, "sender pays exactly the amount");
        } else {
            assertEq(fromBefore - token.balanceOf(from), fee, "a self-transfer costs only the fee");
        }
        assertLe(token.balanceOf(from) + token.balanceOf(to) + token.balanceOf(REQUESTER), SUPPLY);
    }

    // ---------------------------------------------------------------------------------------------
    // Launch exemptions: these flows must move exactly what they say
    // ---------------------------------------------------------------------------------------------

    function test_factoryToDistributorAndClaimAreWhole() public {
        uint256 swarm = SUPPLY / 10;
        assertTrue(factory.move(token, DISTRIBUTOR, swarm));
        assertEq(token.balanceOf(DISTRIBUTOR), swarm, "swarm share arrived short");

        vm.prank(DISTRIBUTOR);
        assertTrue(token.transfer(CAROL, swarm));
        assertEq(token.balanceOf(CAROL), swarm, "claim arrived short");
        assertEq(token.balanceOf(DISTRIBUTOR), 0);
        assertEq(token.balanceOf(REQUESTER), 0, "no fee on launch flows");
    }

    function test_factoryTransfersToAnyoneAreWhole() public {
        factory.move(token, ALICE, 1_000e18);
        assertEq(token.balanceOf(ALICE), 1_000e18);
        assertEq(token.balanceOf(REQUESTER), 0);
    }

    function test_poolManagerFlowsAreWholeBothWays() public {
        // Seed: factory -> pool manager.
        factory.move(token, POOL_MANAGER, 10_000e18);
        assertEq(token.balanceOf(POOL_MANAGER), 10_000e18);

        // Buy: pool manager -> trader (`take`).
        vm.prank(POOL_MANAGER);
        token.transfer(ALICE, 1_000e18);
        assertEq(token.balanceOf(ALICE), 1_000e18, "a buy arrived short");

        // Sell: trader -> pool manager (`settle`).
        vm.prank(ALICE);
        token.transfer(POOL_MANAGER, 1_000e18);
        assertEq(token.balanceOf(POOL_MANAGER), 10_000e18, "a sell arrived short");
        assertEq(token.balanceOf(ALICE), 0);

        // Sell through an operator (a router pulling straight into the manager).
        _fund(BOB, 500e18);
        vm.prank(BOB);
        token.approve(CAROL, 500e18);
        vm.prank(CAROL);
        token.transferFrom(BOB, POOL_MANAGER, 500e18);
        assertEq(token.balanceOf(POOL_MANAGER), 10_500e18);
        assertEq(token.balanceOf(REQUESTER), 0, "no fee on pool flows");
    }

    function test_transfersTouchingTheFeeRecipientAreWhole() public {
        _fund(ALICE, 100e18);
        vm.prank(ALICE);
        token.transfer(REQUESTER, 100e18);
        assertEq(token.balanceOf(REQUESTER), 100e18);
        vm.prank(REQUESTER);
        token.transfer(BOB, 100e18);
        assertEq(token.balanceOf(BOB), 100e18);
        assertEq(token.balanceOf(REQUESTER), 0);
    }

    function test_distributorIsReadFromFactoryAtTransferTime() public {
        address newDistributor = address(0xD2);
        _fund(newDistributor, 100e18);
        assertFalse(token.isFeeExempt(newDistributor, BOB));

        factory.setDistributor(LAUNCH, newDistributor);
        assertEq(token.distributor(), newDistributor);
        assertTrue(token.isFeeExempt(newDistributor, BOB));

        vm.prank(newDistributor);
        token.transfer(BOB, 100e18);
        assertEq(token.balanceOf(BOB), 100e18);
    }

    function test_otherLaunchNumbersDistributorIsNotExempt() public {
        address otherDistributor = address(0xD3);
        factory.setDistributor(LAUNCH + 1, otherDistributor);
        _fund(otherDistributor, 100e18);
        vm.prank(otherDistributor);
        token.transfer(BOB, 100e18);
        assertEq(token.balanceOf(BOB), 92e18);
    }

    function test_ordinaryTransfersStillTaxedWhenFactoryHasNoDistributor() public {
        factory.setDistributor(LAUNCH, address(0));
        assertEq(token.distributor(), address(0));
        _fund(ALICE, 100e18);
        vm.prank(ALICE);
        token.transfer(BOB, 100e18);
        assertEq(token.balanceOf(BOB), 92e18);
    }

    function test_directDeploymentWithoutLaunchTaxesOrdinaryTransfers() public {
        IdentityToken direct = new IdentityToken(address(0), address(0), 0, address(0));
        assertEq(direct.distributor(), address(0));
        direct.transfer(ALICE, 100e18);
        assertEq(direct.balanceOf(ALICE), 100e18, "deployer is the fee recipient and so exempt");
        vm.prank(ALICE);
        direct.transfer(BOB, 100e18);
        assertEq(direct.balanceOf(BOB), 92e18);
        assertEq(direct.balanceOf(address(this)), SUPPLY - 100e18 + 8e18);
    }

    function test_factoryAsEoaIsExemptButNotQueried() public {
        address eoaFactory = address(0xFAC);
        IdentityToken direct = new IdentityToken(eoaFactory, address(0), 1, REQUESTER);
        assertEq(direct.distributor(), address(0));
        direct.transfer(eoaFactory, 100e18);
        assertEq(direct.balanceOf(eoaFactory), 100e18);
        vm.prank(eoaFactory);
        direct.transfer(ALICE, 100e18);
        assertEq(direct.balanceOf(ALICE), 100e18);
    }

    function test_revertingFactoryLookupDoesNotBrickTransfers() public {
        RevertingFactory bad = new RevertingFactory();
        IdentityToken direct = new IdentityToken(address(bad), address(0), 1, address(this));
        assertEq(direct.distributor(), address(0));
        direct.transfer(ALICE, 100e18);
        assertEq(direct.balanceOf(ALICE), 100e18, "the deployer is the fee recipient and so exempt");
        vm.prank(ALICE);
        direct.transfer(BOB, 100e18);
        assertEq(direct.balanceOf(BOB), 92e18);
    }

    function test_malformedFactoryLookupDoesNotBrickTransfers() public {
        MalformedFactory bad = new MalformedFactory();
        IdentityToken direct = new IdentityToken(address(bad), address(0), 1, address(this));
        assertEq(direct.distributor(), address(0));
        direct.transfer(ALICE, 100e18);
        assertEq(direct.balanceOf(ALICE), 100e18, "the deployer is the fee recipient and so exempt");
        vm.prank(ALICE);
        direct.transfer(BOB, 100e18);
        assertEq(direct.balanceOf(BOB), 92e18);
    }

    // ---------------------------------------------------------------------------------------------
    // Fee recipient administration
    // ---------------------------------------------------------------------------------------------

    function test_feeRecipientCanHandOn() public {
        vm.expectEmit(true, true, true, true);
        emit FeeRecipientChanged(REQUESTER, CAROL);
        vm.prank(REQUESTER);
        token.setFeeRecipient(CAROL);
        assertEq(token.feeRecipient(), CAROL);

        _fund(ALICE, 100e18);
        vm.prank(ALICE);
        token.transfer(BOB, 100e18);
        assertEq(token.balanceOf(CAROL), 8e18);
        assertEq(token.balanceOf(REQUESTER), 0);
    }

    function test_RevertWhen_strangerSetsFeeRecipient() public {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IdentityToken.NotFeeRecipient.selector, ALICE));
        token.setFeeRecipient(ALICE);
    }

    function test_RevertWhen_factorySetsFeeRecipient() public {
        vm.prank(address(factory));
        vm.expectRevert(abi.encodeWithSelector(IdentityToken.NotFeeRecipient.selector, address(factory)));
        token.setFeeRecipient(ALICE);
    }

    function test_RevertWhen_feeRecipientSetToZero() public {
        vm.prank(REQUESTER);
        vm.expectRevert(IdentityToken.InvalidFeeRecipient.selector);
        token.setFeeRecipient(address(0));
    }

    function test_feeRecipientCannotMoveOrFreezeHolders() public {
        _fund(ALICE, 100e18);
        vm.prank(REQUESTER);
        vm.expectRevert(abi.encodeWithSelector(IdentityToken.ERC20InsufficientAllowance.selector, REQUESTER, 0, 1));
        token.transferFrom(ALICE, REQUESTER, 1);
        assertEq(token.balanceOf(ALICE), 100e18);
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 50e18));
    }

    // ---------------------------------------------------------------------------------------------
    // ERC-20 failure paths
    // ---------------------------------------------------------------------------------------------

    function test_RevertWhen_transferExceedsBalance() public {
        _fund(ALICE, 10e18);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IdentityToken.ERC20InsufficientBalance.selector, ALICE, 10e18, 11e18));
        token.transfer(BOB, 11e18);
    }

    function test_RevertWhen_transferToZeroAddress() public {
        _fund(ALICE, 10e18);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IdentityToken.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
    }

    function test_RevertWhen_transferFromExceedsAllowance() public {
        _fund(ALICE, 10e18);
        vm.prank(ALICE);
        token.approve(CAROL, 5e18);
        vm.prank(CAROL);
        vm.expectRevert(abi.encodeWithSelector(IdentityToken.ERC20InsufficientAllowance.selector, CAROL, 5e18, 6e18));
        token.transferFrom(ALICE, BOB, 6e18);
    }

    function test_RevertWhen_transferFromWithoutAllowance() public {
        _fund(ALICE, 10e18);
        vm.prank(CAROL);
        vm.expectRevert(abi.encodeWithSelector(IdentityToken.ERC20InsufficientAllowance.selector, CAROL, 0, 1));
        token.transferFrom(ALICE, BOB, 1);
    }

    function test_RevertWhen_approveZeroSpender() public {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IdentityToken.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
    }

    function test_approveEmitsAndOverwrites() public {
        vm.expectEmit(true, true, true, true);
        emit Approval(ALICE, CAROL, 5);
        vm.prank(ALICE);
        assertTrue(token.approve(CAROL, 5));
        vm.prank(ALICE);
        token.approve(CAROL, 2);
        assertEq(token.allowance(ALICE, CAROL), 2);
    }

    // ---------------------------------------------------------------------------------------------
    // Deployment script
    // ---------------------------------------------------------------------------------------------

    function test_deployScriptUsesTheGivenConfig() public {
        DeployIdentityToken script = new DeployIdentityToken();
        IdentityToken deployed = script.deploy(
            DeployIdentityToken.Config({
                factory: address(factory), poolManager: POOL_MANAGER, launchNumber: LAUNCH, feeRecipient: REQUESTER
            })
        );
        assertEq(deployed.factory(), address(factory));
        assertEq(deployed.poolManager(), POOL_MANAGER);
        assertEq(deployed.launchNumber(), LAUNCH);
        assertEq(deployed.feeRecipient(), REQUESTER);
        assertEq(deployed.totalSupply(), SUPPLY);
        assertEq(deployed.balanceOf(address(script)), SUPPLY, "minted to the script, the constructor's caller");
    }

    function test_deployScriptZeroFeeRecipientMeansTheDeployer() public {
        DeployIdentityToken script = new DeployIdentityToken();
        IdentityToken deployed = script.deploy(
            DeployIdentityToken.Config({
                factory: address(0), poolManager: address(0), launchNumber: 0, feeRecipient: address(0)
            })
        );
        assertEq(deployed.feeRecipient(), address(script));
    }

    // ---------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------

    /// @dev Funds `who` fee-free from the factory.
    function _fund(address who, uint256 amount) internal {
        factory.move(token, who, amount);
    }
}
