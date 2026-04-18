use crate::atoms;
use crate::error::XqliteError;
use crate::stream::{bind_named_params_ffi, bind_positional_params_ffi};
use crate::util::{decode_exec_keyword_params, decode_plain_list_params, is_keyword};
use rusqlite::Connection;
use rusqlite::ffi;
use rusqlite::types::Value;
use rustler::types::atom::nil;
use rustler::{Encoder, Env, Term, TermType, types::map::map_new};
use std::ffi::{CStr, CString};
use std::os::raw::c_int;
use std::ptr::NonNull;
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
        let c_sql = CString::new(sql).map_err(|_| XqliteError::NulErrorInString)?;
        let sql_len = c_int::try_from(c_sql.as_bytes().len())
            .map_err(|_| XqliteError::CannotExecute("SQL too long".to_string()))?;

        let mut raw_stmt_ptr: *mut ffi::sqlite3_stmt = std::ptr::null_mut();
        let prepare_rc = ffi::sqlite3_prepare_v2(
            db_handle,
            c_sql.as_ptr(),
            sql_len,
            &mut raw_stmt_ptr,
            std::ptr::null_mut(),
        );

        if prepare_rc != ffi::SQLITE_OK {
            return Err(ffi_error(db_handle, prepare_rc));
        }

        let stmt_ptr = match NonNull::new(raw_stmt_ptr) {
            Some(p) => p,
            None => {
                // Whitespace-only / comment-only SQL. Return an empty report
                // without attempting EXPLAIN QUERY PLAN (which would choke on
                // the same input).
                return Ok(ExplainAnalyze {
                    wall_time_ns: 0,
                    rows_produced: 0,
                    stmt_counters: StmtCounters::zero(),
                    scans: Vec::new(),
                    query_plan: Vec::new(),
                });
            }
        };

        let query_plan = collect_query_plan(conn, sql)?;
        let result =
            run_and_collect(env, stmt_ptr.as_ptr(), db_handle, params_term, query_plan);

        ffi::sqlite3_finalize(stmt_ptr.as_ptr());

        result
    }
}

// --- private ---------------------------------------------------------------

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
        let rc = unsafe { ffi::sqlite3_step(stmt_ptr) };
        match rc {
            ffi::SQLITE_ROW => rows_produced += 1,
            ffi::SQLITE_DONE => break,
            _ => return Err(unsafe { ffi_error(db_handle, rc) }),
        }
    }

    let wall_time_ns = start.elapsed().as_nanos() as u64;
    let stmt_counters = unsafe { collect_stmt_counters(stmt_ptr) };
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

fn collect_query_plan(conn: &Connection, sql: &str) -> Result<Vec<QueryPlanRow>, XqliteError> {
    let eqp_sql = format!("EXPLAIN QUERY PLAN {sql}");
    let mut stmt = conn.prepare(&eqp_sql)?;
    let col_count = stmt.column_count();

    // EXPLAIN QUERY PLAN is documented to return (id, parent, notused, detail).
    // Bail early if the shape ever changes.
    if col_count != 4 {
        return Err(XqliteError::CannotExecute(format!(
            "EXPLAIN QUERY PLAN returned {col_count} columns; expected 4"
        )));
    }

    // `raw_query` skips rusqlite's "params match placeholders" check. The
    // query plan shape does not depend on bound values (SQLite treats unbound
    // placeholders as NULL), so we don't need to re-decode the user's params
    // here just to pass validation.
    let mut rows = stmt.raw_query();
    let mut out = Vec::new();

    while let Some(row) = rows.next()? {
        out.push(QueryPlanRow {
            id: row.get::<_, i32>(0)?,
            parent: row.get::<_, i32>(1)?,
            detail: row.get::<_, String>(3)?,
        });
    }

    Ok(out)
}

/// # Safety
/// `stmt_ptr` must be valid and the connection Mutex must be held.
unsafe fn collect_stmt_counters(stmt_ptr: *mut ffi::sqlite3_stmt) -> StmtCounters {
    let get = |op: i32| -> i64 { unsafe { ffi::sqlite3_stmt_status(stmt_ptr, op, 0) as i64 } };

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

        let name = unsafe { cstr_to_string(name_ptr) };
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
        let err_msg_ptr = unsafe { ffi::sqlite3_errmsg(db_handle) };
        if err_msg_ptr.is_null() {
            format!("SQLite error (code {code}) but no message available")
        } else {
            unsafe { CStr::from_ptr(err_msg_ptr) }
                .to_string_lossy()
                .into_owned()
        }
    };
    let ffi_err = ffi::Error::new(code);
    let rusqlite_err = rusqlite::Error::SqliteFailure(ffi_err, Some(message));
    XqliteError::from(rusqlite_err)
}

