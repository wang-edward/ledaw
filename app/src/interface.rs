//! Desktop interface helpers (raylib). The hardware/OLED path from `interface.zig` is
//! dropped; only the desktop render path remains (render to a 128x128 texture, then blit
//! scaled to the window — done in `main.rs`).
//!
//! Feature-gated behind `ui`; needs the `raylib` crate + system GL/X11 libs. Not built or
//! verified in the core workspace.

use raylib::prelude::*;

use crate::input::{Event, EventType, Key, POLL_KEYS};

pub const WIDTH: i32 = 128;
pub const HEIGHT: i32 = 128;

/// Map our raylib-free `Key` onto raylib's `KeyboardKey` for polling.
pub fn rl_key(k: Key) -> KeyboardKey {
    use Key::*;
    use raylib::consts::KeyboardKey::*;
    match k {
        A => KEY_A,
        B => KEY_B,
        C => KEY_C,
        D => KEY_D,
        E => KEY_E,
        F => KEY_F,
        G => KEY_G,
        H => KEY_H,
        I => KEY_I,
        J => KEY_J,
        K => KEY_K,
        L => KEY_L,
        M => KEY_M,
        N => KEY_N,
        O => KEY_O,
        P => KEY_P,
        Q => KEY_Q,
        R => KEY_R,
        S => KEY_S,
        T => KEY_T,
        U => KEY_U,
        V => KEY_V,
        W => KEY_W,
        X => KEY_X,
        Y => KEY_Y,
        Z => KEY_Z,
        Zero => KEY_ZERO,
        One => KEY_ONE,
        Two => KEY_TWO,
        Three => KEY_THREE,
        Four => KEY_FOUR,
        Five => KEY_FIVE,
        Six => KEY_SIX,
        Seven => KEY_SEVEN,
        Eight => KEY_EIGHT,
        Nine => KEY_NINE,
        Escape => KEY_ESCAPE,
        Grave => KEY_GRAVE,
        Minus => KEY_MINUS,
        Equal => KEY_EQUAL,
        Backspace => KEY_BACKSPACE,
        Tab => KEY_TAB,
        CapsLock => KEY_CAPS_LOCK,
        LeftShift => KEY_LEFT_SHIFT,
        RightShift => KEY_RIGHT_SHIFT,
        LeftControl => KEY_LEFT_CONTROL,
        RightControl => KEY_RIGHT_CONTROL,
        LeftAlt => KEY_LEFT_ALT,
        RightAlt => KEY_RIGHT_ALT,
        LeftSuper => KEY_LEFT_SUPER,
        RightSuper => KEY_RIGHT_SUPER,
        LeftBracket => KEY_LEFT_BRACKET,
        RightBracket => KEY_RIGHT_BRACKET,
        Backslash => KEY_BACKSLASH,
        Semicolon => KEY_SEMICOLON,
        Apostrophe => KEY_APOSTROPHE,
        Enter => KEY_ENTER,
        Comma => KEY_COMMA,
        Period => KEY_PERIOD,
        Slash => KEY_SLASH,
        Space => KEY_SPACE,
        Up => KEY_UP,
        Down => KEY_DOWN,
        Left => KEY_LEFT,
        Right => KEY_RIGHT,
        Delete => KEY_DELETE,
    }
}

/// Collect this frame's key presses then releases (mirrors `interface.nextEvent`'s order).
pub fn poll_events(rl: &RaylibHandle) -> Vec<Event> {
    use raylib::consts::KeyboardKey::*;
    let mut out = Vec::new();
    for &k in POLL_KEYS.iter() {
        if rl.is_key_pressed(rl_key(k)) {
            out.push(Event {
                ty: EventType::KeyPress,
                key: k,
                shift: rl.is_key_down(KEY_LEFT_SHIFT),
                meta: rl.is_key_down(KEY_LEFT_SUPER),
            });
        }
    }
    for &k in POLL_KEYS.iter() {
        if rl.is_key_released(rl_key(k)) {
            out.push(Event {
                ty: EventType::KeyRelease,
                key: k,
                shift: rl.is_key_down(KEY_LEFT_SHIFT),
                meta: rl.is_key_down(KEY_LEFT_SUPER),
            });
        }
    }
    out
}
pub fn measure_text(text: &str, font_size: i32) -> i32 {
    let c = std::ffi::CString::new(text).unwrap_or_default();
    unsafe { raylib::ffi::MeasureText(c.as_ptr(), font_size) }
}

pub fn draw_text_centered<D: RaylibDraw>(
    d: &mut D,
    text: &str,
    cx: i32,
    cy: i32,
    size: i32,
    color: Color,
) {
    let w = measure_text(text, size);
    d.draw_text(text, cx - w / 2, cy - size / 2, size, color);
}
