// SPDX-License-Identifier: MIT
module marketplace::simple;

use marketplace::marketplace::{Self as market, MarketPlace};
use sui::{coin::{Self, Coin}, sui::SUI};

public struct SharedListInfo<phantom T> has key, store {
    id: UID,
    owner: address,
    price: u64,
    item_id: ID,
    marketplace_fee: u64,
}

public struct ListItemKey<phantom T> has copy, drop, store {
    list: ID,
    item: ID,
}

public struct ListItemCap<phantom T> has key {
    id: UID,
    list: ID,
    item: ID,
}

// ================ Error  ================

const ENotAuthorized: u64 = 400;
const ENotSameItem: u64 = 402;
const ENotEnoughFunds: u64 = 403;

// ==================== User Functions  ========================
/// @dev Lists an item on the marketplace with associated price and marketplace
/// fee.
///      This function creates a listing for the item and a corresponding list
/// capability object.
///      It emits a listing event and shares the listing as an object.
/// @param self A mutable reference to the marketplace where the item will be
/// listed.
/// @param item The item to be listed on the marketplace.
/// @param price The price of the item (in mist unit).
/// @param ctx The transaction context of the sender.
public fun list<T: key + store>(
    self: &mut MarketPlace,
    item: T,
    price: u64,
    ctx: &mut TxContext,
) {
    let marketplace_fee =
        (
            ((market::get_fee(self, tx_context::sender(ctx)) as u128) * (price as u128)) / 10000,
        ) as u64;
    let item_id = object::id(&item);
    let market_id = object::id(self);

    let listing = SharedListInfo<T> {
        id: object::new(ctx),
        owner: tx_context::sender(ctx),
        price,
        item_id,
        marketplace_fee,
    };
    let listing_id = object::id(&listing);

    let list_cap = ListItemCap<T> {
        id: object::new(ctx),
        list: object::id(&listing),
        item: item_id,
    };

    market::emit_listing_event(
        market_id,
        object::id(&list_cap),
        object::id(&listing),
        item_id,
        price,
        marketplace_fee,
        tx_context::sender(ctx),
    );

    transfer::share_object(listing);

    self.add_to_marketplace(
        ListItemKey<T> {
            list: listing_id,
            item: item_id,
        },
        item,
    );
    transfer::transfer(list_cap, ctx.sender())
}

/// @dev Updates the price and marketplace fee of a listed item on the
/// marketplace.
///      This function verifies ownership of the listing and ensures the item
/// IDs match.
///      It also emits an update event reflecting the changes.
/// @param self A reference to the marketplace containing the listing.
/// @param list A mutable reference to the shared listing information for the
/// item.
/// @param list_cap The list capability associated with the item being updated.
/// @param item_id The ID of the item being updated in the listing.
/// @param price The new price of the listed item (in mist unit).
/// @param ctx The transaction context of the sender.
public fun update_listing<T: key + store>(
    self: &MarketPlace,
    list: &mut SharedListInfo<T>,
    list_cap: &ListItemCap<T>,
    item_id: ID,
    price: u64,
    ctx: &mut TxContext,
) {
    assert!(list.owner == ctx.sender(), ENotAuthorized);
    assert!(list.item_id == item_id, ENotSameItem);
    assert!(list_cap.item == list.item_id, ENotSameItem);
    let marketplace_fee =
        (
            ((market::get_fee(self, tx_context::sender(ctx)) as u128) * (price as u128)) / 10000,
        ) as u64;

    list.price = price;
    list.marketplace_fee = marketplace_fee;

    market::emit_update_event(
        object::id(self),
        object::id(list_cap),
        item_id,
        object::id(list),
        price,
        marketplace_fee,
        tx_context::sender(ctx),
    );
}

