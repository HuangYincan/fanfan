#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

/* Local builds accept one exact app CodeDirectory hash. The installer writes
 * this policy outside the signed bundle, owned by root and not user-writable.
 * Never fall back to an identifier-only or unauthenticated connection. */
static int load_local_client_policy(const char *path, char *out, size_t capacity)
{
    int fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return -1;
    struct stat st;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_uid != 0 ||
        (st.st_mode & 022) != 0 || st.st_size <= 0 ||
        (uint64_t)st.st_size >= capacity) {
        close(fd);
        return -1;
    }
    size_t used = 0;
    while (used < (size_t)st.st_size) {
        ssize_t n = read(fd, out + used, (size_t)st.st_size - used);
        if (n <= 0) { close(fd); return -1; }
        used += (size_t)n;
    }
    close(fd);
    while (used > 0 && (out[used - 1] == '\n' || out[used - 1] == '\r')) used--;
    if (used == 0) return -1;
    for (size_t i = 0; i < used; i++) {
        if ((unsigned char)out[i] < 32 || (unsigned char)out[i] > 126) return -1;
    }
    out[used] = 0;
    return 0;
}
