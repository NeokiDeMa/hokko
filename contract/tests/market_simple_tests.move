#[test_only]
module marketplace::simple_test {
    use access_control::access_control::{SRoles, OwnerCap, RoleCap};
    use marketplace::{
        marketplace::{Self as marketplace, MarketPlace, AdminCap, MARKETPLACE},
        simple::{Self as market, SharedListInfo, ListItemCap}
    };
    use sui::{
        coin::mint_for_testing,
        sui::SUI,
        test_scenario::{Self as scen, end, Scenario, ctx},
        test_utils::{assert_eq, destroy}
    };

    public struct DummyItem has key, store {
        id: UID,
    }

    const OWNER: address = @0x110e;
    const ALICE: address = @0x110f;

    #[test]
    fun test_list_simple_item() {
        let price = 4000000000;
        let mut scen = scen::begin(OWNER);

        let (mut market, owner_cap, s_roles, dummy_item) = init_setup(&mut scen);
        scen::next_tx(&mut scen, OWNER);

        market::list<DummyItem>(&mut market, dummy_item, price, ctx(&mut scen));
        scen::next_tx(&mut scen, OWNER);
        destroy(owner_cap);
        destroy(s_roles);
        destroy(market);
        end(scen);
    }

    #[test]
    fun test_update_simple_listing() {
        let price = 4000000000;
        let mut scen = scen::begin(OWNER);

        let (mut market, owner_cap, s_roles, dummy_item) = init_setup(&mut scen);
        scen::next_tx(&mut scen, OWNER);
        let dummy_id = object::id(&dummy_item);
        market::list<DummyItem>(&mut market, dummy_item, price, ctx(&mut scen));
        scen::next_tx(&mut scen, OWNER);
        let list_cap = scen.take_from_sender<ListItemCap<DummyItem>>();

        let mut s_listedItem = scen::take_shared<SharedListInfo<DummyItem>>(&scen);
        let owner = market::get_owner(&s_listedItem);
        assert_eq(OWNER, owner);
        scen::next_tx(&mut scen, OWNER);

        market::update_listing(
            &market,
            &mut s_listedItem,
            &list_cap,
            dummy_id,
            price + 1000000000,
            ctx(&mut scen),
        );
        scen::next_tx(&mut scen, OWNER);

        let new_price = market::get_price(&s_listedItem);
        assert_eq(new_price, price + 1000000000);

        scen::return_shared(s_listedItem);

        destroy(owner_cap);
        destroy(list_cap);
        destroy(s_roles);
        destroy(market);
        end(scen);
    }

    #[test]
    fun test_delist_simple_item() {
        let price = 4000000000;
        let mut scen = scen::begin(OWNER);

        let (mut market, owner_cap, s_roles, dummy_item) = init_setup(&mut scen);
        scen::next_tx(&mut scen, OWNER);
        let dummy_id = object::id(&dummy_item);

        market::list<DummyItem>(&mut market, dummy_item, price, ctx(&mut scen));
        scen::next_tx(&mut scen, OWNER);
        let list_cap = scen.take_from_sender<ListItemCap<DummyItem>>();

        let s_listedItem = scen::take_shared<SharedListInfo<DummyItem>>(&scen);
        let owner = market::get_owner(&s_listedItem);
        assert_eq(OWNER, owner);
        scen::next_tx(&mut scen, OWNER);

        market::delist<DummyItem>(&mut market, s_listedItem, list_cap, dummy_id, ctx(&mut scen));
        scen::next_tx(&mut scen, OWNER);

        destroy(owner_cap);
        destroy(s_roles);
        destroy(market);
        end(scen);
    }

    #[test]
    fun test_purchase_simple_item() {
        let price = 4000000000;
        let mut scen = scen::begin(OWNER);

        let (mut market, owner_cap, mut s_roles, dummy_item) = init_setup(&mut scen);
        scen::next_tx(&mut scen, OWNER);
        let dummy_id = object::id(&dummy_item);
        let new_admin = add_admin(&mut scen, &owner_cap, &mut s_roles, OWNER);

        market::list<DummyItem>(&mut market, dummy_item, price, ctx(&mut scen));
        scen::next_tx(&mut scen, OWNER);
        // let list_cap = scen.take_from_sender<ListItemCap<DummyItem>>();

        let s_listedItem = scen::take_shared<SharedListInfo<DummyItem>>(&scen);
        let owner = market::get_owner(&s_listedItem);
        let marketplace_fee = market::get_fee(&s_listedItem);
        assert_eq(OWNER, owner);
        scen::next_tx(&mut scen, ALICE);

        let coin_payment = mint_for_testing<SUI>(price + marketplace_fee, ctx(&mut scen));

        // scen::next_tx(&mut scen, ALICE);
        market::buy<DummyItem>(
            &mut market,
            s_listedItem,
            dummy_id,
            coin_payment,
            ctx(&mut scen),
        );
        scen::next_tx(&mut scen, ALICE);

        let marketplace_profit = marketplace::get_balance(&market, &s_roles, &new_admin);
        assert_eq(marketplace_profit, marketplace_fee);
        // destroy(coin_payment);
        destroy(new_admin);
        destroy(owner_cap);
        destroy(s_roles);
        destroy(market);
        end(scen);
    }

    fun init_setup(
        scen: &mut Scenario,
    ): (MarketPlace, OwnerCap<MARKETPLACE>, SRoles<MARKETPLACE>, DummyItem) {
        marketplace::init_test(ctx(scen));
        scen::next_tx(scen, OWNER);

        let (market, owner_cap, s_roles) = after_init(scen);
        // let admin_cap = add_admin(scen, &owner_cap, &mut s_roles, OWNER);

        let dummy_item = create_dummy_item(scen, OWNER);

        (market, owner_cap, s_roles, dummy_item)
    }

    fun after_init(scen: &mut Scenario): (MarketPlace, OwnerCap<MARKETPLACE>, SRoles<MARKETPLACE>) {
        let s_roles = scen::take_shared<SRoles<MARKETPLACE>>(scen);
        let owner_cap = scen::take_from_address<OwnerCap<MARKETPLACE>>(scen, OWNER);
        let market: MarketPlace = scen::take_shared<MarketPlace>(scen);
        scen::next_tx(scen, OWNER);
        (market, owner_cap, s_roles)
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
