// SPDX-License-Identifier: MIT
module marketplace::marketplace {
    use access_control::access_control::{Self as a_c, OwnerCap, has_cap_access, SRoles, RoleCap};
    use kiosk::{
        floor_price_rule as floor_rule,
        kiosk_lock_rule as l_rule,
        personal_kiosk as PKiosk,
        royalty_rule as r_rule
    };
    use std::string::{String, utf8};
    use sui::{
        balance::{Self, Balance},
        coin::{Self, Coin},
        dynamic_object_field,
        event::emit,
        kiosk::{Self, Kiosk, PurchaseCap, KioskOwnerCap},
        package,
        sui::SUI,
        transfer_policy::{TransferRequest, TransferPolicy},
        vec_map::{Self as map, VecMap}
    };

    public struct MARKETPLACE has drop {}

    public struct MarketPlace has key {
        id: UID,
        // Name of the marketplace
        name: String,
        // Base fee for the marketplace in percentage 100 = 1%
        baseFee: u16,
        // Personal fee for each user in percentage 100 = 1%, 10000 = 100%
        personalFee: VecMap<address, u16>,
        // Store PurchaseCap for each store
        balance: Balance<SUI>,
    }

    // public struct MarketPlaceOwner {}

    public struct SItemWithPurchaseCap<phantom T: key + store> has key {
        id: UID,
        // Kiosk id
        kioskId: ID,
        // purchaseCap for the item
        purchaseCap: PurchaseCap<T>,
        // Id of the item that is listed
        item_id: ID,
        // Minimum price for the item
        min_price: u64,
        // Owner of the kiosk
        owner: address,
        // Royalty fee for the item
        royalty_fee: u64,
        // MarketPlace Fee,
        marketplace_fee: u64,
    }

    public struct AdminCap has key, store {
        id: UID,
    }

    // ======================== Error  =======================
    const ENotAuthorized: u64 = 400;
    const ENotSameKiosk: u64 = 401;
    const ENotSameItem: u64 = 402;
    const ENotEnoughFunds: u64 = 403;
    const ENotSameLength: u64 = 404;

    // ======================== Events ========================
    public struct KioskCreatedEvent has copy, drop {
        kiosk: ID,
        personal_kiosk_cap: ID,
        owner: address,
    }

    public struct PersonalFeeSetEvent has copy, drop {
        recipient: vector<address>,
        fee: vector<u16>,
    }

    public struct ItemListedEvent has copy, drop {
        kiosk: ID,
        kiosk_cap: ID,
        shared_purchaseCap: ID,
        item: ID,
        price: u64,
        marketplace_fee: u64,
        royalty_fee: u64,
        owner: address,
    }

    public struct ItemUpdatedEvent has copy, drop {
        kiosk: ID,
        kiosk_cap: ID,
        item: ID,
        shared_purchaseCap: ID,
        price: u64,
        marketplace_fee: u64,
        royalty_fee: u64,
        owner: address,
    }

    public struct ItemDelistedEvent has copy, drop {
        kiosk: ID,
        item: ID,
        shared_purchaseCap: ID,
        owner: address,
    }

    public struct ItemBoughtEvent has copy, drop {
        kiosk: ID,
        item: ID,
        price: u64,
        shared_purchaseCap: ID,
        buyer: address,
    }

    fun init(otw: MARKETPLACE, ctx: &mut TxContext) {
        let new_marketplace = object::new(ctx);
        transfer::share_object(MarketPlace {
            id: new_marketplace,
            name: utf8(b"Hokko"),
            baseFee: 200, // 2%
            personalFee: map::empty(),
            balance: balance::zero(),
        });
        a_c::new<MARKETPLACE>(&otw, ctx);
        package::claim_and_keep(otw, ctx);
    }

    // ==================== User Functions  ========================