/// @dev Removes a listed item from the marketplace. This function validates
/// ownership and item consistency, transfers the item back to the owner, and
/// emits a delist event.
/// @param self A mutable reference to the marketplace containing the listing.
/// @param list The shared listing information for the item to be delisted.
/// @param list_cap The list capability associated with the item being delisted.
/// @param item The ID of the item to be delisted from the marketplace.
/// @param ctx The transaction context of the sender.
public fun delist<T: key + store>(
    self: &mut MarketPlace,
    list: SharedListInfo<T>,
    list_cap: ListItemCap<T>,
    item: ID,
    ctx: &mut TxContext,
) {
    let ListItemCap { id: cap_id, list: cap_list_id, item: cap_item_id } =
        list_cap;
    let SharedListInfo {
        id,
        owner,
        price: _,
        item_id,
        marketplace_fee: _,
    } = list;
    assert!(id.as_inner() == cap_list_id, ENotSameItem);
    assert!(owner == ctx.sender(), ENotAuthorized);
    assert!(item_id == item, ENotSameItem);
    assert!(item_id == cap_item_id, ENotSameItem);

    let item: T = self.remove_from_marketplace(ListItemKey<T> {
        list: id.to_inner(),
        item: item_id,
    });

    transfer::public_transfer(item, ctx.sender());

    market::emit_delist_event(
        object::id(self),
        item_id,
        id.to_inner(),
        tx_context::sender(ctx),
    );
    id.delete();
    cap_id.delete();
}

/// @dev Handles the purchase of an item from the marketplace. It checks the
/// payment, transfers the item to the buyer, and processes the marketplace fee
/// and seller's payment.
/// @param self A mutable reference to the marketplace handling the transaction.
/// @param list The shared listing information for the item being purchased.
/// @param item The ID of the item being purchased.
/// @param payment The payment coin covering the item's price and the
/// marketplace fee.
/// @param ctx The transaction context of the buyer.
#[allow(lint(self_transfer))]
public fun buy<T: key + store>(
    self: &mut MarketPlace,
    list: SharedListInfo<T>,
    item: ID,
    payment: Coin<SUI>,
    ctx: &mut TxContext,
) {
    let SharedListInfo {
        id,
        owner,
        price,
        item_id: shared_item_id,
        marketplace_fee,
    } = list;
    assert!(owner != ctx.sender(), ENotAuthorized);
    assert!(shared_item_id == item, ENotSameItem);
    let mut payment_balance = payment.into_balance();
    assert!(
        payment_balance.value() >= price + marketplace_fee,
        ENotEnoughFunds,
    );

    let market_fee_coin = coin::take(
        &mut payment_balance,
        marketplace_fee,
        ctx,
    );
    self.add_balance(market_fee_coin);

    let owner_coin = coin::take(&mut payment_balance, price, ctx);
    transfer::public_transfer(owner_coin, owner);

    let item: T = self.remove_from_marketplace(ListItemKey<T> {
        list: id.to_inner(),
        item: item,
    });
    market::emit_buy_event(
        object::id(self),
        object::id(&item),
        price,
        id.to_inner(),
        ctx.sender(),
    );
    transfer::public_transfer(item, ctx.sender());
    let mut remain_coin = coin::zero<SUI>(ctx);
    remain_coin.balance_mut().join(payment_balance);
    transfer::public_transfer(remain_coin, ctx.sender());

    id.delete();
}

// ================ Getter Functions ================

/// @dev Retrieves the owner of the shared listing.
/// @param self A reference to the shared listing information.
/// @return The address of the owner of the listing.
public fun get_owner<T: key + store>(self: &SharedListInfo<T>): address {
    self.owner
}

/// @dev Retrieves the price of the item in the shared listing.
/// @param self A reference to the shared listing information.
/// @return The price of the item in the listing.
public fun get_price<T: key + store>(self: &SharedListInfo<T>): u64 {
    self.price
}

/// @dev Retrieves the item ID from the shared listing.
/// @param self A reference to the shared listing information.
/// @return The ID of the item in the listing.
public fun get_item_id<T: key + store>(self: &SharedListInfo<T>): ID {
    self.item_id
}

/// @dev Retrieves the marketplace fee associated with the shared listing.
/// @param self A reference to the shared listing information.
/// @return The marketplace fee for the listing.
public fun get_fee<T: key + store>(self: &SharedListInfo<T>): u64 {
    self.marketplace_fee
}
