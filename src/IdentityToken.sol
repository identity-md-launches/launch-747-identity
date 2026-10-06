// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The part of the launch factory the token reads at transfer time.
interface ILaunchFactory {
    function distributorOf(uint64 launchNumber) external view returns (address);
}

/// @title Identity (ID)
/// @notice A fixed-supply ERC-20 that pays an 8% fee on ordinary transfers to the deployer.
/// @dev Supply: 1,000,000,000 ID with 18 decimals, minted once to `msg.sender` in the constructor.
///      There is no mint, burn, pause, blacklist or upgrade path: the supply can never grow and no
///      privileged hand can move or freeze a holder's balance.
///
///      Fee rule: every transfer that does not touch an exempt party moves 92% of `amount` to the
///      recipient and 8% to `feeRecipient`. The fee is taken out of `amount`, so the sender's balance
///      drops by exactly `amount` and the supply is unchanged.
///
///      Exempt parties (transfers from or to them move the whole amount):
///        - the launch factory (`factory`), which mints the supply, forwards the swarm's share and
///          seeds the pool;
///        - the Uniswap v4 PoolManager (`poolManager`), so buys and sells into the pool are whole;
///        - the launch's MerkleDistributor, read as `factory.distributorOf(launchNumber)` at transfer
///          time because its address depends on the token's;
///        - the fee recipient itself, so fees are never charged on their own collection.
///      When `factory` is a non-contract (a direct deployment with no launch) the distributor lookup
///      is skipped, and a factory that reverts or returns malformed data is treated as "no distributor".
///
///      Known limit of the PoolManager exemption: the PoolManager is permissionless, so any contract
///      may move ID through it (sync/settle then take, or ERC-6909 claims) and both legs are exempt.
///      The fee therefore applies to transfers that do not pass through the PoolManager; a fee on
///      pool flows would need a pool hook, which is outside this token. See the README.
contract IdentityToken {
    // ---------------------------------------------------------------------------------------------
    // ERC-20 metadata
    // ---------------------------------------------------------------------------------------------

    string public constant name = "Identity";
    string public constant symbol = "ID";
    uint8 public constant decimals = 18;

    /// @notice 1,000,000,000 ID in minor units.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    /// @notice Fee on ordinary transfers, in basis points (8%).
    uint256 public constant FEE_BPS = 800;
    uint256 public constant BPS_DENOMINATOR = 10_000;

    // ---------------------------------------------------------------------------------------------
    // Launch parties
    // ---------------------------------------------------------------------------------------------

    /// @notice The launch factory. Transfers from or to it are fee-free.
    address public immutable factory;
    /// @notice The Uniswap v4 PoolManager. Transfers from or to it are fee-free.
    address public immutable poolManager;
    /// @notice The launch number used to look up the distributor on the factory.
    uint64 public immutable launchNumber;

    /// @notice Where the 8% fee goes. The holder of this role may hand it on in two steps.
    address public feeRecipient;
    /// @notice The address proposed by `setFeeRecipient`; it takes the role by calling `acceptFeeRecipient`.
    address public pendingFeeRecipient;

    // ---------------------------------------------------------------------------------------------
    // ERC-20 state
    // ---------------------------------------------------------------------------------------------

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    // ---------------------------------------------------------------------------------------------
    // Events and errors
    // ---------------------------------------------------------------------------------------------

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event FeePaid(address indexed from, address indexed to, uint256 fee);
    event FeeRecipientProposed(address indexed currentRecipient, address indexed proposedRecipient);
    event FeeRecipientChanged(address indexed previousRecipient, address indexed newRecipient);

    error ERC20InvalidSender(address sender);
    error ERC20InvalidReceiver(address receiver);
    error ERC20InvalidApprover(address approver);
    error ERC20InvalidSpender(address spender);
    error ERC20InsufficientBalance(address sender, uint256 balance, uint256 needed);
    error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed);
    error NotFeeRecipient(address caller);
    error NotPendingFeeRecipient(address caller);
    error InvalidFeeRecipient();

    // ---------------------------------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------------------------------

    /// @param factory_ The launch factory to exempt (address(0) for a deployment outside a launch).
    /// @param poolManager_ The Uniswap v4 PoolManager to exempt (address(0) if none).
    /// @param launchNumber_ The launch number whose distributor is exempt (0 if none).
    /// @param feeRecipient_ Who receives the 8% fee. Outside a launch (`factory_ == address(0)`)
    ///        address(0) means the deployer (`msg.sender`). Under a launch the deployer is the factory
    ///        contract, which could neither spend fees nor hand the role on, so a non-zero recipient
    ///        (the requester's wallet) is required and the constructor reverts otherwise.
    constructor(address factory_, address poolManager_, uint64 launchNumber_, address feeRecipient_) {
        factory = factory_;
        poolManager = poolManager_;
        launchNumber = launchNumber_;

        if (factory_ != address(0) && feeRecipient_ == address(0)) revert InvalidFeeRecipient();
        address recipient = feeRecipient_ == address(0) ? msg.sender : feeRecipient_;
        feeRecipient = recipient;
        emit FeeRecipientChanged(address(0), recipient);

        totalSupply = TOTAL_SUPPLY;
        balanceOf[msg.sender] = TOTAL_SUPPLY;
        emit Transfer(address(0), msg.sender, TOTAL_SUPPLY);
    }

    // ---------------------------------------------------------------------------------------------
    // Fee administration
    // ---------------------------------------------------------------------------------------------

    /// @notice Proposes a new fee recipient. Only the current recipient may call; the proposal takes
    ///         effect when `newRecipient` calls `acceptFeeRecipient`. A later proposal replaces an
    ///         earlier one.
    /// @dev Two steps, so a mistyped address or a contract that cannot call back cannot strand the
    ///      stream: until the proposed address accepts, fees keep going to the current recipient.
    ///      This changes where future fees go; it cannot touch any balance.
    function setFeeRecipient(address newRecipient) external {
        if (msg.sender != feeRecipient) revert NotFeeRecipient(msg.sender);
        if (newRecipient == address(0)) revert InvalidFeeRecipient();
        pendingFeeRecipient = newRecipient;
        emit FeeRecipientProposed(msg.sender, newRecipient);
    }

    /// @notice Completes a hand-off proposed by `setFeeRecipient`. Only the proposed address may call.
    function acceptFeeRecipient() external {
        address pending = pendingFeeRecipient;
        if (pending == address(0) || msg.sender != pending) revert NotPendingFeeRecipient(msg.sender);
        emit FeeRecipientChanged(feeRecipient, msg.sender);
        feeRecipient = msg.sender;
        pendingFeeRecipient = address(0);
    }

    // ---------------------------------------------------------------------------------------------
    // ERC-20
    // ---------------------------------------------------------------------------------------------

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        _transfer(from, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @notice The launch's distributor as the factory reports it, or address(0) when there is none.
    function distributor() public view returns (address) {
        address factory_ = factory;
        if (factory_.code.length == 0) return address(0);
        (bool ok, bytes memory data) = factory_.staticcall(abi.encodeCall(ILaunchFactory.distributorOf, (launchNumber)));
        if (!ok || data.length != 32) return address(0);
        // Decode as a word and range-check it: `abi.decode(data, (address))` reverts on a word with
        // non-zero upper bits, and a lookup failure must never brick transfers.
        uint256 word = abi.decode(data, (uint256));
        if (word > type(uint160).max) return address(0);
        return address(uint160(word));
    }

    /// @notice True when a transfer between `from` and `to` moves the whole amount.
    function isFeeExempt(address from, address to) public view returns (bool) {
        if (from == factory || to == factory) return true;
        if (from == poolManager || to == poolManager) return true;
        address recipient = feeRecipient;
        if (from == recipient || to == recipient) return true;
        address distributor_ = distributor();
        if (distributor_ == address(0)) return false;
        return from == distributor_ || to == distributor_;
    }

    /// @notice The fee an ordinary transfer of `amount` pays (8%, rounded down).
    function feeFor(uint256 amount) public pure returns (uint256) {
        return (amount * FEE_BPS) / BPS_DENOMINATOR;
    }

    // ---------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------

    function _transfer(address from, address to, uint256 amount) internal {
        if (from == address(0)) revert ERC20InvalidSender(address(0));
        if (to == address(0)) revert ERC20InvalidReceiver(address(0));

        uint256 fromBalance = balanceOf[from];
        if (fromBalance < amount) revert ERC20InsufficientBalance(from, fromBalance, amount);

        uint256 fee = isFeeExempt(from, to) ? 0 : feeFor(amount);
        uint256 net = amount - fee;

        unchecked {
            balanceOf[from] = fromBalance - amount;
            // Balances are bounded by totalSupply, so these cannot overflow.
            balanceOf[to] += net;
        }
        emit Transfer(from, to, net);

        if (fee != 0) {
            address recipient = feeRecipient;
            unchecked {
                balanceOf[recipient] += fee;
            }
            emit Transfer(from, recipient, fee);
            emit FeePaid(from, recipient, fee);
        }
    }

    function _approve(address owner, address spender, uint256 amount) internal {
        if (owner == address(0)) revert ERC20InvalidApprover(address(0));
        if (spender == address(0)) revert ERC20InvalidSpender(address(0));
        allowance[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    function _spendAllowance(address owner, address spender, uint256 amount) internal {
        uint256 current = allowance[owner][spender];
        if (current == type(uint256).max) return;
        if (current < amount) revert ERC20InsufficientAllowance(spender, current, amount);
        unchecked {
            allowance[owner][spender] = current - amount;
        }
        emit Approval(owner, spender, current - amount);
    }
}
