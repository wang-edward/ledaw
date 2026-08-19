use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

use raylib::prelude::*;

use ledaw::engine::{Engine, Track, TrackSource};
use ledaw::input::{Event, EventType, POLL_KEYS};
use ledaw::instrument::Instrument;
use ledaw::instrument::sampler::Sampler;
use ledaw::interface::{HEIGHT, WIDTH};
use ledaw::midi::beats_to_frames;
use ledaw::ui::{App, Icons};

/// SplitMix64. No `rand` dependency, seedable for reproducible runs.
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }
    fn below(&mut self, n: u64) -> u64 {
        self.next() % n
    }
    fn coin(&mut self) -> bool {
        self.next() & 1 == 1
    }
}

fn main() {
    let sr = 48_000.0;
    let tempo = 120.0f32;

    let mut engine = Engine::new(sr, tempo);
    engine.add_track(Track::new(TrackSource::Instrument {
        instrument: Instrument::Sampler(Sampler::default()),
        notes: Vec::new(),
    }));
    let engine = Arc::new(Mutex::new(engine));

    let (mut rl, thread) = raylib::init().size(512, 512).title("LeDaw fuzz").build();
    rl.set_exit_key(None);

    let mut target = rl
        .load_render_texture(&thread, WIDTH as u32, HEIGHT as u32)
        .expect("render texture");
    let icons = Icons::load(&mut rl, &thread);
    let mut app = App::new(engine.clone(), icons);

    let seed = std::env::args()
        .nth(1)
        .map(|seed| seed.parse().expect("fuzz seed must be a u64"))
        .unwrap_or_else(|| {
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos() as u64
        });
    let mut rng = Rng(seed);

    const NUM_EVENTS: usize = 100_000;
    println!("fuzz: seed={seed}, sending {NUM_EVENTS} random events...");

    for _ in 0..NUM_EVENTS {
        let key = POLL_KEYS[rng.below(POLL_KEYS.len() as u64) as usize];
        let ev = Event {
            ty: if rng.coin() {
                EventType::KeyPress
            } else {
                EventType::KeyRelease
            },
            key,
        };
        app.handle_event(ev);

        // occasionally skip playhead forward (0.1–1.0 beats)
        if rng.below(100) == 0 {
            let duration = 0.1 + rng.below(10) as f32 * 0.1;
            let frames = beats_to_frames(duration, tempo, sr);
            let mut e = engine.lock().unwrap();
            let pos = e.timeline.playhead + frames;
            e.set_playhead(pos);
        }

        // draw UI into the offscreen target (texture mode directly on rl,
        // skipping begin_drawing/end_drawing so we don't get fps-capped)
        {
            let mut td = rl.begin_texture_mode(&thread, &mut target);
            td.clear_background(Color::BLACK);
            app.render(&mut td);
        }
    }

    println!("fuzz: completed {NUM_EVENTS} events without crash");
}