impl StmtCounters {
    fn zero() -> Self {
        Self {
            fullscan_step: 0,
            sort: 0,
            autoindex: 0,
            vm_step: 0,
            reprepare: 0,
            run: 0,
            filter_miss: 0,
            filter_hit: 0,
            memused_bytes: 0,
        }
    }
}

// --- encoding to Elixir -----------------------------------------------------

impl Encoder for ExplainAnalyze {
    fn encode<'b>(&self, env: Env<'b>) -> Term<'b> {
        let scans_terms: Vec<Term> = self.scans.iter().map(|s| s.encode(env)).collect();
        let plan_terms: Vec<Term> = self.query_plan.iter().map(|r| r.encode(env)).collect();

        let map = map_new(env);
        let map = map
            .map_put(
                atoms::wall_time_ns().encode(env),
                self.wall_time_ns.encode(env),
            )
            .unwrap();
        let map = map
            .map_put(
                atoms::rows_produced().encode(env),
                self.rows_produced.encode(env),
            )
            .unwrap();
        let map = map
            .map_put(
                atoms::stmt_counters().encode(env),
                self.stmt_counters.encode(env),
            )
            .unwrap();
        let map = map
            .map_put(atoms::scans().encode(env), scans_terms.encode(env))
            .unwrap();
        map.map_put(atoms::query_plan().encode(env), plan_terms.encode(env))
            .unwrap()
    }
}

impl Encoder for StmtCounters {
    fn encode<'b>(&self, env: Env<'b>) -> Term<'b> {
        let map = map_new(env);
        let map = map
            .map_put(
                atoms::fullscan_step().encode(env),
                self.fullscan_step.encode(env),
            )
            .unwrap();
        let map = map
            .map_put(atoms::sort().encode(env), self.sort.encode(env))
            .unwrap();
        let map = map
            .map_put(atoms::autoindex().encode(env), self.autoindex.encode(env))
            .unwrap();
        let map = map
            .map_put(atoms::vm_step().encode(env), self.vm_step.encode(env))
            .unwrap();
        let map = map
            .map_put(atoms::reprepare().encode(env), self.reprepare.encode(env))
            .unwrap();
        let map = map
            .map_put(atoms::run().encode(env), self.run.encode(env))
            .unwrap();
        let map = map
            .map_put(
                atoms::filter_miss().encode(env),
                self.filter_miss.encode(env),
            )
            .unwrap();
        let map = map
            .map_put(atoms::filter_hit().encode(env), self.filter_hit.encode(env))
            .unwrap();
        map.map_put(
            atoms::memused_bytes().encode(env),
            self.memused_bytes.encode(env),
        )
        .unwrap()
    }
}

impl Encoder for ScanStatus {
    fn encode<'b>(&self, env: Env<'b>) -> Term<'b> {
        let map = map_new(env);
        let map = map
            .map_put(atoms::loops().encode(env), self.loops.encode(env))
            .unwrap();
        let map = map
            .map_put(
                atoms::rows_visited().encode(env),
                self.rows_visited.encode(env),
            )
            .unwrap();
        let map = map
            .map_put(
                atoms::estimated_rows().encode(env),
                self.estimated_rows.encode(env),
            )
            .unwrap();
        let map = map
            .map_put(atoms::name().encode(env), self.name.as_str().encode(env))
            .unwrap();
        let map = map
            .map_put(
                atoms::explain().encode(env),
                self.explain.as_str().encode(env),
            )
            .unwrap();
        let map = map
            .map_put(atoms::selectid().encode(env), self.selectid.encode(env))
            .unwrap();
        map.map_put(atoms::parentid().encode(env), self.parentid.encode(env))
            .unwrap()
    }
}

impl Encoder for QueryPlanRow {
    fn encode<'b>(&self, env: Env<'b>) -> Term<'b> {
        let map = map_new(env);
        let map = map
            .map_put(atoms::id().encode(env), self.id.encode(env))
            .unwrap();
        let map = map
            .map_put(atoms::parent().encode(env), self.parent.encode(env))
            .unwrap();
        map.map_put(
            atoms::detail().encode(env),
            self.detail.as_str().encode(env),
        )
        .unwrap()
    }
}
