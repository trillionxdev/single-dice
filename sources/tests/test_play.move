#[test_only]
module dice_test::test_play {
    
    use std::vector;
    use sui::coin::{Self, Coin};
    use sui::address as addr;
    use sui::sui::SUI;
    use sui::test_scenario as ts;
    use dice::single_dice::{Self, House};
    use dice_test::test_utils as tu;

    #[test]
    fun test_play_using_sui() {
        let min_stake_amount: u64 = 1_000_000_000; // 1 SUI
        let max_stake_amount: u64 = 50_000_000_000; // 50 SUI
        let init_pool_amount: u64 = 100 * max_stake_amount;
        let player_count: u64 = 8_000;
        let payout_rate: u64 = 4_500;
        let roll_result_vec = vector<u64>[0, 0, 0, 0, 0, 0];

        let scenario_val = tu::setup_house<SUI>(
            init_pool_amount,
            min_stake_amount,
            max_stake_amount,
            payout_rate,
        );
        let scenario = &mut scenario_val;
        let player_generator = tu::new_player_generator(
            b"SingleDice x Suilette",
            min_stake_amount,
            max_stake_amount,
        );

        // players start games and dev settle them
        let idx: u64 = 0;
        while(idx < player_count) {
            let (player, stake) = tu::gen_player_and_stake<SUI>(
                &mut player_generator,
                ts::ctx(scenario)
            );
            let stake_amount = coin::value(&stake);
            let seed = addr::to_bytes(player);
            // start a game
            ts::next_tx(scenario, player);
            let (game_id, pool_balance) = {
                let house = ts::take_shared<House<SUI>>(scenario);
                let pool_balance = single_dice::house_pool_balance(&house);
                let guess = ((idx % 10) as u8);
                let game_id = single_dice::start_game(&mut house, guess, seed, stake, ts::ctx(scenario));
                ts::return_shared(house);
                (game_id, pool_balance)
            };

            // settle
            ts::next_tx(scenario, tu::dev());
            let (player_won, payout_amount) = {
                let house = ts::take_shared<House<SUI>>(scenario);
                assert!(single_dice::game_exists(&house, game_id), 0);
                let game = single_dice::borrow_game(&house, game_id);
                let payout_amount = single_dice::game_payout_amount(game);
                assert!(single_dice::game_guess(game) == ((idx % 10) as u8), 0);
                assert!(single_dice::game_seed(game) == addr::to_bytes(player), 0);
                assert!(single_dice::game_stake_amount(game) == stake_amount, 0);
                assert!(single_dice::house_pool_balance(&house) == pool_balance - payout_amount, 0);
                let bls_sig = addr::to_bytes(addr::from_u256(addr::to_u256(player) - (idx as u256)));
                let (roll_result, player_won) = single_dice::settle_for_testing(&mut house, game_id, bls_sig);
                let roll_count = vector::borrow_mut(&mut roll_result_vec, ((roll_result - 1) as u64));
                *roll_count = *roll_count + 1;
                ts::return_shared(house);
                (player_won, payout_amount)
            };

            // check after settlement
            ts::next_tx(scenario, tu::dev());
            {
                let house = ts::take_shared<House<SUI>>(scenario);
                assert!(!single_dice::game_exists(&house, game_id), 0);
                let pool_balance_after = single_dice::house_pool_balance(&house);
                if (player_won) {
                    assert!(pool_balance_after == pool_balance - payout_amount, 0);
                } else {
                    assert!(pool_balance_after == pool_balance + stake_amount, 0);
                };
                std::debug::print(&single_dice::house_pool_balance(&house));
                ts::return_shared(house);
                let coin_id = ts::most_recent_id_for_address<Coin<SUI>>(player);
                if (std::option::is_some(&coin_id)) {
                    let coin_id = std::option::destroy_some(coin_id);
                    let reward = ts::take_from_address_by_id<Coin<SUI>>(scenario, player, coin_id);
                    assert!(coin::value(&reward) == stake_amount + payout_amount, 0);
                    ts::return_to_address(player, reward);
                };
            };
            idx = idx + 1;
        };

        std::debug::print(&roll_result_vec);

        ts::end(scenario_val);
    }
}