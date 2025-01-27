module marketplace::escrow_simple {
    use marketplace::{escrow, marketplace::{Self, MarketPlace}};
    use sui::{balance::Balance, coin::{Self, Coin}, sui::SUI};

    // ====================== Errors ======================
    const EInsufficientAmount: u64 = 411;

    // ====================== Constants ======================

    // ====================== Structs ======================

    public struct Offer<phantom T: key + store> has key, store {
        id: UID,
        owner: address,
        item: ID,
        price: u64,
        market_fee: u64,
        balance: Balance<SUI>,
    }

    public struct OfferKey<phantom T: key + store> has copy, drop, store {
        offer: ID,
        item: ID,
    }

    public struct OfferCap<phantom T: key + store> has key {
        id: UID,
        offer: ID,
    }

    public struct Ext has drop {}

    // ====================== Public Functions ======================

    #[allow(lint(self_transfer))]
    public fun offer<T: key + store>(
        market: &mut MarketPlace,
        item_id: ID,
        price: u64,
        payment: Coin<SUI>,
        ctx: &mut TxContext,
    ) {
        let (offer, offer_cap) = new_offer<T>(
            market,
            item_id,
            price,
            payment,
            ctx,
        );
        let offer_id = object::id(&offer);
        let offer_cap_id = object::id(&offer_cap);

        escrow::emit_offer_event(
            object::id(market),
            offer_id,
            offer_cap_id,
            offer.item,
            offer.price,
            0,
            offer.market_fee,
        );

        // store Offer<T> object into dynamic object field of marketplace with OfferKey<T>
        market.add_to_marketplace(OfferKey<T> { offer: object::id(&offer), item: item_id }, offer);

        // transfer OfferCap<T> to offerer
        transfer::transfer(offer_cap, tx_context::sender(ctx));
    }

    #[allow(lint(self_transfer))]
    public fun revoke_offer<T: key + store>(
        market: &mut MarketPlace,
        offer_id: ID,
        item_id: ID,
        offer_cap: OfferCap<T>,
        ctx: &mut TxContext,
    ) {
        assert!(offer_cap.offer == offer_id, 100);

        let offer = market.remove_from_marketplace(OfferKey<T> { offer: offer_id, item: item_id });

        let offer_id = object::id(&offer);
        let Offer<T> { id, owner: _, item, price, market_fee, balance } = offer;
        object::delete(id);
        let OfferCap { id, offer: _ } = offer_cap;
        object::delete(id);

        escrow::emit_revoke_offer_event(object::id(market), offer_id, item, price, 0, market_fee);

        let mut coin = coin::zero(ctx);
        coin.balance_mut().join(balance);
        transfer::public_transfer(coin, tx_context::sender(ctx));
    }

    #[allow(lint(self_transfer))]
    public fun accept_offer<T: key + store>(
        market: &mut MarketPlace,
        offer_id: ID,
        item: T,
        ctx: &mut TxContext,
    ) {
        let mut offer = market.remove_from_marketplace<OfferKey<T>, Offer<T>>(OfferKey<T> {
            offer: offer_id,
            item: object::id(&item),
        });

        let market_fee = offer.market_fee;
        let item_price = offer.price;

        let market_fee_coin = coin::take<SUI>(&mut offer.balance, market_fee, ctx);
        market.add_balance(market_fee_coin);

        let item_price_coin = coin::take<SUI>(&mut offer.balance, item_price, ctx);
        transfer::public_transfer(item_price_coin, tx_context::sender(ctx));
        transfer::public_transfer(item, offer.owner);

        let Offer { id, owner, item, price, market_fee: _, balance } = offer;

        let mut remain_coin = coin::zero<SUI>(ctx);
        remain_coin.balance_mut().join(balance);
        transfer::public_transfer(remain_coin, owner);
        object::delete(id);

        escrow::emit_accept_offer_event(object::id(market), offer_id, item, price, 0, market_fee);
    }

    public fun decline_offer<T: key + store>(
        market: &mut MarketPlace,
        offer_id: ID,
        item: &T,
        ctx: &mut TxContext,
    ) {
        let offer = market.remove_from_marketplace<OfferKey<T>, Offer<T>>(OfferKey<T> {
            offer: offer_id,
            item: object::id(item),
        });
        let offer_id = object::id(&offer);

        let Offer { id, owner, item: _, price, market_fee, balance } = offer;

        escrow::emit_decline_offer_event(
            object::id(market),
            offer_id,
            object::id(item),
            price,
            0,
            market_fee,
        );

        let mut coin = coin::zero<SUI>(ctx);
        coin.balance_mut().join(balance);
        transfer::public_transfer(coin, owner);
        object::delete(id);
    }

    // ====================== Package Internal Functions ======================
    public fun new_offer<T: key + store>(
        market: &mut MarketPlace,
        item_id: ID,
        price: u64,
        payment: Coin<SUI>,
        ctx: &mut TxContext,
    ): (Offer<T>, OfferCap<T>) {
        let market_fee =
            (
                ((marketplace::get_fee(market, tx_context::sender(ctx)) as u128) * (price as u128)) / 10000,
            ) as u64;

        assert!(payment.value() >= price + market_fee, EInsufficientAmount);

        let balance = payment.into_balance();

        let offer = Offer<T> {
            id: object::new(ctx),
            owner: tx_context::sender(ctx),
            item: item_id,
            price: price,
            market_fee: market_fee,
            balance,
        };
        let offer_cap = OfferCap<T> {
            id: object::new(ctx),
            offer: object::id(&offer),
        };
        (offer, offer_cap)
    }
}
