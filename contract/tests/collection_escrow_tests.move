#[test_only]
module marketplace::collection_bid_test {
    use access_control::access_control::{SRoles, OwnerCap, RoleCap};
    use kiosk::{kiosk_lock_rule, personal_kiosk::PersonalKioskCap, royalty_rule};
    use marketplace::{
        collection_escrow::{Self as escrow, OfferCap, NewOfferEvent},
        marketplace::{Self, MarketPlace, MARKETPLACE, AdminCap}
    };
    use sui::{
        coin,
        event,
        kiosk::Kiosk,
        sui::SUI,
        test_scenario::{Self as scen, Scenario},
        test_utils::destroy,
        transfer_policy::{Self as policy, TransferPolicy, TransferPolicyCap}
    };

    const NFT_CREATOR: address = @0x110B;
    const ITEM_OWNER: address = @0x110C;
    const OFFERER: address = @0x110D;
    const MARKET_OWNER: address = @0x110A;

    public struct DummyItem has key, store {
        id: UID,
    }

    #[test]
    fun test_make_offer() {
        let mut scen = scen::begin(MARKET_OWNER);
        let (market, market_owner_cap, s_roles, admin_cap) = prepare_marketplace(&mut scen);

        scen.next_tx(NFT_CREATOR);
        let (dummy_item, transfer_policy, policy_cap) = prepare_dummy_item(&mut scen, ITEM_OWNER);

        let (mut kiosk, p_kiosk_cap) = create_kiosk(&mut scen);
        let kiosk_cap = kiosk::personal_kiosk::borrow(&p_kiosk_cap);
        // let item_id = object::id(&dummy_item);

        kiosk.lock<DummyItem>(kiosk_cap, &transfer_policy, dummy_item);

        let price: u64 = 50000;

        scen.next_tx(OFFERER);
        let (mut offerer_kiosk, p_offerer_kiosk_cap) = create_kiosk(&mut scen);
        let offerer_kiosk_cap = kiosk::personal_kiosk::borrow(&p_offerer_kiosk_cap);
        let payment_coin = coin::mint_for_testing<SUI>(price, scen.ctx());

        escrow::offer<DummyItem>(
            &market,
            &mut offerer_kiosk,
            offerer_kiosk_cap,
            payment_coin,
            &transfer_policy,
            scen.ctx(),
        );

        // let offer_events = event::events_by_type<NewOfferEvent<DummyItem>>();
        // let offer_event = offer_events[0];
        // let offer_id = offer_event.offer_event_id();

        destroy(market);
        destroy(market_owner_cap);
        destroy(s_roles);
        destroy(admin_cap);
        destroy(kiosk);
        destroy(transfer_policy);
        destroy(policy_cap);
        destroy(p_kiosk_cap);
        destroy(p_offerer_kiosk_cap);
        destroy(offerer_kiosk);
        scen.end();
    }

