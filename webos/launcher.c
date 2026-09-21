/*
 * KOReader launcher for the HP TouchPad.
 *
 * webOS runs a PDK app's `main` binary inside a jail and does NOT run shell scripts, so this small
 * native program does what koreader.sh does on other platforms: set up the environment, then start
 * KOReader's LuaJIT, and start it again when KOReader asks for a restart (exit code 85).
 *
 * It stays alive as a supervisor for three reasons:
 *   - stdout/stderr of a launcher-started app go nowhere, and a file redirect is block-buffered by
 *     the child's C library (so the last lines are lost on a crash). Reading a pipe and flushing
 *     every chunk to the log file gives a complete log.
 *   - it records how the child ended (exit code or fatal signal), which is otherwise invisible.
 *   - KOReader restarts itself (after a DPI change, an update, "Restart KOReader", ...) by exiting
 *     with code 85; koreader.sh loops on that and so do we.
 *
 * What the jail gives us (see webos://knowledge/pdk):
 *   - the install dir is read-only, /media/internal is read-write;
 *   - argv[0] is unreliable, argv[1] is the launch parameter string "{ }".
 */
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define DATA_DIR "/media/internal/koreader"
#define LOG_FILE DATA_DIR "/webos-launcher.log"
/* The previous run's log is kept here, so a quick close-and-reopen doesn't erase what happened. */
#define OLD_LOG_FILE DATA_DIR "/webos-launcher.log.old"
/* The exit code KOReader uses to say "please start me again" (see reader.lua / koreader.sh). */
#define KO_RESTART_CODE 85
/* Safety net: never restart-loop forever if KOReader dies at startup with code 85 every time. */
#define MAX_RESTARTS_PER_MINUTE 5

static int log_fd = -1;
static volatile pid_t child_pid = -1;
static volatile sig_atomic_t terminating = 0;
static volatile sig_atomic_t term_signal = 0;
static struct timeval term_at;

static void logf_(const char *fmt, ...)
{
    char buf[1024];
    va_list ap;
    int n;

    va_start(ap, fmt);
    n = vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    if (n > 0 && log_fd >= 0)
        (void) !write(log_fd, buf, n < (int) sizeof(buf) ? n : (int) sizeof(buf) - 1);
}

/* webOS closing the card sends SIGTERM to us: pass it on so KOReader can save its state,
 * and remember that we were asked to go away so we don't restart it.
 * We never force-kill KOReader: interrupting it while it saves settings or the reading position
 * could lose data, so we always wait for it to exit on its own. */
static void forward_signal(int sig)
{
    if (!terminating) {
        terminating = 1;
        term_signal = sig;
        gettimeofday(&term_at, NULL);
    }
    if (child_pid > 0)
        kill(child_pid, sig);
}

/*
 * Diagnostics (marker file net-probe): can THIS process, the one webOS launched and whose path is bound
 * to the app's Luna permission file, call system services and open a browser through PDL?
 * libpdl is loaded at runtime so the launcher has no build-time dependency on the PDK.
 */
