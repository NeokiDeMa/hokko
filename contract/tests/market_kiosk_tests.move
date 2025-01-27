#[test_only]
module marketplace::market_kiosk_tests {
    use access_control::access_control::{SRoles, OwnerCap, RoleCap};
    use kiosk::{personal_kiosk::{Self as p_k, PersonalKioskCap}, royalty_rule};
    use marketplace::marketplace::{
        Self as marketplace,
        MARKETPLACE,
        MarketPlace,
        AdminCap,
        SItemWithPurchaseCap
    };
    use sui::{
        coin::mint_for_testing,
        kiosk::{Self, Kiosk},
        sui::SUI,
        test_scenario::{Self as scen, end, Scenario, ctx},
        test_utils::{assert_eq, destroy},
        transfer_policy as transfer_policy
    };

    // use sui::kiosk_test_utils;

    // const ENotImplemented: u64 = 0;
    // const ENotListed: u64 = 1;

    const OWNER: address = @0x110e;
    const ALICE: address = @0x110f;

    // const BOB: address = @0x1111;
    // public struct OTW has drop {}

    public struct DummyItem has key, store {
        id: UID,
    }

    // #[test]
    // fun test_Take_stuff() {
    // }
    #[test]
    fun test_list_item() {
        let price: u64 = 200;
        let personal_fee: vector<u16> = vector[50];
        let owner_address_array: vector<address> = vector[OWNER];

        let mut scen = scen::begin(OWNER);

        // let (market, mut kiosk, pkc) = initial_setup(&mut scen);
        let (mut market, owner_cap, s_roles, dummy_item, admin_cap) = init_setup(&mut scen);

        let (mut kiosk, personal_kiosk_cap) = create_kiosk(&mut scen, OWNER);
        let kiosk_owner_cap = p_k::borrow(&personal_kiosk_cap);

        marketplace::set_personal_fee(
            &mut market,
            &admin_cap,
            &s_roles,
            owner_address_array,
            personal_fee,
        );
        let (tp, tpc) = transfer_policy::new_for_testing<DummyItem>(ctx(&mut scen));
        scen::next_tx(&mut scen, OWNER);
        marketplace::list<DummyItem>(
            &market,
            kiosk_owner_cap,
            &mut kiosk,
            &tp,
            dummy_item,
            price,
            ctx(&mut scen),
        );

        scen::next_tx(&mut scen, OWNER);

        let shared_item_purchase_cap = scen::take_shared<SItemWithPurchaseCap<DummyItem>>(&scen);
        // let min_price = shared_item_purchase_cap;

        scen::return_to_address(OWNER, personal_kiosk_cap);
        scen::return_to_address(OWNER, owner_cap);
        scen::return_to_address(OWNER, admin_cap);
        scen::return_shared(market);
        scen::return_shared(s_roles);
        scen::return_shared(kiosk);
        scen::return_shared(shared_item_purchase_cap);
        destroy(tpc);
        destroy(tp);
        end(scen);
    }

