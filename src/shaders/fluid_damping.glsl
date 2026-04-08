#[compute]
#version 450

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict buffer Params {
    int grid_width;
    int grid_height;
    float delta_time;
    int extra;
} params;

layout(set = 0, binding = 1, std430) restrict buffer UVelocity {
    float data[];
} u_vel;

layout(set = 0, binding = 2, std430) restrict buffer VVelocity {
    float data[];
} v_vel;

// 1% velocity loss per frame. Previously 0.995 (0.5%) when this solver was
// intended for liquids; raised for vapor so gas clouds visibly dissipate
// over ~2-3 seconds rather than drifting forever.
const float DAMPING = 0.99;

void main() {
    int x = int(gl_GlobalInvocationID.x);
    int y = int(gl_GlobalInvocationID.y);
    int w = params.grid_width;
    int h = params.grid_height;

    // Damp u velocity (width+1 × height)
    if (x <= w && y < h) {
        int ui = y * (w + 1) + x;
        u_vel.data[ui] *= DAMPING;
    }

    // Damp v velocity (width × height+1)
    if (x < w && y <= h) {
        int vi = y * w + x;
        v_vel.data[vi] *= DAMPING;
    }
}
