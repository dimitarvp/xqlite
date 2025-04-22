use rustler::{Env, Term};

mod atoms;
mod r2d2;

fn on_load(_env: Env, _info: Term) -> bool {
    true
}

rustler::init!("Elixir.XqliteNIF", load = on_load);
