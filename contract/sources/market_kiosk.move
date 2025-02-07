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

    /// @dev This function creates a new kiosk along with a personal kiosk capability (PersonalKioskCap).
    ///      It sets the kiosk owner, transfers ownership of the kiosk capability to the sender, and emits a KioskCreatedEvent.
    /// @notice This function does not store the created kiosk information in the marketplace. It simply creates a kiosk.
    /// @param ctx The transaction context of the sender.
    /// @return (ID, ID) Return created kiosk and personal kiosk cap ids
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

    /// @dev This function lists an item in a kiosk on the marketplace with purchase cap,
    ///      and stores price and fee information in the shared purchase cap.
    /// @notice This function lists an item placed in a kiosk.
    /// @param market The reference to the marketplace where the item is to be listed.
    /// @param kiosk_cap A capability object that allows modification of the kiosk.
    /// @param kiosk A mutable reference to the kiosk from which the item is listed.
    /// @param tp The transfer policy associated with the listed item.
    /// @param item_id The ID of the item to be listed in the kiosk.
    /// @param price The price of the item being listed (in mist unit).
    /// @param ctx The transaction context of the sender.
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

    /// @dev This function lists an item in a kiosk on the marketplace with purchase cap,
    ///      and stores price and fee information in the shared purchase cap.
    /// @notice This function places and lists an item into a kiosk.
    /// @param market The reference to the marketplace where the item is to be listed.
    /// @param kiosk_cap A capability object that allows modification of the kiosk.
    /// @param kiosk A mutable reference to the kiosk from which the item is listed.
    /// @param tp The transfer policy associated with the listed item.
    /// @param item The item to be listed in the kiosk.
    /// @param price The price of the item being listed (in mist unit).
    /// @param ctx The transaction context of the sender.
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

    /// @dev This function updates an existing kiosk listing by modifying its price and recalculating its fees.
    /// @param market The reference to the marketplace where the item is listed.
    /// @param s_item_pc A mutable reference to the `SItemWithPurchaseCap` representing the listed item to be updated.
    /// @param kiosk_cap A capability object that allows modification of the kiosk.
    /// @param kiosk A mutable reference to the kiosk from which the item is listed.
    /// @param tp The transfer policy associated with the listed item.
    /// @param item The ID of the item listed in the kiosk.
    /// @param price The price of the item listed (in mist unit).
    /// @param ctx The transaction context of the sender.
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

    /// @dev This function delists an item from a kiosk, ensuring all required permissions and checks
    ///      are passed before performing the delisting action. The purchase cap is returned and the item is no longer
    ///      available for purchase through the kiosk.
    /// @param s_item_pc A struct containing the item details, purchase cap, and ownership information.
    /// @param kiosk_cap A capability object that allows modification of the kiosk.
    /// @param kiosk A mutable reference to the kiosk where the item is being delisted from.
    /// @param tp The transfer policy associated with the listed item.
    /// @param item The ID of the item to be delisted from the kiosk.
    /// @param price The price of the item to be delisted (in mist unit).
    /// @param ctx The transaction context of the sender.
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

    /// @dev This function facilitates the purchase of an item from a seller's kiosk. It ensures the buyer has
    ///      sufficient funds, verifies the item and kiosk details, processes the marketplace and royalty fees, and
    ///      transfers ownership of the item to the buyer. If applicable, it applies transfer policies to the item
    ///      and emits an event upon successful purchase.
    /// @param market A mutable reference to the marketplace handling balances and marketplace fees.
    /// @param buyers_kc The kiosk capability used to verify the buyer's access to their kiosk.
    /// @param buyers_kiosk A mutable reference to the buyer's kiosk where the purchased item will be placed or locked.
    /// @param sellers_kiosk A mutable reference to the seller's kiosk from which the item is being purchased.
    /// @param tp The transfer policy associated with the item, defining rules for ownership transfer.
    /// @param item The ID of the item being purchased from the seller's kiosk.
    /// @param item_purchase_cap A struct containing the purchase capability, item details, and pricing information.
    /// @param payment the buyer's payment coin used to pay for the item and associated fees.
    /// @param ctx The transaction context of the sender.
    /// @return TransferRequest<T> The transfer request for the item. After executing this function,
    /// the rules associated with the transfer policy must be collected and confirmed.
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

    /// @dev This function finalizes the purchase process by confirming the transfer request for an item.
    ///      It ensures that all rules and policies associated with the item's transfer policy have been fulfilled
    ///      before completing the transfer.
    /// @notice This function must be called after the `buy` function to validate the transfer and complete the transaction.
    /// @param tr The transfer request generated during the purchase process, containing details of the item and transfer rules to be confirmed.
    /// @param tp A reference to the transfer policy associated with the item, which defines the rules and conditions for the transfer.
    public fun confirm_purchase<T: key + store>(tr: TransferRequest<T>, tp: &TransferPolicy<T>) {
        tp.confirm_request(tr);
    }

    // ==================== Admin Functions  ========================
    /// @dev Sets a personalized fee rate for a recipient in the marketplace.
    /// @param self A mutable reference to the `MarketPlace` object where the fee is being configured.
    /// @param admin A reference to the `AdminCap` role capability for verifying administrative access.
    /// @param roles A reference to the roles object that stores the administrative permissions for the marketplace.
    /// @param recipient A vector of addresses representing the recipients to which the fees will be assigned.
    /// @param fee The fee rate (in basis points, where 1% = 100 basis points) to be applied to the recipient's transactions.
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
            if (map::contains<address, u16>(&self.personalFee, &recipient[i])) {
                let old_fee = map::get_mut<address, u16>(&mut self.personalFee, &recipient[i]);
                *old_fee = fee[i];
                i = i + 1;
            } else {
                map::insert(&mut self.personalFee, recipient[i], fee[i]);
                i = i + 1;
            };
        };
        emit(PersonalFeeSetEvent {
            recipient: recipient,
            fee: fee,
        });
    }

    /// @dev Updates the base fee for all marketplace transactions. Only authorized administrators can call this function.
    /// @param self A mutable reference to the `MarketPlace` object where the base fee will be updated.
    /// @param admin A reference to the `AdminCap` role capability for verifying administrative access.
    /// @param roles A reference to the roles object that stores the administrative permissions for the marketplace.
    /// @param fee The new base fee rate (in basis points, where 1% = 100 basis points) to be applied.
    public fun set_base_fee(
        self: &mut MarketPlace,
        admin: &RoleCap<AdminCap>,
        roles: &SRoles<MARKETPLACE>,
        fee: u16,
    ) {
        assert!(has_cap_access<MARKETPLACE, AdminCap>(roles, admin), ENotAuthorized);
        self.baseFee = fee;
    }

    /// @dev Grants administrative privileges to the specified recipient. Only the marketplace owner can add new administrators.
    /// @param owner A reference to the `OwnerCap` of the marketplace, used to verify ownership and authority.
    /// @param roles A mutable reference to the roles object where the recipient will be granted administrative privileges.
    /// @param recipient The address of the recipient who will be assigned the `AdminCap`.
    /// @param ctx Sender's tx context.
    public fun add_admin(
        owner: &OwnerCap<MARKETPLACE>,
        roles: &mut SRoles<MARKETPLACE>,
        recipient: address,
        ctx: &mut TxContext,
    ) {
        a_c::add_role<MARKETPLACE, AdminCap>(owner, roles, recipient, ctx);
    }

    /// @dev Revokes administrative privileges from a specified administrator. Only the marketplace owner can perform this action.
    /// @param _ A reference to the `OwnerCap` of the marketplace, used to verify ownership and authority.
    /// @param roles A mutable reference to the roles object from which the target administrator's privileges will be removed.
    /// @param target The ID of the administrator whose privileges are to be revoked.
    /// @param ctx Sender's tx context.
    public fun revoke_admin(
        _: &OwnerCap<MARKETPLACE>,
        roles: &mut SRoles<MARKETPLACE>,
        target: ID,
        ctx: &mut TxContext,
    ) {
        a_c::revoke_role_access<MARKETPLACE>(_, roles, target, ctx)
    }

    /// @dev Allows an administrator to withdraw a specified amount of profit from the marketplace's balance.
    /// @notice If no amount is specified, the entire balance is withdrawn.
    /// @param admin A reference to the `AdminCap` role capability to verify administrative access.
    /// @param roles A reference to the roles of the marketplace, used to check authorization.
    /// @param self A mutable reference to the `MarketPlace` object from which the profit is being withdrawn.
    /// @param amount An optional `u64` value specifying the amount to withdraw. If not provided, the full balance is withdrawn.
    /// @param recipient The address of the recipient to whom the withdrawn funds will be transferred.
    /// @param ctx Sender's tx context.
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

    /// @dev Adds the specified payment amount to the marketplace's balance.
    /// @param self A mutable reference to the `MarketPlace` object where the balance will be updated.
    /// @param payment A `Coin<SUI>` representing the SUI coin object to be added to the marketplace's balance.
    public fun add_balance(self: &mut MarketPlace, payment: Coin<SUI>) {
        coin::put<SUI>(&mut self.balance, payment);
    }

    // ==================== Getter Functions  ========================

    /// @dev Retrieves the minimum price of an item associated with its purchase capability.
    /// @param self A reference to the `SItemWithPurchaseCap` object containing the item's details.
    /// @return The minimum price of the item as a `u64` value.
    public fun get_price<T: key + store>(self: &SItemWithPurchaseCap<T>): u64 {
        self.min_price
    }

    /// @dev Calculates the total fee (marketplace fee + royalty fee) for an item associated with its purchase capability.
    /// @param self A reference to the `SItemWithPurchaseCap` object containing the item's details.
    /// @return The total fee for the item as a `u64` value.
    public fun get_fee_by_pc<T: key + store>(self: &SItemWithPurchaseCap<T>): u64 {
        self.marketplace_fee + self.royalty_fee
    }

    /// @dev Retrieves the owner address of an item associated with its purchase capability.
    /// @param self A reference to the `SItemWithPurchaseCap` object containing the item's details.
    /// @return The address of the item's owner.
    public fun get_owner<T: key + store>(self: &SItemWithPurchaseCap<T>): address {
        self.owner
    }

    /// @dev Retrieves the ID of an item associated with its purchase capability.
    /// @param self A reference to the `SItemWithPurchaseCap` object containing the item's details.
    /// @return The ID of the item as an `ID` type.
    public fun get_item_id<T: key + store>(self: &SItemWithPurchaseCap<T>): ID {
        self.item_id
    }

    /// @dev Retrieves the ID of the kiosk associated with an item's purchase capability.
    /// @param self A reference to the `SItemWithPurchaseCap` object containing the item's details.
    /// @return The ID of the kiosk as an `ID` type.
    public fun get_kiosk_id<T: key + store>(self: &SItemWithPurchaseCap<T>): ID {
        self.kioskId
    }

    /// @dev Retrieves the current balance of the marketplace. Only accessible to authorized administrators.
    /// @param self A reference to the `MarketPlace` object containing the balance details.
    /// @param roles A reference to the roles object verifying administrative access.
    /// @param admin A reference to the `AdminCap` role capability for access validation.
    /// @return The current balance of the marketplace as a `u64` value.
    public fun get_balance(
        self: &MarketPlace,
        roles: &SRoles<MARKETPLACE>,
        admin: &RoleCap<AdminCap>,
    ): u64 {
        assert!(has_cap_access<MARKETPLACE, AdminCap>(roles, admin), ENotAuthorized);
        self.balance.value()
    }

    /// @dev Retrieves the ID of the purchase capability associated with an item.
    /// @param self A reference to the `SItemWithPurchaseCap` object containing the item's details.
    /// @return The ID of the purchase capability as an `ID` type.
    public fun get_purchase_cap_id<T: key + store>(self: &SItemWithPurchaseCap<T>): ID {
        object::id(&self.purchaseCap)
    }

    /// @dev Retrieves the fee applicable to a specific owner in the marketplace. If a personal fee exists for the owner, it is returned; otherwise, the base fee is used.
    /// @param self A reference to the `MarketPlace` object containing the fee configuration.
    /// @param owner The address of the owner whose fee is being queried.
    /// @return The applicable fee as a `u16` value.
    public fun get_fee(self: &MarketPlace, owner: address): u16 {
        let personal_fee_exists = map::contains<address, u16>(&self.personalFee, &owner);

        if (personal_fee_exists) {
            let personal_fee = map::get<address, u16>(&self.personalFee, &owner);
            return *personal_fee
        };
        self.baseFee
    }

    // ==================== Package-Public Functions  ========================

    /// @dev Adds a key-value pair to the marketplace's dynamic object fields.
    /// @notice Use this function only to store important information related to trading
    /// @param market A mutable reference to the `MarketPlace` object where the key-value pair will be added.
    /// @param name The key  used to identify the value in the marketplace.
    /// @param value The object value associated with the given key.
    public(package) fun add_to_marketplace<Name: copy + drop + store, Value: key + store>(
        market: &mut MarketPlace,
        name: Name,
        value: Value,
    ) {
        dynamic_object_field::add(&mut market.id, name, value);
    }

    /// @dev Removes a key-value pair from the marketplace's dynamic object fields and retrieves the value associated with the given key.
    /// @param market A mutable reference to the `MarketPlace` object where the key-value pair will be removed.
    /// @param name The key identifying the value to be removed.
    public(package) fun remove_from_marketplace<Name: copy + drop + store, Value: key + store>(
        market: &mut MarketPlace,
        name: Name,
    ): Value {
        dynamic_object_field::remove(&mut market.id, name)
    }

    /// @dev Emits an event when an item is listed in the marketplace.
    /// @param kiosk The ID of the kiosk where the item is listed.
    /// @param kiosk_cap The ID of the kiosk capability used for the listing.
    /// @param shared_purchaseCap The shared purchase capability ID associated with the item.
    /// @param item The ID of the listed item.
    /// @param price The listing price of the item (in mist units).
    /// @param marketplace_fee The fee charged by the marketplace for listing the item.
    /// @param owner The address of the owner listing the item.
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

    /// @dev Emits an event when the details of a listed item are updated in the marketplace.
    /// @param kiosk The ID of the kiosk where the item is listed.
    /// @param kiosk_cap The ID of the kiosk capability used for the update.
    /// @param item The ID of the item being updated.
    /// @param shared_purchaseCap The shared purchase capability ID associated with the item.
    /// @param price The updated price of the item (in mist units).
    /// @param marketplace_fee The updated marketplace fee for the item.
    /// @param owner The address of the owner updating the listing.
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

    /// @dev Emits an event when an item is delisted from the marketplace.
    /// @param kiosk The ID of the kiosk where the item was listed.
    /// @param item The ID of the delisted item.
    /// @param shared_purchaseCap The shared purchase capability ID associated with the item.
    /// @param owner The address of the owner delisting the item.
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

    /// @dev Emits an event when an item is purchased from the marketplace.
    /// @param kiosk The ID of the kiosk where the item was listed.
    /// @param item The ID of the purchased item.
    /// @param price The purchase price of the item (in mist units).
    /// @param shared_purchaseCap The shared purchase capability ID associated with the item.
    /// @param buyer The address of the buyer who purchased the item.
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
    /// @dev Execute init() for test.
    /// @param ctx Sender's tx context.
    #[test_only]
    public(package) fun init_test(ctx: &mut TxContext) {
        let otw = MARKETPLACE {};
        init(otw, ctx);
    }
}
