#pragma once

#include <stdbool.h>
#include <time.h>

#include "desk.h"

struct wl_event_loop;

/* What day it is, and what it is like out at the front door (occasion.c).
 *
 * Christmas (the 24th and 25th of December), the New Year (its first three
 * days) and the birthday set in Shell Settings dress the front door for
 * them, and the desk does a little something at login. Where the house is
 * comes from the time zone -- the city it is named after, in the system's
 * zone1970.tab -- and from that, where the sun is and, if the weather is
 * wanted, what the sky is doing there: asked of open-meteo.com every half
 * hour (with curl, or wget), on a thread of its own, and never anything
 * but the time zone city's latitude and longitude.
 *
 * For the tests: DESK_TODAY=2026-12-31T23:59:50 sets the clock it goes
 * by (the date alone is midday), DESK_WEATHER=rain[:0.8] the weather. */

enum {
	DESK_OCC_XMAS = 1,
	DESK_OCC_NEWYEAR = 2,
	DESK_OCC_BIRTHDAY = 4,
};

struct desk_occasion_conf {
	int bday_month, bday_day;    /* 0: none set */
	bool celebrations;           /* the door dressed, and the shows */
	bool weather;                /* ask for the weather */
	bool have_loc;               /* location set in shell.conf */
	double lat, lon;             /* where the house is, if so */
};

/* changed(data) on the compositor's loop when the weather comes in */
void desk_occasion_init(struct wl_event_loop *loop, void (*changed)(void *data), void *data);
void desk_occasion_conf(const struct desk_occasion_conf *c);
/* now, by the clock occasions go by */
time_t desk_occasion_now(void);
/* what today is (DESK_OCC_*), with celebrations on; 0 otherwise */
unsigned desk_occasion_today(void);
/* the door, as it is out there now */
void desk_occasion_mood(struct desk_door_mood *m);
/* once in a while: ask for the weather again if it is old */
void desk_occasion_tick(void);
/* the weather as last heard, for the clock */
void desk_occasion_weather_now(struct desk_wx_now *out);
