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

layout(set = 0, binding = 2, std430) restrict buffer MarkersIn {
    int data[];
} markers_in;

layout(set = 0, binding = 3, std430) restrict buffer MarkersOut {
    int data[];
} markers_out;

layout(set = 0, binding = 4, std430) restrict buffer UVelocity {
    float data[];
} u_vel;

layout(set = 0, binding = 5, std430) restrict buffer VVelocity {
    float data[];
} v_vel;

layout(set = 0, binding = 6, std430) restrict buffer PressureBuffer {
    float data[];
} pressure;

const float GRAVITY = 50.0;   // In grid cells/s², not pixels.
const float OVERRELAX = 1.0;  // Standard Jacobi (no over-relaxation — SOR > 1 is for sequential Gauss-Seidel only).

bool is_valid(int x, int y) {
    if (x < 0 || x >= params.grid_width || y < 0 || y >= params.grid_height) return false;
    return boundary.data[y * params.grid_width + x] == 1;
}

bool is_fluid(int x, int y) {
    if (!is_valid(x, y)) return false;
    return markers_in.data[y * params.grid_width + x] != 0;
}

int u_idx(int x, int y) {
    return y * (params.grid_width + 1) + x;
}

int v_idx(int x, int y) {
    return y * params.grid_width + x;
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
        if (!is_fluid(x, y)) return;
        // Add gravity to v at bottom face of this cell.
        int vi = v_idx(x, y + 1);
        if (y + 1 <= h) {
            v_vel.data[vi] += GRAVITY * params.delta_time;
            // Clamp velocity to prevent instability.
            v_vel.data[vi] = clamp(v_vel.data[vi], -100.0, 100.0);
        }
        // Also clamp horizontal velocity.
        u_vel.data[u_idx(x, y)] = clamp(u_vel.data[u_idx(x, y)], -100.0, 100.0);
        u_vel.data[u_idx(x + 1, y)] = clamp(u_vel.data[u_idx(x + 1, y)], -100.0, 100.0);
    }
    else if (params.phase == 1) {
        // === JACOBI PRESSURE ITERATION ===
        if (!is_fluid(x, y)) return;

        float s_left  = is_valid(x - 1, y) ? 1.0 : 0.0;
        float s_right = is_valid(x + 1, y) ? 1.0 : 0.0;
        float s_top   = is_valid(x, y - 1) ? 1.0 : 0.0;
        float s_bottom = is_valid(x, y + 1) ? 1.0 : 0.0;
        float s_total = s_left + s_right + s_top + s_bottom;
        if (s_total == 0.0) return;

        // Compute velocity divergence at this cell.
        float div = u_vel.data[u_idx(x + 1, y)] - u_vel.data[u_idx(x, y)]
                  + v_vel.data[v_idx(x, y + 1)] - v_vel.data[v_idx(x, y)];

        // Pressure correction.
        float p = -div / s_total * OVERRELAX;
        pressure.data[idx] += p;

        // Apply correction to velocities.
        u_vel.data[u_idx(x, y)]     -= s_left * p;
        u_vel.data[u_idx(x + 1, y)] += s_right * p;
        v_vel.data[v_idx(x, y)]     -= s_top * p;
        v_vel.data[v_idx(x, y + 1)] += s_bottom * p;
    }
    else if (params.phase == 2) {
        // === ZERO WALL VELOCITIES ===
        if (is_valid(x, y)) return;  // Only process wall cells.
        u_vel.data[u_idx(x, y)] = 0.0;
        if (x + 1 <= w) u_vel.data[u_idx(x + 1, y)] = 0.0;
        v_vel.data[v_idx(x, y)] = 0.0;
        if (y + 1 <= h) v_vel.data[v_idx(x, y + 1)] = 0.0;
    }
    else if (params.phase == 3) {
        // === SEMI-LAGRANGIAN MARKER ADVECTION ===
        if (!is_fluid(x, y)) return;

        int sub_id = markers_in.data[idx];

        // Get velocity at cell center (average of face velocities).
        float vx = (u_vel.data[u_idx(x, y)] + u_vel.data[u_idx(x + 1, y)]) * 0.5;
        float vy = (v_vel.data[v_idx(x, y)] + v_vel.data[v_idx(x, y + 1)]) * 0.5;

        // Target position.
        int tx = clamp(int(round(float(x) + vx * params.delta_time)), 0, w - 1);
        int ty = clamp(int(round(float(y) + vy * params.delta_time)), 0, h - 1);

        int t_idx = ty * w + tx;
        if (is_valid(tx, ty) && markers_out.data[t_idx] == 0) {
            markers_out.data[t_idx] = sub_id;
        } else if (markers_out.data[idx] == 0) {
            // Can't move — stay in place.
            markers_out.data[idx] = sub_id;
        }
    }
}
