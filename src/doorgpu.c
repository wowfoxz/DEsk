/* The front door on the GPU: the thread, its context, and the passes.
 * What and why is in doorgpu.h; the scene is door.glsl, and what goes in
 * it is draw.c's (desk_draw_lock). */

#include "doorgpu.h"
#include "gpu.h"

#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <GLES3/gl3.h>

/* ---- the frame, as the caller fills it in ---- */

void door_gpu_frame_init(struct door_gpu_frame *fr, int w, int h, float post)
{
	memset(fr, 0, sizeof *fr);
	fr->w = w;
	fr->h = h;
	fr->post = post;
}

static struct door_gpu_uniform *frame_add(struct door_gpu_frame *fr, const char *name, bool is_int,
	int comps, int count)
{
	int need = comps * count;
	if (fr->nu >= DOOR_GPU_MAX_U || strlen(name) >= sizeof fr->u[0].name
		|| (is_int ? fr->ni + need > DOOR_GPU_MAX_I : fr->nf + need > DOOR_GPU_MAX_F)) {
		fr->full = true;
		return NULL;
	}
	struct door_gpu_uniform *u = &fr->u[fr->nu++];
	snprintf(u->name, sizeof u->name, "%s", name);
	u->is_int = is_int;
	u->comps = comps;
	u->count = count;
	u->off = is_int ? fr->ni : fr->nf;
	if (is_int) {
		fr->ni += need;
	} else {
		fr->nf += need;
	}
	return u;
}

void door_gpu_f(struct door_gpu_frame *fr, const char *name, int comps, int count, const float *v)
{
	struct door_gpu_uniform *u = frame_add(fr, name, false, comps, count);
	if (u) {
		memcpy(fr->f + u->off, v, sizeof(float) * comps * count);
	}
}

void door_gpu_i(struct door_gpu_frame *fr, const char *name, int count, const int *v)
{
	struct door_gpu_uniform *u = frame_add(fr, name, true, 1, count);
	if (u) {
		memcpy(fr->i + u->off, v, sizeof(int) * count);
	}
}

/* ---- the thread ---- */

static const char *VERT_SRC =
	"#version 300 es\n"
	"void main() {\n"
	"  vec2 p = vec2((gl_VertexID << 1) & 2, gl_VertexID & 2);\n"
	"  gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);\n"
	"}\n";

/* the samplers of the trace, on units 2 .. 8 (u_in0 and u_in1 are 0 and 1) */
static const char *TEX_NAME[DOOR_GPU_TEX] = {
	"u_tsign", "u_tgold", "u_tplate", "u_tpic", "u_tpj0", "u_tpj1", "u_tpj2",
};

struct kept_tex {
	GLuint id;
	const unsigned char *px;
	int w, h, stride;
	bool a8;
	uint64_t sum;
};

static struct {
	pthread_mutex_t lock;
	pthread_cond_t cond;
	pthread_t th;
	int state;
	char name[192];
	char why[512];
	char *src[DOOR_GPU_PASSES];
	bool (*ok)(struct desk_gpu *g, char *why, size_t whysz);
	/* the job in hand: one at a time, the caller waiting for it */
	const struct door_gpu_frame *job;
	unsigned char *dst;
	int stride;
	bool job_ok, job_done;
	double job_ms;
	/* the thread's own */
	struct desk_gpu *g;
	GLuint prog[DOOR_GPU_PASSES];
	GLuint vao, fbo, efbo, dummy;
	GLuint full[2], quarter[2], out, depth;
	int fw, fh;
	struct kept_tex tex[DOOR_GPU_TEX];
} D = {
	.lock = PTHREAD_MUTEX_INITIALIZER,
	.cond = PTHREAD_COND_INITIALIZER,
};

static double now_s(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec * 1e-9;
}

static bool compile(GLuint sh, const char *src, char *err, size_t errsz)
{
	glShaderSource(sh, 1, &src, NULL);
	glCompileShader(sh);
	GLint ok = 0;
	glGetShaderiv(sh, GL_COMPILE_STATUS, &ok);
	if (!ok && err && errsz) {
		GLsizei n = 0;
		glGetShaderInfoLog(sh, (GLsizei)errsz - 1, &n, err);
		err[n < (GLsizei)errsz ? n : (GLsizei)errsz - 1] = '\0';
	}
	return ok != 0;
}

