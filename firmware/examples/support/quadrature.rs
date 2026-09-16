// Positive sequence: 00 -> 01 -> 11 -> 10 -> 00. Physical CW depends on wiring.
pub fn quadrature_delta(previous: u8, next: u8) -> i32 {
    const DELTA: [i32; 16] = [0, 1, -1, 0, -1, 0, 0, 1, 1, 0, 0, -1, 0, -1, 1, 0];
    DELTA[usize::from((previous << 2) | next)]
}

#[cfg(test)]
mod tests {
    use super::*;

    fn movement(states: &[u8]) -> i32 {
        states
            .windows(2)
            .map(|s| quadrature_delta(s[0], s[1]))
            .sum()
    }

    #[test]
    fn directions_and_contact_bounce() {
        assert_eq!(movement(&[0, 1, 3, 2, 0]), 4);
        assert_eq!(movement(&[0, 2, 3, 1, 0]), -4);
        assert_eq!(movement(&[0, 1, 0, 1, 3, 2, 0]), 4);
    }

    #[test]
    fn stationary_and_skipped_states_do_not_count() {
        for state in 0..4 {
            assert_eq!(quadrature_delta(state, state), 0);
            assert_eq!(quadrature_delta(state, state ^ 3), 0);
        }
    }
}
