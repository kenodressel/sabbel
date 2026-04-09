#include <Python.h>
#include <limits.h>
#include <stdio.h>

#ifndef SABBEL_PROJECT_DIR
#define SABBEL_PROJECT_DIR "."
#endif

#ifndef SABBEL_PYTHON_HOME
#define SABBEL_PYTHON_HOME "/usr/local"
#endif

#ifndef SABBEL_SITE_PACKAGES
#define SABBEL_SITE_PACKAGES "."
#endif

#ifndef SABBEL_STDLIB
#define SABBEL_STDLIB "."
#endif

#ifndef SABBEL_DYNLOAD
#define SABBEL_DYNLOAD "."
#endif

static PyStatus append_path(PyConfig *config, const wchar_t *path) {
    return PyWideStringList_Append(&config->module_search_paths, path);
}

int main(int argc, char **argv) {
    PyStatus status;
    PyConfig config;
    PyConfig_InitPythonConfig(&config);

    wchar_t *program_name = Py_DecodeLocale(argv[0], NULL);
    wchar_t *python_home = Py_DecodeLocale(SABBEL_PYTHON_HOME, NULL);
    wchar_t *project_dir = Py_DecodeLocale(SABBEL_PROJECT_DIR, NULL);
    wchar_t *site_packages = Py_DecodeLocale(SABBEL_SITE_PACKAGES, NULL);
    wchar_t *stdlib_dir = Py_DecodeLocale(SABBEL_STDLIB, NULL);
    wchar_t *dynload_dir = Py_DecodeLocale(SABBEL_DYNLOAD, NULL);

    if (
        program_name == NULL || python_home == NULL || project_dir == NULL ||
        site_packages == NULL || stdlib_dir == NULL || dynload_dir == NULL
    ) {
        fprintf(stderr, "Failed to decode launcher paths.\n");
        return 1;
    }

    status = PyConfig_SetString(&config, &config.program_name, program_name);
    if (PyStatus_Exception(status)) {
        goto fail;
    }

    status = PyConfig_SetString(&config, &config.home, python_home);
    if (PyStatus_Exception(status)) {
        goto fail;
    }

    config.module_search_paths_set = 1;
    status = append_path(&config, stdlib_dir);
    if (PyStatus_Exception(status)) {
        goto fail;
    }
    status = append_path(&config, dynload_dir);
    if (PyStatus_Exception(status)) {
        goto fail;
    }
    status = append_path(&config, site_packages);
    if (PyStatus_Exception(status)) {
        goto fail;
    }
    status = append_path(&config, project_dir);
    if (PyStatus_Exception(status)) {
        goto fail;
    }

    status = PyConfig_SetBytesArgv(&config, argc, argv);
    if (PyStatus_Exception(status)) {
        goto fail;
    }

    status = Py_InitializeFromConfig(&config);
    if (PyStatus_Exception(status)) {
        goto fail;
    }

    PyConfig_Clear(&config);
    PyMem_RawFree(program_name);
    PyMem_RawFree(python_home);
    PyMem_RawFree(project_dir);
    PyMem_RawFree(site_packages);
    PyMem_RawFree(stdlib_dir);
    PyMem_RawFree(dynload_dir);

    int rc = PyRun_SimpleString(
        "from sabbel.__main__ import main\n"
        "raise SystemExit(main())\n"
    );

    if (Py_FinalizeEx() < 0) {
        return 120;
    }
    return rc;

fail:
    PyConfig_Clear(&config);
    PyMem_RawFree(program_name);
    PyMem_RawFree(python_home);
    PyMem_RawFree(project_dir);
    PyMem_RawFree(site_packages);
    PyMem_RawFree(stdlib_dir);
    PyMem_RawFree(dynload_dir);
    Py_ExitStatusException(status);
}
