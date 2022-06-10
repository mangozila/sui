// Copyright (c) 2022, Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Example implementation of a liquidity Pool for Sui.
///
/// - Only module publisher can create new Pools.
/// - For simplicity's sake all swaps are done with SUI coin.
/// - Fees are customizable per Pool.
///
/// This solution is rather simple and is based on the example from the Move repo:
/// https://github.com/move-language/move/blob/main/language/documentation/examples/experimental/coin-swap/sources/CoinSwap.move
module defi::pool {
    use sui::Coin::{Self, Coin, TreasuryCap};
    use sui::Balance::{Self, Balance};
    use sui::ID::{VersionedID};
    use sui::SUI::SUI;
    use sui::Transfer;
    use sui::TxContext::{Self, TxContext};

    /// For when supplied Coin is zero.
    const EZeroAmount: u64 = 0;

    /// For when pool fee is set incorrectly.
    /// Allowed values are: 0-1000.
    const EWrongFee: u64 = 0;

    /// The Capability to create new pools.
    struct PoolCreatorCap has key, store {
        id: VersionedID
    }

    /// The Pool token that will be used to mark the pool share
    /// of a liquidity provider.
    struct LSP<phantom T> has drop {}

    /// The pool with exchange.
    ///
    /// - `fee_percent` should be in the range: 0-1000, meaning
    /// that 1000 is 100% and 1 is 0.1%
    struct Pool<phantom T> has key {
        id: VersionedID,
        sui: Balance<SUI>,
        token: Balance<T>,
        lsp_treasury: TreasuryCap<LSP<T>>,
        fee_percent: u64
    }

    /// On init creator of the module gets the capability
    /// to create new `Pool`s.
    fun init(ctx: &mut TxContext) {
        Transfer::transfer(PoolCreatorCap {
            id: TxContext::new_id(ctx)
        }, TxContext::sender(ctx))
    }

    /// Entrypoint for the `create_pool` method.
    public(script) fun create_pool_<T>(
        cap: &PoolCreatorCap,
        token: Coin<T>,
        sui: Coin<SUI>,
        share: u64,
        fee_percent: u64,
        ctx: &mut TxContext
    ) {
        create_pool(cap, token, sui, share, fee_percent, ctx);
    }

    /// Create new `Pool` for token `T`. Each Pool holds a `Coin<T>`
    /// and a `Coin<SUI>`. Swaps are available in both directions.
    ///
    /// - `share` argument defines the initial amount of LSP tokens
    /// received by the creator of the Pool.
    public fun create_pool<T>(
        _: &PoolCreatorCap,
        token: Coin<T>,
        sui: Coin<SUI>,
        share: u64,
        fee_percent: u64,
        ctx: &mut TxContext
    ) {
        assert!(Coin::value(&sui) > 0, EZeroAmount);
        assert!(Coin::value(&token) > 0, EZeroAmount);
        assert!(fee_percent >= 0 && fee_percent < 1000, EWrongFee);

        let lsp_treasury = Coin::create_currency(LSP<T> {}, ctx);
        let lsp = Coin::mint(share, &mut lsp_treasury, ctx);

        Transfer::transfer(lsp, TxContext::sender(ctx));
        Transfer::share_object(Pool {
            id: TxContext::new_id(ctx),
            token: Coin::into_balance(token),
            sui: Coin::into_balance(sui),
            lsp_treasury,
            fee_percent
        });
    }


    /// Entrypoint for the `swap_sui` method. Sends swapped token
    /// to sender.
    public(script) fun swap_sui_<T>(
        pool: &mut Pool<T>, sui: Coin<SUI>, ctx: &mut TxContext
    ) {
        Transfer::transfer(
            swap_sui(pool, sui, ctx),
            TxContext::sender(ctx)
        )
    }

    /// Swap `Coin<SUI>` for the `Coin<T>`.
    /// Returns Coin<T>.
    public fun swap_sui<T>(
        pool: &mut Pool<T>, sui: Coin<SUI>, ctx: &mut TxContext
    ): Coin<T> {
        assert!(Coin::value(&sui) > 0, EZeroAmount);

        let sui_balance = Coin::into_balance(sui);

        // Calculate the output amount - fee
        let (sui_reserve, token_reserve, _) = get_amounts(pool);
        let output_amount = get_input_price(
            Balance::value(&sui_balance),
            sui_reserve,
            token_reserve,
            pool.fee_percent
        );

        Balance::join(&mut pool.sui, sui_balance);
        Coin::withdraw(&mut pool.token, output_amount, ctx)
    }