static GLuint link_prog(const char *frag, char *err, size_t errsz)
{
	GLuint vs = glCreateShader(GL_VERTEX_SHADER), fs = glCreateShader(GL_FRAGMENT_SHADER);
	GLuint prog = 0;
	if (compile(vs, VERT_SRC, err, errsz) && compile(fs, frag, err, errsz)) {
		prog = glCreateProgram();
		glAttachShader(prog, vs);
		glAttachShader(prog, fs);
		glLinkProgram(prog);
		GLint linked = 0;
		glGetProgramiv(prog, GL_LINK_STATUS, &linked);
		if (!linked) {
			GLsizei n = 0;
			glGetProgramInfoLog(prog, (GLsizei)errsz - 1, &n, err);
			err[n < (GLsizei)errsz ? n : (GLsizei)errsz - 1] = '\0';
			glDeleteProgram(prog);
			prog = 0;
		}
	}
	glDeleteShader(vs);
	glDeleteShader(fs);
	if (prog) {
		glUseProgram(prog);
		GLint loc = glGetUniformLocation(prog, "u_in0");
		if (loc >= 0) {
			glUniform1i(loc, 0);
		}
		loc = glGetUniformLocation(prog, "u_in1");
		if (loc >= 0) {
			glUniform1i(loc, 1);
		}
		for (int i = 0; i < DOOR_GPU_TEX; i++) {
			loc = glGetUniformLocation(prog, TEX_NAME[i]);
			if (loc >= 0) {
				glUniform1i(loc, 2 + i);
			}
		}
	}
	return prog;
}

static GLuint make_tex(GLenum ifmt, GLenum fmt, GLenum type, int w, int h)
{
	GLuint t;
	glGenTextures(1, &t);
	glBindTexture(GL_TEXTURE_2D, t);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
	glTexImage2D(GL_TEXTURE_2D, 0, (GLint)ifmt, w, h, 0, fmt, type, NULL);
	return t;
}

static void drop_targets(void)
{
	GLuint all[5] = { D.full[0], D.full[1], D.quarter[0], D.quarter[1], D.out };
	glDeleteTextures(5, all);
	glDeleteRenderbuffers(1, &D.depth);
	D.depth = 0;
	memset(D.full, 0, sizeof D.full);
	memset(D.quarter, 0, sizeof D.quarter);
	D.out = 0;
	D.fw = D.fh = 0;
}

/* the frame's own textures, for a w x h frame */
static void targets(int w, int h)
{
	if (D.fw == w && D.fh == h) {
		return;
	}
	drop_targets();
	int qw = (w + 3) / 4, qh = (h + 3) / 4;
	for (int i = 0; i < 2; i++) {
		D.full[i] = make_tex(GL_RGBA16F, GL_RGBA, GL_HALF_FLOAT, w, h);
		D.quarter[i] = make_tex(GL_RGBA16F, GL_RGBA, GL_HALF_FLOAT, qw, qh);
	}
	D.out = make_tex(GL_RGBA8, GL_RGBA, GL_UNSIGNED_BYTE, w, h);
	/* the edges' marks (pass 6), on a framebuffer of their own */
	glGenRenderbuffers(1, &D.depth);
	glBindRenderbuffer(GL_RENDERBUFFER, D.depth);
	glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT16, w, h);
	glBindFramebuffer(GL_FRAMEBUFFER, D.efbo);
	glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, D.depth);
	D.fw = w;
	D.fh = h;
}

/* a cheap look at whether a picture is still the one uploaded: a word in
 * every so many, and the corners */
