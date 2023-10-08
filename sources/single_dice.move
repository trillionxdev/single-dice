module dice::single_dice {

    use std::vector;
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};
    use sui::object::{Self, UID, ID};
    use sui::tx_context::{Self, TxContext};
    use sui::transfer;
    use sui::bls12381::bls12381_min_pk_verify;
    use sui::hash::blake2b256;
    use sui::event;
    use sui::dynamic_object_field as dof;
    use dice::bet_manager as bm;

    // --------------- Constants ---------------

    const CHALLENGE_EPOCH_INTERVAL: u64 = 7;

    // --------------- Errors ---------------

    const EInvalidStakeAmount: u64 = 0;
    const EInvalidBlsSig: u64 = 1;
    const ECannotChallenge: u64 = 2;
    const EPoolNotEnough: u64 = 3;
    const EGameNotExists: u64 = 4;
    const EBatchSettleInvalidInputs: u64 = 5;
    const ESeedLengthNotEnough: u64 = 6;

    // --------------- Events ---------------

    struct NewGame<phantom T> has copy, drop {
        game_id: ID,
        player: address,
        guess: u8,
        stake_amount: u64,
    }

    struct Outcome<phantom T> has copy, drop {
        game_id: ID,
        player: address,
        player_won: bool,
        pnl: u64,
        challenged: bool,
    }

    struct Deposit<phantom T> has copy, drop {
        amount: u64,
    }

    struct Withdraw<phantom T> has copy, drop {
        amount: u64,
    }

    // --------------- Objects ---------------

    struct House<phantom T> has key {
        id: UID,
        pub_key: vector<u8>,
        min_stake_amount: u64,
        max_stake_amount: u64,
        pool: Balance<T>,
    }

    struct Game<phantom T> has key, store {
        id: UID,
        player: address,
        start_epoch: u64,
        stake: Coin<T>,
        payout: Coin<T>,
        guess: u8,
        seed: vector<u8>,
    }

    struct AdminCap has key {
        id: UID,
    }

    // --------------- Constructor ---------------

    fun init(ctx: &mut TxContext) {
        let admin = tx_context::sender(ctx);
        let admin_cap = AdminCap { id: object::new(ctx) };
        transfer::transfer(admin_cap, admin);
    }

    // --------------- House Funtions ---------------

    public entry fun create_house<T>(
        _: &AdminCap,
        pub_key: vector<u8>,
        min_stake_amount: u64,
        max_stake_amount: u64,
        init_fund: Coin<T>,
        ctx: &mut TxContext,
    ) {
        transfer::share_object(House<T> {
            id: object::new(ctx),
            pub_key,
            min_stake_amount,
            max_stake_amount,
            pool: coin::into_balance(init_fund),
        });
    }

    public entry fun deposit<T>(
        house: &mut House<T>,
        coin: Coin<T>,
    ) {        
        let fund = coin::into_balance(coin);
        let amount = balance::value(&fund);
        balance::join(&mut house.pool, fund);
        event::emit(Deposit<T> { amount });
    }

    public entry fun withdraw<T>(
        _: &AdminCap,
        house: &mut House<T>,
        amount: u64,
        recipient: address,
        ctx: &mut TxContext
    ) {
        assert!(amount <= balance::value(&house.pool), EPoolNotEnough);
        let coin = coin::take(&mut house.pool, amount, ctx);
        transfer::public_transfer(coin, recipient);
        event::emit(Withdraw<T> { amount });
    }

    public entry fun update_max_stake_amount<T>(
        _: &AdminCap,
        house: &mut House<T>,
        max_stake_amount: u64,
    ) {
        house.max_stake_amount = max_stake_amount;
    }

    public entry fun update_min_stake_amount<T>(
        _: &AdminCap,
        house: &mut House<T>,
        min_stake_amount: u64,
    ) {
        house.min_stake_amount = min_stake_amount;
    }

    // --------------- Game Funtions ---------------

    public entry fun start_game<T>(
        house: &mut House<T>,
        guess: u8,
        seed: vector<u8>,
        stake: Coin<T>,
        ctx: &mut TxContext,
    ): ID {
        let stake_amount = coin::value(&stake);
        let payout_amount = bm::payout_amount(stake_amount, guess);
        assert!(
            stake_amount >= house.min_stake_amount &&
            stake_amount <= house.max_stake_amount,
            EInvalidStakeAmount
        );
        assert!(
            vector::length(&seed) >= 32,
            ESeedLengthNotEnough,
        );
        // house place the stake
        assert!(house_pool_balance(house) >= stake_amount, EPoolNotEnough);
        let payout = coin::take(&mut house.pool, payout_amount, ctx);
        let id = object::new(ctx);
        let game_id = object::uid_to_inner(&id);
        let player = tx_context::sender(ctx);
        let game = Game<T> {
            id,
            player,
            start_epoch: tx_context::epoch(ctx),
            stake,
            payout,
            guess,
            seed,
        };
        dof::add(&mut house.id, game_id, game);
        event::emit(NewGame<T> {
            game_id,
            player,
            guess,
            stake_amount,
        });
        game_id
    }

    public entry fun settle<T>(
        house: &mut House<T>,
        game_id: ID,
        bls_sig: vector<u8>,
    ): bool {
        assert!(game_exists(house, game_id), EGameNotExists);
        let game = dof::remove<ID, Game<T>>(&mut house.id, game_id);
        let Game {
            id,
            player,
            start_epoch: _,
            stake,
            payout,
            guess,
            seed,
        } = game;
        let msg_vec = object::uid_to_bytes(&id);
        vector::append(&mut msg_vec, seed);
        let public_key = house_pub_key(house);
        assert!(
            bls12381_min_pk_verify(
                &bls_sig, &public_key, &msg_vec,
            ),
            EInvalidBlsSig
        );
        object::delete(id);

        let hashed_beacon = blake2b256(&bls_sig);
        let roll_result = roll(&hashed_beacon);
        let player_won = bm::player_won(guess, roll_result);

        let pnl = if (player_won) {
            let payout_amount = coin::value(&payout);
            coin::join(&mut payout, stake);
            transfer::public_transfer(payout, player);
            payout_amount
        } else {
            let stake_amount = coin::value(&stake);
            coin::put(&mut house.pool, stake);
            coin::put(&mut house.pool, payout);
            stake_amount
        };

        event::emit(Outcome<T> {
            game_id,
            player,
            player_won,
            pnl,
            challenged: false,
        });
        player_won
    }

    public entry fun batch_settle<T>(
        house: &mut House<T>,
        game_ids: vector<ID>,
        bls_sigs: vector<vector<u8>>,
    ) {
        assert!(
            vector::length(&game_ids) == vector::length(&bls_sigs),
            EBatchSettleInvalidInputs,
        );
        while(!vector::is_empty(&game_ids)) {
            let game_id = vector::pop_back(&mut game_ids);
            let bls_sig = vector::pop_back(&mut bls_sigs);
            if (game_exists(house, game_id)) {
                settle(house, game_id, bls_sig);
            };
        };
    }

    public entry fun challenge<T>(
        house: &mut House<T>,
        game_id: ID,
        ctx: &mut TxContext,
    ) {
        assert!(game_exists(house, game_id), EGameNotExists);
        let current_epoch = tx_context::epoch(ctx);
        let game = dof::remove<ID, Game<T>>(&mut house.id, game_id);
        let Game {
            id,
            player,
            start_epoch,
            stake,
            payout,
            guess: _,
            seed: _,
        } = game;
        object::delete(id);
        
        // Ensure that minimum epochs have passed before user can cancel
        assert!(current_epoch > start_epoch + CHALLENGE_EPOCH_INTERVAL, ECannotChallenge);
        // Auto-win
        let pnl = coin::value(&payout);
        coin::join(&mut payout, stake);
        transfer::public_transfer(payout, player);
        
        event::emit(Outcome<T> {
            game_id,
            player,
            player_won: true,
            pnl,
            challenged: true,
        });
    }

    // --------------- House Accessors ---------------

    public fun house_pub_key<T>(house: &House<T>): vector<u8> {
        house.pub_key
    }

    public fun house_pool_balance<T>(house: &House<T>): u64 {
        balance::value(&house.pool)
    }

    public fun house_stake_range<T>(house: &House<T>): (u64, u64) {
        (house.min_stake_amount, house.max_stake_amount)
    }

    public fun game_exists<T>(house: &House<T>, game_id: ID): bool {
        dof::exists_with_type<ID, Game<T>>(&house.id, game_id)
    }

    // --------------- Game Accessors ---------------

    public fun borrow_game<T>(house: &House<T>, game_id: ID): &Game<T> {
        dof::borrow<ID, Game<T>>(&house.id, game_id)
    }

    public fun game_start_epoch<T>(game: &Game<T>): u64 {
        game.start_epoch
    }

    public fun game_guess<T>(game: &Game<T>): u8 {
        game.guess
    }

    public fun game_stake_amount<T>(game: &Game<T>): u64 {
        coin::value(&game.stake)
    }

    public fun game_payout_amount<T>(game: &Game<T>): u64 {
        coin::value(&game.payout)
    }

    public fun game_seed<T>(game: &Game<T>): vector<u8> {
        game.seed
    }

    // --------------- Helper Funtions ---------------

    fun roll(hashed_beacon: &vector<u8>): u8 {
        let length = vector::length(hashed_beacon);
        let idx: u64 = 0;
        let sum: u64 = 0;
        while (idx < length) {
            sum = sum + (*vector::borrow(hashed_beacon, idx) as u64);
            idx = idx + 1;
        };
        ((sum % 6) as u8)
    }

    // --------------- Test only ---------------

    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        init(ctx)
    }

    #[test_only]
    public fun settle_for_testing<T>(
        house: &mut House<T>,
        game_id: ID,
        bls_sig: vector<u8>,
    ): (u8, bool) {
        assert!(game_exists(house, game_id), EGameNotExists);
        let game = dof::remove<ID, Game<T>>(&mut house.id, game_id);
        let Game {
            id,
            player,
            start_epoch: _,
            stake,
            payout,
            guess,
            seed: _,
        } = game;
        // let msg_vec = object::uid_to_bytes(&id);
        // vector::append(&mut msg_vec, seed);
        // let public_key = house_pub_key(house);
        // assert!(
        //     bls12381_min_pk_verify(
        //         &bls_sig, &public_key, &msg_vec,
        //     ),
        //     EInvalidBlsSig
        // );
        object::delete(id);

        let hashed_beacon = blake2b256(&bls_sig);
        let roll_result = roll(&hashed_beacon);
        let player_won = bm::player_won(guess, roll_result);

        let pnl = if (player_won) {
            let payout_amount = coin::value(&payout);
            coin::join(&mut payout, stake);
            transfer::public_transfer(payout, player);
            payout_amount
        } else {
            let stake_amount = coin::value(&stake);
            coin::put(&mut house.pool, stake);
            coin::put(&mut house.pool, payout);
            stake_amount
        };

        event::emit(Outcome<T> {
            game_id,
            player,
            player_won,
            pnl,
            challenged: false,
        });
        (roll_result, player_won)
    }
}