    #[allow(lint(self_transfer))]
    public fun create_kiosk(ctx: &mut TxContext): (ID, ID) {
        let (mut kiosk, kioskCap) = kiosk::new(ctx);
        let kioskId = object::id(&kiosk);
        kiosk::set_owner(&mut kiosk, &kioskCap, ctx);

        let personal_kiosk_cap = PKiosk::new(&mut kiosk, kioskCap, ctx);
        let pkc_id = object::id(&personal_kiosk_cap);

        transfer::public_share_object(kiosk);
        PKiosk::transfer_to_sender(personal_kiosk_cap, ctx);
        emit(KioskCreatedEvent {
            kiosk: kioskId,
            personal_kiosk_cap: pkc_id,
            owner: tx_context::sender(ctx),
        });
        (kioskId, pkc_id)
    }

    public fun list_kiosk_item<T: key + store>(
        market: &MarketPlace,
        kiosk_cap: &KioskOwnerCap,
        kiosk: &mut Kiosk,
        tp: &TransferPolicy<T>,
        item_id: ID,
        price: u64,
        ctx: &mut TxContext,
    ) {
        let kioskId = object::id(kiosk);
        // List with purchase cap checks if kiosk cap has access
        let purchase_cap = kiosk::list_with_purchase_cap<T>(kiosk, kiosk_cap, item_id, price, ctx);

        let mut royalty_fee = 0;
        if (tp.has_rule<T, r_rule::Rule>()) {
            royalty_fee = r_rule::fee_amount(tp, price);
        };

        let marketplace_fee =
            (((get_fee(market, tx_context::sender(ctx)) as u128) * (price as u128)) / 10000) as u64;

        let new_UID = object::new(ctx);
        let new_id = object::uid_to_inner(&new_UID);
        transfer::share_object(SItemWithPurchaseCap<T> {
            id: new_UID,
            kioskId: kioskId,
            purchaseCap: purchase_cap,
            item_id,
            min_price: price,
            owner: tx_context::sender(ctx),
            royalty_fee,
            marketplace_fee: marketplace_fee,
        });
        // add the royalty fee and the marketplace fee to the price to the DB
        let price = price + royalty_fee + marketplace_fee;
        emit(ItemListedEvent {
            kiosk: kioskId,
            kiosk_cap: object::id(kiosk_cap),
            shared_purchaseCap: new_id,
            item: item_id,
            price: price,
            marketplace_fee,
            royalty_fee,
            owner: tx_context::sender(ctx),
        });
    }

    public fun list<T: key + store>(
        market: &MarketPlace,
        kiosk_cap: &KioskOwnerCap,
        kiosk: &mut Kiosk,
        tp: &TransferPolicy<T>,
        item: T,
        price: u64, // 200 SUI
        ctx: &mut TxContext,
    ) {
        let item_id = object::id(&item);
        let kiosk_id = object::id(kiosk);

        kiosk::place<T>(kiosk, kiosk_cap, item);
        let purchase_cap = kiosk::list_with_purchase_cap<T>(kiosk, kiosk_cap, item_id, price, ctx);

        let mut royalty_fee = 0;
        if (tp.has_rule<T, r_rule::Rule>()) {
            royalty_fee = r_rule::fee_amount(tp, price);
        };

        let marketplace_fee =
            (((get_fee(market, tx_context::sender(ctx)) as u128) * (price as u128)) / 10000) as u64;

        let new_UID = object::new(ctx);
        let new_id = object::uid_to_inner(&new_UID);
        transfer::share_object(SItemWithPurchaseCap<T> {
            id: new_UID,
            kioskId: kiosk_id,
            purchaseCap: purchase_cap,
            item_id,
            min_price: price,
            owner: tx_context::sender(ctx),
            royalty_fee,
            marketplace_fee,
        });
        // add the royalty fee and the marketplace fee to the price to the DB
        let price = price + royalty_fee + marketplace_fee;
        emit(ItemListedEvent {
            kiosk: kiosk_id,
            kiosk_cap: object::id(kiosk_cap),
            shared_purchaseCap: new_id,
            item: item_id,
            price: price,
            marketplace_fee,
            royalty_fee,
            owner: tx_context::sender(ctx),
        });
    }