static uint64_t tex_sum(const struct door_gpu_tex *t)
{
	uint64_t h = 1469598103934665603ull;
	size_t bpp = t->a8 ? 1 : 4, row = (size_t)t->w * bpp;
	for (int y = 0; y < t->h; y += (y + 1 < t->h && t->h > 64) ? 7 : 1) {
		const unsigned char *r = t->px + (size_t)y * t->stride;
		for (size_t x = (size_t)(y % 13); x + 4 <= row; x += 52) {
			uint32_t v;
			memcpy(&v, r + x, 4);
			h = (h ^ v) * 1099511628211ull;
		}
		uint32_t e;
		if (row >= 4) {
			memcpy(&e, r + row - 4, 4);
			h = (h ^ e) * 1099511628211ull;
		}
	}
	return h;
}

static void upload(int i, const struct door_gpu_tex *t)
{
	struct kept_tex *k = &D.tex[i];
	if (!t->px || t->w < 1 || t->h < 1) {
		return;
	}
	uint64_t sum = tex_sum(t);
	if (k->id && k->px == t->px && k->w == t->w && k->h == t->h && k->stride == t->stride
		&& k->a8 == t->a8 && k->sum == sum) {
		return;
	}
	if (!k->id) {
		glGenTextures(1, &k->id);
	}
	glBindTexture(GL_TEXTURE_2D, k->id);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
	glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
	glPixelStorei(GL_UNPACK_ROW_LENGTH, t->stride / (t->a8 ? 1 : 4));
	/* the bytes as they lie: B, G, R, A in a texel of an ARGB32 picture */
	if (t->a8) {
		glTexImage2D(GL_TEXTURE_2D, 0, GL_R8, t->w, t->h, 0, GL_RED, GL_UNSIGNED_BYTE, t->px);
	} else {
		glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, t->w, t->h, 0, GL_RGBA, GL_UNSIGNED_BYTE, t->px);
	}
	glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
	k->px = t->px;
	k->w = t->w;
	k->h = t->h;
	k->stride = t->stride;
	k->a8 = t->a8;
	k->sum = sum;
}

static void set_uniforms(GLuint prog, const struct door_gpu_frame *fr)
{
	for (int i = 0; i < fr->nu; i++) {
		const struct door_gpu_uniform *u = &fr->u[i];
		GLint loc = glGetUniformLocation(prog, u->name);
		if (loc < 0) {
			continue;
		}
		if (u->is_int) {
			glUniform1iv(loc, u->count, fr->i + u->off);
			continue;
		}
		const float *v = fr->f + u->off;
		switch (u->comps) {
		case 1: glUniform1fv(loc, u->count, v); break;
		case 2: glUniform2fv(loc, u->count, v); break;
		case 3: glUniform3fv(loc, u->count, v); break;
		default: glUniform4fv(loc, u->count, v); break;
		}
	}
}

/* one pass over a w x h target, in bands of rows so that no single draw
 * is long enough for a watchdog to call it hung */
static bool pass(int p, GLuint in0, GLuint in1, GLuint out, int w, int h, int band)
{
	glBindFramebuffer(GL_FRAMEBUFFER, p == 1 || p == 6 ? D.efbo : D.fbo);
	glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, out, 0);
	if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
		snprintf(D.why, sizeof D.why, "pass %d: its target is not complete", p);
		return false;
	}
	glUseProgram(D.prog[p]);
	if (p <= 1) {
		glUniform1i(glGetUniformLocation(D.prog[p], "u_stage"), p);
	}
	glActiveTexture(GL_TEXTURE0);
	glBindTexture(GL_TEXTURE_2D, in0);
	glActiveTexture(GL_TEXTURE1);
	glBindTexture(GL_TEXTURE_2D, in1 ? in1 : D.dummy);
	GLint loc = glGetUniformLocation(D.prog[p], "u_res");
	if (loc >= 0) {
		glUniform2f(loc, (float)D.fw, (float)D.fh);
	}
	glViewport(0, 0, w, h);
	if (band <= 0 || band >= h) {
		glDrawArrays(GL_TRIANGLES, 0, 3);
	} else {
		glEnable(GL_SCISSOR_TEST);
		for (int y = 0; y < h; y += band) {
			glScissor(0, y, w, y + band > h ? h - y : band);
			glDrawArrays(GL_TRIANGLES, 0, 3);
			glFlush();
		}
		glDisable(GL_SCISSOR_TEST);
	}
	return true;
}

