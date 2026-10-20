/* The front door (the screen lock), traced on the GPU.
 *
 * This is draw.c's door tracer -- lk_intersect, lk_material, lk_shade,
 * lk_sample and everything under them, the dressing for the days kept,
 * the room through the doorway -- line for line, the way room.glsl is the
 * room's. draw.c stays the reference and the fallback; the numbers they
 * share (LK_*, RM_*) are handed over by draw.c (door_glsl_build) as
 * #defines ahead of this text, so they cannot drift apart. What changes
 * from frame to frame -- the eye, the door's swing, the key, the weather,
 * the room behind it -- comes in as uniforms, and the pictures that go on
 * things (the name board, the plate, the room) as textures.
 *
 * It runs in passes (DOOR_PASS), over the whole frame at the screen's own
 * size (the glow's at a quarter of it):
 *
 *   0  the trace, in two stages (u_stage): a sample a pixel -- what it
 *      shows, as it is to be shown, and what it is (lk_sample's aa) --
 *      then where what a pixel shows changes, four samples instead of
 *      one (the CPU's fine pass, here every frame); 6 marks those pixels
 *      for the second stage, which is shaded nowhere else
 *   2  the bright, a quarter the size (lk_post)
 *   3  blurred across, 4 down, at the stride u_stride (blur_pass_rect)
 *   5  the glow added, the corners let go dark, dithered to bytes and put
 *      in the order cairo keeps them (B, G, R, A)
 *
 * Pixels are counted from the top left, as the CPU counts them: a pass
 * writes pixel (x, y) at gl_FragCoord (x, y), and the frame read back from
 * the last pass comes out top row first with nothing turned over. */

#define M_PI 3.14159265358979323846

float clampf(float v, float lo, float hi)
{
	return v < lo ? lo : (v > hi ? hi : v);
}

float smoothstepf(float a, float b, float x)
{
	float t = clampf((x - a) / (b - a + 1e-9), 0.0, 1.0);
	return t * t * (3.0 - 2.0 * t);
}

float spow(float x, float y)
{
	return pow(max(x, 0.0), y);
}

/* ---- noise, hashed on integers, to the bit what draw.c computes ---- */

uint room_mix(uint v)
{
	uint s = v * 747796405u + 2891336453u;
	uint w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u;
	return (w >> 22u) ^ w;
}

float room_hash(int x, int y)
{
	uint h = room_mix(uint(x) + room_mix(uint(y)));
	return float(h >> 8u) * (1.0 / 16777216.0);
}

uniform vec2 u_res;          /* the frame, pixels */

#if DOOR_PASS <= 1

float atan2f(float y, float x)
{
	return (x == 0.0 && y == 0.0) ? 0.0 : atan(y, x);
}

vec3 vnorm(vec3 a)
{
	float l = length(a);
	return l > 1e-12 ? a * (1.0 / l) : a;
}

vec3 rot_x(vec3 p, float a)
{
	float c = cos(a), s = sin(a);
	return vec3(p.x, p.y * c - p.z * s, p.y * s + p.z * c);
}

vec3 rot_y(vec3 p, float a)
{
	float c = cos(a), s = sin(a);
	return vec3(p.x * c + p.z * s, p.y, -p.x * s + p.z * c);
}

vec3 rot_z(vec3 p, float a)
{
	float c = cos(a), s = sin(a);
	return vec3(p.x * c - p.y * s, p.x * s + p.y * c, p.z);
}

vec3 reflect3(vec3 i, vec3 n)
{
	return i - n * (2.0 * dot(i, n));
}

float room_seed(int i, int salt)
{
	return room_hash(i, ROOM_SEED_ROW + salt);
}

float room_noise(float x, float y)
{
	float xi = floor(x), yi = floor(y);
	float xf = x - xi, yf = y - yi;
	float u = xf * xf * (3.0 - 2.0 * xf);
	float v = yf * yf * (3.0 - 2.0 * yf);
	int ix = int(xi), iy = int(yi);
	float a = room_hash(ix, iy);
	float b = room_hash(ix + 1, iy);
	float c = room_hash(ix, iy + 1);
	float d = room_hash(ix + 1, iy + 1);
	float top = a + (b - a) * u;
	float bot = c + (d - c) * u;
	return top + (bot - top) * v;
}

void env_brdf(float nov, float rough, out float a, out float b)
{
	float rx = rough * -1.00 + 1.00;
	float ry = rough * -0.0275 + 0.0425;
	float rz = rough * -0.572 + 1.04;
	float rw = rough * 0.022 - 0.04;
	float a004 = min(rx * rx, exp2(-9.28 * nov)) * rx + ry;
	a = a004 * -1.04 + rz;
	b = a004 * 1.04 + rw;
}

float sd_box(vec3 p, vec3 b)
{
	vec3 q = abs(p) - b;
	return min(max(q.x, max(q.y, q.z)), 0.0) + length(max(q, vec3(0.0)));
}

float sd_round_box(vec3 p, vec3 b, float r)
{
	return sd_box(p, max(b - vec3(r), vec3(0.0))) - r;
}

float sd_capped_cone(vec3 p, float r1, float r2, float h)
{
	vec2 q = vec2(length(p.xz), p.y);
	vec2 k1 = vec2(r2, h);
	vec2 k2 = vec2(r2 - r1, 2.0 * h);
	vec2 ca = vec2(q.x - min(q.x, (q.y < 0.0) ? r1 : r2), abs(q.y) - h);
	float k2l = length(k2) + 1e-8;
	float t = clampf(dot(k1 - q, k2) / (k2l * k2l), 0.0, 1.0);
	vec2 cb = q - (k1 + k2 * -t);
	float s = (cb.x < 0.0 && ca.y < 0.0) ? -1.0 : 1.0;
	return s * sqrt(min(dot(ca, ca), dot(cb, cb)));
}

float sd_cyl_z(vec3 p, float r, float h)
{
	float d = length(p.xy) - r;
	float dz = abs(p.z) - h;
	return min(max(d, dz), 0.0) + length(max(vec2(d, dz), vec2(0.0)));
}

float aces_ch(float x)
{
	const float a = 2.51, b = 0.03, c = 2.43, d = 0.59, e = 0.14;
	return clampf((x * (a * x + b)) / (x * (c * x + d) + e), 0.0, 1.0);
}

vec3 tonemap(vec3 c)
{
	c = vec3(aces_ch(max(c.x, 0.0)), aces_ch(max(c.y, 0.0)), aces_ch(max(c.z, 0.0)));
	return vec3(spow(c.x, 1.0 / 2.2), spow(c.y, 1.0 / 2.2), spow(c.z, 1.0 / 2.2));
}

/* ---- draw.c's vec3 arithmetic, by the same names, so the port reads as
 * the original ---- */

vec3 v3(float x, float y, float z) { return vec3(x, y, z); }
vec3 v3(int x, float y, float z) { return vec3(float(x), y, z); }
vec3 v3(float x, int y, float z) { return vec3(x, float(y), z); }
vec3 v3(float x, float y, int z) { return vec3(x, y, float(z)); }
vec3 v3(int x, int y, float z) { return vec3(float(x), float(y), z); }
vec3 v3(int x, float y, int z) { return vec3(float(x), y, float(z)); }
vec3 v3(float x, int y, int z) { return vec3(x, float(y), float(z)); }
vec3 v3(int x, int y, int z) { return vec3(float(x), float(y), float(z)); }
vec3 vadd(vec3 a, vec3 b) { return a + b; }
vec3 vsub(vec3 a, vec3 b) { return a - b; }
vec3 vmul(vec3 a, float s) { return a * s; }
vec3 vmul3(vec3 a, vec3 b) { return a * b; }
vec3 vmix(vec3 a, vec3 b, float t) { return a + (b - a) * t; }
float vdot(vec3 a, vec3 b) { return dot(a, b); }
float vlen(vec3 a) { return length(a); }
vec3 vcross(vec3 a, vec3 b) { return cross(a, b); }

/* C's rounding and remainder, which GLSL's round and mod are not */
float lround(float x) { return x < 0.0 ? -floor(-x + 0.5) : floor(x + 0.5); }
float c_fmod(float a, float b) { return a - b * trunc(a / b); }

/* ---- what draw.c hands over ---- */

/* the eye (struct lk_cam), in this frame's pixels */
uniform vec3 u_eye;
uniform float u_yaw, u_pitch, u_f;
uniform vec2 u_c;

/* the scene (struct lk_scene) */
uniform float u_cd, u_sd, u_key, u_lamp, u_open;
uniform int u_rough;
uniform vec4 u_pic;          /* pic_x0, pic_y0, pic_w, pic_h */
uniform vec3 u_roomb;        /* room_hx, room_y0, room_y1 */
uniform vec3 u_edge[5];
uniform int u_ndeco, u_wreath;
uniform int u_deco_kind[LKD_MAX], u_deco_door[LKD_MAX];
uniform vec3 u_deco_lo[LKD_MAX], u_deco_hi[LKD_MAX];

/* the rig (struct lk_rig) */
uniform float u_porch, u_lantern, u_glass, u_sun_soft, u_wet, u_snow, u_haze_k, u_exposure;
uniform vec3 u_sun, u_sun_col, u_moon_col, u_amb_lo, u_amb_hi, u_sky_hi, u_sky_lo;
uniform vec3 u_gnd_hi, u_gnd_lo, u_haze;

/* the room through the doorway (struct lk_room) */
uniform int u_room_on;
uniform vec3 u_rm_t;
uniform float u_rm_s;
uniform vec4 u_rm_shell;     /* wx, fy, cy, bz */
uniform float u_rm_fz;
uniform int u_rm_nbox;
uniform vec3 u_rm_lo[16], u_rm_hi[16];
uniform int u_rm_kind[16];
uniform vec3 u_rm_desk;      /* desk_hx, desk_z0, desk_z1 */
uniform vec3 u_rm_wall, u_rm_ceil;
uniform int u_pj_on[3];
uniform vec3 u_pj_eye[3], u_pj_ww[3], u_pj_uu[3], u_pj_vv[3];
uniform vec2 u_pj_fov[3];
uniform vec4 u_pj_rect[3];   /* x0, y0, sw, sh: where its frame is on its picture */

/* the pictures: ARGB32 as cairo keeps it (so B, G, R, A in a texel), or
 * A8 (in the red) */
uniform sampler2D u_tsign, u_tgold, u_tplate, u_tpic, u_tpj0, u_tpj1, u_tpj2;
uniform int u_has_sign, u_has_gold, u_has_plate, u_has_pic;

#define TX_SIGN 0
#define TX_GOLD 1
#define TX_PLATE 2
#define TX_PIC 3
#define TX_PJ0 4

/* ---- the scene's fixed parts ---- */

#define LK_NONE 0
#define LK_WALL_ID 1
#define LK_CASING 2
#define LK_JAMB 3
#define LK_STEP 4
#define LK_INSIDE 5
#define LK_PICTURE 6
#define LK_ROOMIN 7
#define LK_DOOR 8
#define LK_DOOR_EDGE 9
#define LK_SIGN 10
#define LK_SIGN_EDGE 11
#define LK_PLATE 12
#define LK_BRASS 13
#define LK_KEY 14
#define LK_LGLASS 15
#define LK_IRON 16
#define LK_DECO 17

#define LK_OC_SIGN 0
#define LK_OC_PLATE 1
#define LK_OC_LOCK 2
#define LK_OC_KNOB 3
#define LK_OC_NAIL 4
#define LK_OC_N 5

#define LK_RM_SHELL 0
#define LK_RM_DESK 1
#define LK_RM_LEG 2
#define LK_RM_CASE 3
#define LK_RM_POST 4
#define LK_RM_CONSOLE 5
#define LK_RM_PROP 6

#define LKD_WREATH 0
#define LKD_GARLAND 1
#define LKD_BALLOONS 2
#define LKD_FIR 1
#define LKD_TINSEL 2
#define DM_NEEDLE 0
#define DM_BERRY 1
#define DM_CONE 2
#define DM_BOW 3
#define DM_BULB 4
#define DM_TINSEL 5
#define DM_BAUBLE 6
#define DM_BALLOON 7

const vec3 LK_LIGHT_POS[2] = vec3[2](vec3(0.15, 2.32, 0.95), vec3(0.735, 1.615, 0.125));
const vec3 LK_LIGHT_COL[2] = vec3[2](vec3(3.20, 2.50, 1.70), vec3(0.34, 0.21, 0.09));
const float LK_LIGHT_R[2] = float[2](0.100, 0.030);
const vec3 LK_MOON_DIR = vec3(-0.50, 0.52, 0.69);

const vec3 LK_LANTERN_LO[6] = vec3[6](vec3(0.673, 1.515, 0.062), vec3(0.663, 1.715, 0.052),
	vec3(0.703, 1.742, 0.093), vec3(0.667, 1.497, 0.056), vec3(0.721, 1.457, 0.000),
	vec3(0.697, 1.400, 0.000));
const vec3 LK_LANTERN_HI[6] = vec3[6](vec3(0.797, 1.715, 0.188), vec3(0.807, 1.742, 0.198),
	vec3(0.767, 1.782, 0.157), vec3(0.803, 1.515, 0.194), vec3(0.749, 1.497, 0.140),
	vec3(0.773, 1.560, 0.012));
const int LK_LANTERN_ID[6] = int[6](LK_LGLASS, LK_IRON, LK_IRON, LK_IRON, LK_IRON, LK_IRON);

const vec3 LK_CASE_LO[3] = vec3[3](vec3(-LK_OW - LK_CW, 0.0, 0.0), vec3(LK_OW, 0.0, 0.0),
	vec3(-LK_OW - LK_CW, LK_OH, 0.0));
const vec3 LK_CASE_HI[3] = vec3[3](vec3(-LK_OW, LK_OH + LK_CW, LK_CZ),
	vec3(LK_OW + LK_CW, LK_OH + LK_CW, LK_CZ), vec3(LK_OW + LK_CW, LK_OH + LK_CW, LK_CZ));

const vec3 LKB_C[5] = vec3[5](vec3(0.40, 1.62, 0.24), vec3(0.56, 1.74, 0.18),
	vec3(0.32, 1.82, 0.30), vec3(0.50, 1.92, 0.30), vec3(0.58, 1.48, 0.34));
const float LKB_R[5] = float[5](0.100, 0.095, 0.092, 0.090, 0.085);
const vec3 LKD_BULB_COL[5] = vec3[5](vec3(1.00, 0.10, 0.05), vec3(1.00, 0.50, 0.07),
	vec3(0.10, 0.78, 0.16), vec3(0.12, 0.30, 1.00), vec3(1.00, 0.78, 0.50));
const vec3 LKB_COL[5] = vec3[5](vec3(0.62, 0.025, 0.035), vec3(0.80, 0.50, 0.09),
	vec3(0.035, 0.16, 0.60), vec3(0.80, 0.21, 0.40), vec3(0.80, 0.80, 0.82));

