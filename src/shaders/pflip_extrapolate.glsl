#[compute]
#version 450

// Velocity extrapolation. Standard PIC/FLIP technique.
//
// After pressure projection, fluid cells have correct (divergence-free)
// velocities. AIR cells adjacent to the fluid have whatever velocities the
// p2g scatter put there (raw particle averages). For particles near the
// fluid surface, sampling these uncorrected velocities causes weird
// boundary artifacts (particles "stick" to the surface or shoot away).
//
// Fix: extrapolate fluid velocities outward into the air cells. Each pass
// extends the valid velocity field by 1 cell. Run 2-3 passes for a 2-3 cell
// extrapolation layer.
//
// Per-pass algorithm: for each MAC face, if it's "invalid" (both adjacent
// cells are non-fluid), look at its 4 neighboring faces. Average the values
// of any neighbors that are "valid" (at least one of THEIR adjacent cells
// is fluid). Write the average. If no valid neighbors, leave the face alone.
//
// Reads from u_vel_in / v_vel_in, writes to u_vel_out / v_vel_out (no race).

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

layout(set = 0, binding = 2, std430) restrict buffer UVelIn {
    float data[];
} u_vel_in;

layout(set = 0, binding = 3, std430) restrict buffer VVelIn {
    float data[];
} v_vel_in;

layout(set = 0, binding = 4, std430) restrict buffer UVelOut {
    float data[];
} u_vel_out;

layout(set = 0, binding = 5, std430) restrict buffer VVelOut {
    float data[];
} v_vel_out;

const int CELL_FLUID = 1;

bool is_fluid(int cx, int cy, int w, int h) {
    if (cx < 0 || cx >= w || cy < 0 || cy >= h) return false;
    return cell_type.data[cy * w + cx] == CELL_FLUID;
}

bool u_face_valid(int x, int y, int w, int h) {
    // u-face at (x, y) is between cells (x-1, y) and (x, y).
    return is_fluid(x - 1, y, w, h) || is_fluid(x, y, w, h);
}

bool v_face_valid(int x, int y, int w, int h) {
    // v-face at (x, y) is between cells (x, y-1) and (x, y).
    return is_fluid(x, y - 1, w, h) || is_fluid(x, y, w, h);
}

void main() {
    int x = int(gl_GlobalInvocationID.x);
    int y = int(gl_GlobalInvocationID.y);
    int w = params.grid_width;
    int h = params.grid_height;

    // ---------------- u-face extrapolation ----------------
    if (x <= w && y < h) {
        int u_idx = y * (w + 1) + x;

        if (u_face_valid(x, y, w, h)) {
            // Already valid — pass through unchanged.
            u_vel_out.data[u_idx] = u_vel_in.data[u_idx];
        } else {
            // Look at 4 neighbor u-faces, average the ones that ARE valid.
            float sum = 0.0;
            int count = 0;

            if (x > 0 && u_face_valid(x - 1, y, w, h)) {
                sum += u_vel_in.data[u_idx - 1];
                count += 1;
            }
            if (x < w && u_face_valid(x + 1, y, w, h)) {
                sum += u_vel_in.data[u_idx + 1];
                count += 1;
            }
            if (y > 0 && u_face_valid(x, y - 1, w, h)) {
                sum += u_vel_in.data[u_idx - (w + 1)];
                count += 1;
            }
            if (y < h - 1 && u_face_valid(x, y + 1, w, h)) {
                sum += u_vel_in.data[u_idx + (w + 1)];
                count += 1;
            }

            if (count > 0) {
                u_vel_out.data[u_idx] = sum / float(count);
            } else {
                // No valid neighbors — leave the raw p2g value alone.
                u_vel_out.data[u_idx] = u_vel_in.data[u_idx];
            }
        }
    }

    // ---------------- v-face extrapolation ----------------
    if (x < w && y <= h) {
        int v_idx = y * w + x;

        if (v_face_valid(x, y, w, h)) {
            v_vel_out.data[v_idx] = v_vel_in.data[v_idx];
        } else {
            float sum = 0.0;
            int count = 0;

            if (x > 0 && v_face_valid(x - 1, y, w, h)) {
                sum += v_vel_in.data[v_idx - 1];
                count += 1;
            }
            if (x < w - 1 && v_face_valid(x + 1, y, w, h)) {
                sum += v_vel_in.data[v_idx + 1];
                count += 1;
            }
            if (y > 0 && v_face_valid(x, y - 1, w, h)) {
                sum += v_vel_in.data[v_idx - w];
                count += 1;
            }
            if (y < h && v_face_valid(x, y + 1, w, h)) {
                sum += v_vel_in.data[v_idx + w];
                count += 1;
            }

            if (count > 0) {
                v_vel_out.data[v_idx] = sum / float(count);
            } else {
                v_vel_out.data[v_idx] = v_vel_in.data[v_idx];
            }
        }
    }
}
