module marketplace::collection_escrow {
    use kiosk::{
        floor_price_rule as floor_rule,
        kiosk_lock_rule as lock_rule,
        royalty_rule::{Self, Rule as RoyaltyRule}
    };
    use marketplace::marketplace::{add_balance, MarketPlace};
    use sui::{
        balance::Balance,
        coin::{Self, Coin},
        event::emit,
        kiosk::{KioskOwnerCap, Kiosk},
        kiosk_extension,
        sui::SUI,
        transfer_policy::{TransferPolicy, TransferRequest}
    };

    // ===================== Errors =====================
    const ECanNotPlaceToExtension: u64 = 410;
    const EInsufficientAmount: u64 = 411;
    const EItemNotFound: u64 = 412;
    const EIncorrectPolicy: u64 = 413;
    const EIncorrectOfferId: u64 = 414;
    const ENotAuthorized: u64 = 415;

    public struct Ext has drop {}

    public struct CollectionOffer<phantom T: key + store> has key, store {
        id: UID,
        kiosk: ID,
        balance: Balance<SUI>,
        market_fee: u64,
        royalty_fee: u64,
        policyId: ID,
        owner: address,
    }

    public struct OfferWrapper<phantom T: key + store> {
        offer: CollectionOffer<T>,
        item_id: ID,
        seller: address,
    }

    public struct OfferKey<phantom T: key + store> has copy, drop, store {
        offer: ID,
    }

    public struct OfferCap<phantom T> has key {
        id: UID,
        offer: ID,
    }

    // ===================== Events =====================
    public struct NewOfferEvent<phantom T> has copy, drop {
        kiosk: ID,
        policyId: ID,
        owner: address,
        price: u64,
        royalty_fee: u64,
        market_fee: u64,
        offer_cap: ID,
        offer_id: ID,
    }

    public struct OfferAcceptedEvent<phantom T> has copy, drop {
        offer: ID,
        item: ID,
        buyer: address,
        seller: address,
        price: u64,
    }

    public struct OfferRevokedEvent<phantom T> has copy, drop {
        offer: ID,
        owner: address,
    }