/* DESK_DOOR_PROFILE=1: each stage of a frame waited for and timed, to
 * stderr (which makes the frame itself a little slower) */
static double prof_t;
static char prof_line[256];

static void prof(const char *what)
{
	if (!getenv("DESK_DOOR_PROFILE")) {
		return;
	}
	glFinish();
	double t = now_s();
	size_t n = strlen(prof_line);
	if (what && n + 32 < sizeof prof_line) {
		snprintf(prof_line + n, sizeof prof_line - n, " %s %.2f", what, (t - prof_t) * 1000.0);
	}
	prof_t = t;
}

static bool run_job(const struct door_gpu_frame *fr, unsigned char *dst, int stride)
{
	while (glGetError() != GL_NO_ERROR) {
	}
	prof_line[0] = '\0';
	prof(NULL);
	int w = fr->w, h = fr->h, qw = (w + 3) / 4, qh = (h + 3) / 4;
	targets(w, h);
	for (int i = 0; i < DOOR_GPU_TEX; i++) {
		upload(i, &fr->tex[i]);
	}
	prof("upload");
	glBindFramebuffer(GL_FRAMEBUFFER, D.fbo);
	glBindVertexArray(D.vao);
	glUseProgram(D.prog[0]);
	set_uniforms(D.prog[0], fr);
	/* the trace's pictures, on units 2 .. 8 */
	for (int i = 0; i < DOOR_GPU_TEX; i++) {
		glActiveTexture(GL_TEXTURE2 + i);
		glBindTexture(GL_TEXTURE_2D, fr->tex[i].px && D.tex[i].id ? D.tex[i].id : D.dummy);
	}
	if (!pass(0, D.dummy, 0, D.full[0], w, h, 128)) {
		return false;
	}
	prof("trace");
	/* the edges: the frame as it is, then over it, only where pass 6 marks
	 * a pixel, four samples -- the rest never shaded */
	glBindFramebuffer(GL_READ_FRAMEBUFFER, D.fbo);
	glBindFramebuffer(GL_DRAW_FRAMEBUFFER, D.efbo);
	glFramebufferTexture2D(GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, D.full[1], 0);
	glBlitFramebuffer(0, 0, w, h, 0, 0, w, h, GL_COLOR_BUFFER_BIT, GL_NEAREST);
	glBindFramebuffer(GL_FRAMEBUFFER, D.efbo);
	glClearDepthf(1.0f);
	glClear(GL_DEPTH_BUFFER_BIT);
	glEnable(GL_DEPTH_TEST);
	glDepthFunc(GL_ALWAYS);
	glDepthMask(GL_TRUE);
	glColorMask(GL_FALSE, GL_FALSE, GL_FALSE, GL_FALSE);
	bool marked = pass(6, D.full[0], 0, D.full[1], w, h, 0);
	glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
	/* the triangle is at depth 0.5: in front of a mark (0), behind the
	 * clear (1) */
	glDepthFunc(GL_GREATER);
	glDepthMask(GL_FALSE);
	bool edged = marked && pass(1, D.full[0], 0, D.full[1], w, h, 128);
	glDisable(GL_DEPTH_TEST);
	glDepthMask(GL_TRUE);
	if (!edged) {
		return false;
	}
	prof("edges");
	GLuint glow = D.dummy;
	if (fr->post > 0.0f) {
		if (!pass(2, D.full[1], 0, D.quarter[0], qw, qh, 0)) {
			return false;
		}
		static const int STRIDE[4] = { 1, 2, 4, 8 };
		for (int s = 0; s < 4; s++) {
			for (int p = 3; p <= 4; p++) {
				glUseProgram(D.prog[p]);
				glUniform1i(glGetUniformLocation(D.prog[p], "u_stride"), STRIDE[s]);
				glUniform2f(glGetUniformLocation(D.prog[p], "u_qres"), (float)qw, (float)qh);
				GLuint from = p == 3 ? D.quarter[0] : D.quarter[1];
				GLuint to = p == 3 ? D.quarter[1] : D.quarter[0];
				if (!pass(p, from, 0, to, qw, qh, 0)) {
					return false;
				}
			}
		}
		glow = D.quarter[0];
	}
	prof("glow");
	glUseProgram(D.prog[5]);
	glUniform2f(glGetUniformLocation(D.prog[5], "u_qres"), (float)qw, (float)qh);
	glUniform1f(glGetUniformLocation(D.prog[5], "u_post"), fr->post);
	if (!pass(5, D.full[1], glow, D.out, w, h, 0)) {
		return false;
	}
	/* rows come back bottom of the target first, which is the top of the
	 * frame: door.glsl counts pixels from the top, as cairo does */
	prof("final");
	glPixelStorei(GL_PACK_ALIGNMENT, 4);
	glPixelStorei(GL_PACK_ROW_LENGTH, stride / 4);
	glReadPixels(0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, dst);
	glPixelStorei(GL_PACK_ROW_LENGTH, 0);
	prof("read");
	if (getenv("DESK_DOOR_PROFILE")) {
		fprintf(stderr, "desk: door: %dx%d ms:%s\n", w, h, prof_line);
	}
	for (int i = 0; i < 2; i++) {
		glActiveTexture(GL_TEXTURE0 + i);
		glBindTexture(GL_TEXTURE_2D, 0);
	}
	GLenum e = glGetError();
	if (e != GL_NO_ERROR) {
		snprintf(D.why, sizeof D.why, "GL error 0x%04x drawing a frame", (unsigned)e);
		return false;
	}
	return true;
}

