/* The monitor's own light, over DDC/CI (ddc.h). ddcutil does the talking;
 * this is the thread that waits for it. */
#define _GNU_SOURCE
#include "ddc.h"

#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/eventfd.h>
#include <time.h>
#include <unistd.h>
#include <stdint.h>
#include <wlr/util/log.h>

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_wake = PTHREAD_COND_INITIALIZER;
static bool g_ok;           /* a display answered */
static int g_bus = -1;
static int g_max = 100;
static double g_value = 1.0;
static bool g_pending;      /* a value waiting to be sent */
static double g_want;
static int g_fd = -1;

static void tell(void)
{
	uint64_t one = 1;
	if (g_fd >= 0 && write(g_fd, &one, sizeof one) < 0) {
		/* full: it has news enough already */
	}
}

/* the first display ddcutil finds that it can speak to: its bus, and a
 * name for the log */
static bool find_display(int *bus, char *name, size_t n)
{
	FILE *p = popen("ddcutil detect --brief 2>/dev/null", "re");
	if (!p) {
		return false;
	}
	char line[512];
	int found = -1;
	name[0] = '\0';
	while (fgets(line, sizeof line, p)) {
		const char *s;
		if (found < 0 && (s = strstr(line, "/dev/i2c-"))) {
			found = atoi(s + 9);
		} else if (found >= 0 && !name[0] && (s = strstr(line, "Monitor:"))) {
			/* MFG:model:serial -- the model is what anyone calls it */
			s += 8;
			while (*s == ' ' || *s == '\t') {
				s++;
			}
			const char *a = strchr(s, ':');
			const char *m = a ? a + 1 : s;
			size_t len = strcspn(m, ":\n");
			if (len >= n) {
				len = n - 1;
			}
			memcpy(name, m, len);
			name[len] = '\0';
		} else if (found >= 0 && strncmp(line, "Invalid display", 15) == 0) {
			break;
		}
	}
	pclose(p);
	if (found < 0) {
		return false;
	}
	if (!name[0]) {
		snprintf(name, n, "a display");
	}
	*bus = found;
	return true;
}

/* "VCP 10 C 80 100": brightness now, and its scale */
static bool read_brightness(int bus, int *now, int *max)
{
	char cmd[96];
	snprintf(cmd, sizeof cmd, "ddcutil --bus %d getvcp 10 --brief 2>/dev/null", bus);
	FILE *p = popen(cmd, "re");
	if (!p) {
		return false;
	}
	char line[256];
	bool ok = false;
	while (fgets(line, sizeof line, p)) {
		int a, b;
		if (sscanf(line, "VCP 10 C %d %d", &a, &b) == 2 && b > 0) {
			*now = a;
			*max = b;
			ok = true;
		}
	}
	pclose(p);
	return ok;
}

static bool write_brightness(int bus, int raw)
{
	char cmd[96];
	snprintf(cmd, sizeof cmd, "ddcutil --bus %d setvcp 10 %d >/dev/null 2>&1", bus, raw);
	FILE *p = popen(cmd, "re");
	if (!p) {
		return false;
	}
	return pclose(p) == 0;
}

static void *ddc_thread(void *arg)
{
	(void)arg;
	char name[128];
	int bus, now = 0, max = 100;
	if (!find_display(&bus, name, sizeof name) || !read_brightness(bus, &now, &max)) {
		wlr_log(WLR_INFO, "the screen's light: no backlight, and no display "
			"answering over DDC/CI -- the fader stays where it is");
		tell();
		return NULL;
	}
	pthread_mutex_lock(&g_lock);
	g_bus = bus;
	g_max = max;
	if (!g_pending) {
		g_value = (double)now / max;
	}
	g_ok = true;
	pthread_mutex_unlock(&g_lock);
	wlr_log(WLR_INFO, "the screen's light: %s over DDC/CI (bus %d), at %d%%",
		name, bus, (int)lround(100.0 * now / max));
	tell();
	bool said = false;
	for (;;) {
		pthread_mutex_lock(&g_lock);
		while (!g_pending) {
			pthread_cond_wait(&g_wake, &g_lock);
		}
		double v = g_want;
		g_pending = false;
		pthread_mutex_unlock(&g_lock);
		/* the backlight's floor: never quite to nothing */
		int low = (int)fmax(1.0, ceil(max * 0.01));
		int raw = (int)fmax(low, lround(v * max));
		if (!write_brightness(bus, raw) && !said) {
			said = true;
			wlr_log(WLR_ERROR, "the screen's light would not turn: %s on bus %d "
				"did not take it", name, bus);
		}
		/* and a breath before the next, so a hand running the fader along
		 * is a few turns a second; whatever came in meanwhile is the next */
		struct timespec ts = { 0, 200 * 1000 * 1000 };
		nanosleep(&ts, NULL);
	}
	return NULL;
}

int desk_ddc_start(void)
{
	if (g_fd >= 0) {
		return g_fd;
	}
	g_fd = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
	if (g_fd < 0) {
		return -1;
	}
	pthread_t t;
	pthread_attr_t at;
	pthread_attr_init(&at);
	pthread_attr_setdetachstate(&at, PTHREAD_CREATE_DETACHED);
	int r = pthread_create(&t, &at, ddc_thread, NULL);
	pthread_attr_destroy(&at);
	if (r != 0) {
		close(g_fd);
		g_fd = -1;
		return -1;
	}
	return g_fd;
}

void desk_ddc_drain(int fd)
{
	uint64_t n;
	while (read(fd, &n, sizeof n) > 0) {
	}
}

bool desk_ddc_state(double *v)
{
	pthread_mutex_lock(&g_lock);
	bool ok = g_ok;
	if (v) {
		*v = g_value;
	}
	pthread_mutex_unlock(&g_lock);
	return ok;
}

void desk_ddc_set(double v)
{
	v = v < 0.0 ? 0.0 : (v > 1.0 ? 1.0 : v);
	pthread_mutex_lock(&g_lock);
	g_want = v;
	g_value = v;
	g_pending = true;
	pthread_cond_signal(&g_wake);
	pthread_mutex_unlock(&g_lock);
}