    public fun update_listing<T: key + store>(
        market: &MarketPlace,
        s_item_pc: &mut SItemWithPurchaseCap<T>,
        kiosk_cap: &KioskOwnerCap,
        kiosk: &mut Kiosk,
        tp: &TransferPolicy<T>,
        item: ID,
        price: u64,
        ctx: &mut TxContext,
    ) {
        kiosk.has_access(kiosk_cap);

        let caller = ctx.sender();
        let owner = s_item_pc.owner;
        let item_id = s_item_pc.item_id;
        let kioskId = s_item_pc.kioskId;

        assert!(caller == owner, ENotAuthorized);
        assert!(item_id == item, ENotSameItem);
        assert!(kioskId == object::id(kiosk), ENotSameKiosk);

        if (tp.has_rule<T, r_rule::Rule>()) {
            s_item_pc.royalty_fee = r_rule::fee_amount(tp, price);
        };

        s_item_pc.marketplace_fee =
            (((get_fee(market, tx_context::sender(ctx)) as u128) * (price as u128)) / 10000) as u64;

        s_item_pc.min_price = price;

        emit(ItemUpdatedEvent {
            kiosk: kioskId,
            kiosk_cap: object::id(kiosk_cap),
            item: item,
            shared_purchaseCap: object::uid_to_inner(&s_item_pc.id),
            price: price,
            marketplace_fee: s_item_pc.marketplace_fee,
            royalty_fee: s_item_pc.royalty_fee,
            owner: caller,
        });
    }

    public fun delist<T: key + store>(
        s_item_pc: SItemWithPurchaseCap<T>,
        kiosk_cap: &KioskOwnerCap,
        kiosk: &mut Kiosk,
        item: ID,
        ctx: &TxContext,
    ) {
        let SItemWithPurchaseCap<T> {
            id: s_id,
            kioskId: s_kioskId,
            purchaseCap,
            item_id: _,
            min_price: _,
            owner,
            royalty_fee: _,
            marketplace_fee: _,
        } = s_item_pc;
        let caller = tx_context::sender(ctx);
        assert!(caller == owner, ENotAuthorized);

        let kioskId = object::id(kiosk);
        let has_access = kiosk::has_access(kiosk, kiosk_cap);
        assert!(has_access, ENotAuthorized);
        let item_id = kiosk::purchase_cap_item<T>(&purchaseCap);

        // checks if the kioks are the same
        assert!(kioskId == s_kioskId, ENotSameKiosk);
        assert!(item_id == item, ENotSameItem);
        // return purchaseCap and delist the item
        kiosk::return_purchase_cap<T>(kiosk, purchaseCap);

        emit(ItemDelistedEvent {
            kiosk: kioskId,
            item: item_id,
            shared_purchaseCap: object::uid_to_inner(&s_id),
            owner: tx_context::sender(ctx),
        });

        // delete the old purchase cap wrapper
        object::delete(s_id);
    }

