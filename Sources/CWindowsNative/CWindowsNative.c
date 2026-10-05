#include "CWindowsNative.h"
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#include <windows.h>
#include <aclapi.h>
#include <sddl.h>
#include <bcrypt.h>
#include <wchar.h>

struct COSWRoot {
    /* Every ancestor stays open without FILE_SHARE_WRITE/FILE_SHARE_DELETE. Checking a path
       and immediately closing its handles would permit junction replacement. */
    HANDLE *ancestors;
    size_t count;
    wchar_t *canonical;
};
struct COSWLock { HANDLE file; OVERLAPPED range; };

static int utf16(const char *input, wchar_t **result) {
    *result = NULL;
    if (!input) return COSW_INVALID_PATH;
    int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, input, -1, NULL, 0);
    if (count <= 1 || count > 32700) return COSW_INVALID_PATH;
    wchar_t *wide = calloc((size_t)count, sizeof(wchar_t));
    if (!wide) return COSW_IO_ERROR;
    if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, input, -1, wide, count)) {
        free(wide); return COSW_INVALID_PATH;
    }
    for (int i = 0; i < count; ++i) if (wide[i] == L'/') wide[i] = L'\\';
    *result = wide;
    return COSW_OK;
}

static int component_valid(const wchar_t *start, size_t length) {
    if (!length || length > 255 || start[length - 1] == L'.' || start[length - 1] == L' ') return 0;
    if ((length == 1 && start[0] == L'.') || (length == 2 && start[0] == L'.' && start[1] == L'.')) return 0;
    for (size_t i = 0; i < length; ++i) {
        if (start[i] < 32 || wcschr(L"<>:\"/\\|?*", start[i])) return 0;
    }
    size_t stem_length = 0;
    while (stem_length < length && start[stem_length] != L'.') ++stem_length;
    while (stem_length && start[stem_length - 1] == L' ') --stem_length;
    wchar_t stem[9] = {0};
    if (stem_length < 9) {
        for (size_t i = 0; i < stem_length; ++i) {
            wchar_t ch = start[i];
            stem[i] = ch >= L'a' && ch <= L'z' ? ch - 32 : ch;
        }
        if (!wcscmp(stem, L"CON") || !wcscmp(stem, L"PRN") || !wcscmp(stem, L"AUX") ||
            !wcscmp(stem, L"NUL") || !wcscmp(stem, L"CONIN$") || !wcscmp(stem, L"CONOUT$")) return 0;
        if (stem_length == 4 && (!wcsncmp(stem, L"COM", 3) || !wcsncmp(stem, L"LPT", 3)) &&
            ((stem[3] >= L'1' && stem[3] <= L'9') || stem[3] == 0x00B9 || stem[3] == 0x00B2 || stem[3] == 0x00B3)) return 0;
    }
    return 1;
}

static int relative_valid(const wchar_t *path, int single_component) {
    if (!path || !*path) return 0;
    const wchar_t *start = path;
    for (const wchar_t *cursor = path; ; ++cursor) {
        if (*cursor == L'\\' || !*cursor) {
            if (!component_valid(start, (size_t)(cursor - start))) return 0;
            if (!*cursor) return 1;
            if (single_component) return 0;
            start = cursor + 1;
        }
    }
}

