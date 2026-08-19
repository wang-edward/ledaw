//! Desktop entry point. Ports `main.zig`'s setup (demo lead + bass tracks), the cpal audio
//! stream, and the raylib loop that renders into a 128x128 texture and blits it scaled to a
//! square in the window. Hardware/OLED path removed.
//!
//! Build/run the full app: `cargo run`

fn main() {
    use std::sync::{Arc, Mutex};

    use raylib::prelude::*;

    use ledaw::audio::AudioBuffer;
    use ledaw::audio_in;
    use ledaw::audio_out;
    use ledaw::engine::{AudioClip, Engine, Track, TrackSource};
    use ledaw::instrument::Instrument;
    use ledaw::instrument::juno::Juno;
    use ledaw::instrument::sampler::Sampler;
    use ledaw::interface::{self, HEIGHT, WIDTH};
    use ledaw::midi::{Note, beats_to_frames};
    use ledaw::ui::{App, Icons};

    // Engine must run at the device sample rate.
    let sr = audio_out::default_output_sample_rate().unwrap_or(48_000.0);
    let tempo = 120.0f32;

    let n = |b0: f32, b1: f32, note: u8| Note {
        start: beats_to_frames(b0, tempo, sr),
        end: beats_to_frames(b1, tempo, sr),
        note,
    };

    // Demo melody + bass (from main.zig).
    let lead = [
        n(0.0, 0.9, 60),
        n(1.0, 1.9, 60),
        n(2.0, 2.9, 67),
        n(3.0, 3.9, 67),
        n(4.0, 4.9, 69),
        n(5.0, 5.9, 69),
        n(6.0, 7.9, 67),
        n(8.0, 8.9, 65),
        n(9.0, 9.9, 65),
        n(10.0, 10.9, 64),
        n(11.0, 11.9, 64),
        n(12.0, 12.9, 62),
        n(13.0, 13.9, 62),
        n(14.0, 15.9, 60),
    ];
    let bass = [
        n(0.0, 2.0, 48),
        n(2.0, 4.0, 48),
        n(4.0, 6.0, 43),
        n(6.0, 8.0, 43),
        n(8.0, 10.0, 41),
        n(10.0, 12.0, 40),
        n(12.0, 14.0, 38),
        n(14.0, 16.0, 36),
    ];

    let mut engine = Engine::new(sr, tempo);
    engine.add_track(Track::new(TrackSource::Instrument {
        instrument: Instrument::Sampler(Sampler::default()),
        notes: lead.to_vec(),
    }));
    engine.add_track(Track::new(TrackSource::Instrument {
        instrument: Instrument::Juno(Juno::default()),
        notes: bass.to_vec(),
    }));

    let audio = AudioBuffer::decode_wav(include_bytes!("../assets/samples/pierre.wav"));
    let audio2 = AudioBuffer::decode_wav(include_bytes!("../assets/samples/perfect.wav"));
    engine.add_track(Track::new(TrackSource::Audio {
        clips: vec![
            AudioClip::new(0, audio),
            AudioClip::new(beats_to_frames(7.0, tempo, sr), audio2),
        ],
    }));
    let engine = Arc::new(Mutex::new(engine));

    // Audio stream (held until the end of main).
    let _audio = audio_out::start(engine.clone()).expect("failed to start audio");
    let _audio_in = match audio_in::start(engine.clone()) {
        Ok(audio_in) => Some(audio_in),
        Err(error) => {
            eprintln!("audio input unavailable: {error}");
            None
        }
    };

    // Window + 128x128 render target.
    let (mut rl, thread) = raylib::init().size(512, 512).title("LeDaw").build();
    rl.set_target_fps(60);
    rl.set_exit_key(None); // ESC shouldn't close

    let mut target = rl
        .load_render_texture(&thread, WIDTH as u32, HEIGHT as u32)
        .expect("render texture");

    let icons = Icons::load(&mut rl, &thread);
    let mut app = App::new(engine.clone(), icons);

    while !rl.window_should_close() {
        for ev in interface::poll_events(&rl) {
            app.handle_event(ev);
        }

        let screen_w = rl.get_screen_width();
        let screen_h = rl.get_screen_height();
        let side = screen_w.min(screen_h);
        let pos_x = (screen_w - side) as f32 / 2.0;
        let pos_y = (screen_h - side) as f32 / 2.0;

        let mut d = rl.begin_drawing(&thread);
        d.clear_background(Color::BLACK);

        // draw the app into the 128x128 texture
        {
            let mut td = d.begin_texture_mode(&thread, &mut target);
            td.clear_background(Color::BLACK);
            app.render(&mut td);
        }

        // blit the texture, scaled to a centered square (Y flipped, like the Zig version)
        let src = Rectangle::new(
            0.0,
            0.0,
            target.texture().width as f32,
            -(target.texture().height as f32),
        );
        let dest = Rectangle::new(pos_x, pos_y, side as f32, side as f32);
        d.draw_texture_pro(
            target.texture(),
            src,
            dest,
            Vector2::zero(),
            0.0,
            Color::WHITE,
        );
    }
}