    public fun offer<T: key + store>(
        market: &MarketPlace,
        kiosk: &mut Kiosk,
        kiosk_cap: &KioskOwnerCap,
        payment: Coin<SUI>,
        policy: &TransferPolicy<T>,
        ctx: &mut TxContext,
    ) {
        let payment_balance = payment.into_balance();
        let value = payment_balance.value();

        let market_fee = ((market.get_fee(ctx.sender()) as u128) * (value as u128) / 10000) as u64;

        let royalty_fee = if (policy.has_rule<T, RoyaltyRule>()) {
            let first_round = royalty_rule::fee_amount(policy, value - market_fee);
            let second_round = royalty_rule::fee_amount(policy, value - market_fee - first_round);
            royalty_rule::fee_amount(
                policy,
                value - market_fee - second_round,
            )
        } else {
            0
        };

        assert!(value > market_fee + royalty_fee, EInsufficientAmount);

        let offer = CollectionOffer<T> {
            id: object::new(ctx),
            kiosk: object::id(kiosk),
            balance: payment_balance,
            market_fee,
            royalty_fee,
            policyId: object::id(policy),
            owner: ctx.sender(),
        };
        let offer_cap = OfferCap<T> {
            id: object::new(ctx),
            offer: offer.id.to_inner(),
        };

        if (kiosk_extension::is_installed<Ext>(kiosk) == false) {
            kiosk_extension::add(Ext {}, kiosk, kiosk_cap, 3, ctx);
        } else if (kiosk_extension::is_enabled<Ext>(kiosk) == false) {
            kiosk_extension::enable<Ext>(kiosk, kiosk_cap);
        };

        emit(NewOfferEvent<T> {
            kiosk: offer.kiosk,
            price: value, // 100
            policyId: offer.policyId,
            owner: offer.owner,
            royalty_fee, // 10
            market_fee, // 2
            offer_cap: offer_cap.id.to_inner(),
            offer_id: offer.id.to_inner(),
        });

        kiosk_extension::storage_mut(Ext {}, kiosk).add(
            OfferKey<T> { offer: offer.id.to_inner() },
            offer,
        );
        transfer::transfer(offer_cap, ctx.sender())
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
        assert!(accepter_kiosk.has_item_with_type<T>(item_id), EItemNotFound);
        let mut offer = kiosk_extension::storage_mut(Ext {}, offerer_kiosk).remove<
            OfferKey<T>,
            CollectionOffer<T>,
        >(OfferKey<T> { offer: offer_id });

        assert!(offer.policyId == object::id(policy), EIncorrectPolicy);

        let balance_value = offer.balance.value();
        let market_fee = offer.market_fee;
        let royalty_fee = offer.royalty_fee;

        let market_fee_coin = coin::take<SUI>(&mut offer.balance, market_fee, ctx);
        market.add_balance(market_fee_coin);

        let purchase_cap = accepter_kiosk.list_with_purchase_cap<T>(
            accepter_kiosk_cap,
            item_id,
            (balance_value - market_fee - royalty_fee),
            ctx,
        );

        let price_by_cap = purchase_cap.purchase_cap_min_price();

        let payment_coin = coin::take<SUI>(
            &mut offer.balance,
            price_by_cap,
            ctx,
        );
        let (item, mut request) = accepter_kiosk.purchase_with_cap<T>(purchase_cap, payment_coin);

        if (offer.royalty_fee > 0) {
            let royalty_fee = royalty_rule::fee_amount(policy, price_by_cap);
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

        (OfferWrapper<T> { offer: offer, item_id, seller: ctx.sender() }, request)
    }

    #[allow(lint(self_transfer))]
    public fun confirm_offer_accepted<T: key + store>(
        offer_wrapper: OfferWrapper<T>,
        request: TransferRequest<T>,
        policy: &TransferPolicy<T>,
        ctx: &mut TxContext,
    ) {
        policy.confirm_request(request);

        let OfferWrapper { offer, item_id, seller } = offer_wrapper;

        let offer_id = object::id(&offer);
        emit(OfferAcceptedEvent<T> {
            offer: offer_id,
            item: item_id,
            buyer: offer.owner,
            seller,
            price: offer.balance.value(),
        });

        let CollectionOffer<T> {
            id,
            kiosk: _,
            balance,
            market_fee: _,
            royalty_fee: _,
            policyId: _,
            owner: _,
        } = offer;

        let mut remain_coin = coin::zero<SUI>(ctx);
        remain_coin.balance_mut().join(balance);
        transfer::public_transfer(remain_coin, ctx.sender());
        object::delete(id);
    }

    #[allow(lint(self_transfer))]
    public fun revoke_offer<T: key + store>(
        kiosk: &mut Kiosk,
        kiosk_cap: &KioskOwnerCap,
        offer_id: ID,
        offer_cap: OfferCap<T>,
        ctx: &mut TxContext,
    ) {
        assert!(offer_cap.offer == offer_id, EIncorrectOfferId);
        assert!(kiosk.has_access(kiosk_cap), ENotAuthorized);

        let offer = kiosk_extension::storage_mut(Ext {}, kiosk).remove<
            OfferKey<T>,
            CollectionOffer<T>,
        >(OfferKey<T> { offer: offer_id });

        let offer_id = object::id(&offer);
        let CollectionOffer<T> {
            id,
            kiosk: _,
            balance,
            market_fee: _,
            royalty_fee: _,
            policyId: _,
            owner: _,
        } = offer;
        object::delete(id);

        let OfferCap { id, offer: _ } = offer_cap;
        object::delete(id);

        let mut coin = coin::zero(ctx);
        coin.balance_mut().join(balance);
        transfer::public_transfer(coin, ctx.sender());
        emit(OfferRevokedEvent<T> {
            offer: offer_id,
            owner: ctx.sender(),
        });
    }

    public(package) fun emit_collection_offer_event<T>(
        kiosk: ID,
        offer_id: ID,
        offer_cap: ID,
        price: u64,
        market_fee: u64,
        owner: address,
    ) {
        emit(NewOfferEvent<T> {
            kiosk,
            price,
            policyId: offer_id,
            owner,
            royalty_fee: 0,
            market_fee,
            offer_cap,
            offer_id,
        });
    }

    public(package) fun emit_offer_accepted_event<T>(
        offer: ID,
        item: ID,
        buyer: address,
        seller: address,
        price: u64,
    ) {
        emit(OfferAcceptedEvent<T> {
            offer,
            item,
            buyer,
            seller,
            price,
        });
    }

    public(package) fun emit_offer_revoked_event<T>(offer: ID, owner: address) {
        emit(OfferRevokedEvent<T> {
            offer,
            owner,
        });
    }

    #[test_only]
    public fun offer_event_id<T>(event: &NewOfferEvent<T>): ID {
        event.offer_id
    }
}