static int safe_object(HANDLE file, int directory) {
    BY_HANDLE_FILE_INFORMATION info;
    if (GetFileType(file) != FILE_TYPE_DISK || !GetFileInformationByHandle(file, &info)) return 0;
    if (info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) return 0;
    if (!!(info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != directory) return 0;
    /* A regular file hardlink could expose an object outside the project. */
    return directory || info.nNumberOfLinks == 1;
}

static HANDLE open_directory(const wchar_t *path) {
    return CreateFileW(path, FILE_READ_ATTRIBUTES | READ_CONTROL, FILE_SHARE_READ,
                       NULL, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, NULL);
}

static wchar_t *final_path(HANDLE file) {
    DWORD count = GetFinalPathNameByHandleW(file, NULL, 0, FILE_NAME_NORMALIZED | VOLUME_NAME_GUID);
    if (!count || count > 32700) return NULL;
    wchar_t *path = calloc((size_t)count + 1, sizeof(wchar_t));
    if (!path) return NULL;
    DWORD written = GetFinalPathNameByHandleW(file, path, count + 1, FILE_NAME_NORMALIZED | VOLUME_NAME_GUID);
    if (!written || written > count) { free(path); return NULL; }
    return path;
}

static int within_root(COSWRoot *root, HANDLE file) {
    wchar_t *path = final_path(file);
    if (!path) return 0;
    size_t length = wcslen(root->canonical);
    /* Exact ordinal prefix is deliberately conservative for case-sensitive
       directories. No lowercasing or drive-string comparison authorizes I/O. */
    int valid = length && wcslen(path) > length && !wcsncmp(path, root->canonical, length) &&
                (root->canonical[length - 1] == L'\\' || path[length] == L'\\');
    free(path);
    return valid;
}

static int append_handle(COSWRoot *root, HANDLE file) {
    HANDLE *next = realloc(root->ancestors, (root->count + 1) * sizeof(HANDLE));
    if (!next) return 0;
    root->ancestors = next;
    root->ancestors[root->count++] = file;
    return 1;
}

void cosw_root_close(COSWRoot *root) {
    if (!root) return;
    for (size_t i = root->count; i > 0; --i) CloseHandle(root->ancestors[i - 1]);
    free(root->ancestors); free(root->canonical); free(root);
}

int32_t cosw_available(void) { return 1; }

int32_t cosw_root_open(const char *absolute_utf8, COSWRoot **result) {
    if (!result) return COSW_INVALID_PATH;
    *result = NULL;
    wchar_t *absolute = NULL;
    int status = utf16(absolute_utf8, &absolute);
    if (status) return status;
    size_t length = wcslen(absolute);
    wchar_t drive = absolute[0];
    if (length < 4 || !((drive >= L'A' && drive <= L'Z') || (drive >= L'a' && drive <= L'z')) ||
        absolute[1] != L':' || absolute[2] != L'\\' || !relative_valid(absolute + 3, 0)) {
        free(absolute); return COSW_INVALID_PATH;
    }
    wchar_t drive_root[] = {drive, L':', L'\\', 0};
    if (GetDriveTypeW(drive_root) != DRIVE_FIXED) { free(absolute); return COSW_UNSAFE_OBJECT; }
    COSWRoot *root = calloc(1, sizeof(COSWRoot));
    wchar_t *path = calloc(length + 5, sizeof(wchar_t));
    if (!root || !path) { free(root); free(path); free(absolute); return COSW_IO_ERROR; }
    wcscpy(path, L"\\\\?\\"); wcscat(path, absolute); free(absolute);
    wchar_t saved = path[7]; path[7] = 0;
    HANDLE ancestor = open_directory(path); path[7] = saved;
    if (ancestor == INVALID_HANDLE_VALUE) { status = COSW_IO_ERROR; goto finish; }
    if (!safe_object(ancestor, 1)) { CloseHandle(ancestor); status = COSW_UNSAFE_OBJECT; goto finish; }
    wchar_t filesystem[32] = {0};
    if (!GetVolumeInformationByHandleW(ancestor, NULL, 0, NULL, NULL, NULL, filesystem, 32) ||
        (wcscmp(filesystem, L"NTFS") && wcscmp(filesystem, L"ReFS"))) {
        CloseHandle(ancestor); status = COSW_UNSAFE_OBJECT; goto finish;
    }
    if (!append_handle(root, ancestor)) { CloseHandle(ancestor); status = COSW_IO_ERROR; goto finish; }
    root->canonical = final_path(ancestor);
    if (!root->canonical) { status = COSW_IO_ERROR; goto finish; }
    for (size_t i = 7; ; ++i) {
        if (path[i] == L'\\' || !path[i]) {
            saved = path[i]; path[i] = 0;
            ancestor = open_directory(path); path[i] = saved;
            if (ancestor == INVALID_HANDLE_VALUE) { status = COSW_IO_ERROR; goto finish; }
            if (!safe_object(ancestor, 1) || !within_root(root, ancestor)) {
                CloseHandle(ancestor); status = COSW_UNSAFE_OBJECT; goto finish;
            }
            if (!append_handle(root, ancestor)) { CloseHandle(ancestor); status = COSW_IO_ERROR; goto finish; }
            wchar_t *next_canonical = final_path(ancestor);
            if (!next_canonical) { status = COSW_IO_ERROR; goto finish; }
            free(root->canonical); root->canonical = next_canonical;
            if (!saved) break;
        }
    }
    *result = root; root = NULL; status = COSW_OK;
finish:
    cosw_root_close(root); free(path); return status;
}

static wchar_t *child_path(COSWRoot *root, const wchar_t *relative) {
    size_t left = wcslen(root->canonical), right = wcslen(relative);
    if (left + right + 2 > 32700) return NULL;
    wchar_t *path = calloc(left + right + 2, sizeof(wchar_t));
    if (path) { wcscpy(path, root->canonical); path[left] = L'\\'; wcscpy(path + left + 1, relative); }
    return path;
}

int32_t cosw_root_read(COSWRoot *root, const char *relative_utf8, size_t byte_limit, void **bytes, size_t *count) {
    if (!bytes || !count) return COSW_INVALID_PATH;
    *bytes = NULL; *count = 0;
    if (!root || !byte_limit) return COSW_INVALID_PATH;
    wchar_t *relative = NULL;
    int status = utf16(relative_utf8, &relative);
    if (status) return status;
    if (!relative_valid(relative, 0)) { free(relative); return COSW_INVALID_PATH; }
    wchar_t *path = child_path(root, relative); free(relative);
    if (!path) return COSW_INVALID_PATH;
    COSWRoot parents = {0};
    HANDLE file = INVALID_HANDLE_VALUE;
    void *buffer = NULL;
    size_t first = wcslen(root->canonical) + 1;
    for (size_t i = first; path[i]; ++i) {
        if (path[i] == L'\\') {
            path[i] = 0;
            HANDLE parent = open_directory(path); path[i] = L'\\';
            if (parent == INVALID_HANDLE_VALUE) { status = COSW_IO_ERROR; goto finish; }
            if (!safe_object(parent, 1) || !within_root(root, parent)) {
                CloseHandle(parent); status = COSW_UNSAFE_OBJECT; goto finish;
            }
            if (!append_handle(&parents, parent)) { CloseHandle(parent); status = COSW_IO_ERROR; goto finish; }
        }
    }
    /* Deny writes/deletes while reading so one returned body is a snapshot. */
    file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    if (file == INVALID_HANDLE_VALUE) { status = COSW_IO_ERROR; goto finish; }
    if (!safe_object(file, 0) || !within_root(root, file)) { status = COSW_UNSAFE_OBJECT; goto finish; }
    LARGE_INTEGER length;
    if (!GetFileSizeEx(file, &length) || length.QuadPart < 0) { status = COSW_IO_ERROR; goto finish; }
    if ((uint64_t)length.QuadPart > byte_limit || (uint64_t)length.QuadPart > SIZE_MAX) { status = COSW_TOO_LARGE; goto finish; }
    size_t total = (size_t)length.QuadPart, position = 0;
    buffer = malloc(total ? total : 1);
    if (!buffer) { status = COSW_IO_ERROR; goto finish; }
    while (position < total) {
        size_t remaining = total - position;
        DWORD amount = remaining > MAXDWORD ? MAXDWORD : (DWORD)remaining, received = 0;
        if (!ReadFile(file, (char *)buffer + position, amount, &received, NULL) || !received) { status = COSW_IO_ERROR; goto finish; }
        position += received;
    }
    *bytes = buffer; *count = total; buffer = NULL; status = COSW_OK;
finish:
    if (file != INVALID_HANDLE_VALUE) CloseHandle(file);
    for (size_t i = parents.count; i > 0; --i) CloseHandle(parents.ancestors[i - 1]);
    free(parents.ancestors); free(buffer); free(path); return status;
}

static TOKEN_USER *current_user(void) {
    HANDLE token;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) return NULL;
    DWORD size = 0;
    GetTokenInformation(token, TokenUser, NULL, 0, &size);
    TOKEN_USER *user = size ? malloc(size) : NULL;
    if (!user || !GetTokenInformation(token, TokenUser, user, size, &size)) { free(user); user = NULL; }
    CloseHandle(token); return user;
}

