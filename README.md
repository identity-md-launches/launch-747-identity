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
custody (a router that pulls tokens to itself before settling, a CEX deposit, a bridge), pays 8%.

The distributor lookup is a `staticcall`. If `factory` has no code, reverts, or returns malformed data,
the lookup yields "no distributor" and the transfer proceeds taxed. A lookup failure can never brick
transfers.

## Constructor

```solidity
constructor(address factory_, address poolManager_, uint64 launchNumber_, address feeRecipient_)
```

| Argument | Launch value | Direct deployment |
|----------|--------------|-------------------|
| `factory_` | `$factory` | `address(0)` (no exemption) |
| `poolManager_` | `$poolManager` | `address(0)` (no exemption) |
| `launchNumber_` | `$launchNumber` | `0` |
| `feeRecipient_` | the requester's wallet (`economics.remainderTo`) | `address(0)` = the deployer |

`feeRecipient_ == address(0)` means "the deployer", i.e. the constructor's `msg.sender`. **Under a
launch the constructor's caller is the ProjectFactory**, so the manifest must pass the requester's
address explicitly; a zero fee recipient would send every fee to the factory. All arguments are
static types, so the manifest can carry them.

### Manifest sketch (custom_token)

```json
{
  "token": {
    "contract": "IdentityToken",
    "name": "Identity",
    "symbol": "ID",
    "decimals": 18,
    "constructorArgs": ["$factory", "$poolManager", "$launchNumber", "<requester address>"],
    "totalSupply": "1000000000000000000000000000"
  },
  "contracts": []
}
```

The manifest is written by a separate node; the values above are what this contract expects.

## Administrative power

There is exactly one privileged function:

- `setFeeRecipient(address)`: callable only by the current `feeRecipient`, moves the fee stream to a
  new non-zero address. It cannot mint, burn, pause, blacklist, freeze, or move any balance. It exists
  so a lost or rotated key does not strand the fee stream forever.

There is no owner, no mint, no burn, no pause, no blacklist, no upgrade path, and the runtime contains
no `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT`. The supply is fixed at deployment and cannot grow.

## Trust assumptions

- The fee recipient is trusted to receive 8% of ordinary transfer volume. Holders cannot opt out.
- Transfers touching the fee recipient are fee-free, so the fee recipient can move tokens without tax.
  This is intentional (the fee would otherwise go to itself) but it does mean the recipient enjoys
  tax-free trading against counterparties who pay the full 8% on their side.
- The factory is trusted to report the correct distributor. A factory that reported an arbitrary
  address would grant that address a fee exemption, not access to anyone's balance.
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
| `ID_FEE_RECIPIENT` | fee recipient | `0x0` = the broadcasting deployer |

```bash
forge script script/DeployIdentityToken.s.sol --rpc-url <RPC> --broadcast --sender <DEPLOYER>
```

Tests call `deploy(Config)` directly with explicit values and never read the environment.

## Operational responsibilities

- **Fee recipient key**: guard it. Whoever holds it collects 8% of all ordinary volume and is the only
  party that can hand the role on. A multisig is recommended.
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
distributor lookup (set, unset, other launch number, EOA factory, reverting factory, malformed
factory), the fee recipient hand-off and its failure paths, ERC-20 failure paths, the absence of a
mint surface, and the deploy script's config function. A fuzz test checks supply conservation for
arbitrary senders, recipients and amounts.

Tests passing do not constitute a security audit. The launch's protected floor and an independent
adversarial review are separate steps.
