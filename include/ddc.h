#ifndef DESK_DDC_H
#define DESK_DDC_H

#include <stdbool.h>
#include <stddef.h>

/* The screen's light on a machine with no backlight of its own: the
 * monitor's, over DDC/CI, by way of ddcutil. Every call to ddcutil takes
 * a tenth of a second to a second, so they are made by a thread of their
 * own and the compositor only ever hands it a number.
 *
 * desk_ddc_start looks for a display that answers (once; it is a thread
 * from then on) and returns a descriptor that is readable whenever there
 * is news -- the display found, or found not to be there; -1 if the
 * thread could not be started. desk_ddc_drain empties it. */
int desk_ddc_start(void);
void desk_ddc_drain(int fd);

/* Whether a display answered, and where its light is, 0..1: as it was
 * read, or as it was last asked to be. */
bool desk_ddc_state(double *v);

/* Turn it to v. Only the latest is sent, a few times a second at most,
 * and never quite to nothing -- the same floor as the backlight's. */
void desk_ddc_set(double v);

#endif
