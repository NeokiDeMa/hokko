# Launchpad package

## Installation
Add this in your project Move.toml file:
```toml 
[dependencies]
launchpad = {git = "https://github.com/NeokiDeMa/hokko.git", subdir = "launchpad", rev = "main"}

```

## Overview

The Launchpad package contains 4 modules:

- `launchpad`: Contains Launchpad-related functions. Can be managed by Admin.
- `collection_manager`: Contains Collection-related functions. Can be managed by Creator.
- `roles`: Contains the roles-related functions. Roles: Admin, Creator.
- `utils`: Utility functions.

## Process

- The developer creates a collection through their own NFT contract, creates a shared `Collection` object, and obtains
  the `Creator` role. (using the `launchpad::collection_manager::new` function)
- The `Creator` can update the collection start timestamps if required.
- The `Creator` can add addresses to the whitelist if the whitelist is enabled.
- The `Creator` can pause or resume the collection.
- The `Creator` can withdraw the balance from the collection. The fee from the collection price goes to the launchpad
  balance, and the rest goes to the `Collection` balance.
- Minting goes through the developer's NFT contract using the `launchpad::mint` or `launchpad::mint_with_kiosk`
  functions.

## Modules

### Launchpad module

View functions can be called by any account. Admin functions require the appropriate role to be called.

#### Structs

- `Launchpad`: Contains the launchpad details like id, fee_percentage, balance, collections, collection_types.
- `LaunchpadCollectionState`: Contains the collection state like NotFound, Pending, Approved, Rejected, Paused.

#### View Functions

- `collection_state`: Returns `LaunchpadCollectionState`, the current state of the collection in the launchpad.

#### Structs

- `Collection`: Contains the collection details like id, is_paused, name, description, supply, price, is_kiosk,
  start_timestamp_ms, item_type, items, max_items_per_address, items_per_address, balance, whitelist_enabled,
  whitelist_start_timestamp_ms, whitelist, whitelist_price, whitelist_supply.
- `CollectionPhase`: Contains the collection phase like NotStarted, Whitelist, Public, Ended.

#### View Functions

- `phase`: Returns `CollectionPhase`, the current phase of the collection.

#### Public Functions

- `new`: Creates a new collection. Must be called directly from the developer's NFT contract.
- `mint`: If kiosk is enabled mints an NFT. Must be called directly from the developer's NFT contract.
- `mint_with_kiosk`: If kiosk is enabled mints an NFT with kiosk. Must be called directly from the developer's NFT
  contract.

#### Admin Functions

- `set_start_timestamps`: Updates the collection start timestamps.
- `update_whitelist`: If the whitelist is enabled updates the whitelist with addresses and allocations.
- `pause`: Pauses the collection.
- `resume`: Resumes the collection.
- `withdraw`: Withdraws the balance from the collection.
