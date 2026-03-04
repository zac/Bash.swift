#ifndef BASH_CPYTHON_BRIDGE_H
#define BASH_CPYTHON_BRIDGE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef const char *(*BashCPythonFSHandler)(void *context, const char *request_json);

typedef struct BashCPythonRuntime BashCPythonRuntime;

int bash_cpython_is_available(void);

BashCPythonRuntime *bash_cpython_runtime_create(const char *bootstrap_script, char **error_out);
void bash_cpython_runtime_destroy(BashCPythonRuntime *runtime);

void bash_cpython_runtime_set_fs_handler(
    BashCPythonRuntime *runtime,
    BashCPythonFSHandler handler,
    void *context
);

char *bash_cpython_runtime_execute(
    BashCPythonRuntime *runtime,
    const char *request_json,
    char **error_out
);

char *bash_cpython_runtime_version(BashCPythonRuntime *runtime, char **error_out);

void bash_cpython_free_string(char *value);

#ifdef __cplusplus
}
#endif

#endif
