use crate::atoms;
use crate::error::XqliteError;
use crate::stream::{bind_named_params_ffi, bind_positional_params_ffi};
use crate::util::{decode_exec_keyword_params, decode_plain_list_params, is_keyword};
use rusqlite::Connection;
use rusqlite::ffi;
use rusqlite::types::Value;
use rustler::types::atom::nil;
use rustler::{Encoder, Env, Term, TermType, types::map::map_new};
use std::ffi::CStr;
use std::os::raw::c_int;
use std::time::Instant;

/// Result of running an EXPLAIN ANALYZE on a SQL statement.
pub struct ExplainAnalyze {
    pub wall_time_ns: u64,
    pub rows_produced: u64,
    pub stmt_counters: StmtCounters,
    pub scans: Vec<ScanStatus>,
    pub query_plan: Vec<QueryPlanRow>,
}

/// Statement-level counters from `sqlite3_stmt_status`. Applies to the whole
/// prepared statement regardless of how many scans it contains.
pub struct StmtCounters {
    pub fullscan_step: i64,
    pub sort: i64,
    pub autoindex: i64,
    pub vm_step: i64,
    pub reprepare: i64,
    pub run: i64,
    pub filter_miss: i64,
    pub filter_hit: i64,
    pub memused_bytes: i64,
}

/// One scan entry from `sqlite3_stmt_scanstatus_v2`. Each entry describes a
/// loop in the query plan (table/index scan, subquery, etc).
pub struct ScanStatus {
    pub loops: i64,
    pub rows_visited: i64,
    pub estimated_rows: f64,
    pub name: String,
    pub explain: String,
    pub selectid: i32,
    pub parentid: i32,
}

/// One row from `EXPLAIN QUERY PLAN <sql>`. Captures SQLite's static analysis
/// tree; combined with `scans`, you get the runtime shape of the query.
pub struct QueryPlanRow {
    pub id: i32,
    pub parent: i32,
    pub detail: String,
}

pub fn core_explain_analyze<'a>(
    env: Env<'a>,
    conn: &Connection,
    sql: &str,
    params_term: Term<'a>,
) -> Result<ExplainAnalyze, XqliteError> {
    // SAFETY: `with_conn` at the NIF boundary holds the connection Mutex for
    // the duration of this call. Every `sqlite3_*` FFI below operates on a
    // db_handle and stmt_ptr that belong to this connection; the lock ensures
    // no concurrent BEAM thread can step the same connection.
    unsafe {
        let db_handle = conn.handle();
        let stmt_ptr = crate::statement::prepare_one(db_handle, sql)?;

        let result = match collect_query_plan(stmt_ptr.as_ptr(), db_handle) {
            Ok(query_plan) => {
                reset_stmt_counters(stmt_ptr.as_ptr());
                run_and_collect(env, stmt_ptr.as_ptr(), db_handle, params_term, query_plan)
            }
            Err(e) => Err(e),
        };

        ffi::sqlite3_finalize(stmt_ptr.as_ptr());

        result
    }
}

/// # Safety
/// `stmt_ptr` must be non-null and point to a prepared statement on `db_handle`.
/// The connection Mutex must be held for the duration of this call.
unsafe fn run_and_collect<'a>(
    env: Env<'a>,
    stmt_ptr: *mut ffi::sqlite3_stmt,
    db_handle: *mut ffi::sqlite3,
    params_term: Term<'a>,
    query_plan: Vec<QueryPlanRow>,
) -> Result<ExplainAnalyze, XqliteError> {
    bind_params(env, stmt_ptr, db_handle, params_term)?;

    let start = Instant::now();
    let mut rows_produced: u64 = 0;

    loop {
        // SAFETY: per this fn's contract, `stmt_ptr` is a live prepared statement
        // stepped with the connection Mutex held.
        let rc = unsafe { ffi::sqlite3_step(stmt_ptr) };
        match rc {
            ffi::SQLITE_ROW => rows_produced += 1,
            ffi::SQLITE_DONE => break,
            // SAFETY: `db_handle` is valid and the Mutex is held (fn contract).
            _ => return Err(unsafe { ffi_error(db_handle, rc) }),
        }
    }

    let wall_time_ns = start.elapsed().as_nanos() as u64;
    // SAFETY: `stmt_ptr` is live and the Mutex is held (fn contract).
    let stmt_counters = unsafe { collect_stmt_counters(stmt_ptr) };
    // SAFETY: `stmt_ptr` is live and the Mutex is held (fn contract).
    let scans = unsafe { collect_scan_status(stmt_ptr) };

    Ok(ExplainAnalyze {
        wall_time_ns,
        rows_produced,
        stmt_counters,
        scans,
        query_plan,
    })
}