static void pdl_probe(void)
{
    typedef int (*init_fn)(unsigned int);
    typedef int (*call_fn)(const char *, const char *);
    typedef int (*browser_fn)(const char *);
    typedef const char *(*err_fn)(void);
    typedef int (*sdl_init_fn)(unsigned int);
    typedef void *(*sdl_mode_fn)(int, int, int, unsigned int);
    void *pdl = dlopen("libpdl.so", RTLD_NOW | RTLD_GLOBAL);
    void *sdl = dlopen("libSDL-1.2.so.0", RTLD_NOW | RTLD_GLOBAL);
    init_fn pdl_init;
    call_fn pdl_call;
    browser_fn pdl_browser;
    err_fn pdl_err;
    int r;

    if (!pdl || !sdl) {
        logf_("probe: dlopen failed: %s\n", dlerror());
        return;
    }
    pdl_init = (init_fn) dlsym(pdl, "PDL_Init");
    pdl_call = (call_fn) dlsym(pdl, "PDL_ServiceCall");
    pdl_browser = (browser_fn) dlsym(pdl, "PDL_LaunchBrowser");
    pdl_err = (err_fn) dlsym(pdl, "PDL_GetError");
    if (!pdl_init || !pdl_call || !pdl_browser || !pdl_err) {
        logf_("probe: dlsym failed\n");
        return;
    }

    logf_("probe: (launcher process) PDL_Init -> %d\n", pdl_init(0));
    /* 1: no window in this process */
    r = pdl_call("palm://com.palm.applicationManager/open", "{\"id\":\"com.palm.app.calculator\"}");
    logf_("probe: 1 open Calculator (no window) -> %d [%s]\n", r, pdl_err());
    sleep(6);
    r = pdl_browser("http://appcatalog.webosarchive.org/");
    logf_("probe: 2 open browser (no window) -> %d [%s]\n", r, pdl_err());
    sleep(8);

    /* 2: with a window, like a real app */
    {
        sdl_init_fn sdl_init = (sdl_init_fn) dlsym(sdl, "SDL_Init");
        sdl_mode_fn sdl_mode = (sdl_mode_fn) dlsym(sdl, "SDL_SetVideoMode");
        if (sdl_init && sdl_mode) {
            logf_("probe: SDL_Init -> %d, window %s\n", sdl_init(0x20),
                  sdl_mode(1024, 768, 16, 0x80000000u) ? "ok" : "FAILED");
            sleep(1);
            r = pdl_call("palm://com.palm.applicationManager/open", "{\"id\":\"com.palm.app.calculator\"}");
            logf_("probe: 3 open Calculator (with window) -> %d [%s]\n", r, pdl_err());
            sleep(6);
            r = pdl_browser("http://appcatalog.webosarchive.org/");
            logf_("probe: 4 open browser (with window) -> %d [%s]\n", r, pdl_err());
            sleep(8);
        }
    }
}

/*
 * The jail has no /etc, so libc doesn't find /etc/localtime and KOReader would show UTC.
 * webOS keeps the timezone as a symlink /var/luna/preferences/localtime -> /usr/share/zoneinfo/<Zone>,
 * and both of those are visible inside the jail, so turn it into a TZ name for libc.
 */
static void set_timezone(void)
{
    static const char prefix[] = "/usr/share/zoneinfo/";
    char target[PATH_MAX];
    ssize_t n = readlink("/var/luna/preferences/localtime", target, sizeof(target) - 1);

    if (n > 0) {
        target[n] = '\0';
        if (strncmp(target, prefix, sizeof(prefix) - 1) == 0) {
            setenv("TZ", target + sizeof(prefix) - 1, 1);
            logf_("launcher: timezone %s\n", target + sizeof(prefix) - 1);
            return;
        }
    }
    /* Unknown layout: let libc read the file itself. */
    setenv("TZ", ":/var/luna/preferences/localtime", 1);
    logf_("launcher: timezone from /var/luna/preferences/localtime (link not understood)\n");
}

/* Run KOReader once. Returns the wait status, or -1 if it could not be started. */
static int run_koreader(const char *kodir)
{
    int pfd[2];
    int status = 0;
    ssize_t n;
    pid_t pid;

    if (pipe(pfd) != 0) {
        logf_("launcher: pipe failed: %s\n", strerror(errno));
        return -1;
    }

    pid = fork();
    if (pid < 0) {
        logf_("launcher: fork failed: %s\n", strerror(errno));
        return -1;
    }
    if (pid == 0) {
        /* Child: stdout+stderr go into the pipe, then become KOReader. */
        close(pfd[0]);
        dup2(pfd[1], 1);
        dup2(pfd[1], 2);
        if (pfd[1] > 2)
            close(pfd[1]);
        if (chdir(kodir) != 0) {
            fprintf(stderr, "launcher: chdir(%s) failed: %s\n", kodir, strerror(errno));
            _exit(1);
        }
        /* Diagnostics: with this marker file present, run the jail self-test instead of KOReader. */
        if (access(DATA_DIR "/net-probe", F_OK) == 0)
            execl("./luajit", "luajit", "./webos-netprobe.lua", (char *) NULL);
        /* The launch parameter ("{ }") is deliberately not forwarded: KOReader would treat it as a path. */
        execl("./luajit", "luajit", "./reader.lua", "/media/internal", (char *) NULL);
        fprintf(stderr, "launcher: exec ./luajit failed: %s\n", strerror(errno));
        _exit(127);
    }

    /* Parent: relay the child's output to the log, flushing as we go. */
    child_pid = pid;
    close(pfd[1]);
    for (;;) {
        char buf[4096];
        n = read(pfd[0], buf, sizeof(buf));
        if (n > 0) {
            if (log_fd >= 0)
                (void) !write(log_fd, buf, (size_t) n);
        } else if (n == 0) {
            break; /* every writer closed: child (and anything it spawned) is gone */
        } else if (errno != EINTR) {
            break;
        }
    }
    close(pfd[0]);

    while (waitpid(pid, &status, 0) < 0 && errno == EINTR)
        ;
    child_pid = -1;
    if (terminating) {
        struct timeval now;
        gettimeofday(&now, NULL);
        logf_("\nlauncher: signal %d received; luajit gone %ld ms later\n", (int) term_signal,
              (now.tv_sec - term_at.tv_sec) * 1000L + (now.tv_usec - term_at.tv_usec) / 1000L);
    }

    if (WIFEXITED(status))
        logf_("\nlauncher: luajit exited with code %d\n", WEXITSTATUS(status));
    else if (WIFSIGNALED(status))
        logf_("\nlauncher: luajit was killed by signal %d%s\n", WTERMSIG(status),
              WTERMSIG(status) == SIGSEGV ? " (segmentation fault)" : "");
    else
        logf_("\nlauncher: luajit ended, raw status 0x%x\n", status);
    return status;
}