    /// Entry point for the `swap_token` method. Sends swapped SUI
    /// to the sender.
    public(script) fun swap_token_<T>(
        pool: &mut Pool<T>, token: Coin<T>, ctx: &mut TxContext
    ) {
        Transfer::transfer(
            swap_token(pool, token, ctx),
            TxContext::sender(ctx)
        )
    }

    /// Swap `Coin<T>` for the `Coin<SUI>`.
    /// Returns the swapped `Coin<SUI>`.
    public fun swap_token<T>(
        pool: &mut Pool<T>, token: Coin<T>, ctx: &mut TxContext
    ): Coin<SUI> {
        assert!(Coin::value(&token) > 0, EZeroAmount);

        let tok_balance = Coin::into_balance(token);

        // Calculate the output amount - fee
        let (sui_reserve, token_reserve, _) = get_amounts(pool);
        let output_amount = get_input_price(
            Balance::value(&tok_balance),
            token_reserve,
            sui_reserve,
            pool.fee_percent
        );

        Balance::join(&mut pool.token, tok_balance);
        Coin::withdraw(&mut pool.sui, output_amount, ctx)
    }

    /// Entrypoint for the `add_liquidity` method. Sends `Coin<LSP>` to
    /// the transaction sender.
    public(script) fun add_liquidity_<T>(
        pool: &mut Pool<T>, sui: Coin<SUI>, token: Coin<T>, ctx: &mut TxContext
    ) {
        Transfer::transfer(
            add_liquidity(pool, sui, token, ctx),
            TxContext::sender(ctx)
        );
    }

    /// Add liquidity to the `Pool`. Sender needs to provide both
    /// `Coin<SUI>` and `Coin<T>`, and in exchange he gets `Coin<LSP>` -
    /// liquidity provider tokens.
    public fun add_liquidity<T>(
        pool: &mut Pool<T>, sui: Coin<SUI>, token: Coin<T>, ctx: &mut TxContext
    ): Coin<LSP<T>> {
        assert!(Coin::value(&sui) > 0, EZeroAmount);
        assert!(Coin::value(&token) > 0, EZeroAmount);

        let sui_balance = Coin::into_balance(sui);
        let token_balance = Coin::into_balance(token);

        let (sui_amount, _, lsp_supply) = get_amounts(pool);

        let sui_added = Balance::value(&sui_balance);
        let share_minted = (sui_added * lsp_supply) / sui_amount;

        Balance::join(&mut pool.sui, sui_balance);
        Balance::join(&mut pool.token, token_balance);

        Coin::mint(share_minted, &mut pool.lsp_treasury, ctx)
    }

    /// Entrypoint for the `remove_liquidity` method. Transfers
    /// withdrawn assets to the sender.
    public(script) fun remove_liquidity_<T>(
        pool: &mut Pool<T>,
        lsp: Coin<LSP<T>>,
        ctx: &mut TxContext
    ) {
        let (sui, token) = remove_liquidity(pool, lsp, ctx);
        let sender = TxContext::sender(ctx);

        Transfer::transfer(sui, sender);
        Transfer::transfer(token, sender);
    }

    /// Remove liquidity from the `Pool` by burning `Coin<LSP>`.
    /// Returns `Coin<T>` and `Coin<SUI>`.
    public fun remove_liquidity<T>(
        pool: &mut Pool<T>,
        lsp: Coin<LSP<T>>,
        ctx: &mut TxContext
    ): (Coin<SUI>, Coin<T>) {
        let lsp_amount = Coin::burn(lsp, &mut pool.lsp_treasury);

        assert!(lsp_amount > 0, EZeroAmount);

        let (sui_amt, tok_amt, lsp_supply) = get_amounts(pool);

        let sui_removed = (sui_amt * lsp_amount) / lsp_supply;
        let tok_removed = (tok_amt * lsp_amount) / lsp_supply;

        (
            Coin::withdraw(&mut pool.sui, sui_removed, ctx),
            Coin::withdraw(&mut pool.token, tok_removed, ctx)
        )
    }

    /// Get most used values in a handy way:
    /// - amount of SUI
    /// - amount of token
    /// - total supply of LSP
    public fun get_amounts<T>(pool: &Pool<T>): (u64, u64, u64) {
        (
            Balance::value(&pool.sui),
            Balance::value(&pool.token),
            Coin::total_supply(&pool.lsp_treasury)
        )
    }