fn bind_params<'a>(
    env: Env<'a>,
    stmt_ptr: *mut ffi::sqlite3_stmt,
    db_handle: *mut ffi::sqlite3,
    params_term: Term<'a>,
) -> Result<(), XqliteError> {
    match params_term.get_type() {
        TermType::List if params_term.is_empty_list() => Ok(()),
        TermType::List if is_keyword(params_term) => {
            let named_params_vec = decode_exec_keyword_params(env, params_term)?;
            bind_named_params_ffi(stmt_ptr, &named_params_vec, db_handle)
        }
        TermType::List => {
            let positional_values: Vec<Value> = decode_plain_list_params(env, params_term)?;
            bind_positional_params_ffi(stmt_ptr, &positional_values, db_handle)
        }
        _ if params_term == nil().to_term(env) => Ok(()),
        _ => Err(XqliteError::ExpectedList {
            value_str: format!("{params_term:?}"),
        }),
    }
}

// EXPLAIN QUERY PLAN is documented to return (id, parent, notused, detail).
const QUERY_PLAN_COLUMNS: c_int = 4;

/// Reads the query plan out of the statement that will run for real, rather
/// than out of a second statement compiled from prefixed SQL — a prefix
/// turns SQL that legitimately starts with a semicolon or a comment into a
/// syntax error, while every other entry point accepts it.
///
/// `sqlite3_stmt_explain` makes the statement behave as if its text began
/// with EXPLAIN QUERY PLAN, and the plan rows are then stepped like any
/// other rows. The order of the two restoring calls is not interchangeable:
/// the mode of a statement that has begun running cannot be changed, so
/// switching back before the reset fails with SQLITE_BUSY every time.
///
/// # Safety
/// `stmt_ptr` must be a live prepared statement belonging to `db_handle`,
/// and the connection Mutex must be held for the whole call.
unsafe fn collect_query_plan(
    stmt_ptr: *mut ffi::sqlite3_stmt,
    db_handle: *mut ffi::sqlite3,
) -> Result<Vec<QueryPlanRow>, XqliteError> {
    // SAFETY: `stmt_ptr` is live and the Mutex is held (fn contract).
    let explain_rc = unsafe { ffi::sqlite3_stmt_explain(stmt_ptr, 2) };
    if explain_rc != ffi::SQLITE_OK {
        // SAFETY: `db_handle` is valid and the Mutex is held (fn contract).
        return Err(unsafe { ffi_error(db_handle, explain_rc) });
    }

    // SAFETY: the statement is now in EXPLAIN QUERY PLAN mode; the Mutex is held.
    let plan = unsafe { step_query_plan(stmt_ptr, db_handle) };

    // SAFETY: `stmt_ptr` is live and the Mutex is held (fn contract).
    unsafe { ffi::sqlite3_reset(stmt_ptr) };
    // SAFETY: as above, and the reset above makes the mode changeable again.
    let restore_rc = unsafe { ffi::sqlite3_stmt_explain(stmt_ptr, 0) };

    match (plan, restore_rc) {
        (Ok(rows), ffi::SQLITE_OK) => Ok(rows),
        // SAFETY: `db_handle` is valid and the Mutex is held (fn contract).
        (Ok(_), rc) => Err(unsafe { ffi_error(db_handle, rc) }),
        (Err(e), _) => Err(e),
    }
}

