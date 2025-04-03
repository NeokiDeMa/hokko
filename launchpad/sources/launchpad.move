module launchpad::launchpad {
    use access_control::access_control::RoleCap;
    use launchpad::{roles::Admin, utils::withdraw_balance};
    use std::string::String;
    use sui::{
        balance::{Self, Balance},
        coin::{Self, Coin},
        event::emit,
        package,
        sui::SUI,
        table::{Self, Table}
    };

    // === Errors ===
    const ECollectionNotFound: u64 = 0;
    const ECollectionNotPending: u64 = 1;
    const ECollectionNotApproved: u64 = 2;
    const ECollectionNotPaused: u64 = 3;
    const ECollectionPaused: u64 = 4;
    const ETypeAlreadyExists: u64 = 4;

    // === Constants ===

    const DEFAULT_FEE_PERCENTAGE: u64 = 200;

    // === Structs ===

    public struct LAUNCHPAD has drop {}

    public enum LaunchpadCollectionState has drop, store {
        NotFound,
        Pending,
        Approved,
        Rejected,
        Paused,
    }

    public struct Launchpad has key {
        id: UID,
        base_fee_percentage: u64,
        custom_fee_percentage: Table<ID, u64>,
        balance: Balance<SUI>,
        collections: Table<ID, LaunchpadCollectionState>,
        collection_types: Table<String, bool>,
    }

    // === Events ===
    public struct LaunchpadCollectionPendingEvent has copy, drop (ID)

    public struct LaunchpadCollectionApprovedEvent has copy, drop (ID)

    public struct LaunchpadCollectionRejectedEvent has copy, drop (ID)

    public struct LaunchpadCollectionPausedEvent has copy, drop (ID)

    public struct LaunchpadCollectionResumedEvent has copy, drop (ID)

    // === Init ===

    fun init(otw: LAUNCHPAD, ctx: &mut TxContext) {
        let publisher = package::claim(otw, ctx);

        let launchpad = Launchpad {
            id: object::new(ctx),
            base_fee_percentage: DEFAULT_FEE_PERCENTAGE,
            custom_fee_percentage: table::new(ctx),
            balance: balance::zero(),
            collections: table::new(ctx),
            collection_types: table::new(ctx),
        };

        transfer::public_transfer(publisher, ctx.sender());
        transfer::share_object(launchpad);
    }

    // === Public Functions ===

    // === View Functions ===
    public fun collection_status_appoved(_: &Launchpad): LaunchpadCollectionState {
        LaunchpadCollectionState::Approved
    }

    public fun collection_state(launchpad: &Launchpad, collection: ID): LaunchpadCollectionState {
        if (!launchpad.collections.contains(collection)) {
            return LaunchpadCollectionState::NotFound
        };

        let state = &launchpad.collections[collection];
        if (state == LaunchpadCollectionState::Approved) {
            return LaunchpadCollectionState::Approved
        } else if (state == LaunchpadCollectionState::Paused) {
            return LaunchpadCollectionState::Paused
        } else {
            return LaunchpadCollectionState::Rejected
        }
    }

    public fun fee_percentage(launchpad: &Launchpad, collection: ID): u64 {
        if (launchpad.custom_fee_percentage.contains(collection)) {
            let custom_fee = launchpad.custom_fee_percentage[collection];
            if (custom_fee < launchpad.base_fee_percentage) {
                return launchpad.base_fee_percentage
            } else {
                return custom_fee
            }
        } else {
            launchpad.base_fee_percentage
        }
    }

    // === Admin Functions ===

    public fun set_base_fee(launchpad: &mut Launchpad, _: &RoleCap<Admin>, fee: u64) {
        launchpad.base_fee_percentage = fee;
    }

    public fun set_custom_fee(
        launchpad: &mut Launchpad,
        _: &RoleCap<Admin>,
        collection: ID,
        fee: u64,
    ) {
        assert!(launchpad.collections.contains(collection), ECollectionNotFound);
        if (launchpad.custom_fee_percentage.contains(collection)) {
            let old_fee = launchpad.custom_fee_percentage.borrow_mut(collection);
            *old_fee = fee;
        } else { launchpad.custom_fee_percentage.add(collection, fee); };
    }

    /// Approve a collection.
    /// Once approved, collection creator can launch the collection.
    public fun approve_collection(
        launchpad: &mut Launchpad,
        _: &RoleCap<Admin>,
        collection: ID,
        custom_fee: Option<u64>,
    ) {
        launchpad.assert_collection_exists(collection);
        launchpad.assert_collection_state_pending(collection);

        let state = &mut launchpad.collections[collection];
        if (custom_fee.is_some()) {
            let fee = custom_fee.destroy_some();
            launchpad.custom_fee_percentage.add(collection, fee);
        } else {
            custom_fee.destroy_none();
        };
        emit(LaunchpadCollectionApprovedEvent(collection));

        *state = LaunchpadCollectionState::Approved;
    }

    /// Reject a collection.
    /// Once rejected, collection creator cannot launch the collection.
    public fun reject_collection(launchpad: &mut Launchpad, _: &RoleCap<Admin>, collection: ID) {
        launchpad.assert_collection_exists(collection);
        launchpad.assert_collection_state_pending(collection);

        let state = &mut launchpad.collections[collection];

        emit(LaunchpadCollectionRejectedEvent(collection));

        *state = LaunchpadCollectionState::Rejected;
    }

    /// Pause a collection by admin.
    /// Can only be called if the collection is approved.
    public fun pause_collection(launchpad: &mut Launchpad, _: &RoleCap<Admin>, collection: ID) {
        launchpad.assert_collection_exists(collection);

        let state = &mut launchpad.collections[collection];
        assert!(state == LaunchpadCollectionState::Approved, ECollectionNotApproved);

        emit(LaunchpadCollectionPausedEvent(collection));

        *state = LaunchpadCollectionState::Paused;
    }

    /// Resume a collection by admin.
    /// Can only be called if the collection is paused.
    public fun resume_collection(launchpad: &mut Launchpad, _: &RoleCap<Admin>, collection: ID) {
        launchpad.assert_collection_exists(collection);

        let state = &mut launchpad.collections[collection];
        assert!(state == LaunchpadCollectionState::Paused, ECollectionNotPaused);

        emit(LaunchpadCollectionResumedEvent(collection));

        *state = LaunchpadCollectionState::Approved;
    }

    /// Withdraw the balance from the launchpad by admin.
    public fun withdraw(launchpad: &mut Launchpad, _: &RoleCap<Admin>, ctx: &mut TxContext) {
        withdraw_balance(&mut launchpad.balance, ctx)
    }

    // === Package Functions ===

    /// Registers a collection.
    /// Once initialized, Admin can approve or reject the collection.
    public(package) fun register_collection(
        launchpad: &mut Launchpad,
        collection: ID,
        // To prevent multiple creations from same package
        collection_type: String,
    ) {
        let state = LaunchpadCollectionState::Pending;

        emit(LaunchpadCollectionPendingEvent(collection));

        launchpad.collections.add(collection, state);

        assert!(!launchpad.collection_types.contains(collection_type), ETypeAlreadyExists);
        launchpad.collection_types.add(collection_type, true);
    }

    /// Top up the launchpad balance.
    /// Used to pay the fee for collection launch.
    public(package) fun top_up(launchpad: &mut Launchpad, fee: Coin<SUI>) {
        coin::put(&mut launchpad.balance, fee)
    }

    // === Package Functions: asserts

    public(package) fun assert_collection_approved(launchpad: &Launchpad, collection: ID) {
        assert!(
            launchpad.collection_state(collection) == LaunchpadCollectionState::Approved,
            ECollectionNotApproved,
        );
    }

    public(package) fun assert_collection_not_paused(launchpad: &Launchpad, collection: ID) {
        assert!(
            launchpad.collection_state(collection) != LaunchpadCollectionState::Paused,
            ECollectionPaused,
        );
    }

    // === Private Functions ===

    fun assert_collection_exists(launchpad: &Launchpad, collection: ID) {
        assert!(launchpad.collections.contains(collection), ECollectionNotFound)
    }

    fun assert_collection_state_pending(launchpad: &Launchpad, collection: ID) {
        let state = &launchpad.collections[collection];
        assert!(
            state == LaunchpadCollectionState::Pending || state == LaunchpadCollectionState::Rejected,
            ECollectionNotPending,
        )
    }
}

// === Test Functions ===