    #[test]
    fun test_purchase_item() {
        let price: u64 = 2000;
        let personal_fee: vector<u16> = vector[50];
        let owner_address_array: vector<address> = vector[OWNER];

        let mut scen = scen::begin(OWNER);
        let mut scenTwo = scen::begin(ALICE);

        let (mut alice_kiosk, alice_personal_kiosk_cap) = create_kiosk(&mut scenTwo, ALICE);
        let alice_kiosk_owner_cap = p_k::borrow(&alice_personal_kiosk_cap);
        let (mut market, owner_cap, s_roles, dummy_item, admin_cap) = init_setup(&mut scen);

        let dummy_item_id = object::id(&dummy_item);

        let (mut kiosk, personal_kiosk_cap) = create_kiosk(&mut scen, OWNER);
        let kiosk_owner_cap = p_k::borrow(&personal_kiosk_cap);

        marketplace::set_personal_fee(
            &mut market,
            &admin_cap,
            &s_roles,
            owner_address_array,
            personal_fee,
        );
        let (mut tp, tpc) = transfer_policy::new_for_testing<DummyItem>(ctx(&mut scen));
        scen::next_tx(&mut scen, OWNER);

        marketplace::list<DummyItem>(
            &market,
            kiosk_owner_cap,
            &mut kiosk,
            &tp,
            dummy_item,
            price,
            ctx(&mut scen),
        );

        scen::next_tx(&mut scen, OWNER);

        let shared_item_purchase_cap = scen::take_shared<SItemWithPurchaseCap<DummyItem>>(&scenTwo);

        let sui_coin_amount = mint_for_testing<SUI>(2300, ctx(&mut scenTwo));
        // let mut sui_coin_fee_amount = mint_for_testing<SUI>(300, ctx(&mut scenTwo));
        // scen::next_tx(&mut scenTwo, ALICE);
        scen::next_tx(&mut scenTwo, ALICE);
        let (tr) = marketplace::buy<DummyItem>(
            &mut market,
            alice_kiosk_owner_cap,
            &mut alice_kiosk,
            &mut kiosk,
            &mut tp,
            dummy_item_id,
            shared_item_purchase_cap,
            // &mut sui_coin_fee_amount,
            sui_coin_amount,
            ctx(&mut scenTwo),
        );

        let (confirm_item, confirm_paid, _) = transfer_policy::confirm_request<DummyItem>(&tp, tr);
        scen::next_tx(&mut scen, ALICE);
        let withdraw_amount = option::some(10);
        let before_balance = marketplace::get_balance(&market, &s_roles, &admin_cap);
        assert_eq(before_balance, 10);

        let newItem = scen.take_from_address<DummyItem>(ALICE);
        destroy(newItem);
        marketplace::withdraw_profit(
            &admin_cap,
            &s_roles,
            &mut market,
            withdraw_amount,
            OWNER,
            ctx(&mut scen),
        );

        let market_balance = marketplace::get_balance(&market, &s_roles, &admin_cap);
        assert_eq(market_balance, 0);
        assert_eq(confirm_item, dummy_item_id);
        assert_eq(confirm_paid, price);

        // destroy(sui_coin_amount);
        destroy(alice_personal_kiosk_cap);
        destroy(tp);
        destroy(tpc);
        scen::return_to_address(OWNER, personal_kiosk_cap);
        scen::return_to_address(OWNER, owner_cap);
        scen::return_to_address(OWNER, admin_cap);
        scen::return_shared(market);
        scen::return_shared(s_roles);
        scen::return_shared(kiosk);
        scen::return_shared(alice_kiosk);
        end(scen);
        end(scenTwo);
    }
    #[test]
    fun test_purchase_item_with_royalty_fee() {
        let price: u64 = 2000;
        let personal_fee: vector<u16> = vector[50];
        let owner_address_array: vector<address> = vector[OWNER];

        let mut scen = scen::begin(OWNER);
        let mut scenTwo = scen::begin(ALICE);

        let (mut alice_kiosk, alice_personal_kiosk_cap) = create_kiosk(&mut scenTwo, ALICE);

        let (mut market, owner_cap, s_roles, dummy_item, admin_cap) = init_setup(&mut scen);

        let dummy_item_id = object::id(&dummy_item);

        let (mut kiosk, personal_kiosk_cap) = create_kiosk(&mut scen, OWNER);
        let kiosk_owner_cap = p_k::borrow(&personal_kiosk_cap);

        marketplace::set_personal_fee(
            &mut market,
            &admin_cap,
            &s_roles,
            owner_address_array,
            personal_fee,
        );
        let (mut tp, tpc) = transfer_policy::new_for_testing<DummyItem>(ctx(&mut scen));
        royalty_rule::add<DummyItem>(&mut tp, &tpc, 500, 0);
        scen::next_tx(&mut scen, OWNER);

        marketplace::list<DummyItem>(
            &market,
            kiosk_owner_cap,
            &mut kiosk,
            &tp,
            dummy_item,
            price,
            ctx(&mut scen),
        );

        scen::next_tx(&mut scen, OWNER);

        let shared_item_purchase_cap = scen::take_shared<SItemWithPurchaseCap<DummyItem>>(&scenTwo);
        // let royalty_coin_fee = royalty_rule::fee_amount<DummyItem>(&tp, price);

        let sui_coin_amount = mint_for_testing<SUI>(2300, ctx(&mut scenTwo));
        let alice_kiosk_owner_cap = p_k::borrow(&alice_personal_kiosk_cap);

        scen::next_tx(&mut scenTwo, ALICE);
        let (tr) = marketplace::buy<DummyItem>(
            &mut market,
            alice_kiosk_owner_cap,
            &mut alice_kiosk,
            &mut kiosk,
            &mut tp,
            dummy_item_id,
            shared_item_purchase_cap,
            sui_coin_amount,
            ctx(&mut scenTwo),
        );

        let (confirm_item, confirm_paid, _) = transfer_policy::confirm_request<DummyItem>(&tp, tr);
        let withdraw_amount = option::some(10);
        let before_balance = marketplace::get_balance(&market, &s_roles, &admin_cap);
        assert_eq(before_balance, 10);

        marketplace::withdraw_profit(
            &admin_cap,
            &s_roles,
            &mut market,
            withdraw_amount,
            OWNER,
            ctx(&mut scen),
        );

        let market_balance = marketplace::get_balance(&market, &s_roles, &admin_cap);
        assert_eq(market_balance, 0);

        assert_eq(confirm_item, dummy_item_id);
        assert_eq(confirm_paid, price);

        // destroy(sui_coin_amount);
        destroy(alice_personal_kiosk_cap);
        destroy(tp);
        destroy(tpc);
        scen::return_to_address(OWNER, personal_kiosk_cap);
        scen::return_to_address(OWNER, owner_cap);
        scen::return_to_address(OWNER, admin_cap);
        scen::return_shared(market);
        scen::return_shared(s_roles);
        scen::return_shared(kiosk);
        scen::return_shared(alice_kiosk);
        end(scen);
        end(scenTwo);
    }