/// # Safety
/// `stmt_ptr` must be a live statement in EXPLAIN QUERY PLAN mode that has
/// not been stepped yet, and the connection Mutex must be held.
unsafe fn step_query_plan(
    stmt_ptr: *mut ffi::sqlite3_stmt,
    db_handle: *mut ffi::sqlite3,
) -> Result<Vec<QueryPlanRow>, XqliteError> {
    // SAFETY: `stmt_ptr` is live and the Mutex is held (fn contract).
    let col_count = unsafe { ffi::sqlite3_column_count(stmt_ptr) };
    if col_count != QUERY_PLAN_COLUMNS {
        return Err(XqliteError::CannotExecute(format!(
            "EXPLAIN QUERY PLAN returned {col_count} columns; expected 4"
        )));
    }

    let mut out = Vec::new();

    loop {
        // SAFETY: `stmt_ptr` is live and the Mutex is held (fn contract).
        let rc = unsafe { ffi::sqlite3_step(stmt_ptr) };
        match rc {
            // SAFETY: the statement sits on a row of the four columns
            // checked above, under the held Mutex.
            ffi::SQLITE_ROW => out.push(unsafe { plan_row(stmt_ptr) }),
            ffi::SQLITE_DONE => break,
            // SAFETY: `db_handle` is valid and the Mutex is held (fn contract).
            _ => return Err(unsafe { ffi_error(db_handle, rc) }),
        }
    }

    Ok(out)
}

/// # Safety
/// `stmt_ptr` must sit on an EXPLAIN QUERY PLAN row of four columns, with
/// the connection Mutex held.
unsafe fn plan_row(stmt_ptr: *mut ffi::sqlite3_stmt) -> QueryPlanRow {
    // SAFETY: column 0 is inside the checked column count (fn contract).
    let id = unsafe { ffi::sqlite3_column_int(stmt_ptr, 0) };
    // SAFETY: column 1, as above.
    let parent = unsafe { ffi::sqlite3_column_int(stmt_ptr, 1) };
    // SAFETY: column 3, as above; the returned pointer is SQLite-owned and
    // stays valid until the next step on this statement.
    let detail_ptr = unsafe { ffi::sqlite3_column_text(stmt_ptr, 3) };
    // SAFETY: `detail_ptr` is null or a NUL-terminated SQLite string, valid
    // for the duration of the copy.
    let detail = unsafe { cstr_to_string(detail_ptr.cast()) };

    QueryPlanRow { id, parent, detail }
}

const STMT_STATUS_OPS: [c_int; 9] = [
    ffi::SQLITE_STMTSTATUS_FULLSCAN_STEP,
    ffi::SQLITE_STMTSTATUS_SORT,
    ffi::SQLITE_STMTSTATUS_AUTOINDEX,
    ffi::SQLITE_STMTSTATUS_VM_STEP,
    ffi::SQLITE_STMTSTATUS_REPREPARE,
    ffi::SQLITE_STMTSTATUS_RUN,
    ffi::SQLITE_STMTSTATUS_FILTER_MISS,
    ffi::SQLITE_STMTSTATUS_FILTER_HIT,
    ffi::SQLITE_STMTSTATUS_MEMUSED,
];

/// Zeroes every counter the report carries, so it describes the statement's
/// real run alone: switching into EXPLAIN QUERY PLAN mode and back
/// re-prepares the statement and steps the plan, which would otherwise show
/// up as a reprepare and as VM steps nobody asked for.
///
/// # Safety
/// `stmt_ptr` must be valid and the connection Mutex must be held.
unsafe fn reset_stmt_counters(stmt_ptr: *mut ffi::sqlite3_stmt) {
    for op in STMT_STATUS_OPS {
        // SAFETY: `stmt_ptr` is valid and the Mutex is held (fn contract);
        // the reset flag reads the counter and sets it to zero.
        unsafe { ffi::sqlite3_stmt_status(stmt_ptr, op, 1) };
    }
}