    #[test]
    fun test_accept_offer() {
        let mut scen = scen::begin(MARKET_OWNER);
        let (mut market, market_owner_cap, s_roles, admin_cap) = prepare_marketplace(&mut scen);

        scen.next_tx(NFT_CREATOR);
        let (dummy_item, mut transfer_policy, policy_cap) = prepare_dummy_item(
            &mut scen,
            ITEM_OWNER,
        );

        let (mut kiosk, p_kiosk_cap) = create_kiosk(&mut scen);
        let kiosk_cap = kiosk::personal_kiosk::borrow(&p_kiosk_cap);
        let item_id = object::id(&dummy_item);

        kiosk.lock<DummyItem>(kiosk_cap, &transfer_policy, dummy_item);

        let price: u64 = 3000000000;

        scen.next_tx(OFFERER);
        let (mut offerer_kiosk, p_offerer_kiosk_cap) = create_kiosk(&mut scen);
        let offerer_kiosk_cap = kiosk::personal_kiosk::borrow(&p_offerer_kiosk_cap);
        let payment_coin = coin::mint_for_testing<SUI>(price, scen.ctx());

        escrow::offer<DummyItem>(
            &market,
            &mut offerer_kiosk,
            offerer_kiosk_cap,
            payment_coin,
            &transfer_policy,
            scen.ctx(),
        );

        let offer_events = event::events_by_type<NewOfferEvent<DummyItem>>();
        let offer_event = offer_events[0];
        let offer_id = offer_event.offer_event_id();

        scen.next_tx(NFT_CREATOR);
        let (offer_wrapper, request) = escrow::accept_offer<DummyItem>(
            &mut offerer_kiosk,
            offer_id,
            &mut kiosk,
            kiosk_cap,
            item_id,
            &mut transfer_policy,
            &mut market,
            scen.ctx(),
        );

        escrow::confirm_offer_accepted<DummyItem>(
            offer_wrapper,
            request,
            &transfer_policy,
            scen.ctx(),
        );

        destroy(market);
        destroy(market_owner_cap);
        destroy(s_roles);
        destroy(admin_cap);
        destroy(kiosk);
        destroy(transfer_policy);
        destroy(policy_cap);
        destroy(p_kiosk_cap);
        destroy(p_offerer_kiosk_cap);
        destroy(offerer_kiosk);
        // destroy(o)
        scen.end();
    }
    #[test]
    fun test_revoke_offer() {
        let mut scen = scen::begin(MARKET_OWNER);
        let (market, market_owner_cap, s_roles, admin_cap) = prepare_marketplace(&mut scen);

        scen.next_tx(NFT_CREATOR);
        let (dummy_item, transfer_policy, policy_cap) = prepare_dummy_item(&mut scen, ITEM_OWNER);

        let (mut kiosk, p_kiosk_cap) = create_kiosk(&mut scen);
        let kiosk_cap = kiosk::personal_kiosk::borrow(&p_kiosk_cap);
        // let item_id = object::id(&dummy_item);

        kiosk.lock<DummyItem>(kiosk_cap, &transfer_policy, dummy_item);

        let price: u64 = 3000000000;

        scen.next_tx(OFFERER);
        let (mut offerer_kiosk, p_offerer_kiosk_cap) = create_kiosk(&mut scen);
        let offerer_kiosk_cap = kiosk::personal_kiosk::borrow(&p_offerer_kiosk_cap);
        let payment_coin = coin::mint_for_testing<SUI>(price, scen.ctx());

        escrow::offer<DummyItem>(
            &market,
            &mut offerer_kiosk,
            offerer_kiosk_cap,
            payment_coin,
            &transfer_policy,
            scen.ctx(),
        );
        let offer_events = event::events_by_type<NewOfferEvent<DummyItem>>();
        let offer_event = offer_events[0];
        let offer_id = offer_event.offer_event_id();

        scen.next_tx(OFFERER);
        let offer_cap = scen::take_from_sender<OfferCap<DummyItem>>(&scen);

        scen.next_tx(OFFERER);
        escrow::revoke_offer<DummyItem>(
            &mut offerer_kiosk,
            offerer_kiosk_cap,
            offer_id,
            offer_cap,
            scen.ctx(),
        );
        destroy(market);
        destroy(market_owner_cap);
        destroy(s_roles);
        destroy(admin_cap);
        destroy(kiosk);
        destroy(transfer_policy);
        destroy(policy_cap);
        destroy(p_kiosk_cap);
        destroy(p_offerer_kiosk_cap);
        destroy(offerer_kiosk);
        scen.end();
    }

    #[test_only]
    fun prepare_marketplace(
        scenario: &mut Scenario,
    ): (MarketPlace, OwnerCap<MARKETPLACE>, SRoles<MARKETPLACE>, RoleCap<AdminCap>) {
        let sender = scenario.sender();
        assert!(sender == MARKET_OWNER, 1);
        marketplace::init_test(scenario.ctx());

        scenario.next_tx(sender);
        let mut s_roles = scenario.take_shared<SRoles<MARKETPLACE>>();
        let owner_cap = scenario.take_from_address<OwnerCap<MARKETPLACE>>(MARKET_OWNER);
        let market = scenario.take_shared<MarketPlace>();
        marketplace::add_admin(&owner_cap, &mut s_roles, sender, scenario.ctx());

        scenario.next_tx(sender);
        let admin_cap = scenario.take_from_address<RoleCap<AdminCap>>(MARKET_OWNER);

        (market, owner_cap, s_roles, admin_cap)
    }

    #[test_only]
    fun prepare_dummy_item(
        scenario: &mut Scenario,
        recipient: address,
    ): (DummyItem, TransferPolicy<DummyItem>, TransferPolicyCap<DummyItem>) {
        let sender = scenario.sender();
        assert!(sender == NFT_CREATOR, 2);

        let (mut transfer_policy, policy_cap) = policy::new_for_testing<DummyItem>(scenario.ctx());

        royalty_rule::add<DummyItem>(&mut transfer_policy, &policy_cap, 500, 20000);
        kiosk_lock_rule::add(&mut transfer_policy, &policy_cap);
        transfer::public_transfer(
            DummyItem { id: object::new(scenario.ctx()) },
            recipient,
        );

        scenario.next_tx(recipient);
        let dummy_item = scenario.take_from_address<DummyItem>(recipient);
        (dummy_item, transfer_policy, policy_cap)
    }

    #[test_only]
    fun create_kiosk(scenario: &mut Scenario): (Kiosk, PersonalKioskCap) {
        let sender = scenario.sender();
        marketplace::create_kiosk(scenario.ctx());

        scenario.next_tx(sender);
        let kiosk = scenario.take_shared<Kiosk>();
        let personal_kiosk_cap = scenario.take_from_address<PersonalKioskCap>(scenario.sender());
        (kiosk, personal_kiosk_cap)
    }
}
