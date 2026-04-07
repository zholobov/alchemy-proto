#[compute]
#version 450

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict buffer Params {
    int grid_width;
    int grid_height;
    float delta_time;
    int phase;  // 0=gravity, 1=jacobi, 2=zero_walls, 3=advect
} params;

layout(set = 0, binding = 1, std430) restrict buffer BoundaryBuffer {
    int data[];
} boundary;

layout(set = 0, binding = 2, std430) restrict buffer DensityIn {
    float data[];
} density_in;

layout(set = 0, binding = 3, std430) restrict buffer DensityOut {
    float data[];
} density_out;

layout(set = 0, binding = 4, std430) restrict buffer UVelocity {
    float data[];
} u_vel;

layout(set = 0, binding = 5, std430) restrict buffer VVelocity {
    float data[];
} v_vel;

layout(set = 0, binding = 6, std430) restrict buffer PressureBuffer {
    float data[];
} pressure;

layout(set = 0, binding = 7, std430) restrict buffer SubstanceField {
    int data[];
} substance;

const float GRAVITY = 150.0;  // Grid cells per second squared.

bool is_valid(int x, int y) {
    if (x < 0 || x >= params.grid_width || y < 0 || y >= params.grid_height) return false;
    return boundary.data[y * params.grid_width + x] == 1;
}

bool has_fluid(int x, int y) {
    if (!is_valid(x, y)) return false;
    return density_in.data[y * params.grid_width + x] > 0.001;
}

// Apply gravity/pressure even if neighbors have fluid (surface cells need this).
bool near_fluid(int x, int y) {
    if (!is_valid(x, y)) return false;
    int w = params.grid_width;
    if (density_in.data[y * w + x] > 0.001) return true;
    if (is_valid(x - 1, y) && density_in.data[y * w + x - 1] > 0.001) return true;
    if (is_valid(x + 1, y) && density_in.data[y * w + x + 1] > 0.001) return true;
    if (is_valid(x, y - 1) && density_in.data[(y - 1) * w + x] > 0.001) return true;
    if (is_valid(x, y + 1) && density_in.data[(y + 1) * w + x] > 0.001) return true;
    return false;
}

int u_idx(int x, int y) {
    return y * (params.grid_width + 1) + x;
}

int v_idx(int x, int y) {
    return y * params.grid_width + x;
}

// Bilinear interpolation of density at fractional grid position.
float sample_density(float fx, float fy) {
    int w = params.grid_width;
    int h = params.grid_height;

    // Clamp to grid interior.
    fx = clamp(fx, 0.5, float(w) - 1.5);
    fy = clamp(fy, 0.5, float(h) - 1.5);

    int x0 = int(floor(fx));
    int y0 = int(floor(fy));
    int x1 = min(x0 + 1, w - 1);
    int y1 = min(y0 + 1, h - 1);

    float sx = fx - float(x0);
    float sy = fy - float(y0);

    float d00 = density_in.data[y0 * w + x0];
    float d10 = density_in.data[y0 * w + x1];
    float d01 = density_in.data[y1 * w + x0];
    float d11 = density_in.data[y1 * w + x1];

    float d0 = mix(d00, d10, sx);
    float d1 = mix(d01, d11, sx);
    return mix(d0, d1, sy);
}

void main() {
    int x = int(gl_GlobalInvocationID.x);
    int y = int(gl_GlobalInvocationID.y);
    int w = params.grid_width;
    int h = params.grid_height;

    if (x >= w || y >= h) return;

    int idx = y * w + x;

    if (params.phase == 0) {
        // === GRAVITY ===
        // Apply to cells near fluid so the surface also accelerates downward.
        if (!near_fluid(x, y)) return;
        int vi = v_idx(x, y + 1);
        if (y + 1 <= h) {
            v_vel.data[vi] += GRAVITY * params.delta_time;
            v_vel.data[vi] = clamp(v_vel.data[vi], -200.0, 200.0);
        }
    }
    else if (params.phase == 1) {
        // === JACOBI PRESSURE ITERATION ===
        // Run on cells near fluid so pressure propagates into empty neighbors.
        if (!near_fluid(x, y)) return;

        float s_left   = is_valid(x - 1, y) ? 1.0 : 0.0;
        float s_right  = is_valid(x + 1, y) ? 1.0 : 0.0;
        float s_top    = is_valid(x, y - 1) ? 1.0 : 0.0;
        float s_bottom = is_valid(x, y + 1) ? 1.0 : 0.0;
        float s_total = s_left + s_right + s_top + s_bottom;
        if (s_total == 0.0) return;

        float div = u_vel.data[u_idx(x + 1, y)] - u_vel.data[u_idx(x, y)]
                  + v_vel.data[v_idx(x, y + 1)] - v_vel.data[v_idx(x, y)];

        float p = -div / s_total;
        pressure.data[idx] += p;

        u_vel.data[u_idx(x, y)]     -= s_left * p;
        u_vel.data[u_idx(x + 1, y)] += s_right * p;
        v_vel.data[v_idx(x, y)]     -= s_top * p;
        v_vel.data[v_idx(x, y + 1)] += s_bottom * p;
    }
    else if (params.phase == 2) {
        // === ZERO WALL VELOCITIES ===
        if (is_valid(x, y)) return;
        u_vel.data[u_idx(x, y)] = 0.0;
        if (x + 1 <= w) u_vel.data[u_idx(x + 1, y)] = 0.0;
        v_vel.data[v_idx(x, y)] = 0.0;
        if (y + 1 <= h) v_vel.data[v_idx(x, y + 1)] = 0.0;
    }
    else if (params.phase == 3) {
        // === SEMI-LAGRANGIAN DENSITY ADVECTION (backward trace) ===
        if (!is_valid(x, y)) {
            density_out.data[idx] = 0.0;
            return;
        }

        // Get velocity at cell center.
        float vx = (u_vel.data[u_idx(x, y)] + u_vel.data[u_idx(x + 1, y)]) * 0.5;
        float vy = (v_vel.data[v_idx(x, y)] + v_vel.data[v_idx(x, y + 1)]) * 0.5;

        // Trace BACKWARD to find source position.
        float src_x = float(x) - vx * params.delta_time;
        float src_y = float(y) - vy * params.delta_time;

        // Bilinearly interpolate density at source.
        float new_density = sample_density(src_x, src_y);

        density_out.data[idx] = new_density;

        // Advect substance type using nearest-neighbor (IDs are discrete, can't interpolate).
        int src_xi = clamp(int(round(src_x)), 0, w - 1);
        int src_yi = clamp(int(round(src_y)), 0, h - 1);
        if (new_density > 0.01) {
            substance.data[idx] = substance.data[src_yi * w + src_xi];
        } else {
            substance.data[idx] = 0;
        }
    }
}
