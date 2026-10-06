# Identity (ID)

A fixed-supply ERC-20 that pays an 8% fee on ordinary transfers to the deployer.

| Parameter | Value |
|-----------|-------|
| Name | Identity |
| Symbol | ID |
| Decimals | 18 |
| Total supply | 1,000,000,000 ID = `1000000000000000000000000000` minor units |
| Minted to | `msg.sender` of the constructor, once, in the constructor |
| Transfer fee | 8% (800 bps) of every ordinary transfer, paid to `feeRecipient` |
| Contract | `src/IdentityToken.sol` |

## How the fee works

An ordinary `transfer` or `transferFrom` of `amount` debits the sender by exactly `amount`, credits
the recipient with `amount - fee`, and credits `feeRecipient` with `fee = amount * 800 / 10000`,
rounded down. Three events describe it: `Transfer(from, to, net)`, `Transfer(from, feeRecipient, fee)`
and `FeePaid(from, feeRecipient, fee)`. The total supply never changes.

Amounts under 13 minor units round to a zero fee. That is dust, not a leak: splitting a transfer into
sub-13-wei pieces costs far more gas than the fee it avoids.

### Fee-exempt parties

A transfer is fee-free when its sender **or** recipient is one of:

- the launch **factory** (`factory`, constructor argument);
- the Uniswap v4 **PoolManager** (`poolManager`, constructor argument);
- the launch's **MerkleDistributor**, read as `factory.distributorOf(launchNumber)` at transfer time;
- the **fee recipient** itself.

This is what lets the launch flows move exactly what they say: the factory forwards the swarm's 10%
to the distributor whole, claims leave the distributor whole, the seed reaches the PoolManager whole,
and a trader's buy (PoolManager → trader) and sell (trader → PoolManager) both move the full amount.
Everything else, including wallet-to-wallet transfers and transfers through intermediaries that take
custody without passing through the PoolManager (a router that pulls tokens to itself before settling,
a CEX deposit, a bridge), pays 8%.

### Known limit: transfers routed through the PoolManager are fee-free

The PoolManager exemption is what lets a trader sell (trader → PoolManager) and buy (PoolManager →
trader) whole, which the launch floor requires. The PoolManager is permissionless: inside `unlock()` any
contract may `sync` ID, transfer ID to the manager, `settle()` to be credited, and `take()` the same
amount to any address, with no pool or swap involved; it may also mint ERC-6909 claims of ID and move
them between accounts with no ERC-20 transfer at all. Both legs touch the PoolManager, so a
wallet-to-wallet transfer relayed this way arrives whole and pays no fee. The token cannot tell that
sequence apart from a sell followed by a buy, so no token-side rule can tax the relay without also
taxing swaps and breaking the launch.

The precise fee rule is therefore: **8% on every transfer that does not pass through the PoolManager
(or another exempt party)**. An informed sender with a helper contract can route around the fee at gas
cost; no holder's principal is at risk. Collecting a fee on pool flows as well would need a Uniswap v4
hook on the pool, which is outside this token and this assignment. That is an unresolved deployment
choice for the requester; `test_knownLimit_relayThroughPoolManagerIsFeeFree` documents the behaviour
against a stand-in that copies the manager's unlock/sync/settle/take accounting.

The distributor lookup is a `staticcall`. If `factory` has no code, reverts, returns data that is not
exactly one word, or returns a word that is not an address (non-zero upper 12 bytes), the lookup yields
"no distributor" and the transfer proceeds taxed. A lookup failure can never brick transfers.

## Constructor

```solidity
constructor(address factory_, address poolManager_, uint64 launchNumber_, address feeRecipient_)
```

| Argument | Launch value | Direct deployment |
|----------|--------------|-------------------|
| `factory_` | `$factory` | `address(0)` (no exemption) |
| `poolManager_` | `$poolManager` | `address(0)` (no exemption) |
| `launchNumber_` | `$launchNumber` | `0` |
| `feeRecipient_` | the requester's wallet (`economics.remainderTo`), **required** | `address(0)` = the deployer |

Outside a launch (`factory_ == address(0)`), `feeRecipient_ == address(0)` means "the deployer", i.e.
the constructor's `msg.sender`. **Under a launch the constructor's caller is the ProjectFactory**, a
contract that can neither spend fees nor hand the role on, so the manifest must pass the requester's
wallet (`economics.remainderTo`) explicitly. Whenever `factory_` is non-zero the constructor reverts
with `InvalidFeeRecipient` on a zero recipient, so a manifest that omits it fails at deployment instead
of silently binding the 8% stream to the factory forever. All arguments are static types, so the
manifest can carry them.

### Manifest sketch (custom_token)

```json
{
  "token": {
    "contract": "IdentityToken",
    "name": "Identity",
    "symbol": "ID",
    "decimals": 18,
    "constructorArgs": ["$factory", "$poolManager", "$launchNumber", "<economics.remainderTo>"],
    "totalSupply": "1000000000000000000000000000"
  },
  "contracts": []
}
```