static PSECURITY_DESCRIPTOR private_descriptor(int directory) {
    TOKEN_USER *user = current_user();
    if (!user) return NULL;
    LPWSTR sid = NULL;
    if (!ConvertSidToStringSidW(user->User.Sid, &sid)) { free(user); return NULL; }
    size_t length = wcslen(sid) * 2 + 64;
    wchar_t *sddl = calloc(length, sizeof(wchar_t));
    PSECURITY_DESCRIPTOR descriptor = NULL;
    if (sddl) {
        wcscpy(sddl, L"O:"); wcscat(sddl, sid);
        wcscat(sddl, directory ? L"D:P(A;OICI;FA;;;" : L"D:P(A;;FA;;;"); wcscat(sddl, sid); wcscat(sddl, L")");
        ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl, SDDL_REVISION_1, &descriptor, NULL);
    }
    LocalFree(sid); free(user); free(sddl); return descriptor;
}

static int private_acl(HANDLE file) {
    TOKEN_USER *user = current_user();
    if (!user) return 0;
    PSID owner = NULL; PACL dacl = NULL; PSECURITY_DESCRIPTOR descriptor = NULL;
    DWORD error = GetSecurityInfo(file, SE_FILE_OBJECT, OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
                                  &owner, NULL, &dacl, NULL, &descriptor);
    int valid = error == ERROR_SUCCESS && owner && dacl && IsValidSid(owner) && EqualSid(owner, user->User.Sid);
    SECURITY_DESCRIPTOR_CONTROL control = 0; DWORD revision = 0;
    if (valid) valid = GetSecurityDescriptorControl(descriptor, &control, &revision) && (control & SE_DACL_PROTECTED) && dacl->AceCount > 0;
    for (DWORD i = 0; valid && i < dacl->AceCount; ++i) {
        ACCESS_ALLOWED_ACE *ace = NULL;
        valid = GetAce(dacl, i, (void **)&ace) && ace && ace->Header.AceType == ACCESS_ALLOWED_ACE_TYPE;
        if (valid) valid = IsValidSid(&ace->SidStart) && EqualSid(&ace->SidStart, user->User.Sid) &&
                            (ace->Mask & FILE_ALL_ACCESS) == FILE_ALL_ACCESS;
    }
    if (descriptor) LocalFree(descriptor);
    free(user); return valid;
}

