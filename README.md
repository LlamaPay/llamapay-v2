# llamapay-v2

## Features

### Payer
- Single contract per payer
- Contract address created using CREATE2
- Can stream mutltiple tokens through one contract
- Other wallets can deposit tokens on behalf of payer
- Whitelist other addresses to act on payer behalf

### Streams
- Represented as ERC-721s
- Easily transferrable between addresses
- Can withdraw set amount or entire balance redeemable
- Undercollateralized
- Fixed 
- Tracks debt
- Can create stream that started in the past
- Can create stream that starts in the future
- Can whitelist other addresses to withdraw on behalf
- Can redirect funds to address that isn't the wallet holding NFT