#include "sqlite3ext.h"
SQLITE_EXTENSION_INIT1

static void xqlite_test_fn(sqlite3_context *ctx, int argc,
                            sqlite3_value **argv) {
    (void)argc;
    (void)argv;
    sqlite3_result_text(ctx, "xqlite_ext_ok", -1, SQLITE_STATIC);
}

#ifdef _WIN32
__declspec(dllexport)
#endif
int sqlite3_xqlitetestext_init(sqlite3 *db, char **pzErrMsg,
                                const sqlite3_api_routines *pApi) {
    (void)pzErrMsg;
    SQLITE_EXTENSION_INIT2(pApi);
    return sqlite3_create_function(db, "xqlite_test_ext", 0,
                                   SQLITE_UTF8 | SQLITE_DETERMINISTIC, 0,
                                   xqlite_test_fn, 0, 0);
}