int32_t cosw_private_directory_create(COSWRoot *parent, const char *name_utf8, COSWRoot **result) {
    if (!result) return COSW_INVALID_PATH;
    *result = NULL;
    if (!parent) return COSW_INVALID_PATH;
    wchar_t *name = NULL;
    int status = utf16(name_utf8, &name);
    if (status) return status;
    if (!relative_valid(name, 1)) { free(name); return COSW_INVALID_PATH; }
    wchar_t *path = child_path(parent, name); free(name);
    if (!path) return COSW_INVALID_PATH;
    PSECURITY_DESCRIPTOR descriptor = private_descriptor(1);
    if (!descriptor) { free(path); return COSW_PRIVATE_ACL_REQUIRED; }
    SECURITY_ATTRIBUTES attributes = {sizeof(SECURITY_ATTRIBUTES), descriptor, FALSE};
    BOOL created = CreateDirectoryW(path, &attributes); DWORD error = GetLastError(); LocalFree(descriptor);
    if (!created) { free(path); return error == ERROR_ALREADY_EXISTS ? COSW_ALREADY_EXISTS : COSW_IO_ERROR; }
    HANDLE directory = open_directory(path); free(path);
    if (directory == INVALID_HANDLE_VALUE) return COSW_IO_ERROR;
    if (!safe_object(directory, 1) || !within_root(parent, directory) || !private_acl(directory)) {
        CloseHandle(directory); return COSW_PRIVATE_ACL_REQUIRED;
    }
    COSWRoot *root = calloc(1, sizeof(COSWRoot));
    if (!root) { CloseHandle(directory); return COSW_IO_ERROR; }
    for (size_t i = 0; i < parent->count; ++i) {
        HANDLE duplicate;
        if (!DuplicateHandle(GetCurrentProcess(), parent->ancestors[i], GetCurrentProcess(), &duplicate, 0, FALSE, DUPLICATE_SAME_ACCESS)) {
            status = COSW_IO_ERROR; goto finish;
        }
        if (!append_handle(root, duplicate)) { CloseHandle(duplicate); status = COSW_IO_ERROR; goto finish; }
    }
    if (!append_handle(root, directory)) { status = COSW_IO_ERROR; goto finish; }
    directory = INVALID_HANDLE_VALUE;
    root->canonical = final_path(root->ancestors[root->count - 1]);
    if (!root->canonical) { status = COSW_IO_ERROR; goto finish; }
    *result = root; root = NULL; status = COSW_OK;
finish:
    if (directory != INVALID_HANDLE_VALUE) CloseHandle(directory);
    cosw_root_close(root); return status;
}

