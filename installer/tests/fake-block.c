/* Only the two sandbox placeholders look like block devices. No device is opened. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <string.h>
#include <sys/stat.h>

int stat(const char *path, struct stat *buf) {
    int (*real_stat)(const char *, struct stat *) = dlsym(RTLD_NEXT, "stat");
    int rc = real_stat(path, buf);
    if (rc == 0 && (!strcmp(path, "/dev/vda1") || !strcmp(path, "/dev/vda2")))
        buf->st_mode = (buf->st_mode & ~S_IFMT) | S_IFBLK;
    return rc;
}
