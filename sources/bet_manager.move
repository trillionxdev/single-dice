module dice::bet_manager {

    // Bet types
    const SMALL: u8 = 0;
    const ODD: u8 = 7;
    const EVEN: u8 = 8;
    const BIG: u8 = 9;

    // Errors
    const EInvalidBetType: u64 = 0;

    public fun payout_amount(bet_size: u64, guess: u8): u64 {
        if (guess > BIG) {
            abort EInvalidBetType
        };

        // single number payout 4.9-1        
        if (guess >= 1 && guess <= 6) {
            return (((bet_size as u128) * 49u128 / 10u128) as u64)
        };

        // small/big/even/odd payout 1-1
        bet_size
    }

    public fun player_won(guess: u8, roll_result: u8): bool {
        if (guess == EVEN) {
            roll_result % 2 == 0
        } else if (guess == ODD) {
            roll_result % 2 == 1
        } else if (guess == SMALL) {
            roll_result <= 3
        } else if (guess == BIG) {
            roll_result >= 4
        } else {
            roll_result == guess
        }
    }
}