/* Only one direct child in an already verified private directory. These APIs
   never overwrite a file and are not a settings transaction implementation. */
static int private_file(COSWRoot *root, const char *name_utf8, int existing_allowed, HANDLE *result) {
    *result = INVALID_HANDLE_VALUE;
    if (!root) return COSW_INVALID_PATH;
    if (!private_acl(root->ancestors[root->count - 1])) return COSW_PRIVATE_ACL_REQUIRED;
    wchar_t *name = NULL;
    int status = utf16(name_utf8, &name);
    if (status) return status;
    if (!relative_valid(name, 1)) { free(name); return COSW_INVALID_PATH; }
    wchar_t *path = child_path(root, name); free(name);
    if (!path) return COSW_INVALID_PATH;
    PSECURITY_DESCRIPTOR descriptor = private_descriptor(0);
    if (!descriptor) { free(path); return COSW_PRIVATE_ACL_REQUIRED; }
    SECURITY_ATTRIBUTES attributes = {sizeof(SECURITY_ATTRIBUTES), descriptor, FALSE};
    HANDLE file = CreateFileW(path, GENERIC_READ | GENERIC_WRITE | READ_CONTROL, 0, &attributes,
                              CREATE_NEW, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    DWORD error = GetLastError(); LocalFree(descriptor);
    if (file == INVALID_HANDLE_VALUE && error == ERROR_FILE_EXISTS && existing_allowed) {
        file = CreateFileW(path, GENERIC_READ | GENERIC_WRITE | READ_CONTROL, 0, NULL, OPEN_EXISTING,
                           FILE_FLAG_OPEN_REPARSE_POINT, NULL);
        error = GetLastError();
    }
    free(path);
    if (file == INVALID_HANDLE_VALUE) {
        if (error == ERROR_SHARING_VIOLATION || error == ERROR_LOCK_VIOLATION) return COSW_LOCKED;
        if (error == ERROR_FILE_EXISTS || error == ERROR_ALREADY_EXISTS) return COSW_ALREADY_EXISTS;
        return COSW_IO_ERROR;
    }
    if (!safe_object(file, 0) || !within_root(root, file) || !private_acl(file)) {
        CloseHandle(file); return COSW_PRIVATE_ACL_REQUIRED;
    }
    *result = file; return COSW_OK;
}

int32_t cosw_private_write_new(COSWRoot *root, const char *name_utf8, const void *bytes, size_t count) {
    if (!bytes && count) return COSW_INVALID_PATH;
    HANDLE file;
    int status = private_file(root, name_utf8, 0, &file);
    if (status) return status;
    size_t position = 0;
    while (position < count) {
        size_t remaining = count - position;
        DWORD amount = remaining > MAXDWORD ? MAXDWORD : (DWORD)remaining, written = 0;
        if (!WriteFile(file, (const char *)bytes + position, amount, &written, NULL) || !written) { status = COSW_IO_ERROR; break; }
        position += written;
    }
    if (!status && !FlushFileBuffers(file)) status = COSW_IO_ERROR;
    /* On failure a private incomplete file may remain. Do not delete by name
       after closing a handle: it could then identify somebody else's file. */
    CloseHandle(file); return status;
}

int32_t cosw_lock_acquire(COSWRoot *root, const char *name_utf8, COSWLock **result) {
    if (!result) return COSW_INVALID_PATH;
    *result = NULL;
    HANDLE file;
    int status = private_file(root, name_utf8, 1, &file);
    if (status) return status;
    LARGE_INTEGER size;
    if (!GetFileSizeEx(file, &size) || size.QuadPart != 0) { CloseHandle(file); return COSW_UNSAFE_OBJECT; }
    COSWLock *lock = calloc(1, sizeof(COSWLock));
    if (!lock) { CloseHandle(file); return COSW_IO_ERROR; }
    lock->file = file;
    if (!LockFileEx(file, LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY, 0, MAXDWORD, MAXDWORD, &lock->range)) {
        CloseHandle(file); free(lock); return COSW_LOCKED;
    }
    *result = lock; return COSW_OK;
}

void cosw_lock_release(COSWLock *lock) {
    if (!lock) return;
    UnlockFileEx(lock->file, 0, MAXDWORD, MAXDWORD, &lock->range);
    CloseHandle(lock->file); free(lock);
    /* Keep the private empty lock file. Unlinking it permits competing locks. */
}

int32_t cosw_sha256(const void *bytes, size_t count, uint8_t digest[32]) {
    if ((!bytes && count) || !digest) return COSW_INVALID_PATH;
    BCRYPT_ALG_HANDLE algorithm = NULL; BCRYPT_HASH_HANDLE hash = NULL;
    PUCHAR object = NULL; DWORD object_size = 0, received = 0, digest_size = 0;
    int status = COSW_IO_ERROR;
    if (BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, NULL, 0) < 0) goto finish;
    if (BCryptGetProperty(algorithm, BCRYPT_OBJECT_LENGTH, (PUCHAR)&object_size, sizeof(object_size), &received, 0) < 0 || !object_size) goto finish;
    if (BCryptGetProperty(algorithm, BCRYPT_HASH_LENGTH, (PUCHAR)&digest_size, sizeof(digest_size), &received, 0) < 0 || digest_size != 32) goto finish;
    object = calloc(object_size, 1);
    if (!object || BCryptCreateHash(algorithm, &hash, object, object_size, NULL, 0, 0) < 0) goto finish;
    size_t position = 0;
    while (position < count) {
        size_t remaining = count - position;
        ULONG amount = remaining > MAXULONG ? MAXULONG : (ULONG)remaining;
        if (BCryptHashData(hash, (PUCHAR)bytes + position, amount, 0) < 0) goto finish;
        position += amount;
    }
    if (BCryptFinishHash(hash, digest, 32, 0) < 0) goto finish;
    status = COSW_OK;
finish:
    if (hash) BCryptDestroyHash(hash);
    if (object) { SecureZeroMemory(object, object_size); free(object); }
    if (algorithm) BCryptCloseAlgorithmProvider(algorithm, 0);
    if (status) memset(digest, 0, 32);
    return status;
}