    #[test]
    fun test_update_listing() {
        let price: u64 = 2000;

        let mut scen = scen::begin(OWNER);

        let (market, owner_cap, s_roles, dummy_item, admin_cap) = init_setup(&mut scen);
        let (mut owner_kiosk, owner_personal_kiosk_cap) = create_kiosk(&mut scen, OWNER);
        let kiosk_owner_cap = p_k::borrow(&owner_personal_kiosk_cap);
        let dummy_item_id = object::id(&dummy_item);
        let (tp, tpc) = transfer_policy::new_for_testing<DummyItem>(scen.ctx());
        scen::next_tx(&mut scen, OWNER);

        marketplace::list<DummyItem>(
            &market,
            kiosk_owner_cap,
            &mut owner_kiosk,
            &tp,
            dummy_item,
            price,
            ctx(&mut scen),
        );

        scen::next_tx(&mut scen, OWNER);

        let mut shared_item_purchase_cap = scen::take_shared<SItemWithPurchaseCap<DummyItem>>(
            &scen,
        );

        // let owner_kiosk_cap = p_k::borrow(&owner_personal_kiosk_cap);
        marketplace::update_listing<DummyItem>(
            &market,
            &mut shared_item_purchase_cap,
            kiosk_owner_cap,
            &mut owner_kiosk,
            &tp,
            dummy_item_id,
            price + 1000,
            ctx(&mut scen),
        );
        scen::next_tx(&mut scen, OWNER);
        let is_listed = kiosk::is_listed(&owner_kiosk, dummy_item_id);
        assert_eq(is_listed, true);
        assert_eq(shared_item_purchase_cap.get_price(), price + 1000);
        assert_eq(shared_item_purchase_cap.get_fee_by_pc(), 60);

        destroy(tpc);
        destroy(tp);
        destroy(shared_item_purchase_cap);
        destroy(owner_personal_kiosk_cap);
        destroy(owner_kiosk);
        destroy(owner_cap);
        destroy(admin_cap);
        destroy(market);
        destroy(s_roles);
        end(scen);
    }