static void set_state(int s)
{
	pthread_mutex_lock(&D.lock);
	D.state = s;
	pthread_cond_broadcast(&D.cond);
	pthread_mutex_unlock(&D.lock);
}

static void *door_thread(void *arg)
{
	(void)arg;
	struct desk_gpu *g = desk_gpu_open();
	if (!g) {
		snprintf(D.why, sizeof D.why, "no GPU with GLES 3.0 and a float target");
		goto dead;
	}
	snprintf(D.name, sizeof D.name, "%s", desk_gpu_name(g));
	if (D.ok) {
		char why[400] = "";
		if (!D.ok(g, why, sizeof why)) {
			snprintf(D.why, sizeof D.why, "%s", why[0] ? why : "not wanted");
			desk_gpu_close(g);
			goto dead;
		}
	}
	D.g = g;
	double t0 = now_s();
	for (int p = 0; p < DOOR_GPU_PASSES; p++) {
		char err[2048] = "";
		if (p == 1) {
			/* the trace's second stage is its first program (u_stage) */
			D.prog[1] = D.prog[0];
			continue;
		}
		D.prog[p] = D.src[p] ? link_prog(D.src[p], err, sizeof err) : 0;
		free(D.src[p]);
		D.src[p] = NULL;
		if (!D.prog[p]) {
			snprintf(D.why, sizeof D.why, "pass %d did not compile: %.400s", p, err);
			for (int q = p + 1; q < DOOR_GPU_PASSES; q++) {
				free(D.src[q]);
				D.src[q] = NULL;
			}
			goto dead;
		}
	}
	glGenVertexArrays(1, &D.vao);
	glGenFramebuffers(1, &D.fbo);
	glGenFramebuffers(1, &D.efbo);
	static const unsigned char black[4] = { 0, 0, 0, 0 };
	glGenTextures(1, &D.dummy);
	glBindTexture(GL_TEXTURE_2D, D.dummy);
	glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
	glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 1, 1, 0, GL_RGBA, GL_UNSIGNED_BYTE, black);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
	if (glGetError() != GL_NO_ERROR) {
		snprintf(D.why, sizeof D.why, "could not set up its textures");
		goto dead;
	}
	snprintf(D.why, sizeof D.why, "compiled in %.2f s", now_s() - t0);
	pthread_mutex_lock(&D.lock);
	D.state = DOOR_GPU_READY;
	pthread_cond_broadcast(&D.cond);
	for (;;) {
		while (!D.job) {
			pthread_cond_wait(&D.cond, &D.lock);
		}
		const struct door_gpu_frame *fr = D.job;
		unsigned char *dst = D.dst;
		int stride = D.stride;
		pthread_mutex_unlock(&D.lock);
		double j0 = now_s();
		bool ok = run_job(fr, dst, stride);
		double ms = (now_s() - j0) * 1000.0;
		pthread_mutex_lock(&D.lock);
		D.job = NULL;
		D.job_ok = ok;
		D.job_ms = ms;
		D.job_done = true;
		if (!ok) {
			D.state = DOOR_GPU_DEAD;
		}
		pthread_cond_broadcast(&D.cond);
		if (!ok) {
			break;
		}
	}
	pthread_mutex_unlock(&D.lock);
	return NULL;