float lk_sq(float v)
{
	return v * v;
}

float lk_smin(float a, float b, float k)
{
	float h = clampf(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
	return b + (a - b) * h - k * h * (1.0 - h);
}

/* ---- where things are ---- */

vec3 lk_to_door(vec3 p)
{
	vec3 q = vec3(p.x - LK_HX, p.y, p.z - LK_HZ);
	return vec3(q.x * u_cd - q.z * u_sd, q.y, q.x * u_sd + q.z * u_cd);
}

vec3 lk_door_dir_in(vec3 d)
{
	return vec3(d.x * u_cd - d.z * u_sd, d.y, d.x * u_sd + d.z * u_cd);
}

vec3 lk_door_dir_out(vec3 d)
{
	return vec3(d.x * u_cd + d.z * u_sd, d.y, -d.x * u_sd + d.z * u_cd);
}

vec3 lk_from_door(vec3 q)
{
	vec3 p = lk_door_dir_out(q);
	return vec3(p.x + LK_HX, p.y, p.z + LK_HZ);
}

vec3 lk_to_sign(vec3 q)
{
	float c = cos(LK_SIGN_TILT), s = sin(LK_SIGN_TILT);
	vec3 o = vec3(q.x - LK_SIGN_X, q.y - LK_SIGN_Y, q.z - LK_DT - 0.0004);
	return vec3(o.x, o.y * c + o.z * s, -o.y * s + o.z * c);
}

vec3 lk_sign_dir_in(vec3 d)
{
	float c = cos(LK_SIGN_TILT), s = sin(LK_SIGN_TILT);
	return vec3(d.x, d.y * c + d.z * s, -d.y * s + d.z * c);
}

vec3 lk_sign_dir_out(vec3 d)
{
	float c = cos(LK_SIGN_TILT), s = sin(LK_SIGN_TILT);
	return vec3(d.x, d.y * c - d.z * s, d.y * s + d.z * c);
}

vec3 lk_from_sign(vec3 s)
{
	vec3 d = lk_sign_dir_out(s);
	return vec3(d.x + LK_SIGN_X, d.y + LK_SIGN_Y, d.z + LK_DT + 0.0004);
}

/* where the ray first comes to the box from outside it, and by which face
 * (axis * 2, plus 1 for the far side of the axis) */
bool lk_box(vec3 ro, vec3 rd, vec3 lo, vec3 hi, float tmax, out float t, out int face)
{
	t = 0.0;
	face = 0;
	float t0 = -1e30, t1 = tmax;
	int f = -1;
	for (int i = 0; i < 3; i++) {
		float o = ro[i], d = rd[i], a = lo[i], b = hi[i];
		if (abs(d) < 1e-12) {
			if (o < a || o > b) {
				return false;
			}
			continue;
		}
		float inv = 1.0 / d;
		float ta = (a - o) * inv, tb = (b - o) * inv;
		int fa = i * 2, fb = i * 2 + 1;
		if (ta > tb) {
			float s = ta;
			ta = tb;
			tb = s;
			int g = fa;
			fa = fb;
			fb = g;
		}
		if (ta > t0) {
			t0 = ta;
			f = fa;
		}
		if (tb < t1) {
			t1 = tb;
		}
		if (t0 > t1) {
			return false;
		}
	}
	if (f < 0 || t0 < 1e-7) {
		return false;
	}
	t = t0;
	face = f;
	return true;
}

vec3 lk_face_n(int face)
{
	float s = (face & 1) != 0 ? 1.0 : -1.0;
	int ax = face >> 1;
	return ax == 0 ? vec3(s, 0.0, 0.0) : ax == 1 ? vec3(0.0, s, 0.0) : vec3(0.0, 0.0, s);
}

/* ---- the brass, as distances ---- */

float lk_sd_lock(float key, vec3 q, out int id)
{
	vec3 p = q - vec3(LK_KEY_X, LK_KEY_Y, LK_DT);
	float ros = sd_cyl_z(p - vec3(0.0, 0.0, 0.0035), 0.0270, 0.0012) - 0.0024;
	float plug = sd_cyl_z(p - vec3(0.0, 0.0, 0.0074), 0.0110, 0.0010) - 0.0007;
	float lock = min(ros, plug);
	vec3 k = rot_z(p, key);
	float shank = sd_round_box(k - vec3(0.0, 0.0, 0.032), vec3(0.0026, 0.0062, 0.023), 0.0012);
	float collar = sd_cyl_z(k - vec3(0.0, 0.0, 0.0480), 0.0064, 0.0022) - 0.0011;
	vec3 b = k - vec3(0.0, 0.0, 0.0830);
	float d2 = sqrt(b.y * b.y + b.z * b.z) - 0.0315;
	for (int i = 0; i < 3; i++) {
		float a = float(i) * (2.0 * M_PI / 3.0);
		float hz = b.z - 0.0138 * cos(a), hy = b.y - 0.0138 * sin(a);
		d2 = max(d2, 0.0086 - sqrt(hy * hy + hz * hz));
	}
	const float ra = 0.0013, hx = 0.0028;
	float wa = d2 + ra, wb = abs(b.x) - (hx - ra);
	float bow = min(max(wa, wb), 0.0) + sqrt(lk_sq(max(wa, 0.0)) + lk_sq(max(wb, 0.0))) - ra;
	float keyd = lk_smin(lk_smin(shank, collar, 0.002), bow, 0.003);
	id = keyd < lock ? LK_KEY : LK_BRASS;
	return min(keyd, lock);
}

float lk_sd_knob(vec3 q, out int id)
{
	vec3 p = q - vec3(LK_KNOB_X, LK_KNOB_Y, LK_DT);
	float ros = sd_cyl_z(p - vec3(0.0, 0.0, 0.0035), 0.0245, 0.0012) - 0.0025;
	float neck = sd_cyl_z(p - vec3(0.0, 0.0, 0.0230), 0.0082, 0.0190);
	vec3 b = p - vec3(0.0, 0.0, 0.0600);
	b.z *= 1.30;
	float ball = (length(b) - 0.0285) / 1.30;
	id = LK_BRASS;
	return min(ros, lk_smin(neck, ball, 0.008));
}

float lk_sd_nail(vec3 q, out int id)
{
	vec3 p = q - vec3(LK_SIGN_X, LK_NAIL_Y, LK_DT);
	float head = sd_cyl_z(p - vec3(0.0, 0.0, 0.0076), 0.0042, 0.0006) - 0.0009;
	float shank = sd_cyl_z(p - vec3(0.0, 0.0, 0.0036), 0.0016, 0.0036);
	id = LK_BRASS;
	return min(head, shank);
}

float lk_occ_sd(int j, vec3 q)
{
	int id;
	if (j == LK_OC_SIGN) {
		vec3 s = lk_to_sign(q);
		return sd_box(s - vec3(0.0, LK_SIGN_H * 0.5, LK_SIGN_T * 0.5),
			vec3(LK_SIGN_W * 0.5, LK_SIGN_H * 0.5, LK_SIGN_T * 0.5));
	}
	if (j == LK_OC_PLATE) {
		return sd_box(q - vec3((LK_PL_X0 + LK_PL_X1) * 0.5, (LK_PL_Y0 + LK_PL_Y1) * 0.5,
			LK_DT + LK_PL_T * 0.5), vec3((LK_PL_X1 - LK_PL_X0) * 0.5,
			(LK_PL_Y1 - LK_PL_Y0) * 0.5, LK_PL_T * 0.5));
	}
	if (j == LK_OC_LOCK) {
		return lk_sd_lock(u_key, q, id);
	}
	if (j == LK_OC_KNOB) {
		return lk_sd_knob(q, id);
	}
	return lk_sd_nail(q, id);
}

void lk_occ_bound(int j, out vec3 c, out float r)
{
	if (j == LK_OC_SIGN) {
		c = lk_from_sign(vec3(0.0, LK_SIGN_H * 0.5, LK_SIGN_T * 0.5));
		r = 0.245;
	} else if (j == LK_OC_PLATE) {
		c = vec3((LK_PL_X0 + LK_PL_X1) * 0.5, (LK_PL_Y0 + LK_PL_Y1) * 0.5, LK_DT + 0.003);
		r = 0.202;
	} else if (j == LK_OC_LOCK) {
		c = vec3(LK_KEY_X, LK_KEY_Y, LK_DT + 0.057);
		r = 0.072;
	} else if (j == LK_OC_KNOB) {
		c = vec3(LK_KNOB_X, LK_KNOB_Y, LK_DT + 0.042);
		r = 0.056;
	} else {
		c = vec3(LK_SIGN_X, LK_NAIL_Y, LK_DT + 0.005);
		r = 0.009;
	}
}

/* ---- finding what a ray meets ---- */

struct lk_hit {
	float t;
	int id, face, sub;
	vec3 n;
	vec3 q;
};

vec3 lk_group_normal(int j, vec3 p)
{
	const float e = 0.00022;
	vec3 k1 = vec3(1, -1, -1), k2 = vec3(-1, -1, 1), k3 = vec3(-1, 1, -1), k4 = vec3(1, 1, 1);
	return vnorm(k1 * lk_occ_sd(j, p + k1 * e) + k2 * lk_occ_sd(j, p + k2 * e)
		+ k3 * lk_occ_sd(j, p + k3 * e) + k4 * lk_occ_sd(j, p + k4 * e));
}

void lk_march(int j, vec3 o, vec3 d, inout lk_hit h)
{
	vec3 c;
	float r;
	lk_occ_bound(j, c, r);
	vec3 oc = o - c;
	float b = dot(oc, d), cc = dot(oc, oc) - r * r;
	float disc = b * b - cc;
	if (disc <= 0.0) {
		return;
	}
	float s = sqrt(disc);
	float t = max(-b - s, 0.0), t1 = min(-b + s, h.t);
	for (int i = 0; i < 90 && t < t1; i++) {
		vec3 p = o + d * t;
		int id = LK_BRASS;
		float dist = j == LK_OC_LOCK ? lk_sd_lock(u_key, p, id)
			: j == LK_OC_KNOB ? lk_sd_knob(p, id) : lk_sd_nail(p, id);
		if (dist < 0.00010) {
			h.t = t;
			h.id = id;
			h.face = j;
			h.q = p;
			h.n = lk_door_dir_out(lk_group_normal(j, p));
			return;
		}
		t += dist * 0.92;
	}
}

/* ---- dressed for the day: the shapes ---- */

#define LKD_CX LK_SIGN_X
#define LKD_CY (LK_SIGN_Y + LK_SIGN_H * 0.5)
#define LKD_R 0.355
#define LKD_Z (LK_DT + 0.050)
#define LKD_KNOT_A (M_PI * 1.27)
#define LKD_SLOTS 12

float lkd_ellipsoid(vec3 p, vec3 r)
{
	float k0 = length(p / r);
	float k1 = length(p / (r * r));
	return k1 > 1e-12 ? k0 * (k0 - 1.0) / k1 : -min(r.x, min(r.y, r.z));
}

vec3 lkd_turn(vec3 p, vec3 c, float a)
{
	vec3 d = p - c;
	float s = sin(a), k = cos(a);
	return vec3(d.x * k + d.y * s, -d.x * s + d.y * k, d.z);
}

float lkd_ring(vec3 q, out float a, out float b)
{
	float x = q.x - LKD_CX, y = q.y - LKD_CY, z = q.z - LKD_Z;
	float c = sqrt(x * x + y * y) - LKD_R;
	a = atan2f(y, x);
	b = atan2f(z, c);
	return sqrt(c * c + z * z);
}

vec3 lkd_ring_at(float a, float b, float r)
{
	float rr = LKD_R + r * cos(b);
	return vec3(LKD_CX + cos(a) * rr, LKD_CY + sin(a) * rr, LKD_Z + r * sin(b));
}

float lkd_hash3(int x, int y, int z)
{
	return room_hash(x + z * 7919, y - z * 1543);
}

float lkd_noise3(vec3 p)
{
	float xi = floor(p.x), yi = floor(p.y), zi = floor(p.z);
	float xf = p.x - xi, yf = p.y - yi, zf = p.z - zi;
	float u = xf * xf * (3.0 - 2.0 * xf), v = yf * yf * (3.0 - 2.0 * yf);
	float w = zf * zf * (3.0 - 2.0 * zf);
	int x = int(xi), y = int(yi), z = int(zi);
	float a = lkd_hash3(x, y, z) + (lkd_hash3(x + 1, y, z) - lkd_hash3(x, y, z)) * u;
	float b = lkd_hash3(x, y + 1, z) + (lkd_hash3(x + 1, y + 1, z) - lkd_hash3(x, y + 1, z)) * u;
	float c = lkd_hash3(x, y, z + 1) + (lkd_hash3(x + 1, y, z + 1) - lkd_hash3(x, y, z + 1)) * u;
	float d = lkd_hash3(x, y + 1, z + 1)
		+ (lkd_hash3(x + 1, y + 1, z + 1) - lkd_hash3(x, y + 1, z + 1)) * u;
	float ab = a + (b - a) * v, cd = c + (d - c) * v;
	return ab + (cd - ab) * w;
}

float lkd_fir(vec3 q)
{
	return 0.62 * lkd_noise3(q * 30.0) + 0.38 * lkd_noise3(q * 85.0 + vec3(5.1, 1.7, 3.3));
}

/* draw.c's _Thread_local g_lkd_rough and g_lkd_not_balloon: here each
 * pixel's own */
bool g_lkd_rough = false;
int g_lkd_not_balloon = -1;

float lkd_fir_for(vec3 q)
{
	return g_lkd_rough ? 0.62 * lkd_noise3(q * 30.0) + 0.19 : lkd_fir(q);
}

float lkd_lumps(float a, float b)
{
	return 0.55 * (0.5 + 0.5 * sin(23.0 * a + 1.9 * sin(2.0 * b + 5.0 * a)))
		+ 0.45 * (0.5 + 0.5 * sin(37.0 * a - 3.0 * b + 1.3));
}

int lkd_slot(float a, out float ak)
{
	ak = 0.0;
	float step = 2.0 * M_PI / float(LKD_SLOTS + 1);
	float rel = (a - LKD_KNOT_A) / step;
	rel -= floor(rel / float(LKD_SLOTS + 1)) * float(LKD_SLOTS + 1);
	int k = int(floor(rel + 0.5)) - 1;
	if (k < 0 || k >= LKD_SLOTS) {
		return -1;
	}
	ak = LKD_KNOT_A + float(k + 1) * step;
	return k;
}

float lkd_bow(vec3 q, out int mat)
{
	vec3 c = lkd_ring_at(LKD_KNOT_A, 1.0, 0.040) + vec3(0.0, 0.0, 0.012);
	vec3 l = q - c;
	mat = DM_BOW;
	if (dot(l, l) > 0.13 * 0.13) {
		return length(l) - 0.12;
	}
	float d = lkd_ellipsoid(l, vec3(0.020, 0.017, 0.015));
	for (int si = 0; si < 2; si++) {
		float s = si == 0 ? -1.0 : 1.0;
		vec3 lp = lkd_turn(q, c + vec3(s * 0.039, 0.011, -0.004), -s * 0.42);
		d = min(d, lkd_ellipsoid(lp, vec3(0.043, 0.021, 0.013)));
		vec3 tp = lkd_turn(q, c + vec3(s * 0.022, -0.058, -0.007), s * 0.26);
		float tail = sd_box(tp, vec3(0.0125, 0.052, 0.0022));
		tail = max(tail, (-0.052 + 0.011 - abs(tp.x)) - tp.y);
		d = min(d, tail);
	}
	return d;
}

float lkd_wreath(int kind, vec3 q, out int mat)
{
	float a, b;
	float r = lkd_ring(q, a, b);
	float lump = r > 0.12 ? 1.0 : kind == LKD_TINSEL ? lkd_lumps(a, b) : lkd_fir_for(q);
	float d = r - (kind == LKD_TINSEL ? 0.040 + 0.006 * lump : 0.034 + 0.030 * lump);
	mat = kind == LKD_TINSEL ? DM_TINSEL : DM_NEEDLE;
	float ak = 0.0;
	int k = -1;
	if (d >= 0.09) {
		d -= 0.04;
	} else {
		k = lkd_slot(a, ak);
	}
	if (k >= 0) {
		float e;
		if (kind == LKD_TINSEL) {
			e = length(q - lkd_ring_at(ak, 0.95, 0.052)) - 0.024;
			if (e < d) {
				d = e;
				mat = DM_BAUBLE;
			}
		} else if (k % 3 == 1) {
			vec3 c = lkd_ring_at(ak, 0.75, 0.050);
			vec3 u = q - c;
			float along = -u.x * sin(ak) + u.y * cos(ak), across = u.x * cos(ak) + u.y * sin(ak);
			e = lkd_ellipsoid(vec3(along, across, u.z), vec3(0.031, 0.020, 0.018));
			if (e < d) {
				d = e;
				mat = DM_CONE;
			}
		} else {
			vec3 c = lkd_ring_at(ak, 1.05, 0.052);
			vec3 O[3] = vec3[3](vec3(0.0, 0.012, 0.003), vec3(-0.011, -0.006, 0.0),
				vec3(0.011, -0.007, 0.002));
			for (int i = 0; i < 3; i++) {
				e = length(q - (c + O[i])) - 0.0115;
				if (e < d) {
					d = e;
					mat = DM_BERRY;
				}
			}
		}
	}
	int m2 = DM_BOW;
	float e = lkd_bow(q, m2);
	if (e < d) {
		d = e;
		mat = m2;
	}
	return d;
}
/* The garland up the casing and over the head of it, the lights wound in
 * it every so far, pointing out, each side of it in turn: the run (0 left,
 * 1 head, 2 right), how far along it, and which light. */
#define LKG_X (LK_OW + LK_CW * 0.5)
#define LKG_TOP (LK_OH + LK_CW * 0.5)
#define LKG_Z (LK_CZ + 0.030)
#define LKG_PITCH 0.105
#define LKG_N 5                   /* the colours, in turn */

void lkd_run(vec3 p, inout int run, inout float s, inout vec3 off)
{
	float sl = clampf(p.y, 0.0, LKG_TOP), sh = clampf(p.x, -LKG_X, LKG_X);
	vec3 ol = v3(p.x + LKG_X, p.y - sl, p.z - LKG_Z);
	vec3 or_ = v3(p.x - LKG_X, p.y - sl, p.z - LKG_Z);
	vec3 oh = v3(p.x - sh, p.y - LKG_TOP, p.z - LKG_Z);
	float dl = vdot(ol, ol), dr = vdot(or_, or_), dh = vdot(oh, oh);
	if (dl <= dr && dl <= dh) {
		run = 0;
		s = sl;
		off = ol;
	} else if (dr <= dh) {
		run = 2;
		s = sl;
		off = or_;
	} else {
		run = 1;
		/* round from the left side, so the lights go on in order */
		s = LKG_TOP + (sh + LKG_X);
		off = oh;
	}
}

/* the light k along a run, where it is (the run's own frame: across, along,
 * out) */
vec3 lkd_bulb_at(int run, int k)
{
	float s = 0.05 + float(k) * LKG_PITCH, side = (k & 1) != 0 ? 1.0 : -1.0;
	if (run == 1) {
		return v3(s - LKG_TOP - LKG_X, LKG_TOP + side * 0.021, LKG_Z + 0.024);
	}
	float x = run == 0 ? -LKG_X : LKG_X;
	return v3(x + side * 0.021, s, LKG_Z + 0.024);
}

float lkd_garland(vec3 p, inout int mat, inout int bulb)
{
	int run;
	float s;
	vec3 off;
	lkd_run(p, run, s, off);
	float r = vlen(off);
	if (r > 0.12) {
		mat = DM_NEEDLE;
		bulb = -1;
		return r - 0.06;
	}
	float d = r - (0.020 + 0.026 * lkd_fir_for(p));
	mat = DM_NEEDLE;
	bulb = -1;
	int k = int(lround((s - 0.05) / LKG_PITCH));
	for (int j = k - 1; j <= k + 1; j++) {
		if (j < 0) {
			continue;
		}
		vec3 c = lkd_bulb_at(run, j);
		c.z += 0.006;
		vec3 u = vsub(p, c);
		float e = lkd_ellipsoid(u, v3(0.0105, 0.0105, 0.0150));
		if (e < d) {
			d = e;
			mat = DM_BULB;
			bulb = j * 3 + run;
		}
	}
	return d;
}

/* The balloons, a bunch of them tied below the lantern, floating up past
 * the door: where, how big, what colour. */
/* LKB: LKB_C and LKB_R, above */
/* where their strings are tied: round a nail in the casing */
#define LKB_TIE_X (LK_OW + LK_CW * 0.45)
#define LKB_TIE_Y 1.20
#define LKB_TIE_Z (LK_CZ + 0.004)

/* a balloon's knot: the foot of its string */
vec3 lkd_knot(int i)
{
	return v3(LKB_C[i].x, LKB_C[i].y - LKB_R[i] * 1.16 - 0.014, LKB_C[i].z);
}


float lkd_balloons(vec3 p, inout int mat, inout int which)
{
	float d = 1e9;
	mat = DM_BALLOON;
	which = 0;
	for (int i = 0; i < 5; i++) {
		if (i == g_lkd_not_balloon) {
			continue;
		}
		vec3 u = vsub(p, LKB_C[i]);
		float r = LKB_R[i];
		if (vdot(u, u) > lk_sq(r * 1.5)) {
			float e = vlen(u) - r * 1.3;
			if (e < d) {
				d = e;
				which = i;
			}
			continue;
		}
		/* full above, drawn in toward the knot */
		float pinch = 1.0 - 0.16 * smoothstepf(0.1, -1.0, u.y / r);
		float e = lkd_ellipsoid(u, v3(r * pinch, r * 1.16, r * pinch));
		vec3 k = vsub(p, vadd(lkd_knot(i), v3(0, 0.006, 0)));
		e = min(e, sd_capped_cone(k, 0.0045, 0.0085, 0.008));
		if (e < d) {
			d = e;
			which = i;
		}
	}
	return d;
}

/* any group's distance, in its frame */
float lkd_sd(int g, vec3 q, inout int mat,
	inout int part)
{
	part = -1;
	switch (u_deco_kind[g]) {
	case LKD_WREATH:
		return lkd_wreath(u_wreath, q, mat);
	case LKD_GARLAND:
		return lkd_garland(q, mat, part);
	default:
		return lkd_balloons(q, mat, part);
	}
}

/* A cheap distance that is never more than the real one: to the shape
 * each group is roughly, with room for all that is on it. Marching on this
 * gets a ray to near the thing in a few long strides, and only then is
 * the real one -- the needles, the ornaments -- asked for. */
float lkd_bound(int g, vec3 q)
{
	switch (u_deco_kind[g]) {
	case LKD_WREATH: {
		float a, b;
		float d = lkd_ring(q, a, b) - 0.080;
		vec3 c = vadd(lkd_ring_at(LKD_KNOT_A, 1.0, 0.040), v3(0.0, 0.0, 0.012));
		return min(d, vlen(vsub(q, c)) - 0.13);
	}
	case LKD_GARLAND: {
		int run;
		float s;
		vec3 off;
		lkd_run(q, run, s, off);
		return vlen(off) - 0.066;
	}
	case LKD_BALLOONS: {
		float d = 1e9;
		for (int i = 0; i < 5; i++) {
			d = min(d, vlen(vsub(q, LKB_C[i])) - LKB_R[i] * 1.32);
		}
		return d;
	}
	default:
		return -1.0;
	}
}

vec3 lkd_normal(int g, vec3 q)
{
	const float e = 0.00025;
	int m, pt;
	vec3 k1 = v3(1, -1, -1), k2 = v3(-1, -1, 1), k3 = v3(-1, 1, -1), k4 = v3(1, 1, 1);
	return vnorm(vadd(vadd(vmul(k1, lkd_sd(g, vadd(q, vmul(k1, e)), m, pt)),
		vmul(k2, lkd_sd(g, vadd(q, vmul(k2, e)), m, pt))),
		vadd(vmul(k3, lkd_sd(g, vadd(q, vmul(k3, e)), m, pt)),
		vmul(k4, lkd_sd(g, vadd(q, vmul(k4, e)), m, pt)))));
}

/* where a ray is inside a box, if it is: t0..t1 (t0 may be 0) */
bool lkd_slab(vec3 o, vec3 d, vec3 lo, vec3 hi, float tmax, inout float t0, inout float t1)
{
	vec3 oo = o, dd = d, a = lo, b = hi;
	float n = 0.0, f = tmax;
	for (int i = 0; i < 3; i++) {
		if (abs(dd[i]) < 1e-12) {
			if (oo[i] < a[i] || oo[i] > b[i]) {
				return false;
			}
			continue;
		}
		float ta = (a[i] - oo[i]) / dd[i], tb = (b[i] - oo[i]) / dd[i];
		if (ta > tb) {
			float s = ta;
			ta = tb;
			tb = s;
		}
		n = max(n, ta);
		f = min(f, tb);
		if (n > f) {
			return false;
		}
	}
	t0 = n;
	t1 = f;
	return true;
}

/* the ray, through what the door is dressed in (door: the door's frame) */
void lkd_hit(bool door, vec3 o, vec3 d, inout lk_hit h)
{
	for (int i = 0; i < u_ndeco; i++) {
		int g = i;
		float t, t1;
		if ((u_deco_door[g] != 0) != door || !lkd_slab(o, d, u_deco_lo[g], u_deco_hi[g], h.t, t, t1)) {
			continue;
		}
		g_lkd_rough = (u_rough != 0);
		for (int n = 0; n < 220 && t < t1; n++) {
			vec3 q = vadd(o, vmul(d, t));
			float far = lkd_bound(g, q);
			if (far > 0.002) {
				t += far;
				continue;
			}
			int mat, part;
			float dist = lkd_sd(g, q, mat, part);
			if (dist < 0.00012) {
				h.t = t;
				h.id = LK_DECO;
				h.sub = mat;
				h.face = i;
				h.q = q;
				vec3 nn = lkd_normal(g, q);
				h.n = door ? lk_door_dir_out(nn) : nn;
				break;
			}
			t += max(dist * ((u_rough != 0) ? 0.62 : 0.48), 0.00008);
		}
		g_lkd_rough = false;
	}
}

/* how much of a light the dressing lets through to p, softly (as lk_soft);
 * skip: the group p is on, which shades itself only from a little way off */
float lkd_shadow(vec3 p, vec3 l, float dist, float k,
	int skip)
{
	float res = 1.0;
	g_lkd_rough = true;
	for (int i = 0; i < u_ndeco && res > 0.002; i++) {
		int g = i;
		vec3 o = (u_deco_door[g] != 0) ? lk_to_door(p) : p, d = (u_deco_door[g] != 0) ? lk_door_dir_in(l) : l;
		float t, t1;
		if (!lkd_slab(o, d, u_deco_lo[g], u_deco_hi[g], dist, t, t1)) {
			continue;
		}
		/* on itself only whether it is in the way at all: the soft edge
		 * a surface would give itself just off it is stripes -- but a
		 * balloon is shaded by the others in the bunch like anything */
		bool self = i == skip;
		if (self && u_deco_kind[g] == LKD_BALLOONS) {
			int mat, part;
			lkd_balloons(o, mat, part);
			g_lkd_not_balloon = part;
			self = false;
		}
		t = max(t, self ? 0.012 : 0.0015);
		float ph = 1e20;
		for (int n = 0; n < 48 && t < t1; n++) {
			int mat, part;
			vec3 q = vadd(o, vmul(d, t));
			/* well clear of the cone the penumbra is in: nothing from here */
			float far = lkd_bound(g, q);
			if (far > 0.004 && far * k >= t) {
				t += far;
				ph = 1e20;
				continue;
			}
			float hh = lkd_sd(g, q, mat, part);
			if (hh < 0.0001) {
				res = 0.0;
				break;
			}
			if (!self) {
				/* the nearest the ray came, from this distance and the last
				 * (Quilez): no stripes where the steps fall */
				float y = hh * hh / (2.0 * ph);
				float dd = sqrt(max(hh * hh - y * y, 0.0));
				res = min(res, k * dd / max(t - y, 1e-4));
			}
			ph = hh;
			t += clampf(hh * 0.9, 0.0015, 0.05);
		}
		g_lkd_not_balloon = -1;
	}
	g_lkd_rough = false;
	res = clampf(res, 0.0, 1.0);
	return res * res * (3.0 - 2.0 * res);
}

/* how shut in p is by the dressing beside it */
float lkd_ao(vec3 p, vec3 n)
{
	float ao = 1.0;
	for (int i = 0; i < u_ndeco; i++) {
		int g = i;
		vec3 o = (u_deco_door[g] != 0) ? lk_to_door(p) : p, d = (u_deco_door[g] != 0) ? lk_door_dir_in(n) : n;
		if (o.x < u_deco_lo[g].x - 0.06 || o.y < u_deco_lo[g].y - 0.06 || o.z < u_deco_lo[g].z - 0.06
			|| o.x > u_deco_hi[g].x + 0.06 || o.y > u_deco_hi[g].y + 0.06 || o.z > u_deco_hi[g].z + 0.06) {
			continue;
		}
		const float D[4] = float[4](0.006, 0.016, 0.032, 0.060);
		const float W[4] = float[4](0.30, 0.26, 0.22, 0.16);
		int mat, part;
		g_lkd_rough = true;
		/* nothing of it within reach: nothing to shut it in */
		if (lkd_bound(g, o) > 0.065 || lkd_sd(g, o, mat, part) > 0.065) {
			g_lkd_rough = false;
			continue;
		}
		float occ = 0.0;
		for (int j = 0; j < 4; j++) {
			float hh = lkd_sd(g, vadd(o, vmul(d, D[j])), mat, part);
			occ += clampf((D[j] - hh) / D[j], 0.0, 1.0) * W[j];
		}
		g_lkd_rough = false;
		ao *= 1.0 - clampf(occ, 0.0, 1.0) * 0.80;
	}
	return ao;
}


void lk_door_hit(vec3 ro, vec3 rd, inout lk_hit h)
{
	vec3 o = lk_to_door(ro), d = lk_door_dir_in(rd);
	float t;
	int f;
	if (lk_box(o, d, v3(0, LK_DY, 0), v3(LK_DW, LK_DY + LK_DH, LK_DT), h.t, t, f)) {
		h.t = t;
		h.face = f;
		h.q = vadd(o, vmul(d, t));
		h.id = f == 5 ? LK_DOOR : LK_DOOR_EDGE;
		h.n = lk_door_dir_out(lk_face_n(f));
	}
	vec3 so = lk_to_sign(o), sd = lk_sign_dir_in(d);
	if (lk_box(so, sd, v3(-LK_SIGN_W * 0.5, 0, 0), v3(LK_SIGN_W * 0.5, LK_SIGN_H, LK_SIGN_T),
			h.t, t, f)) {
		h.t = t;
		h.face = f;
		h.q = vadd(so, vmul(sd, t));
		h.id = f == 5 ? LK_SIGN : LK_SIGN_EDGE;
		h.n = lk_door_dir_out(lk_sign_dir_out(lk_face_n(f)));
	}
	if (lk_box(o, d, v3(LK_PL_X0, LK_PL_Y0, LK_DT), v3(LK_PL_X1, LK_PL_Y1, LK_DT + LK_PL_T),
			h.t, t, f)) {
		h.t = t;
		h.face = f;
		h.q = vadd(o, vmul(d, t));
		h.id = LK_PLATE;
		h.n = lk_door_dir_out(lk_face_n(f));
	}
	lk_march(LK_OC_LOCK, o, d, h);
	lk_march(LK_OC_KNOB, o, d, h);
	lk_march(LK_OC_NAIL, o, d, h);
	if (u_ndeco != 0) {
		lkd_hit(true, o, d, h);
	}
}

/* the nearest thing in the room along o + d t, from inside it (units) */
float lk_room_trace(vec3 o, vec3 d, float tmax, inout int kind, inout vec3 n)
{
	float best = tmax;
	kind = -1;
	float ct[3];
	vec3 cn[3];
	ct[0] = d.x > 0.0 ? (u_rm_shell.x - o.x) / d.x : d.x < 0.0 ? (-u_rm_shell.x - o.x) / d.x : 1e30;
	cn[0] = v3(d.x > 0.0 ? -1 : 1, 0, 0);
	ct[1] = d.y > 0.0 ? (u_rm_shell.z - o.y) / d.y : d.y < 0.0 ? (u_rm_shell.y - o.y) / d.y : 1e30;
	cn[1] = v3(0, d.y > 0.0 ? -1 : 1, 0);
	ct[2] = d.z > 0.0 ? (u_rm_fz - o.z) / d.z : d.z < 0.0 ? (u_rm_shell.w - o.z) / d.z : 1e30;
	cn[2] = v3(0, 0, d.z > 0.0 ? -1 : 1);
	for (int i = 0; i < 3; i++) {
		if (ct[i] > 0.0 && ct[i] < best) {
			best = ct[i];
			kind = LK_RM_SHELL;
			n = cn[i];
		}
	}
	for (int i = 0; i < u_rm_nbox; i++) {
		float t;
		int f;
		if (lk_box(o, d, u_rm_lo[i], u_rm_hi[i], best, t, f)) {
			best = t;
			kind = u_rm_kind[i];
			n = lk_face_n(f);
		}
	}
	return best;
}

/* into the room: from the doorway, or from where the eye already is */
void lk_room_hit(vec3 ro, vec3 rd, inout lk_hit h)
{
	float t0 = 0.0;
	vec3 o = ro;
	if (ro.z > -LK_WALL) {
		if (rd.z >= 0.0) {
			return;
		}
		t0 = (-LK_WALL - ro.z) / rd.z;
		o = vadd(ro, vmul(rd, t0));
		if (abs(o.x) > LK_OW || o.y < 0.0 || o.y > LK_OH || t0 >= h.t) {
			return;
		}
	}
	vec3 orr = vmul(vsub(o, u_rm_t), 1.0 / u_rm_s);
	int kind;
	vec3 n = v3(0, 0, 1);
	float tr = lk_room_trace(orr, rd, 1e9, kind, n);
	if (kind < 0) {
		return;
	}
	float t = t0 + tr * u_rm_s;
	if (t >= h.t) {
		return;
	}
	h.t = t;
	h.id = LK_ROOMIN;
	h.sub = kind;
	h.n = n;
	h.q = vadd(orr, vmul(rd, tr));
}

void lk_intersect(vec3 ro, vec3 rd, inout lk_hit h)
{
	h.t = 1e9;
	h.id = LK_NONE;
	h.face = 0;
	h.sub = 0;
	float t;
	int f;
	/* the wall, the doorway and the casing out of it */
	if (rd.z < 0.0 && ro.z > 0.0) {
		t = -ro.z / rd.z;
		vec3 p = vadd(ro, vmul(rd, t));
		if (p.y >= 0.0 && (abs(p.x) > LK_OW + LK_CW || p.y > LK_OH + LK_CW)) {
			h.t = t;
			h.id = LK_WALL_ID;
			h.n = v3(0, 0, 1);
			h.q = p;
		}
	}
	/* the step, and the sill through the doorway */
	if (rd.y < 0.0 && ro.y > 0.0) {
		t = -ro.y / rd.y;
		vec3 p = vadd(ro, vmul(rd, t));
		if (t < h.t && (p.z > 0.0 || (abs(p.x) < LK_OW && p.z > -LK_WALL))) {
			h.t = t;
			h.id = LK_STEP;
			h.n = v3(0, 1, 0);
			h.q = p;
		}
	}
	for (int i = 0; i < 3; i++) {
		if (lk_box(ro, rd, LK_CASE_LO[i], LK_CASE_HI[i], h.t, t, f)) {
			h.t = t;
			h.id = LK_CASING;
			h.face = f;
			h.sub = i;
			h.n = lk_face_n(f);
			h.q = vadd(ro, vmul(rd, t));
		}
	}
	/* the reveal: the jambs and the head, back through the wall */
	for (int si = -1; si <= 1; si += 2) {
		float s = float(si);
		if (rd.x * s > 0.0 && ro.x * s < LK_OW) {
			t = (s * LK_OW - ro.x) / rd.x;
			vec3 p = vadd(ro, vmul(rd, t));
			if (t < h.t && p.z <= 0.0 && p.z >= -LK_WALL && p.y >= 0.0 && p.y <= LK_OH) {
				h.t = t;
				h.id = LK_JAMB;
				h.n = v3(-s, 0, 0);
				h.q = p;
			}
		}
	}
	if (rd.y > 0.0 && ro.y < LK_OH) {
		t = (LK_OH - ro.y) / rd.y;
		vec3 p = vadd(ro, vmul(rd, t));
		if (t < h.t && p.z <= 0.0 && p.z >= -LK_WALL && abs(p.x) <= LK_OW) {
			h.t = t;
			h.id = LK_JAMB;
			h.n = v3(0, -1, 0);
			h.q = p;
		}
	}
	/* inside: the room, from where the ray comes through the doorway */
	if ((u_room_on != 0)) {
		lk_room_hit(ro, rd, h);
	} else if (rd.z < 0.0) {
		const float z0 = -LK_WALL, z1 = LK_ROOM_Z;
		float ct[5];
		vec3 cn[5];
		int cs[5];
		int nc = 0;
		if (rd.y < 0.0) {
			ct[nc] = (u_roomb.y - ro.y) / rd.y; cn[nc] = v3(0, 1, 0); cs[nc] = 0; nc++;
		}
		if (rd.y > 0.0) {
			ct[nc] = (u_roomb.z - ro.y) / rd.y; cn[nc] = v3(0, -1, 0); cs[nc] = 1; nc++;
		}
		if (rd.x < 0.0) {
			ct[nc] = (-u_roomb.x - ro.x) / rd.x; cn[nc] = v3(1, 0, 0); cs[nc] = 2; nc++;
		}
		if (rd.x > 0.0) {
			ct[nc] = (u_roomb.x - ro.x) / rd.x; cn[nc] = v3(-1, 0, 0); cs[nc] = 4; nc++;
		}
		ct[nc] = (z1 - ro.z) / rd.z; cn[nc] = v3(0, 0, 1); cs[nc] = 3; nc++;
		for (int i = 0; i < nc; i++) {
			if (ct[i] <= 0.0 || ct[i] >= h.t) {
				continue;
			}
			vec3 p = vadd(ro, vmul(rd, ct[i]));
			if (p.z > z0 + 1e-6 || p.z < z1 - 1e-6 || abs(p.x) > u_roomb.x + 1e-6
				|| p.y < u_roomb.y - 1e-6 || p.y > u_roomb.z + 1e-6) {
				continue;
			}
			h.t = ct[i];
			h.id = cs[i] == 3 ? LK_PICTURE : LK_INSIDE;
			h.sub = cs[i];
			h.n = cn[i];
			h.q = p;
		}
	}
	for (int i = 0; i < 6; i++) {
		if (lk_box(ro, rd, LK_LANTERN_LO[i], LK_LANTERN_HI[i], h.t, t, f)) {
			h.t = t;
			h.id = LK_LANTERN_ID[i];
			h.face = f;
			h.sub = i;
			h.n = lk_face_n(f);
			h.q = vadd(ro, vmul(rd, t));
		}
	}
	if (u_ndeco != 0) {
		lkd_hit(false, ro, rd, h);
	}
	lk_door_hit(ro, rd, h);
}

/* ---- light, and what is in its way ---- */

bool lk_in_doorway(vec3 p)
{
	return p.z < LK_CZ - 1e-5 && abs(p.x) < LK_OW + 1e-4 && p.y < LK_OH + 1e-4;
}

/* From inside the doorway the light has to come out through it: where the
 * ray to it crosses the front of the casing, how far inside the opening. */
float lk_tunnel(vec3 p, vec3 l, float dist, float rad)
{
	if (p.z >= LK_CZ || l.z <= 1e-6) {
		return 1.0;
	}
	float s = (LK_CZ - p.z) / l.z;
	if (s >= dist) {
		return 1.0;
	}
	vec3 c = vadd(p, vmul(l, s));
	float m = min(min(LK_OW - abs(c.x), LK_OH - c.y), c.y + 0.5);
	float w = rad * s / max(dist - s, 0.02) + 0.0006;
	return smoothstepf(-w, w, m);
}

/* the shadow of one thing on the door: march its distance along the ray,
 * the nearest it comes for how far along, which is the penumbra */
float lk_soft(int j, vec3 o, vec3 d, float tmax, float k)
{
	vec3 c;
	float r;
	lk_occ_bound(j, c, r);
	vec3 oc = vsub(c, o);
	float tc = vdot(oc, d);
	float d2 = vdot(oc, oc) - tc * tc;
	float reach = r + max(tc, 0.0) / k;
	bool inside = vdot(oc, oc) < r * r;
	if (!inside && (tc < 0.0 || d2 > reach * reach)) {
		return 1.0;
	}
	float t = max(0.0016, tc - r - 0.01), t1 = min(tmax, tc + r + 0.01);
	float res = 1.0;
	for (int i = 0; i < 36 && t < t1; i++) {
		float hh = lk_occ_sd(j, vadd(o, vmul(d, t)));
		if (hh < 0.00008) {
			return 0.0;
		}
		res = min(res, k * hh / t);
		t += clampf(hh, 0.0006, 0.024);
	}
	res = clampf(res, 0.0, 1.0);
	return res * res * (3.0 - 2.0 * res);
}

int lk_self_occ(lk_hit h)
{
	switch (h.id) {
	case LK_SIGN:
	case LK_SIGN_EDGE:
		return LK_OC_SIGN;
	case LK_PLATE:
		return LK_OC_PLATE;
	default:
		return -1;
	}
}

float lk_shadow(vec3 p, vec3 n, vec3 l, float dist,
	float rad, int light, lk_hit h)
{
	float s = 1.0;
	if (lk_in_doorway(p)) {
		s = lk_tunnel(p, l, dist, rad);
		if (s <= 0.002) {
			return 0.0;
		}
	}
	vec3 pp = vadd(p, vmul(n, 0.0007));
	/* the casing over the wall beside it, the lantern over the wall under it */
	if (h.id == LK_WALL_ID || h.id == LK_CASING || h.id == LK_STEP) {
		float t;
		int f;
		for (int i = 0; i < 3; i++) {
			if (!(h.id == LK_CASING && h.sub == i)
				&& lk_box(pp, l, LK_CASE_LO[i], LK_CASE_HI[i], dist, t, f)) {
				return 0.0;
			}
		}
		if (light != 1 && lk_box(pp, l, LK_LANTERN_LO[1], LK_LANTERN_HI[1], dist, t, f)) {
			return 0.0;
		}
	}
	if (h.id == LK_LGLASS || h.id == LK_IRON || h.id == LK_PICTURE || h.id == LK_INSIDE
		|| h.id == LK_ROOMIN) {
		return s;
	}
	vec3 o = lk_to_door(pp), d = lk_door_dir_in(l);
	float k = dist / max(rad, 1e-3);
	int self = lk_self_occ(h);
	for (int j = 0; j < LK_OC_N && s > 0.002; j++) {
		if (j != self) {
			s *= lk_soft(j, o, d, dist, k);
		}
	}
	/* the lantern is beside the door and low: the dressing's shadows from
	 * it are long, faint and dear to find; the lamp overhead's and the
	 * sun's are what it is seen by */
	if (u_ndeco != 0 && s > 0.002 && light != 1) {
		s *= lkd_shadow(pp, l, dist, k, h.id == LK_DECO ? h.face : -1);
	}
	return s;
}

/* how shut in a point on or near the door is by what stands on it */
float lk_ao(vec3 p, vec3 n)
{
	vec3 o = lk_to_door(p), d = lk_door_dir_in(n);
	const float D[4] = float[4](0.004, 0.012, 0.026, 0.050);
	const float W[4] = float[4](0.30, 0.26, 0.22, 0.16);
	float ao = 1.0;
	for (int j = 0; j < LK_OC_N; j++) {
		vec3 c;
		float r;
		lk_occ_bound(j, c, r);
		if (vlen(vsub(o, c)) > r + 0.06) {
			continue;
		}
		float occ = 0.0;
		for (int i = 0; i < 4; i++) {
			float hh = lk_occ_sd(j, vadd(o, vmul(d, D[i])));
			occ += clampf((D[i] - hh) / D[i], 0.0, 1.0) * W[i];
		}
		ao *= 1.0 - clampf(occ, 0.0, 1.0) * 0.85;
	}
	return ao;
}

/* GGX, its lobe widened by the size of the light so a big lamp makes a
 * broad soft highlight rather than a pinpoint, and dimmed to match */
float lk_ggx(vec3 n, vec3 v, vec3 l, float rough, float grow)
{
	float a0 = max(rough * rough, 0.002);
	float a = min(1.0, a0 + grow);
	vec3 hv = vnorm(vadd(v, l));
	float noh = max(vdot(n, hv), 0.0), nov = max(vdot(n, v), 1e-4), nol = max(vdot(n, l), 1e-4);
	float a2 = a * a;
	float dd = noh * noh * (a2 - 1.0) + 1.0;
	float D = a2 / (M_PI * dd * dd) * lk_sq(a0 / a);
	float k = lk_sq(rough + 1.0) / 8.0;
	float G = nov / (nov * (1.0 - k) + k) * nol / (nol * (1.0 - k) + k);
	return D * G / (4.0 * nov * nol);
}

/* all round: the street, the step the lamp lights, the sky (the rig's);
 * as a surface that rough sees it, the horizon not a line in it */
vec3 lk_env(vec3 r, float rough)
{
	vec3 sky = vmix(u_sky_lo, u_sky_hi, smoothstepf(0.0, 0.8, r.y));
	vec3 gnd = vmix(u_gnd_hi, u_gnd_lo, smoothstepf(0.0, -0.6, r.y));
	float b = 0.03 + 0.55 * clampf(rough, 0.0, 1.0);
	vec3 c = vmix(gnd, sky, smoothstepf(-b, b, r.y));
	if (u_porch > 0.0) {
		float lamp = max(vdot(r, vnorm(v3(0.12, 0.70, 0.70))), 0.0);
		c = vadd(c, vmul(v3(1.0, 0.80, 0.55), 0.55 * pow(lamp, 10.0) * u_porch));
		float step = max(vdot(r, vnorm(v3(0.0, -0.55, 0.84))), 0.0);
		c = vadd(c, vmul(v3(0.30, 0.23, 0.15), 0.30 * step * step * u_porch));
	}
	return c;
}

/* The porch's eave, out of sight overhead -- 2.45 m up, 0.95 m out from
 * the wall -- which keeps a high sun off the door: how much of the sun a
 * point still has, softly at the eave's shadow's edge. */
#define LK_EAVE_Y 2.45
#define LK_EAVE_Z 0.95
float lk_eave(vec3 p, vec3 l)
{
	if (l.y <= 1e-4 || p.y >= LK_EAVE_Y || p.z >= LK_EAVE_Z) {
		return 1.0;
	}
	float t = (LK_EAVE_Y - p.y) / l.y;
	float z = p.z + l.z * t, x = p.x + l.x * t;
	if (abs(x) > 2.6) {
		return 1.0;
	}
	/* soft: the eave is never seen, and its shadow is not to read as a
	 * line drawn across the house */
	float w = 0.12 * t + 0.10;
	return smoothstepf(LK_EAVE_Z - w, LK_EAVE_Z + w, z);
}

struct lk_mat {
	vec3 albedo, emit, n;
	float rough, metal, coat, ao;
	int sub;
	bool unlit, disp;
};

vec3 lk_shade(vec3 p, vec3 v, lk_mat m,
	lk_hit h)
{
	if (m.unlit) {
		return m.emit;
	}
	vec3 n = m.n;
	vec3 diff = vmul(m.albedo, 1.0 - m.metal);
	vec3 f0 = vmix(v3(0.04, 0.04, 0.04), m.albedo, m.metal);
	vec3 col = m.emit;
	float nov = max(vdot(n, v), 1e-4);
	for (int i = 0; i < 2; i++) {
		float level = i == 0 ? u_porch : u_lantern;
		if (level <= 0.002 || (i == 1 && (h.id == LK_LGLASS || h.id == LK_IRON))) {
			continue;
		}
		vec3 lv = vsub(LK_LIGHT_POS[i], p);
		float d2 = vdot(lv, lv), d = sqrt(d2);
		vec3 l = vmul(lv, 1.0 / d);
		float nol = vdot(n, l);
		if (nol <= 0.0 || vdot(h.n, l) <= -0.05) {
			continue;
		}
		float sh = lk_shadow(p, h.n, l, d, LK_LIGHT_R[i], i, h);
		if (sh <= 0.002) {
			continue;
		}
		vec3 E = vmul(LK_LIGHT_COL[i], level * sh * nol / d2);
		vec3 hv = vnorm(vadd(v, l));
		float fw = pow(1.0 - max(vdot(v, hv), 0.0), 5.0);
		vec3 F = vadd(f0, vmul(vsub(v3(1, 1, 1), f0), fw));
		float s = lk_ggx(n, v, l, m.rough, LK_LIGHT_R[i] / d);
		col = vadd(col, vmul3(vadd(vmul(diff, 1.0 / M_PI), vmul(F, s)), E));
		if (m.coat > 0.0) {
			float cs = lk_ggx(n, v, l, 0.10, LK_LIGHT_R[i] / d) * (0.04 + 0.96 * fw) * m.coat;
			col = vadd(col, vmul(E, cs));
		}
	}
	/* the sun, out and round this side of the house */
	if (u_sun_col.x > 0.0) {
		vec3 l = u_sun;
		float nol = vdot(n, l);
		if (nol > 0.0 && vdot(h.n, l) > -0.05) {
			float sh = lk_eave(p, l);
			if (sh > 0.002) {
				sh *= lk_shadow(p, h.n, l, 60.0, 60.0 * u_sun_soft, 2, h);
			}
			if (sh > 0.002) {
				vec3 E = vmul(u_sun_col, sh * nol);
				vec3 hv = vnorm(vadd(v, l));
				float fw = pow(1.0 - max(vdot(v, hv), 0.0), 5.0);
				vec3 F = vadd(f0, vmul(vsub(v3(1, 1, 1), f0), fw));
				float s = lk_ggx(n, v, l, m.rough, u_sun_soft);
				col = vadd(col, vmul3(vadd(vmul(diff, 1.0 / M_PI), vmul(F, s)), E));
				if (m.coat > 0.0) {
					float cs = lk_ggx(n, v, l, 0.10, u_sun_soft) * (0.04 + 0.96 * fw)
						* m.coat;
					col = vadd(col, vmul(E, cs));
				}
			}
		}
	}
	/* the moon, over the roofs to the left */
	if (u_moon_col.z > 0.0) {
		vec3 l = vnorm(LK_MOON_DIR);
		float nol = vdot(n, l);
		if (nol > 0.0 && vdot(h.n, l) > -0.05) {
			float sh = lk_in_doorway(p) ? lk_tunnel(p, l, 1e3, 1e3 * 0.012) : 1.0;
			col = vadd(col, vmul3(vmul(diff, 1.0 / M_PI), vmul(u_moon_col, nol * sh)));
		}
	}
	/* the room's light, out through the doorway once it is open */
	if (u_open > 0.0 && p.z > -LK_WALL) {
		vec3 lp = v3(0.0, 1.25, -0.80);
		vec3 lv = vsub(lp, p);
		float d2 = vdot(lv, lv), d = sqrt(d2);
		vec3 l = vmul(lv, 1.0 / d);
		float nol = vdot(n, l);
		if (nol > 0.0) {
			float sh = 1.0;
			if (p.z > -LK_WALL) {
				float s0 = (0.0 - p.z) / min(l.z, -1e-6);
				vec3 c = vadd(p, vmul(l, max(s0, 0.0)));
				sh = smoothstepf(-0.02, 0.02, min(LK_OW - abs(c.x), LK_OH - c.y));
			}
			vec3 E = vmul(v3(0.95, 0.70, 0.42), 0.55 * u_open * sh * nol / max(d2, 0.15));
			col = vadd(col, vmul3(vmul(diff, 1.0 / M_PI), E));
		}
	}
	/* the night all round, less where it is shut in */
	vec3 amb = vmix(u_amb_lo, u_amb_hi, 0.5 + 0.5 * n.y);
	col = vadd(col, vmul3(diff, vmul(amb, m.ao)));
	float ea, eb;
	env_brdf(nov, m.rough, ea, eb);
	vec3 r = reflect3(vmul(v, -1.0), n);
	vec3 env = lk_env(r, m.rough);
	col = vadd(col, vmul3(env, vmul(vadd(vmul(f0, ea), v3(eb, eb, eb)), m.ao)));
	if (m.coat > 0.0) {
		float ca, cb;
		env_brdf(nov, 0.10, ca, cb);
		col = vadd(col, vmul(env, (0.04 * ca + cb) * m.coat * m.ao));
	}
	return col;
}

/* ---- what things are made of ---- */

/* the pictures, by which (TX_*) */
vec4 lk_fetch(int t, ivec2 p)
{
	switch (t) {
	case TX_SIGN: return texelFetch(u_tsign, p, 0);
	case TX_GOLD: return texelFetch(u_tgold, p, 0);
	case TX_PLATE: return texelFetch(u_tplate, p, 0);
	case TX_PIC: return texelFetch(u_tpic, p, 0);
	case TX_PJ0: return texelFetch(u_tpj0, p, 0);
	case TX_PJ0 + 1: return texelFetch(u_tpj1, p, 0);
	default: return texelFetch(u_tpj2, p, 0);
	}
}

ivec2 lk_tex_size(int t)
{
	switch (t) {
	case TX_SIGN: return textureSize(u_tsign, 0);
	case TX_GOLD: return textureSize(u_tgold, 0);
	case TX_PLATE: return textureSize(u_tplate, 0);
	case TX_PIC: return textureSize(u_tpic, 0);
	case TX_PJ0: return textureSize(u_tpj0, 0);
	case TX_PJ0 + 1: return textureSize(u_tpj1, 0);
	default: return textureSize(u_tpj2, 0);
	}
}

bool lk_tex_has(int t)
{
	switch (t) {
	case TX_SIGN: return u_has_sign != 0;
	case TX_GOLD: return u_has_gold != 0;
	case TX_PLATE: return u_has_plate != 0;
	case TX_PIC: return u_has_pic != 0;
	default: return u_pj_on[t - TX_PJ0] != 0;
	}
}

/* bilinear, u and v 0..1 across the picture; linear light unless disp. As
 * draw.c's to the byte: four texels fetched and weighed by hand, each
 * unpremultiplied in whole numbers, then to linear by the same power. */
vec3 lk_tex_at(int t, float u, float v, bool disp, inout float alpha)
{
	if (!lk_tex_has(t)) {
		alpha = 0.0;
		return v3(0, 0, 0);
	}
	bool a8 = t == TX_GOLD || t == TX_PLATE;
	ivec2 sz = lk_tex_size(t);
	float x = u * float(sz.x) - 0.5, y = v * float(sz.y) - 0.5;
	int x0 = int(floor(x)), y0 = int(floor(y));
	float fx = x - float(x0), fy = y - float(y0);
	vec3 c = v3(0, 0, 0);
	float al = 0.0;
	for (int j = 0; j < 2; j++) {
		for (int i = 0; i < 2; i++) {
			int xi = clamp(x0 + i, 0, sz.x - 1), yi = clamp(y0 + j, 0, sz.y - 1);
			float wgt = (i != 0 ? fx : 1.0 - fx) * (j != 0 ? fy : 1.0 - fy);
			vec4 tx = lk_fetch(t, ivec2(xi, yi));
			if (a8) {
				al += wgt * tx.r;
				continue;
			}
			/* B, G, R, A as cairo keeps them */
			ivec4 b = ivec4(floor(tx * 255.0 + 0.5));
			int a = b.a;
			if (a == 0) {
				continue;
			}
			ivec3 rgb = min(ivec3(b.b, b.g, b.r) * 255 / a, ivec3(255));
			vec3 f = vec3(rgb) / 255.0;
			float wa = wgt * float(a) / 255.0;
			c += (disp ? f : pow(f, vec3(2.2))) * wa;
			al += wa;
		}
	}
	alpha = al;
	return al > 1e-6 && !a8 ? vmul(c, 1.0 / al) : c;
}

/* Walnut, cheaply: growth rings across the grain (u, metres), their line
 * wandering slowly along it (v), broad figure over them and open pores in
 * them; piece says which board, so that no two are cut alike. */
vec3 lk_wood(float u, float v, int piece, inout float rough)
{
	float s = room_seed(piece, 11);
	float x = u + (room_noise(v * 2.2 + s * 31.0, u * 6.0 + s * 5.0) - 0.5) * 0.034
		+ (room_noise(v * 11.0 + s * 3.0, u * 40.0) - 0.5) * 0.006;
	float ring = x * (95.0 + s * 45.0) + room_noise(x * 22.0 + s * 4.0, v * 0.9 + s * 9.0) * 3.2;
	float g = 0.5 + 0.5 * sin(ring * 2.0 * M_PI);
	g = g * g * g;
	float fig = room_noise(x * 13.0 + s * 3.0, v * 1.1 + s);
	float tone = 0.88 + s * 0.24;
	vec3 c = vmix(vmul(v3(0.215, 0.112, 0.054), tone), vmul(v3(0.082, 0.038, 0.017), tone),
		clampf(g * 0.62 + fig * 0.42, 0.0, 1.0));
	float pore = room_noise(u * 640.0 + s * 17.0, v * 30.0);
	pore = pore * pore * pore * pore;
	c = vmul(c, 1.0 - pore * 0.28);
	rough = 0.34 + g * 0.10 + pore * 0.16;
	return c;
}

float lk_rect_d(float x, float y, float x0, float y0, float x1, float y1, inout int edge)
{
	float d = x - x0;
	int e = 0;
	if (x1 - x < d) {
		d = x1 - x;
		e = 1;
	}
	if (y - y0 < d) {
		d = y - y0;
		e = 2;
	}
	if (y1 - y < d) {
		d = y1 - y;
		e = 3;
	}
	edge = e;
	return d;
}

/* The face of the door as relief: how far each point stands proud of the
 * stiles and rails (or sinks below them), what it is, and the nearest
 * edge of what it is in, which way its grain runs. */
#define LK_DF_FRAME 0
#define LK_DF_PANEL 1
#define LK_DF_MOULD 2
#define LK_DF_GLASS 3
#define LK_DF_BEAD 4
#define LK_DF_MUNTIN 5

float lk_relief(float x, float y, inout int what, inout int edge, inout float dist)
{
	int e;
	what = LK_DF_FRAME;
	edge = -1;
	dist = 1.0;
	float d = lk_rect_d(x, y, LK_STILE, LK_GLASS0, LK_DW - LK_STILE, LK_GLASS1, e);
	if (d >= 0.0) {
		edge = e;
		dist = d;
		if (d < 0.008) {
			what = LK_DF_BEAD;
			return 0.0032 * sin(M_PI * d / 0.008);
		}
		if (d < 0.016) {
			what = LK_DF_BEAD;
			float s = (d - 0.008) / 0.008;
			return -0.016 + 0.016 * sqrt(max(0.0, 1.0 - s * s));
		}
		float dv = abs(x - LK_DW * 0.5), dh = abs(y - LK_MUNTIN);
		float dm = min(dv, dh);
		if (dm < 0.013) {
			what = LK_DF_MUNTIN;
			edge = dv < dh ? 0 : 2;
			return -0.016 + 0.015 * sqrt(max(0.0, 1.0 - lk_sq(dm / 0.013)));
		}
		what = LK_DF_GLASS;
		dist = min(d, dm);
		return -0.016;
	}
	for (int i = 0; i < 2; i++) {
		float x0 = i != 0 ? LK_DW * 0.5 + LK_MID : LK_STILE;
		float x1 = i != 0 ? LK_DW - LK_STILE : LK_DW * 0.5 - LK_MID;
		d = lk_rect_d(x, y, x0, LK_PANEL0, x1, LK_RAIL0, e);
		if (d < 0.0) {
			continue;
		}
		edge = e;
		dist = d;
		if (d < 0.010) {
			what = LK_DF_MOULD;
			return -0.010 + sqrt(max(0.0, 0.0001 - d * d));
		}
		what = LK_DF_PANEL;
		if (d < 0.016) {
			return -0.010;
		}
		if (d < 0.060) {
			return -0.010 + 0.007 * (d - 0.016) / 0.044;
		}
		if (d < 0.064) {
			return -0.003 + 0.003 * smoothstepf(0.060, 0.064, d);
		}
		return 0.0;
	}
	return 0.0;
}

void lk_door_face(vec3 q, inout lk_mat m)
{
	float x = q.x, y = q.y;
	int what, edge;
	float dist;
	float h0 = lk_relief(x, y, what, edge, dist);
	const float e = 0.0006;
	int w2, e2;
	float d2;
	float hx = lk_relief(x + e, y, w2, e2, d2), hy = lk_relief(x, y + e, w2, e2, d2);
	vec3 nl = vnorm(v3(-(hx - h0) / e, -(hy - h0) / e, 1.0));
	m.n = lk_door_dir_out(nl);
	m.sub = what;
	/* which board, and which way its grain goes */
	bool along_y;
	int piece;
	switch (what) {
	case LK_DF_PANEL:
		along_y = true;
		piece = x < LK_DW * 0.5 ? 7 : 8;
		break;
	case LK_DF_MOULD:
	case LK_DF_BEAD:
		along_y = edge < 2;
		piece = 20 + edge;
		break;
	case LK_DF_MUNTIN:
		along_y = edge == 0;
		piece = 12 + edge;
		break;
	default:
		if (x < LK_STILE || x > LK_DW - LK_STILE || (abs(x - LK_DW * 0.5) < LK_MID + 0.001
			&& y > LK_PANEL0 && y < LK_RAIL0)) {
			along_y = true;
			piece = x < LK_STILE ? 1 : x > LK_DW - LK_STILE ? 2 : 6;
		} else {
			along_y = false;
			piece = y > LK_GLASS1 ? 3 : y > LK_PANEL0 ? 4 : 5;
		}
		break;
	}
	float rough;
	m.albedo = along_y ? lk_wood(x + float(piece) * 0.37, y, piece, rough)
		: lk_wood(y + float(piece) * 0.37, x, piece, rough);
	m.rough = rough;
	m.coat = 0.55;
	m.metal = 0.0;
	/* shut in: the grooves, and round the frame while it is shut */
	float ao = 1.0;
	if (what == LK_DF_PANEL && dist < 0.016) {
		ao = 0.60;
	} else if (what == LK_DF_PANEL && dist < 0.060) {
		ao = 0.60 + 0.40 * smoothstepf(0.016, 0.060, dist);
	} else if (what == LK_DF_MOULD) {
		ao = 0.70 + 0.30 * (1.0 - dist / 0.010);
	}
	float rim = min(min(x, LK_DW - x), LK_DY + LK_DH - y);
	ao *= 1.0 - 0.55 * exp(-rim / 0.030) * (1.0 - u_open);
	if (what == LK_DF_GLASS) {
		/* frosted, and the room's light coming through it */
		float fr = room_noise(x * 380.0, y * 380.0) * 0.6 + room_noise(x * 90.0, y * 90.0) * 0.4;
		float lamp = exp(-(lk_sq(x - 0.30) + lk_sq(y - 1.50) * 0.6) / 0.10);
		vec3 warm = vmul(v3(1.00, 0.56, 0.22), (0.16 + 0.34 * lamp) * (0.70 + 0.55 * fr));
		float shut = smoothstepf(0.0, 0.035, dist);
		m.emit = vmul(warm, u_lamp * u_glass * (0.35 + 0.65 * shut));
		m.albedo = v3(0.015, 0.012, 0.010);
		m.rough = 0.16 + fr * 0.10;
		m.coat = 0.0;
		ao *= 0.55 + 0.45 * shut;
	}
	m.ao = ao;
}

float lk_brick_h(float x, float y, inout int id, inout float edge)
{
	const float H = 0.075, L = 0.225, J = 0.0095;
	float row = floor(y / H);
	float off = (int(row) & 1) != 0 ? L * 0.5 : 0.0;
	float col = floor((x + off) / L);
	float bx = x + off - col * L, by = y - row * H;
	float e = min(min(bx - J * 0.5, L - J * 0.5 - bx), min(by - J * 0.5, H - J * 0.5 - by));
	e += (room_noise(x * 150.0, y * 150.0) - 0.5) * 0.0026;
	id = int(col) * 73 + int(row) * 1009;
	edge = e;
	if (e < 0.0) {
		return -0.0068 - room_noise(x * 320.0, y * 320.0) * 0.0014;
	}
	return -0.0042 * (1.0 - smoothstepf(0.0, 0.0065, e))
		+ (room_noise(x * 64.0 + float(id), y * 64.0) - 0.5) * 0.0012;
}

void lk_brick(vec3 p, inout lk_mat m)
{
	int id, i2;
	float edge, e2;
	const float e = 0.0007;
	float h0 = lk_brick_h(p.x, p.y, id, edge);
	float hx = lk_brick_h(p.x + e, p.y, i2, e2), hy = lk_brick_h(p.x, p.y + e, i2, e2);
	m.n = vnorm(v3(-(hx - h0) / e, -(hy - h0) / e, 1.0));
	if (edge < 0.0) {
		m.albedo = vmul(v3(0.27, 0.255, 0.235), 0.80 + 0.35 * room_noise(p.x * 200.0, p.y * 200.0));
		m.rough = 0.95;
		m.sub = 1;
		m.ao = 0.70;
	} else {
		float s0 = room_seed(id, 21), s1 = room_seed(id, 22);
		vec3 c = vmix(v3(0.25, 0.085, 0.050), v3(0.40, 0.165, 0.085), s0);
		if (s1 > 0.84) {
			c = vmul(c, 0.55);
		}
		c = vmul(c, 0.78 + 0.40 * room_noise(p.x * 48.0 + float(id), p.y * 48.0));
		float speck = room_noise(p.x * 260.0, p.y * 260.0);
		c = vmul(c, 1.0 - 0.45 * smoothstepf(0.78, 0.95, speck));
		m.albedo = c;
		m.rough = 0.82;
		m.sub = 0;
		m.ao = 0.85 + 0.15 * smoothstepf(0.0, 0.010, edge);
	}
	/* the casing standing off the wall beside it */
	float dx = abs(p.x) - (LK_OW + LK_CW), dy = p.y - (LK_OH + LK_CW);
	float dc = dx > 0.0 && dy > 0.0 ? length(vec2(dx, dy)) : max(dx, dy);
	if (dc > 0.0) {
		m.ao *= 1.0 - 0.40 * exp(-dc / 0.022);
	}
}

float lk_casing_h(float t)
{
	float h = -0.006 * (1.0 - smoothstepf(0.0, 0.07, t));
	h += 0.0028 * exp(-lk_sq((t - 0.15) / 0.035));
	h -= 0.0020 * exp(-lk_sq((t - 0.25) / 0.020));
	h += 0.0060 * smoothstepf(0.80, 0.86, t);
	h -= 0.0090 * lk_sq(smoothstepf(0.93, 1.0, t));
	return h;
}

void lk_casing(lk_hit h, vec3 p, inout lk_mat m)
{
	m.albedo = vmul(v3(0.60, 0.555, 0.48), 0.95 + 0.06 * room_noise(p.x * 18.0 + p.y * 2.0,
		p.y * 260.0 + p.x * 9.0));
	m.rough = 0.42;
	m.coat = 0.25;
	m.ao = 1.0;
	m.n = h.n;
	if (h.face != 5) {
		if (h.face >> 1 == 0 && abs(p.x) < LK_OW + 0.001) {
			/* the side facing into the doorway: the jamb, coming forward */
			m.ao = 1.0 - 0.45 * exp(-abs(p.z - LK_DZ) / 0.015);
		}
		return;
	}
	float tx = (abs(p.x) - LK_OW) / LK_CW, ty = (p.y - LK_OH) / LK_CW;
	bool side = tx > ty;
	float t = side ? tx : ty;
	const float e = 0.004;
	float dh = (lk_casing_h(t + e) - lk_casing_h(t - e)) / (2.0 * e) / LK_CW;
	m.n = side ? vnorm(v3(-dh * (p.x < 0.0 ? -1.0 : 1.0), 0.0, 1.0)) : vnorm(v3(0.0, -dh, 1.0));
	m.ao = 0.80 + 0.20 * smoothstepf(0.0, 0.25, t);
	m.sub = t < 0.3 ? 1 : 0;
}

void lk_sign_face(lk_hit h, inout lk_mat m)
{
	float u = (h.q.x + LK_SIGN_W * 0.5) / LK_SIGN_W, v = 1.0 - h.q.y / LK_SIGN_H;
	float a, ga;
	m.albedo = lk_tex_at(TX_SIGN, u, v, false, a);
	if (a < 0.5) {
		m.albedo = v3(0.20, 0.11, 0.05);
	}
	lk_tex_at(TX_GOLD, u, v, false, ga);
	/* the gilt stands up off the board a little */
	ivec2 gs = lk_tex_size(TX_GOLD);
	float du = 1.5 / float(max(gs.x, 1)), dv = 1.5 / float(max(gs.y, 1));
	float gx, gy;
	lk_tex_at(TX_GOLD, u + du, v, false, gx);
	lk_tex_at(TX_GOLD, u, v + dv, false, gy);
	float sx = (gx - ga) / (du * LK_SIGN_W) * 0.0006, sy = (gy - ga) / (dv * LK_SIGN_H) * 0.0006;
	vec3 nl = vnorm(v3(-sx, sy, 1.0));
	m.n = lk_door_dir_out(lk_sign_dir_out(nl));
	m.albedo = vmix(m.albedo, v3(0.98, 0.74, 0.34), ga);
	m.metal = ga;
	m.rough = 0.42 - 0.20 * ga;
	m.coat = 0.45 * (1.0 - ga);
	m.ao = 1.0;
	m.sub = ga > 0.5 ? 1 : 0;
}

void lk_plate_face(lk_hit h, inout lk_mat m)
{
	float x = h.q.x, y = h.q.y;
	m.metal = 1.0;
	m.albedo = vmul(v3(0.93, 0.70, 0.36), 0.90 + 0.10 * room_noise(x * 18.0, y * 1400.0));
	m.rough = 0.30 + 0.10 * room_noise(x * 6.0, y * 900.0);
	m.ao = 1.0;
	vec3 nl = lk_face_n(h.face);
	if (h.face == 5) {
		/* a bevel round the edge */
		float be = min(min(x - LK_PL_X0, LK_PL_X1 - x), min(y - LK_PL_Y0, LK_PL_Y1 - y));
		if (be < 0.0022) {
			float s = 1.0 - be / 0.0022;
			float ex = x - LK_PL_X0 < LK_PL_X1 - x ? -1.0 : 1.0, ey = y - LK_PL_Y0 < LK_PL_Y1 - y ? -1.0 : 1.0;
			bool xs = min(x - LK_PL_X0, LK_PL_X1 - x) < min(y - LK_PL_Y0, LK_PL_Y1 - y);
			nl = vnorm(v3(xs ? ex * s : 0.0, xs ? 0.0 : ey * s, 1.0));
			m.sub = 2;
		}
		if (x > LK_WIN_X0 && x < LK_WIN_X1 && y > LK_WIN_Y0 && y < LK_WIN_Y1) {
			/* the slot: black glass, its edge going down into it */
			float we = min(min(x - LK_WIN_X0, LK_WIN_X1 - x), min(y - LK_WIN_Y0, LK_WIN_Y1 - y));
			m.metal = 0.0;
			m.albedo = v3(0.010, 0.008, 0.007);
			m.rough = 0.07;
			m.coat = 0.6;
			m.ao = 0.45 + 0.55 * smoothstepf(0.0, 0.006, we);
			m.sub = 3;
			if (we < 0.0016) {
				bool xs = min(x - LK_WIN_X0, LK_WIN_X1 - x) < min(y - LK_WIN_Y0, LK_WIN_Y1 - y);
				float ex = x - LK_WIN_X0 < LK_WIN_X1 - x ? 1.0 : -1.0;
				float ey = y - LK_WIN_Y0 < LK_WIN_Y1 - y ? 1.0 : -1.0;
				nl = vnorm(v3(xs ? ex : 0.0, xs ? 0.0 : ey, 0.9));
				m.metal = 1.0;
				m.albedo = v3(0.80, 0.60, 0.30);
				m.rough = 0.35;
				m.coat = 0.0;
			}
		} else {
			float u = (x - LK_PL_X0) / (LK_PL_X1 - LK_PL_X0), v = (LK_PL_Y1 - y) / (LK_PL_Y1 - LK_PL_Y0);
			float ea;
			lk_tex_at(TX_PLATE, u, v, false, ea);
			if (ea > 0.02) {
				m.albedo = vmix(m.albedo, v3(0.16, 0.10, 0.045), ea * 0.85);
				m.rough = min(1.0, m.rough + ea * 0.35);
				m.sub = 1;
			}
		}
	}
	m.n = lk_door_dir_out(nl);
}

vec3 lk_room_colour(vec3 p, vec3 n, int kind, inout int sub);

/* room_project, for the room's three cameras */
bool lk_project_room(int k, vec3 p, out float u, out float v)
{
	u = 0.0;
	v = 0.0;
	vec3 w = p - u_pj_eye[k];
	float dw = dot(w, u_pj_ww[k]);
	if (dw < 1e-3) {
		return false;
	}
	u = 0.5 + (dot(w, u_pj_uu[k]) / dw) / u_pj_fov[k].x;
	v = 0.5 - (dot(w, u_pj_vv[k]) / dw) / u_pj_fov[k].y;
	return true;
}

/* The weather on what a ray met, outside. Rain blown in on the wall, the
 * step shining and in puddles, the iron of the lantern wet; the door,
 * under the eave, dry. Snow on whatever faces up -- the lantern's roof,
 * the top of the board, the ledge every course of brick makes over the
 * mortar under it. */
void lk_weather_on(lk_hit h, vec3 p, inout lk_mat m)
{
	if (u_wet > 0.0) {
		float w = 0.0;
		switch (h.id) {
		case LK_WALL_ID:
			w = u_wet * (0.50 + 0.50 * smoothstepf(1.9, 0.5, p.y))
				* (0.70 + 0.30 * room_noise(p.x * 6.0, p.y * 2.5));
			break;
		case LK_STEP:
			w = p.z > 0.0 ? u_wet : 0.0;
			break;
		case LK_CASING:
			w = u_wet * 0.30;
			break;
		case LK_IRON:
		case LK_LGLASS:
			w = u_wet * 0.80;
			break;
		default:
			break;
		}
		if (w > 0.0) {
			m.albedo = vmul(m.albedo, 1.0 - 0.40 * w);
			m.rough += (0.16 - m.rough) * w * 0.85;
			m.coat = max(m.coat, 0.50 * w);
			if (h.id == LK_STEP) {
				float pd = smoothstepf(0.46, 0.60, room_noise(p.x * 3.0 + 7.0, p.z * 3.0));
				m.rough += (0.03 - m.rough) * pd;
				m.albedo = vmul(m.albedo, 1.0 - 0.45 * pd);
				m.coat = max(m.coat, pd);
				m.n = vnorm(vmix(m.n, v3(0, 1, 0), pd));
			}
		}
	}
	if (u_snow > 0.0) {
		/* on the wall, only the very lip of each course */
		float ny = h.id == LK_WALL_ID ? (m.n.y - 0.22) * 4.0 : h.n.y;
		float up = smoothstepf(0.40, 0.80, ny);
		if (up > 0.0) {
			float drift = room_noise(p.x * 23.0 + p.z * 11.0, p.z * 23.0 + p.y * 9.0);
			float cover = up * smoothstepf(0.15, 0.45, u_snow * (0.55 + 0.6 * drift));
			if (cover > 0.0) {
				m.albedo = vmix(m.albedo, v3(0.86, 0.88, 0.93), cover);
				m.rough += (0.80 - m.rough) * cover;
				m.metal *= 1.0 - cover;
				m.coat *= 1.0 - cover;
				m.emit = vmul(m.emit, 1.0 - cover);
				m.n = vnorm(vmix(m.n, v3(0, 1, 0), cover * 0.6));
			}
		}
	}
}

/* ---- dressed for the day: what it is made of ---- */

/* Needles, as shading. Each sprig lays its needles its own way across the
 * surface; their rows tilt the normal this way and that, dark down in the
 * crowd of them, the new growth lighter at the tips. q: the point in the
 * group's frame; tf, bf: two ways along the surface there, and tw, bw the
 * same in the world; lump: how far out it stands. */
void lkd_needles(inout lk_mat m, vec3 q, vec3 tf, vec3 bf, vec3 tw, vec3 bw,
	float lump, float dark)
{
	float ang = lkd_noise3(vmul(q, 30.0)) * 9.4;
	float c = cos(ang), s = sin(ang);
	vec3 dirf = vadd(vmul(tf, c), vmul(bf, s)), crossf = vadd(vmul(tf, -s), vmul(bf, c));
	vec3 dirw = vadd(vmul(tw, c), vmul(bw, s)), crossw = vadd(vmul(tw, -s), vmul(bw, c));
	float u = vdot(q, dirf), v = vdot(q, crossf);
	float row = sin(v * 1500.0 + 9.0 * lkd_noise3(vmul(q, 140.0)));
	float brk = lkd_noise3(v3(u * 160.0, v * 1100.0, 0.37));
	m.n = vnorm(vadd(m.n, vadd(vmul(crossw, 0.55 * row), vmul(dirw, 0.35 * (brk - 0.5)))));
	float tone = lkd_noise3(vadd(vmul(q, 55.0), v3(2.2, 7.1, 4.4)));
	vec3 col = vmix(v3(0.010, 0.030, 0.014), v3(0.040, 0.095, 0.038), tone);
	float tip = smoothstepf(0.55, 0.95, lump) * smoothstepf(0.1, 0.9, brk);
	col = vmix(col, v3(0.085, 0.150, 0.050), tip * 0.75);
	col = vmul(col, 0.70 + 0.30 * (0.5 + 0.5 * row));
	m.albedo = vmul(col, dark);
	m.rough = 0.60;
	m.coat = 0.06;
	m.ao *= 0.40 + 0.60 * smoothstepf(0.1, 0.9, lump);
}

/* a little noise of three numbers, for a surface that glitters */
vec3 lkd_jitter(vec3 q, float scale)
{
	int x = int(floor(q.x * scale)), y = int(floor(q.y * scale)), z = int(floor(q.z * scale));
	return v3(room_hash(x * 3 + z, y) - 0.5, room_hash(y * 5 + x, z + 7) - 0.5,
		room_hash(z * 7 + y, x + 13) - 0.5);
}

void lkd_material(lk_hit h, vec3 p, inout lk_mat m)
{
	int g = h.face;
	vec3 q = h.q;
	int mat, part;
	m.ao = lkd_ao(p, h.n);
	m.rough = 0.5;
	switch (h.sub) {
	case DM_NEEDLE:
		if (u_deco_kind[g] == LKD_WREATH) {
			float a, b;
			lkd_ring(q, a, b);
			vec3 tf = v3(-sin(a), cos(a), 0.0);
			vec3 bf = v3(-sin(b) * cos(a), -sin(b) * sin(a), cos(b));
			lkd_needles(m, q, tf, bf, lk_door_dir_out(tf), lk_door_dir_out(bf),
				lkd_fir(q), 1.0);
		} else {
			int run;
			float s;
			vec3 off;
			lkd_run(q, run, s, off);
			vec3 t = run == 1 ? v3(1, 0, 0) : v3(0, 1, 0);
			vec3 bt = vnorm(vcross(t, vlen(off) > 1e-6 ? off : v3(0, 0, 1)));
			lkd_needles(m, q, t, bt, t, bt, lkd_fir(q), 1.0);
		}
		break;
	case DM_BERRY:
		m.albedo = v3(0.60, 0.022, 0.032);
		m.rough = 0.10;
		m.coat = 1.0;
		break;
	case DM_CONE: {
		float sc1 = sin(q.x * 820.0 + q.y * 410.0) * sin(q.y * 820.0 - q.x * 410.0);
		m.albedo = vmul(v3(0.21, 0.11, 0.050), 0.55 + 0.45 * abs(sc1));
		m.rough = 0.78;
		m.ao *= 0.75 + 0.25 * abs(sc1);
		break;
	}
	case DM_BOW:
		if (u_wreath == LKD_TINSEL) {
			m.albedo = v3(0.86, 0.64, 0.30);
			m.metal = 0.65;
			m.rough = 0.30;
		} else {
			m.albedo = v3(0.50, 0.020, 0.030);
			m.rough = 0.34;
			m.coat = 0.55;
		}
		break;
	case DM_BULB: {
		lkd_garland(q, mat, part);
		int run = part < 0 ? 0 : part % 3, k = part < 0 ? 0 : part / 3;
		vec3 col = LKD_BULB_COL[(k + run * 2) % LKG_N];
		vec3 c = lkd_bulb_at(run, k);
		if (q.z - c.z < -0.0045) {
			/* its socket, in the green */
			m.albedo = v3(0.020, 0.045, 0.020);
			m.rough = 0.4;
			break;
		}
		m.emit = vmul(col, 1.9);
		m.albedo = vmul(col, 0.05);
		m.rough = 0.08;
		m.coat = 0.9;
		break;
	}
	case DM_TINSEL:
		m.n = vnorm(vadd(m.n, vmul(lkd_jitter(q, 380.0), 1.6)));
		m.albedo = v3(0.95, 0.70, 0.27);
		m.metal = 1.0;
		m.rough = 0.16;
		break;
	case DM_BAUBLE: {
		float a, b, ak;
		lkd_ring(q, a, b);
		int k = lkd_slot(a, ak);
		m.albedo = (k & 1) != 0 ? v3(0.90, 0.91, 0.93) : v3(0.95, 0.72, 0.32);
		m.metal = 1.0;
		m.rough = 0.06;
		break;
	}
	case DM_BALLOON: {
		lkd_balloons(q, mat, part);
		int i = part < 0 ? 0 : part;
		m.albedo = LKB_COL[i];
		m.rough = 0.17;
		m.coat = 0.95;
		if (i == 1) {
			m.metal = 0.55;
		}
		if (q.y < LKB_C[i].y - LKB_R[i] * 1.12) {
			m.rough = 0.45;
			m.coat = 0.2;
		}
		break;
	}
	default:
		m.albedo = v3(0.3, 0.3, 0.3);
		break;
	}
}

void lk_material(lk_hit h, vec3 p, inout lk_mat m)
{
	m = lk_mat(vec3(0.0), vec3(0.0), vec3(0.0), 0.0, 0.0, 0.0, 0.0, 0, false, false);
	m.n = h.n;
	m.ao = 1.0;
	m.rough = 0.5;
	switch (h.id) {
	case LK_WALL_ID:
		lk_brick(p, m);
		break;
	case LK_CASING:
		lk_casing(h, p, m);
		break;
	case LK_JAMB:
		m.albedo = v3(0.56, 0.52, 0.45);
		m.rough = 0.50;
		m.coat = 0.15;
		if (p.z > LK_DZ) {
			m.ao = 1.0 - 0.50 * exp(-(p.z - LK_DZ) / 0.014) * (1.0 - u_open);
		} else {
			/* behind the door, in the wall: plaster */
			m.albedo = v3(0.50, 0.46, 0.40);
			m.rough = 0.90;
			m.coat = 0.0;
		}
		break;
	case LK_STEP: {
		float g = room_noise(p.x * 30.0, p.z * 30.0) * 0.6 + room_noise(p.x * 160.0, p.z * 160.0) * 0.4;
		m.albedo = vmul(v3(0.30, 0.285, 0.265), 0.75 + 0.40 * g);
		m.rough = 0.80;
		if (p.z < 0.0) {
			/* the sill: oak, worn */
			m.albedo = vmul(v3(0.34, 0.22, 0.12), 0.85 + 0.25 * room_noise(p.x * 3.0, p.z * 120.0));
			m.rough = 0.55;
		}
		break;
	}
	case LK_INSIDE: {
		/* the room round the picture of it, the picture's colours carried
		 * on along the walls, darker toward the door */
		float fall = 0.45 + 0.55 * smoothstepf(-LK_WALL, LK_ROOM_Z, p.z);
		m.emit = vmul(u_edge[h.sub], fall);
		m.unlit = true;
		m.disp = true;
		break;
	}
	case LK_ROOMIN:
		m.emit = lk_room_colour(h.q, h.n, h.sub, m.sub);
		m.unlit = true;
		m.disp = true;
		break;
	case LK_PICTURE: {
		float u = (p.x - u_pic.x) / u_pic.z, v = 1.0 - (p.y - u_pic.y) / u_pic.w;
		float a;
		if (u_has_pic != 0 && u >= 0.0 && u <= 1.0 && v >= 0.0 && v <= 1.0) {
			m.emit = lk_tex_at(TX_PIC, u, v, true, a);
			m.disp = true;
		} else {
			m.emit = vmul(vadd(vadd(u_edge[0], u_edge[1]), vadd(u_edge[2], u_edge[4])), 0.25);
			m.disp = true;
		}
		m.unlit = true;
		break;
	}
	case LK_DOOR:
		lk_door_face(h.q, m);
		break;
	case LK_DOOR_EDGE: {
		float rough;
		m.albedo = vmul(lk_wood(h.q.z * 3.0, h.q.y, 30 + h.face, rough), 0.85);
		m.rough = rough;
		m.coat = 0.3;
		break;
	}
	case LK_SIGN:
		lk_sign_face(h, m);
		break;
	case LK_SIGN_EDGE: {
		float rough;
		m.albedo = vmul(lk_wood(h.q.z * 4.0 + h.q.x, h.q.y + h.q.x, 40 + h.face, rough),
			1.30);
		m.rough = rough;
		m.coat = 0.2;
		break;
	}
	case LK_PLATE:
		lk_plate_face(h, m);
		break;
	case LK_BRASS:
	case LK_KEY: {
		vec3 q = h.q;
		float nz = room_noise(q.x * 900.0 + q.z * 600.0, q.y * 900.0);
		m.metal = 1.0;
		m.albedo = h.id == LK_KEY ? v3(0.98, 0.79, 0.44) : v3(0.92, 0.70, 0.37);
		m.albedo = vmul(m.albedo, 0.92 + 0.10 * nz);
		m.rough = (h.id == LK_KEY ? 0.17 : 0.22) + 0.08 * nz;
		m.sub = h.id == LK_KEY ? 1 : 0;
		break;
	}
	case LK_LGLASS: {
		/* the lantern: glass in an iron frame, the flame inside it */
		vec3 lo = LK_LANTERN_LO[0], hi = LK_LANTERN_HI[0];
		int ax = h.face >> 1;
		float a = ax == 0 ? p.z : p.x, b = ax == 1 ? p.z : p.y;
		float a0 = ax == 0 ? lo.z : lo.x, a1 = ax == 0 ? hi.z : hi.x;
		float b0 = ax == 1 ? lo.z : lo.y, b1 = ax == 1 ? hi.z : hi.y;
		float fe = min(min(a - a0, a1 - a), min(b - b0, b1 - b));
		float mid = abs(a - (a0 + a1) * 0.5);
		if (fe < 0.0075 || (ax != 1 && mid < 0.0022)) {
			m.albedo = v3(0.035, 0.032, 0.030);
			m.metal = 0.6;
			m.rough = 0.38;
			m.sub = 1;
			break;
		}
		vec3 bulb = LK_LIGHT_POS[1];
		float ba = ax == 0 ? bulb.z : bulb.x, bb = ax == 1 ? bulb.z : bulb.y;
		float r2 = lk_sq(a - ba) + lk_sq(b - bb);
		m.emit = vmul(vadd(vmul(v3(1.0, 0.50, 0.17), 0.24),
			vmul(v3(1.0, 0.76, 0.45), 1.5 * exp(-r2 / 0.0008))), u_lantern);
		m.albedo = v3(0.02, 0.02, 0.02);
		m.rough = 0.10;
		break;
	}
	case LK_IRON:
		m.albedo = v3(0.035, 0.032, 0.030);
		m.metal = 0.6;
		m.rough = 0.40;
		break;
	case LK_DECO:
		lkd_material(h, p, m);
		break;
	default:
		m.unlit = true;
		m.emit = v3(0.004, 0.005, 0.009);
		break;
	}
	if (h.id >= LK_DOOR && h.id <= LK_KEY) {
		m.ao *= lk_ao(p, h.n);
	}
	if (u_ndeco != 0 && !m.unlit && h.id != LK_DECO) {
		m.ao *= lkd_ao(p, h.n);
	}
	bool lit_or_aloft = h.id == LK_DECO && (h.sub == DM_BULB || h.sub == DM_BALLOON);
	if (!m.unlit && !lit_or_aloft && (u_wet > 0.0 || u_snow > 0.0) && p.z > -0.01) {
		lk_weather_on(h, p, m);
	}
}

/* What a point in the room looks like: the picture of it, from the first
 * camera that saw it (in its frame, facing it, nothing in between), or
 * else made here -- walnut, the walls' colour, under the room's lamp. */
vec3 lk_room_colour(vec3 p, vec3 n, int kind, inout int sub)
{
	for (int k = 0; k < 3; k++) {
		float u, v;
		if (u_pj_on[k] == 0 || !lk_project_room(k, p, u, v) || u < 0.0 || u > 1.0 || v < 0.0
			|| v > 1.0) {
			continue;
		}
		vec3 d = vsub(p, u_pj_eye[k]);
		float dist = vlen(d);
		if (dist < 1e-6 || vdot(n, d) > 0.0) {
			continue;
		}
		int kk;
		vec3 nn;
		float th = lk_room_trace(u_pj_eye[k], vmul(d, 1.0 / dist), dist + 1.0, kk, nn);
		if (th < dist - 0.10) {
			continue;   /* something stood between it and the camera */
		}
		float a;
		float px = u_pj_rect[k].x + u * u_pj_rect[k].z, py = u_pj_rect[k].y + v * u_pj_rect[k].w;
		sub = k;
		vec2 ts = vec2(lk_tex_size(TX_PJ0 + k));
		return lk_tex_at(TX_PJ0 + k, px / ts.x, py / ts.y, true, a);
	}
	sub = 2 + kind;
	/* made: walnut for the desk and the case, the walls in the colour they
	 * have at the edges of the picture, the lamp over the desk */
	vec3 c;
	float rough;
	switch (kind) {
	case LK_RM_DESK:
	case LK_RM_LEG: {
		bool across = abs(n.z) > 0.5;
		vec3 a = across ? lk_wood(p.x * u_rm_s * 0.6, p.y * u_rm_s, 50 + kind, rough)
			: lk_wood(p.z * u_rm_s * 0.6, p.y * u_rm_s, 52 + kind, rough);
		c = vmul(a, 1.35);
		if (kind == LK_RM_DESK && n.z > 0.5 && p.y < -RM_TOP_T - 0.2) {
			/* the drawer, in the apron: a dark line round it, a brass pull */
			float dx = RM_DR_HX - abs(p.x), dy = min(p.y - (RM_DR_BOT - 0.10), (-RM_TOP_T - 0.15) - p.y);
			if (dx > 0.0 && dy > 0.0 && min(dx, dy) < 0.12) {
				c = vmul(c, 0.35);
			}
			if (abs(p.x) < 1.9 && abs(p.y - (RM_DR_BOT + RM_DR_TOP) * 0.5) < 0.40) {
				c = v3(0.55, 0.40, 0.16);
			}
		}
		break;
	}
	case LK_RM_CASE:
		c = vmul(lk_wood(p.z * u_rm_s * 0.6 + p.x * u_rm_s, p.y * u_rm_s, 60, rough), 1.1);
		break;
	case LK_RM_POST:
		c = v3(0.30, 0.040, 0.025);
		break;
	case LK_RM_CONSOLE:
		c = v3(0.050, 0.046, 0.042);
		break;
	case LK_RM_PROP:
		c = v3(0.42, 0.31, 0.12);
		break;
	default:
		if (n.y > 0.5) {
			/* the floor: boards running away from the door */
			float bx = p.x * u_rm_s / 0.14;
			int board = int(floor(bx));
			c = vmul(lk_wood(bx * 0.14, p.z * u_rm_s + float(board) * 1.7, 70 + board, rough), 1.3);
			float seam = abs(bx - floor(bx) - 0.5);
			c = vmul(c, 1.0 - 0.45 * smoothstepf(0.47, 0.5, seam));
		} else if (n.y < -0.5) {
			c = u_rm_ceil;
		} else {
			/* the wall, as the picture has it beside the bookcase; along its
			 * foot a skirting board, its top edge catching the lamp */
			c = u_rm_wall;
			float up = p.y - u_rm_shell.y;
			if (up < 4.2) {
				c = up > 3.8 ? v3(0.30, 0.19, 0.11) : v3(0.17, 0.105, 0.06);
			}
			return vmul(c, 0.86 + 0.14 * smoothstepf(-10.0, 20.0, p.y)
				- 0.10 * smoothstepf(30.0, 60.0, abs(p.x)));
		}
		break;
	}
	/* the lamp is over the desk; lower down and further off, darker */
	vec3 lamp = v3(0.0, 34.0, (u_rm_desk.y + u_rm_desk.z) * 0.5);
	vec3 lv = vsub(lamp, p);
	float ld = vlen(lv);
	float lit = max(vdot(n, vmul(lv, 1.0 / ld)), 0.0);
	float fall = 1.0 / (1.0 + lk_sq(ld / 38.0));
	float k = 0.30 + 0.95 * lit * fall;
	/* shut in: down at the floor, under the desk */
	if (p.y < -RM_TOP_T && abs(p.x) < u_rm_desk.x && p.z > u_rm_desk.y && p.z < u_rm_desk.z) {
		k *= 0.45;
	}
	k *= 0.70 + 0.30 * smoothstepf(0.0, 6.0, p.y - u_rm_shell.y);
	if (kind != LK_RM_SHELL || n.y > 0.5) {
		/* wood is made in light; shown, it wants the curve the pictures went through */
		return tonemap(vmul(c, k * 0.9));
	}
	return vmul(c, 0.75 + 0.25 * k);
}

/* one sample: what the ray meets, lit, as it is to be shown */
vec3 lk_sample(vec3 ro, vec3 rd, inout int aa)
{
	lk_hit h;
	lk_intersect(ro, rd, h);
	vec3 p = vadd(ro, vmul(rd, h.t));
	lk_mat m;
	lk_material(h, p, m);
	aa = h.id * 8 + (m.sub & 7);
	if (m.disp) {
		return m.emit;
	}
	vec3 v = vmul(rd, -1.0);
	if (vdot(m.n, v) < 0.0) {
		m.n = vnorm(vsub(m.n, vmul(v, vdot(m.n, v) * 1.02)));
	}
	vec3 c = lk_shade(p, v, m, h);
	if (u_haze_k > 0.0) {
		c = vmix(c, u_haze, 1.0 - exp(-h.t * u_haze_k));
	}
	return tonemap(vmul(c, u_exposure));
}


/* ---- the eye ---- */

vec3 lk_cam_dir(float x, float y)
{
	vec3 d = v3((x - u_c.x) / u_f, -(y - u_c.y) / u_f, -1.0);
	return vnorm(rot_y(rot_x(d, u_pitch), u_yaw));
}

#endif /* DOOR_PASS <= 1 */

/* the dither lk_pack puts on every byte */
float lk_dz(ivec2 p)
{
	return (room_hash(p.x, p.y + 0x7777) - 0.5) / 255.0;
}

out vec4 o_col;

#if DOOR_PASS <= 1

/* The trace: one program for both of its passes, a driver taking most of
 * a minute over each copy of a program this size the first time it sees
 * it. u_stage 0: a sample a pixel, through its middle (lk_row, pass 0),
 * what it is in the alpha for the edges. 1: where what a pixel shows
 * changes (the alpha differs from a neighbour's), four samples instead of
 * one (lk_row, pass 1). */

uniform int u_stage;
uniform sampler2D u_in0;

const vec2 SS_OFF[4] = vec2[4](vec2(0.125, 0.375), vec2(0.625, 0.125), vec2(0.375, 0.875),
	vec2(0.875, 0.625));

void main()
{
	ivec2 p = ivec2(gl_FragCoord.xy), sz = ivec2(u_res);
	if (u_stage == 0) {
		int a;
		vec3 c = lk_sample(u_eye, lk_cam_dir(float(p.x) + 0.5, float(p.y) + 0.5), a);
		o_col = vec4(clamp(c, 0.0, 1.0), float(a));
		return;
	}
	vec4 me = texelFetch(u_in0, p, 0);
	float a = me.a;
	bool edge = (p.x > 0 && texelFetch(u_in0, p - ivec2(1, 0), 0).a != a)
		|| (p.x + 1 < sz.x && texelFetch(u_in0, p + ivec2(1, 0), 0).a != a)
		|| (p.y > 0 && texelFetch(u_in0, p - ivec2(0, 1), 0).a != a)
		|| (p.y + 1 < sz.y && texelFetch(u_in0, p + ivec2(0, 1), 0).a != a);
	if (!edge) {
		o_col = me;
		return;
	}
	vec3 sum = vec3(0.0);
	for (int s = 0; s < 4; s++) {
		int b;
		sum += lk_sample(u_eye, lk_cam_dir(float(p.x) + SS_OFF[s].x, float(p.y) + SS_OFF[s].y), b);
	}
	o_col = vec4(clamp(sum * 0.25, 0.0, 1.0), a);
}

#elif DOOR_PASS == 2

uniform sampler2D u_in0;

/* the bright, a quarter the size: each texel the sum of its 4 x 4 */
void main()
{
	ivec2 q = ivec2(gl_FragCoord.xy), sz = ivec2(u_res);
	vec3 sum = vec3(0.0);
	for (int j = 0; j < 4; j++) {
		for (int i = 0; i < 4; i++) {
			ivec2 p = q * 4 + ivec2(i, j);
			if (p.x >= sz.x || p.y >= sz.y) {
				continue;
			}
			vec3 c = texelFetch(u_in0, p, 0).rgb;
			float l = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b;
			float k = max(l - 0.62, 0.0) / 0.38 / 16.0;
			sum += c * k;
		}
	}
	o_col = vec4(sum, 1.0);
}

#elif DOOR_PASS == 3 || DOOR_PASS == 4

uniform sampler2D u_in0;
uniform int u_stride;
uniform vec2 u_qres;

/* five taps, binomial, across (3) or down (4), at a stride
 * (blur_pass_rect) */
void main()
{
	const float k5[5] = float[5](0.0625, 0.25, 0.375, 0.25, 0.0625);
	ivec2 p = ivec2(gl_FragCoord.xy), sz = ivec2(u_qres);
#if DOOR_PASS == 3
	ivec2 dir = ivec2(1, 0);
#else
	ivec2 dir = ivec2(0, 1);
#endif
	vec3 sum = vec3(0.0);
	for (int k = -2; k <= 2; k++) {
		ivec2 s = clamp(p + dir * (k * u_stride), ivec2(0), sz - 1);
		sum += texelFetch(u_in0, s, 0).rgb * k5[k + 2];
	}
	o_col = vec4(sum, 1.0);
}

#elif DOOR_PASS == 6

uniform sampler2D u_in0;

/* Which pixels the trace's second stage is for: where what the pixel
 * shows (the alpha) differs from a neighbour's. Those are marked in the
 * depth buffer, and the second stage is drawn behind a depth test, so the
 * rest are never shaded at all -- not even in the same group of pixels as
 * one that is, which is what made the whole frame pay for its edges. */
void main()
{
	ivec2 p = ivec2(gl_FragCoord.xy), sz = ivec2(u_res);
	float a = texelFetch(u_in0, p, 0).a;
	bool edge = (p.x > 0 && texelFetch(u_in0, p - ivec2(1, 0), 0).a != a)
		|| (p.x + 1 < sz.x && texelFetch(u_in0, p + ivec2(1, 0), 0).a != a)
		|| (p.y > 0 && texelFetch(u_in0, p - ivec2(0, 1), 0).a != a)
		|| (p.y + 1 < sz.y && texelFetch(u_in0, p + ivec2(0, 1), 0).a != a);
	if (!edge) {
		discard;
	}
	gl_FragDepth = 0.0;
	o_col = vec4(0.0);
}

#else

uniform sampler2D u_in0, u_in1;
uniform vec2 u_qres;
uniform float u_post;

/* the glow added, the corners let go dark (lk_post), dithered to bytes
 * and put in cairo's order */
void main()
{
	ivec2 p = ivec2(gl_FragCoord.xy);
	float W = u_res.x, H = u_res.y;
	vec3 c = texelFetch(u_in0, p, 0).rgb;
	if (u_post > 0.0) {
		ivec2 bs = ivec2(u_qres);
		vec2 f = (vec2(p) + 0.5) / 4.0 - 0.5;
		ivec2 i0 = ivec2(floor(f));
		vec2 t = f - vec2(i0);
		ivec2 a = clamp(i0, ivec2(0), bs - 1), b = clamp(i0 + 1, ivec2(0), bs - 1);
		vec3 p00 = texelFetch(u_in1, ivec2(a.x, a.y), 0).rgb, p10 = texelFetch(u_in1, ivec2(b.x, a.y), 0).rgb;
		vec3 p01 = texelFetch(u_in1, ivec2(a.x, b.y), 0).rgb, p11 = texelFetch(u_in1, ivec2(b.x, b.y), 0).rgb;
		vec3 gl = (p00 * (1.0 - t.x) + p10 * t.x) * (1.0 - t.y) + (p01 * (1.0 - t.x) + p11 * t.x) * t.y;
		float vx = (float(p.x) - W * 0.5) / (W * 0.5) * min(W / H, 1.8) / 1.6;
		float vy = (float(p.y) - H * 0.5) / (H * 0.5);
		float vig = 1.0 - 0.38 * u_post * smoothstepf(0.35, 1.35, sqrt(vx * vx + vy * vy));
		c = c * vig + gl * 1.6 * u_post;
	}
	c = floor(clamp(c + lk_dz(p), 0.0, 1.0) * 255.0 + 0.5) / 255.0;
	o_col = vec4(c.b, c.g, c.r, 1.0);
}

#endif
