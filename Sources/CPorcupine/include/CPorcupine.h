// CPorcupine — a minimal runtime loader for Picovoice's macOS C library.
//
// Why a loader instead of linking?
//   * The app (and `swift test`) builds and launches even when libpv_porcupine.dylib is
//     absent; a missing library becomes an ordinary, recoverable engine error rather than
//     a dyld crash at launch.
//   * The function table below is typed from the *vendored official header* with
//     `__typeof__`, so a signature change in a future SDK is a compile error here, not a
//     silent ABI mismatch.
//
// This is the only translation unit in the project that knows Picovoice's C API.

#ifndef CPORCUPINE_H
#define CPORCUPINE_H

#include <stddef.h>
#include "picovoice.h"
#include "pv_porcupine.h"

#ifdef __cplusplus
extern "C" {
#endif

/// Function table resolved from libpv_porcupine.dylib. Every member is non-NULL after a
/// successful `cpv_load`.
typedef struct {
    void *library;  // dlopen handle (kept for the process lifetime; never dlclose'd)

    __typeof__(pv_porcupine_init)         *porcupine_init;
    __typeof__(pv_porcupine_delete)       *porcupine_delete;
    __typeof__(pv_porcupine_process)      *porcupine_process;
    __typeof__(pv_porcupine_version)      *porcupine_version;
    __typeof__(pv_porcupine_frame_length) *porcupine_frame_length;
    __typeof__(pv_sample_rate)            *sample_rate;
    __typeof__(pv_status_to_string)       *status_to_string;
    __typeof__(pv_get_error_stack)        *get_error_stack;
    __typeof__(pv_free_error_stack)       *free_error_stack;
} cpv_api_t;

typedef enum {
    CPV_LOAD_OK = 0,
    CPV_LOAD_NOT_FOUND = 1,       // dlopen failed (missing file, wrong architecture, bad signature…)
    CPV_LOAD_MISSING_SYMBOL = 2,  // library loaded but an expected export is absent
} cpv_load_status_t;

/// Loads the library at `path` (an absolute path) and resolves all symbols into `api`.
/// On failure `api` is zeroed and a human-readable reason is written to `error`.
cpv_load_status_t cpv_load(const char *path, cpv_api_t *api, char *error, size_t error_capacity);

#ifdef __cplusplus
}
#endif

#endif  // CPORCUPINE_H