    #[allow(lint(self_transfer))]
    public fun buy<T: key + store>(
        market: &mut MarketPlace,
        buyers_kc: &KioskOwnerCap,
        buyers_kiosk: &mut Kiosk,
        sellers_kiosk: &mut Kiosk,
        tp: &mut TransferPolicy<T>,
        item: ID,
        item_purchase_cap: SItemWithPurchaseCap<T>,
        payment: Coin<SUI>,
        ctx: &mut TxContext,
    ): (TransferRequest<T>) {
        let spc_id = object::id(&item_purchase_cap);
        let SItemWithPurchaseCap<T> {
            id,
            kioskId: targetKiosk,
            purchaseCap,
            item_id: _,
            min_price: price,
            owner: _,
            royalty_fee,
            marketplace_fee,
        } = item_purchase_cap;

        let mut payment_balance = payment.into_balance();

        let pc_item: ID = purchaseCap.purchase_cap_item<T>();

        assert!(payment_balance.value() >= price + royalty_fee + marketplace_fee, ENotEnoughFunds);

        // checks if the kioks are the same and if the item seleted is the same
        assert!(targetKiosk == object::id(sellers_kiosk), ENotSameKiosk);
        assert!(pc_item == item, ENotSameItem);
        // checks if the buyer provided enough funds to buy the item
        let market_fee_coin = coin::take<SUI>(&mut payment_balance, marketplace_fee, ctx);
        let payment_coin = coin::take<SUI>(&mut payment_balance, price, ctx);
        coin::put<SUI>(&mut market.balance, market_fee_coin);

        let (i, mut tr) = kiosk::purchase_with_cap<T>(sellers_kiosk, purchaseCap, payment_coin);
        emit(ItemBoughtEvent {
            kiosk: targetKiosk,
            item: pc_item,
            price: price,
            shared_purchaseCap: spc_id,
            buyer: tx_context::sender(ctx),
        });
        id.delete();
        if (tp.has_rule<T, l_rule::Rule>()) {
            kiosk::lock<T>(buyers_kiosk, buyers_kc, tp, i);
            l_rule::prove(&mut tr, buyers_kiosk);
        } else {
            // kiosk::place<T>(buyers_kiosk, buyers_pkc, i);
            transfer::public_transfer(i, ctx.sender());
        };

        if (tp.has_rule<T, r_rule::Rule>()) {
            let royalty_fee_coin = coin::take<SUI>(&mut payment_balance, royalty_fee, ctx);
            r_rule::pay(tp, &mut tr, royalty_fee_coin);
        };
        if (tp.has_rule<T, floor_rule::Rule>()) {
            floor_rule::prove(tp, &mut tr);
        };
        let mut remaining_coin = coin::zero<SUI>(ctx);
        remaining_coin.balance_mut().join(payment_balance);
        transfer::public_transfer(remaining_coin, ctx.sender());
        tr
    }

    public fun confirm_purchase<T: key + store>(tr: TransferRequest<T>, tp: &TransferPolicy<T>) {
        tp.confirm_request(tr);
    }

    // ==================== Admin Functions  ========================
    public fun set_personal_fee(
        self: &mut MarketPlace,
        admin: &RoleCap<AdminCap>,
        roles: &SRoles<MARKETPLACE>,
        recipient: vector<address>,
        fee: vector<u16>,
    ) {
        assert!(has_cap_access<MARKETPLACE, AdminCap>(roles, admin), ENotAuthorized);
        assert!(recipient.length() == fee.length(), ENotSameLength);

        let mut i = 0;
        while (i < recipient.length()) {
            map::insert(&mut self.personalFee, recipient[i], fee[i]);
            i = i + 1;
        };
        emit(PersonalFeeSetEvent {
            recipient: recipient,
            fee: fee,
        });
    }

    public fun set_base_fee(
        self: &mut MarketPlace,
        admin: &RoleCap<AdminCap>,
        roles: &SRoles<MARKETPLACE>,
        fee: u16,
    ) {
        assert!(has_cap_access<MARKETPLACE, AdminCap>(roles, admin), ENotAuthorized);
        self.baseFee = fee;
    }

    public fun add_admin(
        owner: &OwnerCap<MARKETPLACE>,
        roles: &mut SRoles<MARKETPLACE>,
        recipient: address,
        ctx: &mut TxContext,
    ) {
        a_c::add_role<MARKETPLACE, AdminCap>(owner, roles, recipient, ctx);
    }

    public fun revoke_admin(
        _: &OwnerCap<MARKETPLACE>,
        roles: &mut SRoles<MARKETPLACE>,
        target: ID,
        ctx: &mut TxContext,
    ) {
        a_c::revoke_role_access<MARKETPLACE>(_, roles, target, ctx)
    }

    public fun withdraw_profit(
        admin: &RoleCap<AdminCap>,
        roles: &SRoles<MARKETPLACE>,
        self: &mut MarketPlace,
        amount: Option<u64>,
        recipient: address,
        ctx: &mut TxContext,
    ) {
        assert!(has_cap_access<MARKETPLACE, AdminCap>(roles, admin), ENotAuthorized);
        let amount = if (amount.is_some()) {
            let amt = amount.destroy_some();
            assert!(amt <= self.balance.value(), ENotEnoughFunds);
            amt
        } else {
            self.balance.value()
        };

        let coin = coin::take<SUI>(&mut self.balance, amount, ctx);
        transfer::public_transfer(coin, recipient);
    }

