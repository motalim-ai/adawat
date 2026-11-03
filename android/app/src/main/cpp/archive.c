// Archives for Android, a thin bridge from Kotlin (com.motalim.adawat.ops.ArchiveNative) to libarchive.
#include <jni.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include "archive.h"
#include "archive_entry.h"

#define EXPORT __attribute__((visibility("default")))

static jstring message(JNIEnv *env, const char *text) { return (*env)->NewStringUTF(env, text ? text : "unknown error"); }

static int copy_data(struct archive *in, struct archive *out) {
    const void *buffer;
    size_t size;
    la_int64_t offset;
    for (;;) {
        int r = archive_read_data_block(in, &buffer, &size, &offset);
        if (r == ARCHIVE_EOF) return ARCHIVE_OK;
        if (r < ARCHIVE_WARN) return r;
        r = archive_write_data_block(out, buffer, size, offset);
        if (r < ARCHIVE_WARN) return r;
    }
}

// Unpacks [path] into the folder [dest]. Paths that would leave the folder are refused. A single compressed file
// (.gz, .bz2, .xz with no archive inside) comes out as [single]. Returns null, or what went wrong; "ENCRYPTED" for
// archives that need a password.
EXPORT JNIEXPORT jstring JNICALL
Java_com_motalim_adawat_ops_ArchiveNative_extract(JNIEnv *env, jclass cls, jstring jpath, jstring jdest, jstring jsingle, jstring jpassword) {
    const char *path = (*env)->GetStringUTFChars(env, jpath, NULL);
    const char *dest = (*env)->GetStringUTFChars(env, jdest, NULL);
    const char *single = (*env)->GetStringUTFChars(env, jsingle, NULL);
    const char *password = jpassword ? (*env)->GetStringUTFChars(env, jpassword, NULL) : NULL;
    jstring result = NULL;
    struct archive *in = archive_read_new();
    archive_read_support_filter_all(in);
    archive_read_support_format_all(in);
    archive_read_support_format_raw(in);
    archive_read_set_options(in, "hdrcharset=UTF-8");
    if (password) archive_read_add_passphrase(in, password);
    struct archive *out = archive_write_disk_new();
    // Names are joined to [dest] here, so absolute names are made relative below instead of being refused;
    // ".." and paths through symbolic links are still refused, so nothing lands outside [dest].
    archive_write_disk_set_options(out, ARCHIVE_EXTRACT_TIME | ARCHIVE_EXTRACT_SECURE_NODOTDOT | ARCHIVE_EXTRACT_SECURE_SYMLINKS);
    if (archive_read_open_filename(in, path, 1 << 16) != ARCHIVE_OK) {
        result = message(env, archive_error_string(in));
        goto done;
    }
    char target[4096];
    struct archive_entry *entry;
    int count = 0;
    for (;;) {
        int r = archive_read_next_header(in, &entry);
        if (r == ARCHIVE_EOF) break;
        if (r < ARCHIVE_WARN) { result = message(env, archive_error_string(in)); goto done; }
        if (archive_entry_is_encrypted(entry) && !password) { result = message(env, "ENCRYPTED"); goto done; }
        const char *name = archive_format(in) == ARCHIVE_FORMAT_RAW ? single : archive_entry_pathname(entry);
        while (name && *name == '/') name++;
        if (!name || !*name) continue;
        // The Mac's resource-fork shadows ("._name", "__MACOSX/") are not files anyone wants.
        const char *base = strrchr(name, '/');
        base = base ? base + 1 : name;
        if (strncmp(name, "__MACOSX/", 9) == 0 || strncmp(base, "._", 2) == 0 || strcmp(base, ".DS_Store") == 0) {
            archive_read_data_skip(in);
            continue;
        }
        // A link could point anywhere, such as the app's own data, which saving would then copy out.
        if (archive_entry_filetype(entry) == AE_IFLNK) {
            archive_read_data_skip(in);
            continue;
        }
        snprintf(target, sizeof target, "%s/%s", dest, name);
        archive_entry_set_pathname(entry, target);
        const char *link = archive_entry_hardlink(entry);
        if (link) {
            while (*link == '/') link++;
            char linked[4096];
            snprintf(linked, sizeof linked, "%s/%s", dest, link);
            archive_entry_set_hardlink(entry, linked);
        }
        if (archive_format(in) == ARCHIVE_FORMAT_RAW) archive_entry_set_perm(entry, 0644);
        r = archive_write_header(out, entry);
        if (r < ARCHIVE_WARN) { result = message(env, archive_error_string(out)); goto done; }
        if (archive_entry_size(entry) != 0 || archive_entry_size_is_set(entry) == 0) {
            r = copy_data(in, out);
            if (r < ARCHIVE_WARN) {
                const char *why = archive_error_string(in) ? archive_error_string(in) : archive_error_string(out);
                result = message(env, why && strstr(why, "assphrase") ? "ENCRYPTED" : why);
                goto done;
            }
        }
        archive_write_finish_entry(out);
        count++;
    }
    if (count == 0) result = message(env, "EMPTY");
done:
    archive_read_free(in);
    archive_write_free(out);
    (*env)->ReleaseStringUTFChars(env, jpath, path);
    (*env)->ReleaseStringUTFChars(env, jdest, dest);
    (*env)->ReleaseStringUTFChars(env, jsingle, single);
    if (password) (*env)->ReleaseStringUTFChars(env, jpassword, password);
    return result;
}

