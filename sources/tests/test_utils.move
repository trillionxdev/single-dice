#[test_only]
module dice_test::test_utils {
    use sui::address as addr;
    use sui::balance;
    use sui::coin::{Self, Coin};
    use sui::tx_context::TxContext;
    use sui::test_random::{Self, Random};
    use sui::test_scenario::{Self as ts, Scenario};
    use dice::single_dice::{Self, AdminCap};

    const DEV: address = @0xde1;

    struct PlayerGenerator has store, drop {
        random: Random,
        min_stake_amount: u64,
        max_stake_amount: u64,
    }

    public fun setup_house<T>(
        init_pool_amount: u64,
        min_stake_amount: u64,
        max_stake_amount: u64,
        payout_rate: u64,
    ): Scenario {
        let scenario_val = ts::begin(dev());
        let scenario = &mut scenario_val;
        {
            single_dice::init_for_testing(ts::ctx(scenario));
        };

        ts::next_tx(scenario, dev());
        {
            let init_pool = balance::create_for_testing<T>(init_pool_amount);
            let init_pool = coin::from_balance(init_pool, ts::ctx(scenario));
            let admin_cap = ts::take_from_sender<AdminCap>(scenario);
            single_dice::create_house(
                &admin_cap,
                b"",
                min_stake_amount,
                max_stake_amount,
                payout_rate,
                init_pool,
                ts::ctx(scenario)
            );
            ts::return_to_sender(scenario, admin_cap);
        };

        scenario_val
    }

    public fun new_player_generator(
        seed: vector<u8>,
        min_stake_amount: u64,
        max_stake_amount: u64,
    ): PlayerGenerator {
        PlayerGenerator {
            random: test_random::new(seed),
            min_stake_amount,
            max_stake_amount,
        }
    }

    public fun gen_player_and_stake<T>(
        generator: &mut PlayerGenerator,
        ctx: &mut TxContext,
    ): (address, Coin<T>) {
        let random = &mut generator.random;
        let player = addr::from_u256(test_random::next_u256(random));
        let stake_amount_diff = generator.max_stake_amount - generator.min_stake_amount;
        let stake = balance::create_for_testing<T>(
            generator.min_stake_amount +
            test_random::next_u64(random) % stake_amount_diff
        );
        let stake = coin::from_balance(stake, ctx);
        (player, stake)
    }

    public fun dev(): address { DEV }
}