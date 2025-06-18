# Options Contracts

## Deployment

Need to tell hyperCore that we want to deploy in a slow block:

```
npx @layerzerolabs/hyperliquid-composer set-block --size big --network mainnet --private-key $PRIVATE_KEY
```

This will tell hypercore that any tx coming from signing wallet will be in slow block for hyperEVM. This needs some HYPE or USDC on **hyperCore** to work, as this tells the chain that the signing wallet is a "Core user".

Run forge script:

```
forge script script/Market.s.sol --broadcast
```

Switch back to fast blocks with:
```
npx @layerzerolabs/hyperliquid-composer set-block --size small --network mainnet --private-key $PRIVATE_KEY
```

Deployment is expensive. Deploying a proxy and the current Market implementation cost ~4.5m gas at 19 gwei, which was about $14