int main(int argc, char **argv)
{
    char exe[PATH_MAX];
    char appdir[PATH_MAX];
    char kodir[PATH_MAX + 16];
    char libs[PATH_MAX + 32];
    ssize_t n;
    char *slash;
    int status = 0;
    int restarts = 0;
    time_t window_start = time(NULL);

    (void) argc;
    (void) argv;

    /* Log and data directories first, so we can report anything that goes wrong afterwards. */
    mkdir(DATA_DIR, 0777);
    rename(LOG_FILE, OLD_LOG_FILE);
    log_fd = open(LOG_FILE, O_WRONLY | O_CREAT | O_TRUNC, 0666);

    /* Find ourselves: argv[0] can't be trusted inside the jail. */
    n = readlink("/proc/self/exe", exe, sizeof(exe) - 1);
    if (n < 0) {
        logf_("launcher: readlink(/proc/self/exe) failed: %s\n", strerror(errno));
        return 1;
    }
    exe[n] = '\0';
    strcpy(appdir, exe);
    slash = strrchr(appdir, '/');
    if (!slash) {
        logf_("launcher: odd exe path '%s'\n", exe);
        return 1;
    }
    *slash = '\0';
    snprintf(kodir, sizeof(kodir), "%s/koreader", appdir);
    snprintf(libs, sizeof(libs), "%s/libs", kodir);

    /* Tells frontend/device.lua that this is a TouchPad (/etc isn't visible in the jail). */
    setenv("KO_WEBOS", "1", 1);
    /* Settings, history, plugins and so on live here (writable, and visible over USB). */
    setenv("KO_HOME", DATA_DIR, 1);
    setenv("HOME", "/media/internal", 1);
    /* Keep the bundled libstdc++ / libgcc_s (the device's are from 2008) ahead of the system ones. */
    setenv("LD_LIBRARY_PATH", libs, 1);

    signal(SIGTERM, forward_signal);
    signal(SIGINT, forward_signal);
    signal(SIGHUP, forward_signal);

    {
        time_t t = time(NULL);
        logf_("launcher: started at unix time %ld\n", (long) t);
    }
    logf_("launcher: exe=%s\nlauncher: cwd=%s\nlauncher: pid=%ld\n", exe, kodir, (long) getpid());

    if (access(DATA_DIR "/net-probe", F_OK) == 0)
        pdl_probe();

    for (;;) {
        set_timezone(); /* every time: the user may have changed it since the last start */
        logf_("launcher: starting luajit\n");
        status = run_koreader(kodir);

        if (status == -1 || terminating)
            break;
        if (!(WIFEXITED(status) && WEXITSTATUS(status) == KO_RESTART_CODE))
            break;

        /* KOReader asked to be restarted. */
        if (time(NULL) - window_start > 60) {
            window_start = time(NULL);
            restarts = 0;
        }
        if (++restarts > MAX_RESTARTS_PER_MINUTE) {
            logf_("launcher: too many restarts in a minute, giving up\n");
            break;
        }
        logf_("launcher: restart requested (exit code %d), starting again\n", KO_RESTART_CODE);
    }

    if (status == -1)
        return 1;
    return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
}