    #[test]
    fun test_delist() {
        let price: u64 = 2000;

        let mut scen = scen::begin(OWNER);

        let (market, owner_cap, s_roles, dummy_item, admin_cap) = init_setup(&mut scen);
        let (mut owner_kiosk, owner_personal_kiosk_cap) = create_kiosk(&mut scen, OWNER);
        let kiosk_owner_cap = p_k::borrow(&owner_personal_kiosk_cap);
        let dummy_item_id = object::id(&dummy_item);
        let (tp, tpc) = transfer_policy::new_for_testing<DummyItem>(ctx(&mut scen));
        scen::next_tx(&mut scen, OWNER);

        marketplace::list<DummyItem>(
            &market,
            kiosk_owner_cap,
            &mut owner_kiosk,
            &tp,
            dummy_item,
            price,
            ctx(&mut scen),
        );

        scen::next_tx(&mut scen, OWNER);

        let shared_item_purchase_cap = scen::take_shared<SItemWithPurchaseCap<DummyItem>>(&scen);

        // let owner_kiosk_cap = p_k::borrow(&owner_personal_kiosk_cap);
        marketplace::delist<DummyItem>(
            shared_item_purchase_cap,
            kiosk_owner_cap,
            &mut owner_kiosk,
            dummy_item_id,
            ctx(&mut scen),
        );
        scen::next_tx(&mut scen, OWNER);
        let is_listed = kiosk::is_listed(&owner_kiosk, dummy_item_id);
        assert_eq(is_listed, false);

        // destroy(shared_item_purchase_cap);
        destroy(tpc);
        destroy(tp);
        destroy(owner_personal_kiosk_cap);
        destroy(owner_kiosk);
        destroy(owner_cap);
        destroy(admin_cap);
        destroy(market);
        destroy(s_roles);
        end(scen);
    }

    // #[test, expected_failure(abort_code = ::market_kiosk::market_kiosk_tests::ENotImplemented)]
    // fun test_market_kiosk_fail() {
    //     abort ENotImplemented
    // }

    // =================== Helper functions ===================
    fun init_setup(
        scen: &mut Scenario,
    ): (MarketPlace, OwnerCap<MARKETPLACE>, SRoles<MARKETPLACE>, DummyItem, RoleCap<AdminCap>) {
        marketplace::init_test(ctx(scen));
        scen::next_tx(scen, OWNER);

        let (market, owner_cap, mut s_roles) = after_init(scen);
        let admin_cap = add_admin(scen, &owner_cap, &mut s_roles, OWNER);

        let dummy_item = create_dummy_item(scen, OWNER);

        (market, owner_cap, s_roles, dummy_item, admin_cap)
    }

    fun after_init(scen: &mut Scenario): (MarketPlace, OwnerCap<MARKETPLACE>, SRoles<MARKETPLACE>) {
        let s_roles = scen::take_shared<SRoles<MARKETPLACE>>(scen);
        let owner_cap = scen::take_from_address<OwnerCap<MARKETPLACE>>(scen, OWNER);
        let market: MarketPlace = scen::take_shared<MarketPlace>(scen);
        scen::next_tx(scen, OWNER);
        (market, owner_cap, s_roles)
    }

    fun create_kiosk(scen: &mut Scenario, recipient: address): (Kiosk, PersonalKioskCap) {
        marketplace::create_kiosk(ctx(scen));
        scen::next_tx(scen, recipient);

        let kiosk = scen::take_shared<Kiosk>(scen);
        let personal_kiosk_cap = scen::take_from_address<PersonalKioskCap>(scen, recipient);
        (kiosk, personal_kiosk_cap)
    }

    fun add_admin(
        scen: &mut Scenario,
        owner_cap: &OwnerCap<MARKETPLACE>,
        s_roles: &mut SRoles<MARKETPLACE>,
        recipient: address,
    ): RoleCap<AdminCap> {
        marketplace::add_admin(owner_cap, s_roles, recipient, ctx(scen));
        scen::next_tx(scen, OWNER);

        let admin_cap = scen::take_from_address<RoleCap<AdminCap>>(scen, OWNER);
        admin_cap
    }

    fun create_dummy_item(scen: &mut Scenario, recipient: address): DummyItem {
        transfer::transfer(
            DummyItem {
                id: object::new(ctx(scen)),
            },
            recipient,
        );
        scen::next_tx(scen, recipient);
        let dummy_item = scen::take_from_address<DummyItem>(scen, recipient);
        dummy_item
    }
}
