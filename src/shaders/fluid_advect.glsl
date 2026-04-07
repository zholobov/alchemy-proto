#[compute]
#version 450

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

layout(set = 0, binding = 2, std430) restrict buffer DensityIn {
    float data[];
} density_in;

layout(set = 0, binding = 3, std430) restrict buffer DensityOut {
    float data[];
} density_out;

layout(set = 0, binding = 4, std430) restrict buffer SubstanceIn {
    int data[];
} substance_in;

layout(set = 0, binding = 5, std430) restrict buffer SubstanceOut {
    int data[];
} substance_out;

layout(set = 0, binding = 6, std430) restrict buffer UVelocity {
    float data[];
} u_vel;

layout(set = 0, binding = 7, std430) restrict buffer VVelocity {
    float data[];
} v_vel;

const int CELL_AIR = 0;
const int CELL_FLUID = 1;
const int CELL_WALL = 2;

int u_idx(int x, int y, int w) {
    return y * (w + 1) + x;
}

int v_idx(int x, int y, int w) {
    return y * w + x;
}

// Bilinear density sample at fractional grid position, skipping wall cells.
float sample_density(float fx, float fy, int w, int h) {
    fx = clamp(fx, 0.0, float(w - 1));
    fy = clamp(fy, 0.0, float(h - 1));

    int x0 = int(floor(fx));
    int y0 = int(floor(fy));
    int x1 = min(x0 + 1, w - 1);
    int y1 = min(y0 + 1, h - 1);

    float sx = fx - float(x0);
    float sy = fy - float(y0);

    float w00 = (1.0 - sx) * (1.0 - sy);
    float w10 = sx * (1.0 - sy);
    float w01 = (1.0 - sx) * sy;
    float w11 = sx * sy;

    bool v00 = cell_type.data[y0 * w + x0] != CELL_WALL;
    bool v10 = cell_type.data[y0 * w + x1] != CELL_WALL;
    bool v01 = cell_type.data[y1 * w + x0] != CELL_WALL;
    bool v11 = cell_type.data[y1 * w + x1] != CELL_WALL;

    if (!v00) w00 = 0.0;
    if (!v10) w10 = 0.0;
    if (!v01) w01 = 0.0;
    if (!v11) w11 = 0.0;

    float total_w = w00 + w10 + w01 + w11;
    if (total_w <= 0.0) return 0.0;

    float inv = 1.0 / total_w;
    w00 *= inv; w10 *= inv; w01 *= inv; w11 *= inv;

    float d00 = v00 ? density_in.data[y0 * w + x0] : 0.0;
    float d10 = v10 ? density_in.data[y0 * w + x1] : 0.0;
    float d01 = v01 ? density_in.data[y1 * w + x0] : 0.0;
    float d11 = v11 ? density_in.data[y1 * w + x1] : 0.0;

    return d00 * w00 + d10 * w10 + d01 * w01 + d11 * w11;
}

void main() {
    int x = int(gl_GlobalInvocationID.x);
    int y = int(gl_GlobalInvocationID.y);
    int w = params.grid_width;
    int h = params.grid_height;

    if (x >= w || y >= h) return;

    int idx = y * w + x;

    if (cell_type.data[idx] == CELL_WALL) {
        density_out.data[idx] = 0.0;
        substance_out.data[idx] = 0;
        return;
    }

    // Velocity at cell center (average of face velocities).
    float vx = (u_vel.data[u_idx(x, y, w)] + u_vel.data[u_idx(x + 1, y, w)]) * 0.5;
    float vy = (v_vel.data[v_idx(x, y, w)] + v_vel.data[v_idx(x, y + 1, w)]) * 0.5;

    // Backward trace.
    float src_x = float(x) - vx * params.delta_time;
    float src_y = float(y) - vy * params.delta_time;

    density_out.data[idx] = sample_density(src_x, src_y, w, h);

    // Nearest-neighbor substance sample.
    int sx = clamp(int(round(src_x)), 0, w - 1);
    int sy = clamp(int(round(src_y)), 0, h - 1);
    substance_out.data[idx] = substance_in.data[sy * w + sx];
}
