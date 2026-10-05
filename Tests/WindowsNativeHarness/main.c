/* Disposable Windows CI fixtures only; not part of a customer product. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>
#include "CWindowsNative.h"

static wchar_t *wide(const char *text) {
    int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1, NULL, 0);
    if (!count) return NULL;
    wchar_t *value = calloc((size_t)count, sizeof(wchar_t));
    if (value) MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1, value, count);
    return value;
}

static int other_process_is_locked(const char *directory) {
    wchar_t executable[32700], command[32700];
    wchar_t *path = wide(directory);
    if (!path || !GetModuleFileNameW(NULL, executable, 32700)) { free(path); return 0; }
    int size = swprintf(command, 32700, L"\"%ls\" --try-lock \"%ls\"", executable, path);
    free(path);
    if (size <= 0 || size >= 32700) return 0;
    STARTUPINFOW startup = {0}; startup.cb = sizeof(startup);
    PROCESS_INFORMATION process = {0};
    if (!CreateProcessW(executable, command, NULL, NULL, FALSE, CREATE_NO_WINDOW, NULL, NULL, &startup, &process)) {
        fprintf(stderr, "Lock probe could not start: win32=%lu\n", GetLastError()); return 0;
    }
    DWORD waited = WaitForSingleObject(process.hProcess, 5000), code = 1;
    if (waited == WAIT_OBJECT_0) GetExitCodeProcess(process.hProcess, &code);
    else TerminateProcess(process.hProcess, 2); /* Only this probe's own child. */
    CloseHandle(process.hThread); CloseHandle(process.hProcess);
    if (waited != WAIT_OBJECT_0 || code != 0)
        fprintf(stderr, "Lock probe did not reject the competing holder: wait=%lu child_exit=%lu\n", waited, code);
    return waited == WAIT_OBJECT_0 && code == 0;
}

int main(int argc, char **argv) {
    if (argc == 3 && !strcmp(argv[1], "--try-lock")) {
        COSWRoot *root = NULL; COSWLock *lock = NULL;
        int status = cosw_root_open(argv[2], &root);
        if (status) return 20 + status;
        status = cosw_lock_acquire(root, "cross-process.lock", &lock);
        cosw_lock_release(lock); cosw_root_close(root);
        return status == COSW_LOCKED ? 0 : 40 + status;
    }
    if (argc != 2) return 2;
    char project[4096], private_name[80], private_path[4096], renamed[4096];
    if (snprintf(project, sizeof(project), "%s/project", argv[1]) >= (int)sizeof(project)) return 2;
    COSWRoot *root = NULL, *private_root = NULL; COSWLock *lock = NULL;
    void *bytes = NULL; size_t count = 0;
    int failure = 1;
    const char *stage = "open project root";
    int status = cosw_root_open(project, &root);
    if (status) goto finish;
    const char *invalid[] = {"../outside/secret.txt", "file:stream", "NUL.txt", "a/../b", "CON .txt", "COM1.txt", "/absolute"};
    for (size_t i = 0; i < sizeof(invalid) / sizeof(invalid[0]); ++i) {
        stage = invalid[i];
        status = cosw_root_read(root, invalid[i], 1024, &bytes, &count);
        if (status != COSW_INVALID_PATH || bytes || count) goto finish;
    }
    stage = "reject junction";
    status = cosw_root_read(root, "junction/secret.txt", 1024, &bytes, &count);
    if (status != COSW_UNSAFE_OBJECT || bytes) goto finish;
    stage = "reject hardlink";
    status = cosw_root_read(root, "hardlinked.txt", 1024, &bytes, &count);
    if (status != COSW_UNSAFE_OBJECT || bytes) goto finish;
    stage = "read known fixture body";
    status = cosw_root_read(root, "Sources/valid.swift", 1024, &bytes, &count);
    if (status || count != 13 || memcmp(bytes, "FIXTURE_BODY\n", 13)) goto finish;
    cosw_buffer_free(bytes); bytes = NULL;
    snprintf(renamed, sizeof(renamed), "%s/renamed-project", argv[1]);
    wchar_t *from = wide(project), *to = wide(renamed);
    stage = "block ancestor rename";
    if (!from || !to) { free(from); free(to); goto finish; }
    BOOL moved = MoveFileW(from, to); DWORD error = GetLastError(); free(from); free(to);
    if (moved || (error != ERROR_SHARING_VIOLATION && error != ERROR_ACCESS_DENIED)) goto finish;
    snprintf(private_name, sizeof(private_name), "native-harness-%lu", GetCurrentProcessId());
    stage = "create private directory";
    status = cosw_private_directory_create(root, private_name, &private_root);
    if (status) goto finish;
    stage = "write new private file";
    status = cosw_private_write_new(private_root, "preserved", "FIRST", 5);
    if (status) goto finish;
    stage = "refuse private overwrite";
    status = cosw_private_write_new(private_root, "preserved", "NEW", 3);
    if (status != COSW_ALREADY_EXISTS) goto finish;
    stage = "verify preserved private body";
    status = cosw_root_read(private_root, "preserved", 1024, &bytes, &count);
    if (status || count != 5 || memcmp(bytes, "FIRST", 5)) goto finish;
    cosw_buffer_free(bytes); bytes = NULL;
    stage = "acquire first private lock";
    status = cosw_lock_acquire(private_root, "cross-process.lock", &lock);
    if (status) goto finish;
    if (snprintf(private_path, sizeof(private_path), "%s/%s", project, private_name) >= (int)sizeof(private_path)) goto finish;
    stage = "reject competing process lock";
    if (!other_process_is_locked(private_path)) goto finish;
    cosw_lock_release(lock); lock = NULL;
    stage = "reacquire released lock";
    status = cosw_lock_acquire(private_root, "cross-process.lock", &lock);
    if (status) goto finish;
    failure = 0;
    puts("{\"native_windows_fixture_passed\":true,\"cross_process_lock_passed\":true,\"ancestor_rename_blocked\":true,\"windows_product_ready\":false}");
finish:
    if (failure) fprintf(stderr, "Native fixture failed: stage=%s native_status=%d win32=%lu bytes=%zu\n", stage, status, GetLastError(), count);
    cosw_buffer_free(bytes); cosw_lock_release(lock); cosw_root_close(private_root); cosw_root_close(root);
    return failure;
}
