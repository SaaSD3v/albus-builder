#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#define WCNSS_CTRL "/dev/wcnss_ctrl"
#define WCNSS_DEVICE "/dev/wcnss_wlan"
#define CAL_FILE "/tmp/albus-wifi/WCNSS_qcom_wlan_cal.bin"
#define READY_FILE "/tmp/albus-wifi/wcnss.opened"
#define CAL_CHUNK (3 * 1024)
#define WCNSS_USR_HAS_CAL_DATA 2

static int wait_open(const char *path, int flags, int seconds)
{
    int fd;
    while (seconds-- >= 0) {
        fd = open(path, flags);
        if (fd >= 0)
            return fd;
        if (errno != ENOENT && errno != ENXIO && errno != EAGAIN)
            break;
        sleep(1);
    }
    return -1;
}

static int send_cal_state(int has_cal)
{
    unsigned char msg[3];
    int fd = wait_open(WCNSS_CTRL, O_WRONLY, 8);
    if (fd < 0) {
        fprintf(stderr, "wcnss-recovery-albus: cannot open %s: %s\n",
                WCNSS_CTRL, strerror(errno));
        return -1;
    }

    msg[0] = (WCNSS_USR_HAS_CAL_DATA >> 8) & 0xff;
    msg[1] = WCNSS_USR_HAS_CAL_DATA & 0xff;
    msg[2] = has_cal ? 1 : 0;

    /*
     * Albus 3.18 wcnss_ctrl_write() returns copy_from_user()'s result.
     * Therefore a successful 3-byte control command returns 0, while
     * related Qualcomm trees can return count. Accept both.
     */
    ssize_t wr = write(fd, msg, sizeof(msg));
    if (wr != 0 && wr != (ssize_t)sizeof(msg)) {
        fprintf(stderr,
                "wcnss-recovery-albus: write %s failed: rc=%zd errno=%s\n",
                WCNSS_CTRL, wr, strerror(errno));
        close(fd);
        return -1;
    }

    close(fd);
    return 0;
}

static int write_cal_to_device(int fd_dev, const char *path)
{
    struct stat st;
    int fd;
    uint32_t size;
    char buf[CAL_CHUNK];
    ssize_t n;

    if (stat(path, &st) < 0 || st.st_size <= 0 || st.st_size > 64 * 1024)
        return -1;

    fd = open(path, O_RDONLY);
    if (fd < 0)
        return -1;

    size = (uint32_t)st.st_size;
    if (write(fd_dev, &size, sizeof(size)) != (ssize_t)sizeof(size)) {
        close(fd);
        return -1;
    }

    while ((n = read(fd, buf, sizeof(buf))) > 0) {
        char *p = buf;
        ssize_t left = n;
        while (left > 0) {
            ssize_t w = write(fd_dev, p, (size_t)left);
            if (w <= 0) {
                close(fd);
                return -1;
            }
            p += w;
            left -= w;
        }
    }

    close(fd);
    return n < 0 ? -1 : 0;
}

static void cal_alarm_handler(int signo)
{
    (void)signo;
}

static void collect_runtime_cal(int fd_dev)
{
    struct sigaction sa;
    struct sigaction old_sa;
    int out = -1;
    int idle_rounds = 0;
    char buf[CAL_CHUNK];

    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = cal_alarm_handler;
    sigemptyset(&sa.sa_mask);

    if (sigaction(SIGALRM, &sa, &old_sa) < 0)
        return;

    /*
     * Albus' wcnss_wlan node uses wait_event_interruptible() and has no
     * useful poll() path for this userspace flow. Interrupt idle reads with
     * SIGALRM so the recovery helper cannot remain blocked forever.
     */
    for (;;) {
        ssize_t n;
        int saved_errno;

        alarm(1);
        n = read(fd_dev, buf, sizeof(buf));
        saved_errno = errno;
        alarm(0);

        if (n < 0 && (saved_errno == EINTR || saved_errno == EAGAIN)) {
            if (++idle_rounds >= 20)
                break;
            continue;
        }
        if (n <= 0)
            break;

        idle_rounds = 0;
        if (out < 0) {
            out = open(CAL_FILE, O_WRONLY | O_CREAT | O_TRUNC, 0600);
            if (out < 0)
                break;
        }

        if (write(out, buf, (size_t)n) != n)
            break;
    }

    alarm(0);
    sigaction(SIGALRM, &old_sa, NULL);
    if (out >= 0)
        close(out);
}

int main(void)
{
    struct stat st;
    int has_cal = (stat(CAL_FILE, &st) == 0 && st.st_size > 0);

    fprintf(stderr, "wcnss-recovery-albus: signaling has_cal=%d\n", has_cal);

    if (send_cal_state(has_cal) < 0)
        return 1;

    /*
     * In the pinned Albus 3.18 kernel, open(/dev/wcnss_wlan) invokes
     * wcnss_node_open(), which synchronously calls wcnss_trigger_config()
     * and subsystem_get("wcnss") when the built-in WCNSS driver has not
     * been triggered yet.
     */
    int fd_dev = wait_open(WCNSS_DEVICE, O_RDWR | O_NONBLOCK, 8);
    if (fd_dev < 0) {
        fprintf(stderr, "wcnss-recovery-albus: cannot open %s: %s\n",
                WCNSS_DEVICE, strerror(errno));
        return 1;
    }

    int ready = open(READY_FILE, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (ready >= 0) {
        static const char one[] = "1\n";
        (void)write(ready, one, sizeof(one) - 1);
        close(ready);
    }

    if (has_cal) {
        int flags = fcntl(fd_dev, F_GETFL, 0);
        if (flags >= 0)
            fcntl(fd_dev, F_SETFL, flags & ~O_NONBLOCK);

        if (write_cal_to_device(fd_dev, CAL_FILE) < 0)
            fprintf(stderr,
                    "wcnss-recovery-albus: cached calibration write failed\n");

        if (flags >= 0)
            fcntl(fd_dev, F_SETFL, flags | O_NONBLOCK);
    }

    collect_runtime_cal(fd_dev);
    close(fd_dev);
    return 0;
}