/// # Safety
/// `stmt_ptr` must be valid and the connection Mutex must be held.
unsafe fn collect_stmt_counters(stmt_ptr: *mut ffi::sqlite3_stmt) -> StmtCounters {
    let get = |op: i32| -> i64 {
        // SAFETY: `stmt_ptr` is valid and the Mutex is held (fn contract).
        unsafe { ffi::sqlite3_stmt_status(stmt_ptr, op, 0) as i64 }
    };

    StmtCounters {
        fullscan_step: get(ffi::SQLITE_STMTSTATUS_FULLSCAN_STEP),
        sort: get(ffi::SQLITE_STMTSTATUS_SORT),
        autoindex: get(ffi::SQLITE_STMTSTATUS_AUTOINDEX),
        vm_step: get(ffi::SQLITE_STMTSTATUS_VM_STEP),
        reprepare: get(ffi::SQLITE_STMTSTATUS_REPREPARE),
        run: get(ffi::SQLITE_STMTSTATUS_RUN),
        filter_miss: get(ffi::SQLITE_STMTSTATUS_FILTER_MISS),
        filter_hit: get(ffi::SQLITE_STMTSTATUS_FILTER_HIT),
        memused_bytes: get(ffi::SQLITE_STMTSTATUS_MEMUSED),
    }
}

/// # Safety
/// `stmt_ptr` must be valid and the connection Mutex must be held. The returned
/// `String`s are copied out of SQLite-owned memory before any use that could
/// invalidate it.
unsafe fn collect_scan_status(stmt_ptr: *mut ffi::sqlite3_stmt) -> Vec<ScanStatus> {
    let mut scans = Vec::new();
    let mut idx: c_int = 0;

    loop {
        let mut nloop: i64 = 0;
        // SAFETY: `stmt_ptr` is valid and the Mutex is held (fn contract); the
        // out-param is a stack local written by SQLite.
        let rc = unsafe {
            ffi::sqlite3_stmt_scanstatus_v2(
                stmt_ptr,
                idx,
                ffi::SQLITE_SCANSTAT_NLOOP,
                ffi::SQLITE_SCANSTAT_COMPLEX,
                &mut nloop as *mut i64 as *mut std::os::raw::c_void,
            )
        };
        if rc != 0 {
            break;
        }

        let mut nvisit: i64 = 0;
        let mut est: f64 = 0.0;
        let mut name_ptr: *const std::os::raw::c_char = std::ptr::null();
        let mut explain_ptr: *const std::os::raw::c_char = std::ptr::null();
        let mut selectid: c_int = 0;
        let mut parentid: c_int = 0;

        // SAFETY: `stmt_ptr` is valid and the Mutex is held (fn contract). Each
        // out-param is a stack local; `name_ptr`/`explain_ptr` receive
        // SQLite-owned pointers valid while the statement lives under the lock.
        unsafe {
            ffi::sqlite3_stmt_scanstatus_v2(
                stmt_ptr,
                idx,
                ffi::SQLITE_SCANSTAT_NVISIT,
                ffi::SQLITE_SCANSTAT_COMPLEX,
                &mut nvisit as *mut i64 as *mut std::os::raw::c_void,
            );
            ffi::sqlite3_stmt_scanstatus_v2(
                stmt_ptr,
                idx,
                ffi::SQLITE_SCANSTAT_EST,
                ffi::SQLITE_SCANSTAT_COMPLEX,
                &mut est as *mut f64 as *mut std::os::raw::c_void,
            );
            ffi::sqlite3_stmt_scanstatus_v2(
                stmt_ptr,
                idx,
                ffi::SQLITE_SCANSTAT_NAME,
                ffi::SQLITE_SCANSTAT_COMPLEX,
                &mut name_ptr as *mut *const std::os::raw::c_char as *mut std::os::raw::c_void,
            );
            ffi::sqlite3_stmt_scanstatus_v2(
                stmt_ptr,
                idx,
                ffi::SQLITE_SCANSTAT_EXPLAIN,
                ffi::SQLITE_SCANSTAT_COMPLEX,
                &mut explain_ptr as *mut *const std::os::raw::c_char
                    as *mut std::os::raw::c_void,
            );
            ffi::sqlite3_stmt_scanstatus_v2(
                stmt_ptr,
                idx,
                ffi::SQLITE_SCANSTAT_SELECTID,
                ffi::SQLITE_SCANSTAT_COMPLEX,
                &mut selectid as *mut c_int as *mut std::os::raw::c_void,
            );
            ffi::sqlite3_stmt_scanstatus_v2(
                stmt_ptr,
                idx,
                ffi::SQLITE_SCANSTAT_PARENTID,
                ffi::SQLITE_SCANSTAT_COMPLEX,
                &mut parentid as *mut c_int as *mut std::os::raw::c_void,
            );
        }

        // SAFETY: `name_ptr` is null or a SQLite-owned NUL-terminated string,
        // valid while the statement lives under the held Mutex.
        let name = unsafe { cstr_to_string(name_ptr) };
        // SAFETY: as above, for `explain_ptr`.
        let explain = unsafe { cstr_to_string(explain_ptr) };

        scans.push(ScanStatus {
            loops: nloop,
            rows_visited: nvisit,
            estimated_rows: est,
            name,
            explain,
            selectid,
            parentid,
        });

        idx += 1;
    }

    scans
}

