module nft::nft {
    use launchpad::{collection_manager, launchpad};
    use std::string::String;
    use sui::{
        clock::Clock,
        coin::Coin,
        display,
        kiosk::{Kiosk, KioskOwnerCap},
        package::{Self, Publisher},
        sui::SUI,
        transfer_policy::TransferPolicy
    };

    // === Structs ===

    public struct NFT has drop {}

    public struct MyNft has key, store {
        id: UID,
        name: String,
        description: String,
        image_url: String,
        count: u64,
        // Add your custom fields here
        // attributes: VecMap<String, String>,
    }

    /// Optionally, you can set up a custom generator for more complex NFT generation logic.
    /// It can be tailored to your needs.
    public struct MyNftCollection has key, store {
        id: UID,
        counter: u64,
        // Add your custom fields here
        // attributes: Table<u64, VecMap<String, String>>,
        // ...
    }

    // === Errors ===

    // === Init ===

    fun init(otw: NFT, ctx: &mut TxContext) {
        // Publisher
        let publisher = package::claim(otw, ctx);

        // Display
        let mut display = display::new<MyNft>(&publisher, ctx);
        display.add(b"name".to_string(), b"{character.name}".to_string());
        display.add(b"description".to_string(), b"{character.description}".to_string());
        display.add(b"image_url".to_string(), b"{image_url}".to_string());
        display.add(b"project_url".to_string(), b"example.com".to_string());

        display.update_version();
        transfer::public_transfer(publisher, ctx.sender());
        transfer::public_transfer(display, ctx.sender());

        // Generator
        transfer::share_object(MyNftCollection {
            id: object::new(ctx),
            counter: 0,
        })
    }

    // === Mint Functions: Choose one depending on if kiosk is enabled/disabled ===

    /// Collection must be approved by Launchpad Admin
    /// Collection start timestamps must be valid
    /// Collection must not be paused by Launchpad Admin or Creator
    /// Will throw error Kiosk is enabled
    public entry fun mint(
        manager: &mut collection_manager::Collection,
        launchpad: &mut launchpad::Launchpad,
        payment: Coin<SUI>,
        clock: &Clock,
        // Your custom generator
        generator: &mut MyNftCollection,
        ctx: &mut TxContext,
    ) {
        let item = generate_nft(
            generator,
            ctx,
        );

        manager.mint(launchpad, item, payment, clock, ctx)
    }

    /// Collection must be approved by Launchpad Admin
    /// Collection start timestamps must be valid
    /// Collection must not be paused by Launchpad Admin or Creator
    /// Will throw error if Kiosk is disabled
    public entry fun mint_with_kiosk(
        manager: &mut collection_manager::Collection,
        launchpad: &mut launchpad::Launchpad,
        payment: Coin<SUI>,
        clock: &Clock,
        kiosk: &mut Kiosk,
        cap: &KioskOwnerCap,
        _policy: &TransferPolicy<MyNft>,
        // Your custom generator
        generator: &mut MyNftCollection,
        ctx: &mut TxContext,
    ) {
        let item = generate_nft(
            generator,
            ctx,
        );

        manager.mint_with_kiosk(launchpad, item, payment, clock, kiosk, cap, _policy, ctx)
    }

    // === Admin(Creator Role) Functions ===

    /// Create a new Collection. Shares Collection object and send Creator object to the sender.
    /// Sends collection to launchpad for approval.
    /// If `is_kiosk` is true, also creates a shared object TransferPolicy<T>, and TranferPolicyCap to manage it
    /// If `whitelist_price`, `whitelist_supply`, and `whitelist_start_timestamp_ms` are set,
    /// whitelist phase is enabled.
    public fun create_collection(
        launchpad: &mut launchpad::Launchpad,
        // publisher of nft package
        publisher: &Publisher,
        clock: &Clock,
        name: String,
        description: String,
        supply: u64,
        price: u64,
        is_kiosk: bool,
        start_timestamp_ms: u64,
        max_items_per_address: u64,
        // Optional fields. Use option::some to set them or option::none to skip them
        // By default whitelist is disabled
        // To enable whitelist, set whitelist_price, whitelist_supply, and whitelist_start_timestamp_ms
        whitelist_price: Option<u64>,
        whitelist_supply: Option<u64>,
        whitelist_start_timestamp_ms: Option<u64>,
        // By default, Custom is disabled
        // To enable custom, set custom_fee
        // custom_fee: Option<u64>,
        // By default, custom_fee is 0
        custom_name: Option<String>,
        custom_price: Option<u64>,
        custom_supply: Option<u64>,
        custom_start_timestamp_ms: Option<u64>,
        ctx: &mut TxContext,
    ) {
        collection_manager::new<MyNft>(
            launchpad,
            publisher,
            clock,
            name,
            description,
            supply,
            price,
            is_kiosk,
            start_timestamp_ms,
            max_items_per_address,
            whitelist_price,
            whitelist_supply,
            whitelist_start_timestamp_ms,
            custom_name,
            custom_price,
            custom_supply,
            custom_start_timestamp_ms,
            ctx,
        );
    }

    // === Private Functions ===

    /// Add your generation logic here
    fun generate_nft(generator: &mut MyNftCollection, ctx: &mut TxContext): MyNft {
        let id = object::new(ctx);
        let name = b"NFT".to_string();
        let description = b"NFT".to_string();
        let image_url = b"https://tradeport.mypinata.cloud/ipfs/Qmai3CRQTrtTFWuCfF56jvLZZSqTwQvN1EwUAFK3Mt3GhF?pinataGatewayToken=sd9Ceh-eJIQ43PRB3JW6QGkHAr8-cxGhhjDF0Agxwd_X7N4_reLPQXZSP_vUethU".to_string();

        let nft = MyNft {
            id,
            name,
            description,
            image_url,
            count: generator.counter,
        };
        generator.counter = generator.counter + 1;

        return nft
    }
}
