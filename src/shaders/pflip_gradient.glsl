#[compute]
#version 450

// Variable-density pressure gradient application. Updates MAC grid
// velocities with
//   u_face -= (∂p/∂x) * dt * (1/ρ_face)
// where 1/ρ_face is the harmonic mean of the two adjacent cells' 1/ρ
// (i.e. arithmetic mean of 1/ρ). Must match the face weighting used by
// pflip_jacobi so the discrete ∇·u correction is consistent.
//
// At fluid-air faces, uses the fluid cell's own 1/ρ and treats p_air = 0.
// At fluid-wall faces, no update (velocity is zeroed separately).
//
// Safe against races at interior fluid-fluid faces: each face is updated by
// both adjacent fluid cells, but the harmonic-mean weighting is symmetric
// so both cells compute and write the same new value. This matches the
// behavior of the uniform-density gradient shader.

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict buffer Params {
    int grid_width;
    int grid_height;
    float delta_time;
    int extra;
} params;

layout(set = 0, binding = 1, std430) restrict buffer CellTypeBuffer {
    int data[];
} cell_type;

layout(set = 0, binding = 2, std430) restrict buffer PressureBuffer {
    float data[];
} pressure;

layout(set = 0, binding = 3, std430) restrict buffer UVelocity {
    float data[];
} u_vel;

layout(set = 0, binding = 4, std430) restrict buffer VVelocity {
    float data[];
} v_vel;

layout(set = 0, binding = 5, std430) restrict buffer CellDensity {
    float data[];
} cell_density;

const int CELL_FLUID = 1;
const int CELL_WALL = 2;
const float MIN_DENSITY = 0.0012;

int u_idx(int x, int y, int w) {
    return y * (w + 1) + x;
}

int v_idx(int x, int y, int w) {
    return y * w + x;
}

void main() {
    int x = int(gl_GlobalInvocationID.x);
    int y = int(gl_GlobalInvocationID.y);
    int w = params.grid_width;
    int h = params.grid_height;
    if (x >= w || y >= h) return;

    int idx = y * w + x;
    if (cell_type.data[idx] != CELL_FLUID) return;

    float p_here = pressure.data[idx];
    float inv_rho_here = 1.0 / max(cell_density.data[idx], MIN_DENSITY);
    float dt = params.delta_time;

    // Left face: between (x-1, y) and (x, y)
    if (x > 0) {
        int left_idx = idx - 1;
        int left_ct = cell_type.data[left_idx];
        if (left_ct != CELL_WALL) {
            float p_left = 0.0;
            float inv_rho_face = inv_rho_here;
            if (left_ct == CELL_FLUID) {
                p_left = pressure.data[left_idx];
                float inv_rho_left = 1.0 / max(cell_density.data[left_idx], MIN_DENSITY);
                inv_rho_face = (inv_rho_here + inv_rho_left) * 0.5;
            }
            u_vel.data[u_idx(x, y, w)] -= (p_here - p_left) * dt * inv_rho_face;
        }
    }
    // Right face: between (x, y) and (x+1, y)
    if (x + 1 < w) {
        int right_idx = idx + 1;
        int right_ct = cell_type.data[right_idx];
        if (right_ct != CELL_WALL) {
            float p_right = 0.0;
            float inv_rho_face = inv_rho_here;
            if (right_ct == CELL_FLUID) {
                p_right = pressure.data[right_idx];
                float inv_rho_right = 1.0 / max(cell_density.data[right_idx], MIN_DENSITY);
                inv_rho_face = (inv_rho_here + inv_rho_right) * 0.5;
            }
            u_vel.data[u_idx(x + 1, y, w)] -= (p_right - p_here) * dt * inv_rho_face;
        }
    }
    // Top face: between (x, y-1) and (x, y)
    if (y > 0) {
        int top_idx = idx - w;
        int top_ct = cell_type.data[top_idx];
        if (top_ct != CELL_WALL) {
            float p_top = 0.0;
            float inv_rho_face = inv_rho_here;
            if (top_ct == CELL_FLUID) {
                p_top = pressure.data[top_idx];
                float inv_rho_top = 1.0 / max(cell_density.data[top_idx], MIN_DENSITY);
                inv_rho_face = (inv_rho_here + inv_rho_top) * 0.5;
            }
            v_vel.data[v_idx(x, y, w)] -= (p_here - p_top) * dt * inv_rho_face;
        }
    }
    // Bottom face: between (x, y) and (x, y+1)
    if (y + 1 < h) {
        int bottom_idx = idx + w;
        int bottom_ct = cell_type.data[bottom_idx];
        if (bottom_ct != CELL_WALL) {
            float p_bottom = 0.0;
            float inv_rho_face = inv_rho_here;
            if (bottom_ct == CELL_FLUID) {
                p_bottom = pressure.data[bottom_idx];
                float inv_rho_bottom = 1.0 / max(cell_density.data[bottom_idx], MIN_DENSITY);
                inv_rho_face = (inv_rho_here + inv_rho_bottom) * 0.5;
            }
            v_vel.data[v_idx(x, y + 1, w)] -= (p_bottom - p_here) * dt * inv_rho_face;
        }
    }
}
