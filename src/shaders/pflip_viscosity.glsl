#[compute]
#version 450

// Per-substance viscosity. Diffuses MAC face velocities using a Laplacian
// smoothing scaled by the local viscosity. The local viscosity at each face
// is the AVERAGE of the two adjacent cells' substance viscosities, looked up
// in the SubstanceProperties table by substance id.
//
// Run AFTER fluid_gradient (post-pressure) and BEFORE the post-pressure
// wall_zero — this way the viscosity correction is included in the (current -
// saved) FLIP delta and particles pick it up via both PIC and FLIP components.
//
// Reads from u_vel/v_vel, writes to u_vel_temp/v_vel_temp (no read/write race).
// The solver dispatches buffer_copy to merge temp -> vel after this pass.

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

layout(set = 0, binding = 2, std430) restrict buffer SubstanceBuffer {
    int data[];
} substance;

layout(set = 0, binding = 3, std430) restrict buffer SubstanceProperties {
    // vec2 per substance id. .x = viscosity, .y = flip_ratio (used in g2p).
    vec2 data[];
} substance_props;

layout(set = 0, binding = 4, std430) restrict buffer UVelIn {
    float data[];
} u_vel_in;

layout(set = 0, binding = 5, std430) restrict buffer VVelIn {
    float data[];
} v_vel_in;

layout(set = 0, binding = 6, std430) restrict buffer UVelOut {
    float data[];
} u_vel_out;

layout(set = 0, binding = 7, std430) restrict buffer VVelOut {
    float data[];
} v_vel_out;

const int CELL_FLUID = 1;
const int CELL_WALL = 2;

// Global multiplier on top of per-substance viscosity. Stability limit for
// explicit-Euler diffusion is (ν * SCALE * dt) < 0.25. At 60 FPS (dt ≈ 0.017)
// this means ν * SCALE < ~15. Water viscosity = 0.3, so SCALE up to ~50 is safe.
const float VISCOSITY_SCALE = 10.0;

// Average the viscosities of two adjacent cells. Returns 0 if neither side
// has a fluid substance (no diffusion across air-only or wall-only faces).
float face_visc(int idx_a, int idx_b, int w, int h) {
    float v = 0.0;
    int n = 0;
    if (idx_a >= 0 && idx_a < w * h) {
        int s = substance.data[idx_a];
        if (s > 0 && cell_type.data[idx_a] == CELL_FLUID) {
            v += substance_props.data[s].x;
            n += 1;
        }
    }
    if (idx_b >= 0 && idx_b < w * h) {
        int s = substance.data[idx_b];
        if (s > 0 && cell_type.data[idx_b] == CELL_FLUID) {
            v += substance_props.data[s].x;
            n += 1;
        }
    }
    if (n == 0) return 0.0;
    return v / float(n);
}

void main() {
    int x = int(gl_GlobalInvocationID.x);
    int y = int(gl_GlobalInvocationID.y);
    int w = params.grid_width;
    int h = params.grid_height;

    // ---------------- u-face diffusion ----------------
    // u-face (x, y) is between cells (x-1, y) and (x, y).
    if (x <= w && y < h) {
        int u_idx_c = y * (w + 1) + x;
        float u_c = u_vel_in.data[u_idx_c];

        // Look up adjacent cell substance viscosities.
        int cell_left = (x > 0) ? (y * w + x - 1) : -1;
        int cell_right = (x < w) ? (y * w + x) : -1;
        float visc = face_visc(cell_left, cell_right, w, h);

        if (visc > 0.0) {
            // 5-point Laplacian on the u-grid (which is (w+1) x h).
            float u_left  = (x > 0)         ? u_vel_in.data[u_idx_c - 1]      : u_c;
            float u_right = (x < w)         ? u_vel_in.data[u_idx_c + 1]      : u_c;
            float u_top   = (y > 0)         ? u_vel_in.data[u_idx_c - (w+1)]  : u_c;
            float u_bot   = (y < h - 1)     ? u_vel_in.data[u_idx_c + (w+1)]  : u_c;

            float lap = u_left + u_right + u_top + u_bot - 4.0 * u_c;
            u_vel_out.data[u_idx_c] = u_c + visc * VISCOSITY_SCALE * params.delta_time * lap;
        } else {
            u_vel_out.data[u_idx_c] = u_c;
        }
    }

    // ---------------- v-face diffusion ----------------
    // v-face (x, y) is between cells (x, y-1) and (x, y).
    if (x < w && y <= h) {
        int v_idx_c = y * w + x;
        float v_c = v_vel_in.data[v_idx_c];

        int cell_top = (y > 0) ? ((y - 1) * w + x) : -1;
        int cell_bot = (y < h) ? (y * w + x) : -1;
        float visc = face_visc(cell_top, cell_bot, w, h);

        if (visc > 0.0) {
            float v_left  = (x > 0)         ? v_vel_in.data[v_idx_c - 1]  : v_c;
            float v_right = (x < w - 1)     ? v_vel_in.data[v_idx_c + 1]  : v_c;
            float v_top   = (y > 0)         ? v_vel_in.data[v_idx_c - w]  : v_c;
            float v_bot   = (y < h)         ? v_vel_in.data[v_idx_c + w]  : v_c;

            float lap = v_left + v_right + v_top + v_bot - 4.0 * v_c;
            v_vel_out.data[v_idx_c] = v_c + visc * VISCOSITY_SCALE * params.delta_time * lap;
        } else {
            v_vel_out.data[v_idx_c] = v_c;
        }
    }
}
