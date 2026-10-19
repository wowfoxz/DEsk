#ifndef DESK_DOORGPU_H
#define DESK_DOORGPU_H

#include <stdbool.h>
#include <stddef.h>

/* The front door (the screen lock), traced on the GPU.
 *
 * draw.c's door is a ray tracer, and on the CPU it can only keep up by
 * tracing a moving frame at a fraction of the screen and the fine one
 * later, on the side. Here the same scene (door.glsl, a line for line port
 * of it) is a fragment program, and every frame is the fine one at the
 * screen's own size: a sample a pixel, four where what a pixel shows
 * changes, the glow and the vignette, dithered to bytes.
 *
 * It has a thread of its own, holding an offscreen GLES context (gpu.h's
 * desk_gpu_open) for as long as the process runs, so the compositor's own
 * context on the main thread is never touched. The programs are compiled
 * there as soon as it is started; until they are, and if they fail, the
 * CPU tracer draws the door as before. A frame is asked for with
 * door_gpu_render, which waits for it: the scene as uniforms, the pictures
 * that go on things as textures (uploaded once, and again only when they
 * change), and the answer read straight back into a cairo ARGB32 surface. */

struct desk_gpu;

#define DOOR_GPU_PASSES 7     /* door.glsl's DOOR_PASS 0 .. 6 */
#define DOOR_GPU_TEX 7          /* sign, gold, plate, picture, the room's three */

struct door_gpu_tex {
	const unsigned char *px;     /* cairo's ARGB32, or A8; NULL for none */
	int w, h, stride;
	bool a8;
};

struct door_gpu_uniform {
	char name[24];
	bool is_int;
	int comps, count, off;       /* into f[] or i[] */
};

#define DOOR_GPU_MAX_U 112
#define DOOR_GPU_MAX_F 1024
#define DOOR_GPU_MAX_I 96

/* One frame of the door: its size, how much glow and vignette (lk_post's
 * amount), the pictures, and every uniform of door.glsl's trace by name. */
struct door_gpu_frame {
	int w, h;
	float post;
	struct door_gpu_tex tex[DOOR_GPU_TEX];
	int nu, nf, ni;
	bool full;                   /* ran out of room for a uniform */
	struct door_gpu_uniform u[DOOR_GPU_MAX_U];
	float f[DOOR_GPU_MAX_F];
	int i[DOOR_GPU_MAX_I];
};

void door_gpu_frame_init(struct door_gpu_frame *fr, int w, int h, float post);
/* a float uniform of comps components (1 to 4), count of them (an array) */
void door_gpu_f(struct door_gpu_frame *fr, const char *name, int comps, int count, const float *v);
void door_gpu_i(struct door_gpu_frame *fr, const char *name, int count, const int *v);

enum { DOOR_GPU_DEAD = -1, DOOR_GPU_OFF = 0, DOOR_GPU_BUSY = 1, DOOR_GPU_READY = 2 };

/* Start the thread with the programs' sources (DOOR_GPU_PASSES of them,
 * malloc'd: they become its, and are freed once compiled; the second is
 * not used -- the trace's two stages are one program -- and may be NULL). ok, if given,
 * is asked on that thread with the GPU open whether to go on with it at
 * all (a software rasterizer, a driver known to fall over), and says why
 * not. False if it was started already. */
bool door_gpu_start(char *src[DOOR_GPU_PASSES], bool (*ok)(struct desk_gpu *g, char *why,
	size_t whysz));
int door_gpu_state(void);
/* wait up to secs for it to be ready or dead; true if it is ready */
bool door_gpu_wait(double secs);
/* what it is running on, once open; why it is dead, once dead */
const char *door_gpu_name(void);
const char *door_gpu_why(void);

/* Trace a frame, fr->w x fr->h, into dst (cairo ARGB32, stride bytes a
 * row). Waits for it. False if it could not: the CPU then draws it, and a
 * GL error on the way leaves the GPU path dead for the rest of the run.
 * ms, if given, is how long the GPU took, upload and read back included. */
bool door_gpu_render(const struct door_gpu_frame *fr, unsigned char *dst, int stride, double *ms);

#endif