dead:
	for (int p = 0; p < DOOR_GPU_PASSES; p++) {
		free(D.src[p]);
		D.src[p] = NULL;
	}
	set_state(DOOR_GPU_DEAD);
	return NULL;
}

bool door_gpu_start(char *src[DOOR_GPU_PASSES], bool (*ok)(struct desk_gpu *g, char *why,
	size_t whysz))
{
	pthread_mutex_lock(&D.lock);
	if (D.state != DOOR_GPU_OFF) {
		pthread_mutex_unlock(&D.lock);
		for (int p = 0; p < DOOR_GPU_PASSES; p++) {
			free(src[p]);
		}
		return false;
	}
	for (int p = 0; p < DOOR_GPU_PASSES; p++) {
		D.src[p] = src[p];
	}
	D.ok = ok;
	D.state = DOOR_GPU_BUSY;
	pthread_attr_t at;
	pthread_attr_init(&at);
	pthread_attr_setdetachstate(&at, PTHREAD_CREATE_DETACHED);
	if (pthread_create(&D.th, &at, door_thread, NULL) != 0) {
		for (int p = 0; p < DOOR_GPU_PASSES; p++) {
			free(D.src[p]);
			D.src[p] = NULL;
		}
		snprintf(D.why, sizeof D.why, "no thread for it");
		D.state = DOOR_GPU_DEAD;
	}
	pthread_attr_destroy(&at);
	pthread_mutex_unlock(&D.lock);
	return true;
}

int door_gpu_state(void)
{
	pthread_mutex_lock(&D.lock);
	int s = D.state;
	pthread_mutex_unlock(&D.lock);
	return s;
}

bool door_gpu_wait(double secs)
{
	struct timespec until;
	clock_gettime(CLOCK_REALTIME, &until);
	long ns = until.tv_nsec + (long)((secs - (long)secs) * 1e9);
	until.tv_sec += (time_t)secs + ns / 1000000000L;
	until.tv_nsec = ns % 1000000000L;
	pthread_mutex_lock(&D.lock);
	while (D.state == DOOR_GPU_BUSY) {
		if (pthread_cond_timedwait(&D.cond, &D.lock, &until) != 0) {
			break;
		}
	}
	bool ready = D.state == DOOR_GPU_READY;
	pthread_mutex_unlock(&D.lock);
	return ready;
}

const char *door_gpu_name(void)
{
	return D.name;
}

const char *door_gpu_why(void)
{
	return D.why;
}

bool door_gpu_render(const struct door_gpu_frame *fr, unsigned char *dst, int stride, double *ms)
{
	if (!fr || !dst || fr->full || fr->w < 1 || fr->h < 1 || stride < fr->w * 4 || stride % 4) {
		return false;
	}
	pthread_mutex_lock(&D.lock);
	if (D.state != DOOR_GPU_READY || D.job) {
		pthread_mutex_unlock(&D.lock);
		return false;
	}
	D.job = fr;
	D.dst = dst;
	D.stride = stride;
	D.job_done = false;
	pthread_cond_broadcast(&D.cond);
	while (!D.job_done) {
		pthread_cond_wait(&D.cond, &D.lock);
	}
	bool ok = D.job_ok;
	if (ms) {
		*ms = D.job_ms;
	}
	pthread_mutex_unlock(&D.lock);
	return ok;
}