The manifest is written by a separate node; the values above are what this contract expects. The
fourth argument must be the requester's wallet, the same address as `economics.remainderTo`. The zero
address is refused by the constructor and the launch would fail.

## Administrative power

There is exactly one privileged role, the fee recipient, with a two-step hand-off:

- `setFeeRecipient(address)`: callable only by the current `feeRecipient`, records a non-zero
  `pendingFeeRecipient` and emits `FeeRecipientProposed`. Nothing moves yet; fees keep going to the
  current recipient. A later call replaces the pending proposal.
- `acceptFeeRecipient()`: callable only by the pending address, moves the fee stream to it, clears the
  proposal and emits `FeeRecipientChanged`.

Two steps mean a mistyped address, or a contract that cannot call back, cannot take the role and so
cannot strand the stream: the current recipient simply proposes again. Neither function can mint,
burn, pause, blacklist, freeze, or move any balance. The hand-off exists so a rotated key does not
strand the fee stream forever; a key that is already lost cannot propose, so guard it (see below).

There is no owner, no mint, no burn, no pause, no blacklist, no upgrade path, and the runtime contains
no `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT`. The supply is fixed at deployment and cannot grow.

## Trust assumptions

- The fee recipient is trusted to receive 8% of ordinary transfer volume. Holders cannot opt out.
- Transfers touching the fee recipient are fee-free, so the fee recipient can move tokens without tax.
  This is intentional (the fee would otherwise go to itself) but it does mean the recipient enjoys
  tax-free trading against counterparties who pay the full 8% on their side.
- The factory is trusted to report the correct distributor. A factory that reported an arbitrary
  address would grant that address a fee exemption, not access to anyone's balance.
- The PoolManager exemption is a fee exemption for anyone willing to route through the PoolManager
  (see "Known limit" above). The fee recipient should expect the 8% on direct wallet, CEX, bridge and
  custodial-router transfers, not on volume that passes through the pool manager.
- Composability: contracts that assume `balanceOf(to)` rises by exactly `amount` (most lending markets,
  many vaults, naive airdrop contracts) will mis-account unless they are exempt. Only the four parties
  above are exempt. Integrators should measure balance deltas, as the fee-on-transfer checklist item
  in the security reference says.

## Deployment

Under the launch, the ProjectFactory deploys the token via `launchCustom` from the manifest; nothing
here broadcasts a transaction or touches a key.

For a stand-alone deployment, `script/DeployIdentityToken.s.sol` reads these optional environment
variables in `run()` and passes them to `deploy(Config)`:

| Variable | Meaning | Default |
|----------|---------|---------|
| `ID_FACTORY` | factory to exempt | `0x0` |
| `ID_POOL_MANAGER` | PoolManager to exempt | `0x0` |
| `ID_LAUNCH_NUMBER` | launch number for the distributor lookup | `0` |
| `ID_FEE_RECIPIENT` | fee recipient | `0x0` = the broadcasting deployer, allowed only when `ID_FACTORY` is `0x0` |

```bash
forge script script/DeployIdentityToken.s.sol --rpc-url <RPC> --broadcast --sender <DEPLOYER>
```

Tests call `deploy(Config)` directly with explicit values and never read the environment.

## Operational responsibilities

- **Manifest**: the fourth constructor argument must be the requester's wallet
  (`economics.remainderTo`). The constructor refuses the zero address under a launch.
- **Fee recipient key**: guard it. Whoever holds it collects 8% of all ordinary volume and is the only
  party that can propose a hand-off; the proposed address must then accept. A multisig is recommended.
- **Fee economics**: decide whether the fee-free PoolManager relay (see "Known limit") is acceptable or
  whether a pool hook should collect a fee on pool flows as well. This token does not resolve that.
- **Explorer verification** after deployment (`forge verify-contract`) belongs to the network's deployer.
- **Exchange and integrator notice**: tell listings and integrators that ID is a fee-on-transfer token
  so they measure received amounts.
- **No pause, no rescue**: tokens sent to a wrong address are gone; there is no admin recovery.

## Building and testing

```bash
forge build
forge test
forge fmt --check
```

`foundry.toml` pins `solc = "0.8.26"`, sets `bytecode_hash = "none"` and `cbor_metadata = false` for
reproducible bytes, and enables neither `ffi` nor filesystem access. `forge-std` v1.9.7 is vendored as
plain files under `lib/forge-std/src` (MIT/Apache-2.0); there are no submodules.

Tests cover the fee on `transfer` and `transferFrom`, rounding, self-transfers, every exemption, the
distributor lookup (set, unset, other launch number, EOA factory, reverting factory, empty answer,
non-address word, overlong answer), the constructor's refusal of a zero recipient under a launch, the
two-step fee recipient hand-off and its failure paths, the fee-free PoolManager relay as a documented
limit, ERC-20 failure paths, the absence of a mint surface, and the deploy script's config function.
A fuzz test checks supply conservation for arbitrary senders, recipients and amounts.

Tests passing do not constitute a security audit. The launch's protected floor and an independent
adversarial review are separate steps.
