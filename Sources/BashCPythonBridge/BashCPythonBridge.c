#include "BashCPythonBridge.h"

#include <stdlib.h>
#include <string.h>

#include <TargetConditionals.h>

#if (TARGET_OS_OSX || TARGET_OS_IOS) && __has_include(<Python.h>)
#define BASHSWIFT_CPYTHON_AVAILABLE 1
#include <Python.h>
#else
#define BASHSWIFT_CPYTHON_AVAILABLE 0
#endif

struct BashCPythonRuntime {
    BashCPythonFSHandler fs_handler;
    void *fs_context;
    int initialized;
    char *bootstrap_script;
};

static char *bash_strdup(const char *input) {
    if (input == NULL) {
        return NULL;
    }

    size_t length = strlen(input);
    char *output = (char *)malloc(length + 1);
    if (output == NULL) {
        return NULL;
    }

    memcpy(output, input, length);
    output[length] = '\0';
    return output;
}

static void bash_set_error(char **error_out, const char *message) {
    if (error_out == NULL) {
        return;
    }

    *error_out = bash_strdup(message != NULL ? message : "unknown error");
}

#if BASHSWIFT_CPYTHON_AVAILABLE

static BashCPythonRuntime *g_current_runtime = NULL;
static int g_inittab_registered = 0;
static PyThreadState *g_saved_thread_state = NULL;
static int g_active_runtime_count = 0;

static char *bash_python_error_string(void) {
    if (!PyErr_Occurred()) {
        return bash_strdup("unknown python error");
    }

    PyObject *ptype = NULL;
    PyObject *pvalue = NULL;
    PyObject *ptraceback = NULL;
    PyErr_Fetch(&ptype, &pvalue, &ptraceback);
    PyErr_NormalizeException(&ptype, &pvalue, &ptraceback);

    char *message = NULL;

    if (pvalue != NULL) {
        PyObject *string_value = PyObject_Str(pvalue);
        if (string_value != NULL) {
            const char *utf8 = PyUnicode_AsUTF8(string_value);
            if (utf8 != NULL) {
                message = bash_strdup(utf8);
            }
            Py_DECREF(string_value);
        }
    }

    if (message == NULL && ptype != NULL) {
        PyObject *type_name = PyObject_GetAttrString(ptype, "__name__");
        if (type_name != NULL) {
            const char *utf8 = PyUnicode_AsUTF8(type_name);
            if (utf8 != NULL) {
                message = bash_strdup(utf8);
            }
            Py_DECREF(type_name);
        }
    }

    if (message == NULL) {
        message = bash_strdup("unknown python error");
    }

    Py_XDECREF(ptype);
    Py_XDECREF(pvalue);
    Py_XDECREF(ptraceback);

    return message;
}

static PyObject *bashswift_fs_call(PyObject *self, PyObject *args) {
    (void)self;

    const char *request_json = NULL;
    if (!PyArg_ParseTuple(args, "s", &request_json)) {
        return NULL;
    }

    if (g_current_runtime == NULL || g_current_runtime->fs_handler == NULL) {
        PyErr_SetString(PyExc_RuntimeError, "filesystem bridge is not active");
        return NULL;
    }

    const char *response_json = g_current_runtime->fs_handler(g_current_runtime->fs_context, request_json);
    if (response_json == NULL) {
        PyErr_SetString(PyExc_RuntimeError, "filesystem bridge returned no response");
        return NULL;
    }

    PyObject *result = PyUnicode_FromString(response_json);
    free((void *)response_json);
    return result;
}

static PyMethodDef bashswift_host_methods[] = {
    {"fs_call", bashswift_fs_call, METH_VARARGS, "Perform a filesystem operation through the host bridge."},
    {NULL, NULL, 0, NULL}
};

static struct PyModuleDef bashswift_host_module = {
    PyModuleDef_HEAD_INIT,
    "_bashswift_host",
    "Bash.swift host bridge module",
    -1,
    bashswift_host_methods,
    NULL,
    NULL,
    NULL,
    NULL,
};

PyMODINIT_FUNC PyInit__bashswift_host(void) {
    return PyModule_Create(&bashswift_host_module);
}

static int bash_ensure_initialized(BashCPythonRuntime *runtime, char **error_out) {
    if (runtime->initialized) {
        return 1;
    }

    if (!g_inittab_registered) {
        if (PyImport_AppendInittab("_bashswift_host", PyInit__bashswift_host) == -1) {
            bash_set_error(error_out, "failed to register _bashswift_host module");
            return 0;
        }
        g_inittab_registered = 1;
    }

    int initialized_here = 0;
    if (!Py_IsInitialized()) {
        Py_Initialize();
        if (!Py_IsInitialized()) {
            bash_set_error(error_out, "failed to initialize CPython");
            return 0;
        }
        initialized_here = 1;
    }

    PyGILState_STATE gstate = PyGILState_Ensure();

    if (PyRun_SimpleString("import _bashswift_host\n") != 0) {
        char *message = bash_python_error_string();
        bash_set_error(error_out, message);
        free(message);
        PyGILState_Release(gstate);
        return 0;
    }

    if (runtime->bootstrap_script != NULL) {
        if (PyRun_SimpleString(runtime->bootstrap_script) != 0) {
            char *message = bash_python_error_string();
            bash_set_error(error_out, message);
            free(message);
            PyGILState_Release(gstate);
            return 0;
        }
    }

    runtime->initialized = 1;
    PyGILState_Release(gstate);

    if (initialized_here) {
        g_saved_thread_state = PyEval_SaveThread();
    }

    return 1;
}

#endif

