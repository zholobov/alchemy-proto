#[compute]
#version 450

// Grid-to-Particle gather. For each particle, sample the grid velocity at
// its position via bilinear interpolation. Uses FLIP/PIC blending:
//   FLIP: particle.vel += (current_vel - old_vel)   — preserves swirl
//   PIC:  particle.vel = current_vel                — more diffusive but stable
// Hybrid (default): 0.95 * FLIP + 0.05 * PIC = sharp surface, stable.

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict buffer Params {
    int grid_width;
    int grid_height;
    float delta_time;
    int particle_count;
} params;

struct Particle {
    vec2 pos;
    vec2 vel;
    int substance_id;
    int alive;
};

layout(set = 0, binding = 1, std430) restrict buffer ParticleBuffer {
    Particle data[];
} particles;

layout(set = 0, binding = 2, std430) restrict buffer UVel {
    float data[];
} u_vel;

layout(set = 0, binding = 3, std430) restrict buffer VVel {
    float data[];
} v_vel;

layout(set = 0, binding = 4, std430) restrict buffer UOld {
    float data[];
} u_old;

layout(set = 0, binding = 5, std430) restrict buffer VOld {
    float data[];
} v_old;

const float FLIP_RATIO = 0.95;

float bilerp_u(float fx, float fy, int w, int h, bool use_old) {
    fx = clamp(fx, 0.0, float(w));
    fy = clamp(fy, 0.0, float(h - 1));
    int x0 = int(floor(fx));
    int y0 = int(floor(fy));
    int x1 = min(x0 + 1, w);
    int y1 = min(y0 + 1, h - 1);
    float wx = fx - float(x0);
    float wy = fy - float(y0);
    float v00, v10, v01, v11;
    if (use_old) {
        v00 = u_old.data[y0 * (w + 1) + x0];
        v10 = u_old.data[y0 * (w + 1) + x1];
        v01 = u_old.data[y1 * (w + 1) + x0];
        v11 = u_old.data[y1 * (w + 1) + x1];
    } else {
        v00 = u_vel.data[y0 * (w + 1) + x0];
        v10 = u_vel.data[y0 * (w + 1) + x1];
        v01 = u_vel.data[y1 * (w + 1) + x0];
        v11 = u_vel.data[y1 * (w + 1) + x1];
    }
    return mix(mix(v00, v10, wx), mix(v01, v11, wx), wy);
}

float bilerp_v(float fx, float fy, int w, int h, bool use_old) {
    fx = clamp(fx, 0.0, float(w - 1));
    fy = clamp(fy, 0.0, float(h));
    int x0 = int(floor(fx));
    int y0 = int(floor(fy));
    int x1 = min(x0 + 1, w - 1);
    int y1 = min(y0 + 1, h);
    float wx = fx - float(x0);
    float wy = fy - float(y0);
    float v00, v10, v01, v11;
    if (use_old) {
        v00 = v_old.data[y0 * w + x0];
        v10 = v_old.data[y0 * w + x1];
        v01 = v_old.data[y1 * w + x0];
        v11 = v_old.data[y1 * w + x1];
    } else {
        v00 = v_vel.data[y0 * w + x0];
        v10 = v_vel.data[y0 * w + x1];
        v01 = v_vel.data[y1 * w + x0];
        v11 = v_vel.data[y1 * w + x1];
    }
    return mix(mix(v00, v10, wx), mix(v01, v11, wx), wy);
}

void main() {
    uint pi = gl_GlobalInvocationID.x;
    if (pi >= uint(params.particle_count)) return;

    Particle p = particles.data[pi];
    if (p.alive == 0) return;

    int w = params.grid_width;
    int h = params.grid_height;

    // u-grid coordinates: u-face (i, j) is at (i, j+0.5), so to sample at
    // particle position we use (px, py-0.5).
    float u_fx = p.pos.x;
    float u_fy = p.pos.y - 0.5;
    float u_new = bilerp_u(u_fx, u_fy, w, h, false);
    float u_pre = bilerp_u(u_fx, u_fy, w, h, true);

    // v-grid coordinates: v-face (i, j) is at (i+0.5, j), sample at (px-0.5, py).
    float v_fx = p.pos.x - 0.5;
    float v_fy = p.pos.y;
    float v_new = bilerp_v(v_fx, v_fy, w, h, false);
    float v_pre = bilerp_v(v_fx, v_fy, w, h, true);

    // FLIP delta: how much the grid velocity changed during pressure projection.
    float u_delta = u_new - u_pre;
    float v_delta = v_new - v_pre;

    // Hybrid PIC/FLIP blend.
    vec2 flip_vel = p.vel + vec2(u_delta, v_delta);
    vec2 pic_vel = vec2(u_new, v_new);
    p.vel = mix(pic_vel, flip_vel, FLIP_RATIO);

    particles.data[pi] = p;
}