/// # Safety
/// `ptr` must be either null or point to a valid NUL-terminated C string whose
/// memory is valid for the duration of the copy.
unsafe fn cstr_to_string(ptr: *const std::os::raw::c_char) -> String {
    if ptr.is_null() {
        String::new()
    } else {
        // SAFETY: `ptr` is non-null here and, per this fn's contract, points to a
        // valid NUL-terminated C string live for the copy.
        unsafe { CStr::from_ptr(ptr) }
            .to_string_lossy()
            .into_owned()
    }
}

/// # Safety
/// `db_handle` must point to a valid sqlite3 connection and the caller must
/// hold its Mutex.
unsafe fn ffi_error(db_handle: *mut ffi::sqlite3, code: c_int) -> XqliteError {
    let message = {
        // SAFETY: `db_handle` is valid and the Mutex is held (fn contract).
        let err_msg_ptr = unsafe { ffi::sqlite3_errmsg(db_handle) };
        if err_msg_ptr.is_null() {
            format!("SQLite error (code {code}) but no message available")
        } else {
            // SAFETY: `err_msg_ptr` is non-null here and points to SQLite's
            // NUL-terminated error string, valid while the Mutex is held.
            unsafe { CStr::from_ptr(err_msg_ptr) }
                .to_string_lossy()
                .into_owned()
        }
    };
    let ffi_err = ffi::Error::new(code);
    let rusqlite_err = rusqlite::Error::SqliteFailure(ffi_err, Some(message));
    XqliteError::from(rusqlite_err)
}

/// Finalizes a chained `map_put` build. A map-build failure is practically
/// unreachable (the receiver is always a map), but degrade it to a structured
/// `InternalEncodingError` term instead of panicking — matching the crate's
/// graceful `ok_or_else`/`map_err` convention rather than `unwrap`.
#[inline]
fn map_or_encoding_error<'b>(
    env: Env<'b>,
    built: rustler::NifResult<Term<'b>>,
    context: &str,
) -> Term<'b> {
    built.unwrap_or_else(|_| {
        XqliteError::InternalEncodingError {
            context: context.to_string(),
        }
        .encode(env)
    })
}

