#[test_only]
module marketplace::escrow_tests {
    use access_control::access_control::{SRoles, OwnerCap, RoleCap};
    use kiosk::{personal_kiosk::PersonalKioskCap, royalty_rule};
    use marketplace::{
        escrow::{Self, OfferEvent, offer_event_id},
        marketplace::{Self, MarketPlace, MARKETPLACE, AdminCap}
    };
    use sui::{
        coin,
        event,
        kiosk::Kiosk,
        sui::SUI,
        test_utils::destroy,
        transfer_policy as transfer_policy
    };

    #[test_only]
    use sui::test_scenario::{Self, end, Scenario, ctx};

    const MARKET_OWNER: address = @0x110A;
    const NFT_CREATOR: address = @0x110B;
    const ITEM_OWNER: address = @0x110C;
    const OFFER_CREATOR: address = @0x110D;

    public struct DummyItem has key, store {
        id: UID,
    }

    #[test]
    fun test_escrow() {
        let personal_fee: vector<u16> = vector[50];
        let owner_address_array: vector<address> = vector[OFFER_CREATOR];

        let mut scenario = test_scenario::begin(MARKET_OWNER);
        let (mut market, market_owner_cap, s_roles, admin_cap) = prepare_marketplace(&mut scenario);
        marketplace::set_personal_fee(
            &mut market,
            &admin_cap,
            &s_roles,
            owner_address_array,
            personal_fee,
        );

        scenario.next_tx(NFT_CREATOR);
        let (mut policy, policy_cap) = transfer_policy::new_for_testing<DummyItem>(scenario.ctx());
        royalty_rule::add(&mut policy, &policy_cap, 500, 20000);

        scenario.next_tx(NFT_CREATOR);
        let item = prepare_dummy_item(&mut scenario, ITEM_OWNER);
        let item_id = object::id(&item);

        scenario.next_tx(ITEM_OWNER);
        let (mut accepter_kiosk, accepter_personal_kiosk_cap) = create_kiosk(&mut scenario);

        scenario.next_tx(OFFER_CREATOR);
        let (mut offerer_kiosk, offerer_personal_kiosk_cap) = create_kiosk(&mut scenario);
        let price: u64 = 30000000;
        // let marketplace_fee = price * (personal_fee[0] as u64) / 10_000;
        // let royalty_fee: u64 = price * 500 / 10_000;
        let offer_creator_coin = coin::mint_for_testing<SUI>(
            price,
            scenario.ctx(),
        );
        escrow::offer<DummyItem>(
            &mut offerer_kiosk,
            offerer_personal_kiosk_cap.borrow(),
            item_id,
            // price,
            offer_creator_coin,
            &policy,
            &market,
            scenario.ctx(),
        );

        let offer_events = event::events_by_type<OfferEvent>();
        let offer_event = offer_events[0];
        let offer_id = offer_event_id(&offer_event);

        scenario.next_tx(ITEM_OWNER);
        accepter_kiosk.place<DummyItem>(accepter_personal_kiosk_cap.borrow(), item);

        scenario.next_tx(ITEM_OWNER);
        let (offer_wrapper, request) = escrow::accept_offer(
            &mut offerer_kiosk,
            offer_id,
            &mut accepter_kiosk,
            accepter_personal_kiosk_cap.borrow(),
            item_id,
            &mut policy,
            &mut market,
            scenario.ctx(),
        );
        escrow::confirm_offer_accepted(offer_wrapper, request, &policy, scenario.ctx());

        destroy(market_owner_cap);
        destroy(admin_cap);

        destroy(policy_cap);
        destroy(offerer_personal_kiosk_cap);
        destroy(accepter_personal_kiosk_cap);
        destroy(market);
        destroy(s_roles);
        destroy(policy);
        destroy(offerer_kiosk);
        destroy(accepter_kiosk);
        scenario.end();
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
    fun prepare_dummy_item(scenario: &mut Scenario, recipient: address): DummyItem {
        let sender = scenario.sender();
        assert!(sender == NFT_CREATOR, 2);

        transfer::transfer(
            DummyItem { id: object::new(scenario.ctx()) },
            recipient,
        );

        scenario.next_tx(recipient);
        let dummy_item = scenario.take_from_address<DummyItem>(recipient);
        dummy_item
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