    public fun add_balance(self: &mut MarketPlace, payment: Coin<SUI>) {
        coin::put<SUI>(&mut self.balance, payment);
    }

    // ==================== Getter Functions  ========================

    public fun get_price<T: key + store>(self: &SItemWithPurchaseCap<T>): u64 {
        self.min_price
    }

    public fun get_fee_by_pc<T: key + store>(self: &SItemWithPurchaseCap<T>): u64 {
        self.marketplace_fee + self.royalty_fee
    }

    public fun get_owner<T: key + store>(self: &SItemWithPurchaseCap<T>): address {
        self.owner
    }

    public fun get_item_id<T: key + store>(self: &SItemWithPurchaseCap<T>): ID {
        self.item_id
    }

    public fun get_kiosk_id<T: key + store>(self: &SItemWithPurchaseCap<T>): ID {
        self.kioskId
    }

    public fun get_balance(
        self: &MarketPlace,
        roles: &SRoles<MARKETPLACE>,
        admin: &RoleCap<AdminCap>,
    ): u64 {
        assert!(has_cap_access<MARKETPLACE, AdminCap>(roles, admin), ENotAuthorized);
        self.balance.value()
    }

    public fun get_purchase_cap_id<T: key + store>(self: &SItemWithPurchaseCap<T>): ID {
        object::id(&self.purchaseCap)
    }

    public fun get_fee(self: &MarketPlace, owner: address): u16 {
        let personal_fee_exists = map::contains<address, u16>(&self.personalFee, &owner);

        if (personal_fee_exists) {
            let personal_fee = map::get<address, u16>(&self.personalFee, &owner);
            return *personal_fee
        };
        self.baseFee
    }

    public(package) fun add_to_marketplace<Name: copy + drop + store, Value: key + store>(
        market: &mut MarketPlace,
        name: Name,
        value: Value,
    ) {
        dynamic_object_field::add(&mut market.id, name, value);
    }

    public(package) fun remove_from_marketplace<Name: copy + drop + store, Value: key + store>(
        market: &mut MarketPlace,
        name: Name,
    ): Value {
        dynamic_object_field::remove(&mut market.id, name)
    }

    public(package) fun emit_listing_event(
        kiosk: ID,
        kiosk_cap: ID,
        shared_purchaseCap: ID,
        item: ID,
        price: u64,
        marketplace_fee: u64,
        owner: address,
    ) {
        emit(ItemListedEvent {
            kiosk,
            kiosk_cap,
            shared_purchaseCap,
            item,
            price,
            marketplace_fee,
            royalty_fee: 0,
            owner,
        });
    }

    public(package) fun emit_update_event(
        kiosk: ID,
        kiosk_cap: ID,
        item: ID,
        shared_purchaseCap: ID,
        price: u64,
        marketplace_fee: u64,
        owner: address,
    ) {
        emit(ItemUpdatedEvent {
            kiosk,
            kiosk_cap,
            item,
            shared_purchaseCap,
            price,
            marketplace_fee,
            royalty_fee: 0,
            owner,
        });
    }

    public(package) fun emit_delist_event(
        kiosk: ID,
        item: ID,
        shared_purchaseCap: ID,
        owner: address,
    ) {
        emit(ItemDelistedEvent {
            kiosk,
            item,
            shared_purchaseCap,
            owner,
        });
    }

    public(package) fun emit_buy_event(
        kiosk: ID,
        item: ID,
        price: u64,
        shared_purchaseCap: ID,
        buyer: address,
    ) {
        emit(ItemBoughtEvent {
            kiosk,
            item,
            price,
            shared_purchaseCap,
            buyer,
        });
    }

    #[test_only]
    public(package) fun init_test(ctx: &mut TxContext) {
        let otw = MARKETPLACE {};
        init(otw, ctx);
    }
    #[test_only]
    public fun list_event_id(event: &ItemListedEvent): ID {
        event.shared_purchaseCap
    }
}
