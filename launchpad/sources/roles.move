module launchpad::roles {
    use access_control::access_control::{Self as control, SRoles, OwnerCap};

    // === Errors ===

    const ENotCollectionDeployer: u64 = 0;

    // === Constants ===

    // === Structs ===

    /// Represents an admin role.
    /// Admins have the ability to manage Launchpad.
    public struct Admin has key {
        id: UID,
    }

    public struct ROLES has drop {}

    /// Represents a creator role.
    /// Creators have the ability to manage a collection.
    public struct Creator has key, store {
        id: UID,
        collection: ID,
    }

    // === Events ===

    // === Init ===

    fun init(otw: ROLES, ctx: &mut TxContext) {
        control::default<ROLES>(&otw, ctx);
    }

    // === Public Functions ===

    /// Check if the creator is for the given collection.
    public fun assert_collection_creator(creator: &Creator, collection: ID) {
        assert!(creator.collection == collection, ENotCollectionDeployer)
    }

    // === View Functions ===

    // === Admin Functions ===

    /// @dev Grants administrative privileges to the specified recipient. Only the marketplace owner can add new administrators.
    /// @param owner A reference to the `OwnerCap` of the marketplace, used to verify ownership and authority.
    /// @param roles A mutable reference to the roles object where the recipient will be granted administrative privileges.
    /// @param recipient The address of the recipient who will be assigned the `AdminCap`.
    /// @param ctx Sender's tx context.
    public fun add_admin(
        owner: &OwnerCap<ROLES>,
        roles: &mut SRoles<ROLES>,
        recipient: address,
        ctx: &mut TxContext,
    ) {
        control::add_role<ROLES, Admin>(owner, roles, recipient, ctx);
    }

    /// @dev Revokes administrative privileges from a specified administrator. Only the marketplace owner can perform this action.
    /// @param _ A reference to the `OwnerCap` of the marketplace, used to verify ownership and authority.
    /// @param roles A mutable reference to the roles object from which the target administrator's privileges will be removed.
    /// @param target The ID of the administrator whose privileges are to be revoked.
    /// @param ctx Sender's tx context.
    public fun revoke_admin(
        _: &OwnerCap<ROLES>,
        roles: &mut SRoles<ROLES>,
        target: ID,
        ctx: &mut TxContext,
    ) {
        control::revoke_role_access<ROLES>(_, roles, target, ctx)
    }

    // === Package Functions ===

    /// Create a new creator role for the given collection ID.
    public(package) fun new_creator(collection: ID, ctx: &mut TxContext): Creator {
        Creator {
            id: object::new(ctx),
            collection,
        }
    }
}

// === Private Functions ===

// === Test Functions ===