// Writes [output] as "zip", "tar" or "tgz" from files and folders on disk, each under its name in the archive.
// Folders are listed by the caller, one entry per file and folder. Returns null, or what went wrong.
EXPORT JNIEXPORT jstring JNICALL
Java_com_motalim_adawat_ops_ArchiveNative_create(JNIEnv *env, jclass cls, jstring joutput, jstring jformat, jobjectArray jpaths, jobjectArray jnames) {
    const char *output = (*env)->GetStringUTFChars(env, joutput, NULL);
    const char *format = (*env)->GetStringUTFChars(env, jformat, NULL);
    jstring result = NULL;
    struct archive *out = archive_write_new();
    if (strcmp(format, "zip") == 0) {
        archive_write_set_format_zip(out);
        archive_write_set_options(out, "zip:hdrcharset=UTF-8");
    } else {
        archive_write_set_format_pax_restricted(out);
        if (strcmp(format, "tgz") == 0) archive_write_add_filter_gzip(out);
    }
    if (archive_write_open_filename(out, output) != ARCHIVE_OK) {
        result = message(env, archive_error_string(out));
        goto done;
    }
    jsize count = (*env)->GetArrayLength(env, jpaths);
    char buffer[1 << 16];
    for (jsize i = 0; i < count && !result; i++) {
        jstring jp = (*env)->GetObjectArrayElement(env, jpaths, i);
        jstring jn = (*env)->GetObjectArrayElement(env, jnames, i);
        const char *p = (*env)->GetStringUTFChars(env, jp, NULL);
        const char *n = (*env)->GetStringUTFChars(env, jn, NULL);
        struct stat st;
        if (stat(p, &st) != 0) {
            result = message(env, strerror(errno));
        } else {
            struct archive_entry *entry = archive_entry_new();
            archive_entry_set_pathname(entry, n);
            archive_entry_set_mtime(entry, st.st_mtime, 0);
            if (S_ISDIR(st.st_mode)) {
                archive_entry_set_filetype(entry, AE_IFDIR);
                archive_entry_set_perm(entry, 0755);
                if (archive_write_header(out, entry) < ARCHIVE_WARN) result = message(env, archive_error_string(out));
            } else {
                archive_entry_set_filetype(entry, AE_IFREG);
                archive_entry_set_perm(entry, 0644);
                archive_entry_set_size(entry, st.st_size);
                if (archive_write_header(out, entry) < ARCHIVE_WARN) result = message(env, archive_error_string(out));
                else {
                    int fd = open(p, O_RDONLY);
                    if (fd < 0) result = message(env, strerror(errno));
                    else {
                        ssize_t got;
                        while ((got = read(fd, buffer, sizeof buffer)) > 0) {
                            if (archive_write_data(out, buffer, (size_t) got) < 0) { result = message(env, archive_error_string(out)); break; }
                        }
                        close(fd);
                    }
                }
            }
            archive_entry_free(entry);
        }
        (*env)->ReleaseStringUTFChars(env, jp, p);
        (*env)->ReleaseStringUTFChars(env, jn, n);
        (*env)->DeleteLocalRef(env, jp);
        (*env)->DeleteLocalRef(env, jn);
    }
    if (archive_write_close(out) != ARCHIVE_OK && !result) result = message(env, archive_error_string(out));
done:
    archive_write_free(out);
    (*env)->ReleaseStringUTFChars(env, joutput, output);
    (*env)->ReleaseStringUTFChars(env, jformat, format);
    return result;
}
