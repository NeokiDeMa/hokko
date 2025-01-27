module marketplace::escrow {
    use kiosk::{
        floor_price_rule as floor_rule,
        kiosk_lock_rule as lock_rule,
        royalty_rule::{Self, Rule as RoyaltyRule}
    };
    use marketplace::marketplace::{Self, MarketPlace};
    use sui::{
        balance::Balance,
        coin::{Self, Coin},
        event::emit,
        kiosk::{Kiosk, KioskOwnerCap},
        kiosk_extension,
        sui::SUI,
        transfer_policy::{TransferPolicy, TransferRequest}
    };

    // ====================== Errors ======================
    const ECanNotPlaceToExtension: u64 = 410;
    const EInsufficientAmount: u64 = 411;

    // ====================== Structs ======================

    public struct Offer<phantom T: key + store> has key, store {
        id: UID,
        kiosk: ID,
        owner: address,
        item: ID,
        // df_infos: VecMap<Name, ID>, // key : name of dynamic field, value : id of object
        price: u64,
        royalty_fee: u64,
        market_fee: u64,
        balance: Balance<SUI>,
    }

    public struct OfferWrapper<phantom T: key + store> {
        offer: Offer<T>,
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

    // ====================== Events ======================

    public struct OfferEvent has copy, drop {
        kiosk: ID,
        offer_id: ID,
        offer_cap: ID,
        item: ID,
        price: u64,
        royalty_fee: u64,
        market_fee: u64,
    }

    public struct RevokeOfferEvent has copy, drop {
        kiosk: ID,
        offer_id: ID,
        item: ID,
        price: u64,
        royalty_fee: u64,
        market_fee: u64,
    }

    public struct AcceptOfferEvent has copy, drop {
        kiosk: ID,
        offer_id: ID,
        item: ID,
        price: u64,
        royalty_fee: u64,
        market_fee: u64,
    }

    public struct DeclineOfferEvent has copy, drop {
        kiosk: ID,
        offer_id: ID,
        item: ID,
        price: u64,
        royalty_fee: u64,
        market_fee: u64,
    }

    // ====================== Public Functions ======================
    #[allow(lint(self_transfer))]
    public fun offer<T: key + store>(
        kiosk: &mut Kiosk,
        kiosk_cap: &KioskOwnerCap,
        item_id: ID,
        price: u64,
        payment: Coin<SUI>,
        policy: &TransferPolicy<T>,
        market: &mut MarketPlace,
        ctx: &mut TxContext,
    ) {
        // length of df_names is should be equal to length of df_object_ids
        let (offer, offer_cap) = new_offer<T>(
            kiosk,
            kiosk_cap,
            item_id,
            price,
            payment,
            policy,
            market,
            ctx,
        );
        let offer_id = object::id(&offer);
        let offer_cap_id = object::id(&offer_cap);

        // if kiosk has no extension or extension is disabled -> install or enable extension
        if (kiosk_extension::is_installed<Ext>(kiosk) == false) {
            kiosk_extension::add(Ext {}, kiosk, kiosk_cap, 3, ctx);
        } else if (kiosk_extension::is_enabled<Ext>(kiosk) == false) {
            kiosk_extension::enable<Ext>(kiosk, kiosk_cap);
        };

        emit_offer_event(
            offer.kiosk,
            offer_id,
            offer_cap_id,
            offer.item,
            offer.price,
            offer.royalty_fee,
            offer.market_fee,
        );

        // store Offer<T> object into kiosk extension storage
        kiosk_extension::storage_mut(Ext {}, kiosk).add(
            OfferKey<T> { offer: object::id(&offer), item: item_id },
            offer,
        );

        // transfer OfferCap<T> to offerer
        transfer::transfer(offer_cap, tx_context::sender(ctx));
    }

    #[allow(lint(self_transfer))]
    public fun revoke_offer<T: key + store>(
        kiosk: &mut Kiosk,
        kiosk_cap: &KioskOwnerCap,
        offer_id: ID,
        item_id: ID,
        offer_cap: OfferCap<T>,
        ctx: &mut TxContext,
    ) {
        assert!(offer_cap.offer == offer_id, 100);
        assert!(kiosk.has_access(kiosk_cap), 100);

        let offer = kiosk_extension::storage_mut(Ext {}, kiosk).remove<
            OfferKey<T>,
            Offer<T>,
        >(OfferKey<T> { offer: offer_id, item: item_id });
        let offer_id = object::id(&offer);
        let Offer {
            id,
            kiosk,
            owner: _,
            item,
            price,
            market_fee,
            royalty_fee,
            balance,
        } = offer;
        object::delete(id);
        let OfferCap { id, offer: _ } = offer_cap;
        object::delete(id);

        emit_revoke_offer_event(kiosk, offer_id, item, price, royalty_fee, market_fee);

        let mut coin = coin::zero(ctx);
        coin.balance_mut().join(balance);
        transfer::public_transfer(coin, tx_context::sender(ctx));
    }

    public fun accept_offer<T: key + store>(
        offerer_kiosk: &mut Kiosk,
        offer_id: ID,
        accepter_kiosk: &mut Kiosk,
        accepter_kiosk_cap: &KioskOwnerCap,
        item_id: ID,
        policy: &mut TransferPolicy<T>,
        market: &mut MarketPlace,
        ctx: &mut TxContext,
    ): (OfferWrapper<T>, TransferRequest<T>) {
        let mut offer = kiosk_extension::storage_mut(Ext {}, offerer_kiosk).remove<
            OfferKey<T>,
            Offer<T>,
        >(OfferKey<T> { offer: offer_id, item: item_id });
        let market_fee = offer.market_fee;
        let royalty_fee = offer.royalty_fee;
        let item_price = offer.price;

        let market_fee_coin = coin::take<SUI>(&mut offer.balance, market_fee, ctx);
        market.add_balance(market_fee_coin);

        let item_price_coin = coin::take<SUI>(&mut offer.balance, item_price, ctx);
        accepter_kiosk.list<T>(accepter_kiosk_cap, item_id, item_price);

        let (item, mut request) = accepter_kiosk.purchase<T>(item_id, item_price_coin);
        if (royalty_fee > 0) {
            let royalty_fee_coin = coin::take<SUI>(&mut offer.balance, royalty_fee, ctx);
            royalty_rule::pay<T>(policy, &mut request, royalty_fee_coin);
        };

        assert!(kiosk_extension::can_place<Ext>(offerer_kiosk), ECanNotPlaceToExtension);
        if (policy.has_rule<T, lock_rule::Rule>()) {
            kiosk_extension::lock(Ext {}, offerer_kiosk, item, policy);
            lock_rule::prove(&mut request, offerer_kiosk);
        } else {
            kiosk_extension::place(Ext {}, offerer_kiosk, item, policy);
        };
        if (policy.has_rule<T, floor_rule::Rule>()) {
            floor_rule::prove(policy, &mut request);
        };
        (OfferWrapper<T> { offer: offer }, request)
    }

    public fun confirm_offer_accepted<T: key + store>(
        // offerer_kiosk: &mut Kiosk,
        offer_wrapper: OfferWrapper<T>,
        request: TransferRequest<T>,
        policy: &TransferPolicy<T>,
        ctx: &mut TxContext,
    ) {
        policy.confirm_request(request);

        let OfferWrapper { offer } = offer_wrapper;
        let offer_id = object::id(&offer);

        emit_accept_offer_event(
            offer.kiosk,
            offer_id,
            offer.item,
            offer.price,
            offer.royalty_fee,
            offer.market_fee,
        );

        // have to destroy offer object here
        // return back balance to offer owner
        let Offer {
            id,
            kiosk: _,
            owner,
            item: _,
            price: _,
            market_fee: _,
            royalty_fee: _,
            balance,
        } = offer;

        let mut remain_coin = coin::zero<SUI>(ctx);
        remain_coin.balance_mut().join(balance);
        transfer::public_transfer(remain_coin, owner);
        object::delete(id);

        // kiosk_extension::storage_mut(Ext{}, offerer_kiosk).add(OfferKey<T>{offer: object::id(&offer), item: offer.item}, offer);
    }

    public fun decline_offer<T: key + store>(
        offerer_kiosk: &mut Kiosk,
        offer_id: ID,
        item: &T,
        ctx: &mut TxContext,
    ) {
        let offer = kiosk_extension::storage_mut(Ext {}, offerer_kiosk).remove<
            OfferKey<T>,
            Offer<T>,
        >(OfferKey<T> { offer: offer_id, item: object::id(item) });

        let offer_id = object::id(&offer);

        let Offer {
            id,
            kiosk,
            owner,
            item,
            price,
            market_fee,
            royalty_fee,
            balance,
        } = offer;

        let mut coin = coin::zero<SUI>(ctx);

        emit_decline_offer_event(
            kiosk,
            offer_id,
            item,
            price,
            royalty_fee,
            market_fee,
        );

        coin.balance_mut().join(balance);
        transfer::public_transfer(coin, owner);
        id.delete();
    }

    // ====================== Package Internal Functions ======================
    fun new_offer<T: key + store>(
        kiosk: &mut Kiosk,
        kiosk_cap: &KioskOwnerCap,
        item_id: ID,
        // df_object_ids: vector<ID>,
        price: u64,
        payment: Coin<SUI>,
        policy: &TransferPolicy<T>,
        market: &MarketPlace,
        ctx: &mut TxContext,
    ): (Offer<T>, OfferCap<T>) {
        assert!(kiosk.has_access(kiosk_cap), 100);

        let market_fee =
            (
                ((marketplace::get_fee(market, tx_context::sender(ctx)) as u128) * (price as u128)) / 10000,
            ) as u64;

        let mut royalty_fee = 0;
        if (policy.has_rule<T, RoyaltyRule>()) {
            royalty_fee = royalty_rule::fee_amount(policy, price);
        };

        assert!(payment.value() >= price + market_fee + royalty_fee, EInsufficientAmount);

        // let df_infos = vec_map::empty<Name, ID>();
        // let mut i = 0;
        // while (i < df_names.length()) {
        //     df_infos.insert(df_names[i], df_object_ids[i]);
        //     i = i + 1;
        // };
        let balance = payment.into_balance();
        let offer = Offer<T> {
            id: object::new(ctx),
            kiosk: object::id(kiosk),
            owner: tx_context::sender(ctx),
            item: item_id,
            price: price,
            market_fee: market_fee,
            royalty_fee: royalty_fee,
            balance,
        };
        let offer_cap = OfferCap<T> {
            id: object::new(ctx),
            offer: object::id(&offer),
        };
        (offer, offer_cap)
    }

    // ====================== Emit Event Functions ======================

    public(package) fun emit_offer_event(
        kiosk: ID,
        offer_id: ID,
        offer_cap: ID,
        item: ID,
        price: u64,
        royalty_fee: u64,
        market_fee: u64,
    ) {
        emit(OfferEvent {
            kiosk,
            offer_id,
            offer_cap,
            item,
            price,
            royalty_fee,
            market_fee,
        });
    }

    public(package) fun emit_revoke_offer_event(
        kiosk: ID,
        offer_id: ID,
        item: ID,
        price: u64,
        royalty_fee: u64,
        market_fee: u64,
    ) {
        emit(RevokeOfferEvent {
            kiosk,
            offer_id,
            item,
            price,
            royalty_fee,
            market_fee,
        });
    }

    public(package) fun emit_accept_offer_event(
        kiosk: ID,
        offer_id: ID,
        item: ID,
        price: u64,
        royalty_fee: u64,
        market_fee: u64,
    ) {
        emit(AcceptOfferEvent {
            kiosk,
            offer_id,
            item,
            price,
            royalty_fee,
            market_fee,
        });
    }

    public(package) fun emit_decline_offer_event(
        kiosk: ID,
        offer_id: ID,
        item: ID,
        price: u64,
        royalty_fee: u64,
        market_fee: u64,
    ) {
        emit(DeclineOfferEvent {
            kiosk,
            offer_id,
            item,
            price,
            royalty_fee,
            market_fee,
        });
    }

    // ====================== Test ======================
    #[test_only]
    public fun offer_event_id(event: &OfferEvent): ID {
        event.offer_id
    }
}
