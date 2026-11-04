#include "CPorcupine.h"

#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

#define CPV_RESOLVE(member, symbol)                                                         \
    do {                                                                                    \
        api->member = (__typeof__(api->member))dlsym(handle, symbol);                       \
        if (api->member == NULL) {                                                          \
            snprintf(error, error_capacity, "the library does not export `%s`", symbol);    \
            dlclose(handle);                                                                \
            memset(api, 0, sizeof(*api));                                                   \
            return CPV_LOAD_MISSING_SYMBOL;                                                 \
        }                                                                                   \
    } while (0)

cpv_load_status_t cpv_load(const char *path, cpv_api_t *api, char *error, size_t error_capacity) {
    if (api == NULL || error == NULL || error_capacity == 0) {
        return CPV_LOAD_NOT_FOUND;
    }
    memset(api, 0, sizeof(*api));
    error[0] = '\0';

    void *handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (handle == NULL) {
        const char *reason = dlerror();
        snprintf(error, error_capacity, "%s", reason != NULL ? reason : "dlopen failed");
        return CPV_LOAD_NOT_FOUND;
    }

    CPV_RESOLVE(porcupine_init, "pv_porcupine_init");
    CPV_RESOLVE(porcupine_delete, "pv_porcupine_delete");
    CPV_RESOLVE(porcupine_process, "pv_porcupine_process");
    CPV_RESOLVE(porcupine_version, "pv_porcupine_version");
    CPV_RESOLVE(porcupine_frame_length, "pv_porcupine_frame_length");
    CPV_RESOLVE(sample_rate, "pv_sample_rate");
    CPV_RESOLVE(status_to_string, "pv_status_to_string");
    CPV_RESOLVE(get_error_stack, "pv_get_error_stack");
    CPV_RESOLVE(free_error_stack, "pv_free_error_stack");

    api->library = handle;
    return CPV_LOAD_OK;
}
