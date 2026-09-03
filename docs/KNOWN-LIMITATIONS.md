# Known limitations

> **Scope.** This file currently records the limitations of the **`shielded-night`** profile.
> The other profiles' entries land with 00005 P6.

## `shielded-night`

### The browser flow needs the DEFAULT port block

Lace resolves the `undeployed` network to fixed endpoints — `127.0.0.1:9944` (node),
`:8088` (indexer), `:6300` (proof server) — and offers no way to be told otherwise. A stack
brought up on a generated port block (`./scripts/pick-ports.sh`) is therefore invisible to it,
and the page will connect to a wallet that is looking at a different chain, or at nothing.

**This profile has no override lane for it, and cannot have one.** The page never learns those
URLs from us: the wallet supplies them through the dApp connector's `getConfiguration()`. That
is what makes the profile port-agnostic in every other respect — only the contract address is
injected — and it is also why the browser flow is pinned to the default ports.

The automated verification is unaffected: `./verify.sh`'s round trips run inside the compose
network against service hostnames, on any port block.

This limitation is shared with the `frontend` (zswap-da) profile.

### The wallet must implement `getProvingProvider`

The page refuses to connect to a `window.midnight` wallet that does not implement the
dApp-connector 4.x `getProvingProvider`. This is a design decision upstream, not a gap: the
dApp hands the wallet the contract's ZK key material and the **wallet** proves, inside its own
trust boundary. A dApp that named its own proof server could send the private witness to a
prover the user never chose.

The consequence is that wallet support is version-dependent, and the page surfaces its own
explicit error ("This wallet does not support dApp proving yet") rather than failing obscurely.
`./verify.sh` cannot see this at all — it exercises the contract through the Node-side harness,
not through a browser — so the wallet requirement is documented here rather than asserted.

Upstream's live Preview deployment depends on this call, which is evidence that a current Lace
build implements it. Whether the same build also serves `undeployed` **with** proving
delegation is measured at the hand test; record what you observe here.

### The reverse conversion only works for coins minted in that browser

sNight → NIGHT in the page works only for wrapper coins minted **in this browser's session
storage**. The dApp connector exposes shielded balances in aggregate only — it does not hand
back the individual coin objects (`{nonce, color, value}`) a burn circuit needs — so the page
keeps the coins it minted itself in `localStorage` and can only spend those.

Consequences, all upstream and none fixed here:

* clearing site data, or opening the page in another browser or profile, loses the ability to
  unwrap coins that wallet still holds (the NIGHT is not lost — the contract still backs the
  credit — but that browser cannot build the burn);
* sNight **received from someone else** cannot be unwrapped in the page.

The Node-side harness has no such limit: it discovers coins from the wallet's own synced state,
which is why `./verify.sh`'s round trips exercise the full unwrap path that the browser cannot.

### The verify driver shares a seed with the Lace hand-test wallet

`SHIELDED_NIGHT_DRIVER_SEED` defaults to the `lace-test` seed, because it is the only
genesis-funded, DUST-registered wallet on this line that no container facade holds open (see
`docs/WALLETS.md`). **Do not run `./verify.sh --shielded-night` while Lace is connected on that
wallet**: two facades on one seed force each other's connection down, and it presents as a
round trip that hangs rather than as a conflict. The verify run and the hand test are
sequential.

The clean fix is a dedicated driver seed with its own NIGHT + DUST provisioning lane, which
this repository does not have yet (the 2.x sibling's `scripts/fund-wallet.sh` is the shape it
would take). Tracked as question Q6 of project 00007.

### The page also offers the live Preview network

Upstream's committed `frontend/.env` carries the real Preview contract address, so the network
dropdown lists *Preview* alongside *Local (undeployed)*. That file is upstream's and this image
applies no patch, so the entry stays. Selecting *Preview* talks to the public Preview network
through your wallet and has nothing to do with this stack; nothing here can or should be
transacted from a demo stack.

### `undeployed` only

This profile deploys to `undeployed` and refuses any other `MN_ENV`. shielded-night's Preview
contract is already live and permanently locked; deploying another one from a demo stack with a
public dev seed would be noise on a real network at best.