int bash_cpython_is_available(void) {
#if BASHSWIFT_CPYTHON_AVAILABLE
    return 1;
#else
    return 0;
#endif
}

BashCPythonRuntime *bash_cpython_runtime_create(const char *bootstrap_script, char **error_out) {
#if BASHSWIFT_CPYTHON_AVAILABLE
    BashCPythonRuntime *runtime = (BashCPythonRuntime *)calloc(1, sizeof(BashCPythonRuntime));
    if (runtime == NULL) {
        bash_set_error(error_out, "failed to allocate runtime");
        return NULL;
    }

    if (bootstrap_script != NULL) {
        runtime->bootstrap_script = bash_strdup(bootstrap_script);
        if (runtime->bootstrap_script == NULL) {
            free(runtime);
            bash_set_error(error_out, "failed to copy bootstrap script");
            return NULL;
        }
    }

    runtime->initialized = 0;
    runtime->fs_handler = NULL;
    runtime->fs_context = NULL;
    g_active_runtime_count += 1;

    return runtime;
#else
    (void)bootstrap_script;
    bash_set_error(error_out, "CPython bridge is unavailable on this platform");
    return NULL;
#endif
}

void bash_cpython_runtime_destroy(BashCPythonRuntime *runtime) {
    if (runtime == NULL) {
        return;
    }

#if BASHSWIFT_CPYTHON_AVAILABLE
    if (g_active_runtime_count > 0) {
        g_active_runtime_count -= 1;
    }

    if (g_active_runtime_count == 0 && Py_IsInitialized()) {
        if (g_saved_thread_state != NULL) {
            PyEval_RestoreThread(g_saved_thread_state);
            g_saved_thread_state = NULL;
        }
        Py_Finalize();
    }
#endif

    if (runtime->bootstrap_script != NULL) {
        free(runtime->bootstrap_script);
    }

    free(runtime);
}

void bash_cpython_runtime_set_fs_handler(
    BashCPythonRuntime *runtime,
    BashCPythonFSHandler handler,
    void *context
) {
    if (runtime == NULL) {
        return;
    }

    runtime->fs_handler = handler;
    runtime->fs_context = context;
}

char *bash_cpython_runtime_execute(
    BashCPythonRuntime *runtime,
    const char *request_json,
    char **error_out
) {
#if BASHSWIFT_CPYTHON_AVAILABLE
    if (runtime == NULL) {
        bash_set_error(error_out, "runtime is null");
        return NULL;
    }

    if (!bash_ensure_initialized(runtime, error_out)) {
        return NULL;
    }

    const char *payload = request_json != NULL ? request_json : "{}";

    PyGILState_STATE gstate = PyGILState_Ensure();

    PyObject *main_module = PyImport_AddModule("__main__");
    if (main_module == NULL) {
        char *message = bash_python_error_string();
        bash_set_error(error_out, message);
        free(message);
        PyGILState_Release(gstate);
        return NULL;
    }

    PyObject *globals = PyModule_GetDict(main_module);
    if (globals == NULL) {
        bash_set_error(error_out, "failed to load __main__ globals");
        PyGILState_Release(gstate);
        return NULL;
    }

    PyObject *execute_function = PyDict_GetItemString(globals, "__bashswift_execute");
    if (execute_function == NULL || !PyCallable_Check(execute_function)) {
        bash_set_error(error_out, "bootstrap function __bashswift_execute is unavailable");
        PyGILState_Release(gstate);
        return NULL;
    }

    PyObject *argument = PyUnicode_FromString(payload);
    if (argument == NULL) {
        char *message = bash_python_error_string();
        bash_set_error(error_out, message);
        free(message);
        PyGILState_Release(gstate);
        return NULL;
    }

    g_current_runtime = runtime;
    PyObject *result = PyObject_CallFunctionObjArgs(execute_function, argument, NULL);
    g_current_runtime = NULL;

    Py_DECREF(argument);

    if (result == NULL) {
        char *message = bash_python_error_string();
        bash_set_error(error_out, message);
        free(message);
        PyGILState_Release(gstate);
        return NULL;
    }

    const char *utf8 = PyUnicode_AsUTF8(result);
    if (utf8 == NULL) {
        Py_DECREF(result);
        char *message = bash_python_error_string();
        bash_set_error(error_out, message);
        free(message);
        PyGILState_Release(gstate);
        return NULL;
    }

    char *output = bash_strdup(utf8);
    Py_DECREF(result);

    if (output == NULL) {
        bash_set_error(error_out, "failed to allocate execution output");
        PyGILState_Release(gstate);
        return NULL;
    }

    PyGILState_Release(gstate);
    return output;
#else
    (void)runtime;
    (void)request_json;
    bash_set_error(error_out, "CPython bridge is unavailable on this platform");
    return NULL;
#endif
}

char *bash_cpython_runtime_version(BashCPythonRuntime *runtime, char **error_out) {
#if BASHSWIFT_CPYTHON_AVAILABLE
    if (runtime == NULL) {
        bash_set_error(error_out, "runtime is null");
        return NULL;
    }

    if (!bash_ensure_initialized(runtime, error_out)) {
        return NULL;
    }

    PyGILState_STATE gstate = PyGILState_Ensure();

    const char *version = Py_GetVersion();
    char *result = bash_strdup(version != NULL ? version : "Python 3");
    if (result == NULL) {
        bash_set_error(error_out, "failed to allocate version string");
    }

    PyGILState_Release(gstate);
    return result;
#else
    (void)runtime;
    bash_set_error(error_out, "CPython bridge is unavailable on this platform");
    return NULL;
#endif
}

void bash_cpython_free_string(char *value) {
    if (value != NULL) {
        free(value);
    }
}
