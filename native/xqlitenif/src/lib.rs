use rustler::{Env, Term};

mod atoms;
mod close;
mod exec;
mod open;
mod pragma_get;
mod pragma_put;
mod shared;

use crate::shared::XqliteConnection;

fn on_load(env: Env, _info: Term) -> bool {
    rustler::resource!(XqliteConnection, env);
    true
}

rustler::init!(
    "Elixir.XqliteNIF",
    [
        open::open,
        close::close,
        exec::exec,
        pragma_get::pragma_get0,
        pragma_get::pragma_get1,
        pragma_put::pragma_put
    ],
    load = on_load
);