impl Encoder for ExplainAnalyze {
    fn encode<'b>(&self, env: Env<'b>) -> Term<'b> {
        let scans_terms: Vec<Term> = self.scans.iter().map(|s| s.encode(env)).collect();
        let plan_terms: Vec<Term> = self.query_plan.iter().map(|r| r.encode(env)).collect();

        let built = map_new(env)
            .map_put(
                atoms::wall_time_ns().encode(env),
                self.wall_time_ns.encode(env),
            )
            .and_then(|m| {
                m.map_put(
                    atoms::rows_produced().encode(env),
                    self.rows_produced.encode(env),
                )
            })
            .and_then(|m| {
                m.map_put(
                    atoms::stmt_counters().encode(env),
                    self.stmt_counters.encode(env),
                )
            })
            .and_then(|m| m.map_put(atoms::scans().encode(env), scans_terms.encode(env)))
            .and_then(|m| m.map_put(atoms::query_plan().encode(env), plan_terms.encode(env)));

        map_or_encoding_error(env, built, "explain_analyze result")
    }
}

impl Encoder for StmtCounters {
    fn encode<'b>(&self, env: Env<'b>) -> Term<'b> {
        let built = map_new(env)
            .map_put(
                atoms::fullscan_step().encode(env),
                self.fullscan_step.encode(env),
            )
            .and_then(|m| m.map_put(atoms::sort().encode(env), self.sort.encode(env)))
            .and_then(|m| {
                m.map_put(atoms::autoindex().encode(env), self.autoindex.encode(env))
            })
            .and_then(|m| m.map_put(atoms::vm_step().encode(env), self.vm_step.encode(env)))
            .and_then(|m| {
                m.map_put(atoms::reprepare().encode(env), self.reprepare.encode(env))
            })
            .and_then(|m| m.map_put(atoms::run().encode(env), self.run.encode(env)))
            .and_then(|m| {
                m.map_put(
                    atoms::filter_miss().encode(env),
                    self.filter_miss.encode(env),
                )
            })
            .and_then(|m| {
                m.map_put(atoms::filter_hit().encode(env), self.filter_hit.encode(env))
            })
            .and_then(|m| {
                m.map_put(
                    atoms::memused_bytes().encode(env),
                    self.memused_bytes.encode(env),
                )
            });

        map_or_encoding_error(env, built, "explain_analyze stmt_counters")
    }
}

impl Encoder for ScanStatus {
    fn encode<'b>(&self, env: Env<'b>) -> Term<'b> {
        let built = map_new(env)
            .map_put(atoms::loops().encode(env), self.loops.encode(env))
            .and_then(|m| {
                m.map_put(
                    atoms::rows_visited().encode(env),
                    self.rows_visited.encode(env),
                )
            })
            .and_then(|m| {
                m.map_put(
                    atoms::estimated_rows().encode(env),
                    self.estimated_rows.encode(env),
                )
            })
            .and_then(|m| m.map_put(atoms::name().encode(env), self.name.as_str().encode(env)))
            .and_then(|m| {
                m.map_put(
                    atoms::explain().encode(env),
                    self.explain.as_str().encode(env),
                )
            })
            .and_then(|m| m.map_put(atoms::selectid().encode(env), self.selectid.encode(env)))
            .and_then(|m| m.map_put(atoms::parentid().encode(env), self.parentid.encode(env)));

        map_or_encoding_error(env, built, "explain_analyze scan")
    }
}

impl Encoder for QueryPlanRow {
    fn encode<'b>(&self, env: Env<'b>) -> Term<'b> {
        let built = map_new(env)
            .map_put(atoms::id().encode(env), self.id.encode(env))
            .and_then(|m| m.map_put(atoms::parent().encode(env), self.parent.encode(env)))
            .and_then(|m| {
                m.map_put(
                    atoms::detail().encode(env),
                    self.detail.as_str().encode(env),
                )
            });

        map_or_encoding_error(env, built, "explain_analyze query_plan row")
    }
}