#else
/* No Foundation/POSIX fallback on an unimplemented platform. */
int32_t cosw_available(void) { return 0; }
int32_t cosw_root_open(const char *path, COSWRoot **result) { (void)path; if (result) *result = NULL; return COSW_UNAVAILABLE; }
void cosw_root_close(COSWRoot *root) { (void)root; }
int32_t cosw_root_read(COSWRoot *root, const char *path, size_t limit, void **bytes, size_t *count) {
    (void)root; (void)path; (void)limit; if (bytes) *bytes = NULL; if (count) *count = 0; return COSW_UNAVAILABLE;
}
int32_t cosw_private_directory_create(COSWRoot *root, const char *name, COSWRoot **result) {
    (void)root; (void)name; if (result) *result = NULL; return COSW_UNAVAILABLE;
}
int32_t cosw_private_write_new(COSWRoot *root, const char *name, const void *bytes, size_t count) {
    (void)root; (void)name; (void)bytes; (void)count; return COSW_UNAVAILABLE;
}
int32_t cosw_lock_acquire(COSWRoot *root, const char *name, COSWLock **result) {
    (void)root; (void)name; if (result) *result = NULL; return COSW_UNAVAILABLE;
}
void cosw_lock_release(COSWLock *lock) { (void)lock; }
int32_t cosw_sha256(const void *bytes, size_t count, uint8_t digest[32]) {
    (void)bytes; (void)count; if (digest) memset(digest, 0, 32); return COSW_UNAVAILABLE;
}
#endif

void cosw_buffer_free(void *bytes) { free(bytes); }