    /// Calculate the output amount minus the fee - 0.3%
    fun get_input_price(
        input_amount: u64, input_reserve: u64, output_reserve: u64, fee_percent: u64
    ): u64 {
        let input_amount_with_fee = input_amount * (1000 - fee_percent); // 0.3% fee
        let numerator = input_amount_with_fee * output_reserve;
        let denominator = (input_reserve * 1000) + input_amount_with_fee;

        numerator / denominator
    }

    public fun sui_price_in_token<T>(pool: &Pool<T>, to_sell: u64): u64 {
        let (sui_amt, tok_amt, _) = get_amounts(pool);
        get_input_price(to_sell, tok_amt, sui_amt, pool.fee_percent)
    }

    public fun token_price_in_sui<T>(pool: &Pool<T>, to_sell: u64): u64 {
        let (sui_amt, tok_amt, _) = get_amounts(pool);
        get_input_price(to_sell, sui_amt, tok_amt, pool.fee_percent)
    }

    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        init(ctx)
    }
}

#[test_only]
module defi::pool_tests {
    use sui::SUI::SUI;
    use sui::Coin::{Self, Coin, mint_for_testing as mint, burn_for_testing as burn};
    use sui::TestScenario::{Self as test, Scenario, next_tx, ctx};
    use defi::pool::{Self, Pool, LSP};

    // Gonna be our test token.
    struct BEEP {}

    // Tests section
    #[test] fun test_init_pool() { test_init_pool_(&mut scenario()) }
    #[test] fun test_swap_sui() { test_swap_sui_(&mut scenario()) }
    #[test] fun test_swap_tok() { test_swap_tok_(&mut scenario()) }

    /// Init a Pool with a 1_000_000 BEEP and 1_000_000_000 SUI;
    /// Set the ratio BEEP : SUI = 1 : 1000.
    /// Set LSP token amount to 1000;
    fun test_init_pool_(test: &mut Scenario) {
        let (owner, _) = people();

        next_tx(test, &owner); {
            pool::init_for_testing(ctx(test));
        };

        next_tx(test, &owner); {
            let pool_cap = test::take_owned<pool::PoolCreatorCap>(test);

            pool::create_pool(
                &pool_cap,
                mint<BEEP>(1000000, ctx(test)),
                mint<SUI>(1000000000, ctx(test)),
                1000,
                3,
                ctx(test)
            );

            test::return_owned(test, pool_cap);
        };

        next_tx(test, &owner); {
            let lsp = test::take_owned<Coin<LSP<BEEP>>>(test);
            let pool = test::take_shared<Pool<BEEP>>(test);
            let pool_mut = test::borrow_mut(&mut pool);
            let (amt_sui, amt_tok, lsp_supply) = pool::get_amounts(pool_mut);

            assert!(Coin::value(&lsp) == 1000, 0);
            assert!(lsp_supply == 1000, 0);
            assert!(amt_sui == 1000000000, 0);
            assert!(amt_tok == 1000000, 0);

            test::return_owned(test, lsp);
            test::return_shared(test, pool);
        };
    }

    /// The other guy tries to exchange 5_000_000 sui for ~ 5000 BEEP,
    /// minus the commission that is paid to the pool.
    fun test_swap_sui_(test: &mut Scenario) {
        test_init_pool_(test);

        let (_, the_guy) = people();

        next_tx(test, &the_guy); {
            let pool = test::take_shared<Pool<BEEP>>(test);
            let pool_mut = test::borrow_mut(&mut pool);

            let token = pool::swap_sui(pool_mut, mint<SUI>(5000000, ctx(test)), ctx(test));

            // Check the value of the coin received by the guy.
            // Due to rounding problem the value is not precise
            // (works better on larger numbers).
            assert!(burn(token) > 4950, 1);

            test::return_shared(test, pool);
        };
    }

    /// The owner swaps back BEEP for SUI and expects an increase in price.
    /// The sent amount of BEEP is 1000, initial price was 1 BEEP : 1000 SUI;
    fun test_swap_tok_(test: &mut Scenario) {
        test_swap_sui_(test);

        let (owner, _) = people();

        next_tx(test, &owner); {
            let pool = test::take_shared<Pool<BEEP>>(test);
            let pool_mut = test::borrow_mut(&mut pool);

            let sui = pool::swap_token(pool_mut, mint<BEEP>(1000, ctx(test)), ctx(test));

            // Actual win is 1005971, which is ~ 0.6% profit
            assert!(burn(sui) > 1000000u64, 2);

            test::return_shared(test, pool);
        };
    }

    // utilities
    fun scenario(): Scenario { test::begin(&@0x1) }
    fun people(): (address, address) { (@0xBEEF, @0x1337) }
}