module launchpad::utils {
    use std::{string::{Self, String}, type_name::get_with_original_ids};
    use sui::{balance::Balance, coin::{Self, Coin}, pay::keep};

    const EInvalidPayment: u64 = 0;

    /// Withdraw all coins from the balance and send them to the transaction sender.
    public(package) fun withdraw_balance<T>(balance: &mut Balance<T>, ctx: &mut TxContext) {
        keep(coin::from_balance(balance.withdraw_all(), ctx), ctx);
    }

    /// Convert a type T to a string.
    public(package) fun type_to_string<T>(): String {
        string::from_ascii(get_with_original_ids<T>().into_string())
    }

    public(package) fun payment_split_fee<T>(
        payment: &mut Coin<T>,
        price: u64,
        fee_percentage: u64,
        ctx: &mut TxContext,
    ): Coin<T> {
        assert!(payment.value() == price, EInvalidPayment);

        let fee_value = ((payment.value() as u128)  * (fee_percentage as u128) / 10000) as u64;

        let fee = payment.split(fee_value, ctx);

        fee
    }
}
