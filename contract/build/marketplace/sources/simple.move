// SPDX-License-Identifier: MIT
module marketplace::simple {
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

    public fun delist<T: key + store>(
        self: &mut MarketPlace,
        list: SharedListInfo<T>,
        list_cap: ListItemCap<T>,
        item: ID,
        ctx: &mut TxContext,
    ) {
        let ListItemCap { id: cap_id, list: cap_list_id, item: cap_item_id } = list_cap;
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
        assert!(payment_balance.value() >= price + marketplace_fee, ENotEnoughFunds);

        let market_fee_coin = coin::take(&mut payment_balance, marketplace_fee, ctx);
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

    public fun get_owner<T: key + store>(self: &SharedListInfo<T>): address {
        self.owner
    }

    public fun get_price<T: key + store>(self: &SharedListInfo<T>): u64 {
        self.price
    }

    public fun get_item_id<T: key + store>(self: &SharedListInfo<T>): ID {
        self.item_id
    }

    public fun get_fee<T: key + store>(self: &SharedListInfo<T>): u64 {
        self.marketplace_fee
    }
}
