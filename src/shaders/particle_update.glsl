#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict buffer Params {
    int grid_width;
    int grid_height;
    float delta_time;
    int frame_count;
} params;

layout(set = 0, binding = 1, std430) restrict buffer CellsBuffer {
    int data[];
} cells;

layout(set = 0, binding = 2, std430) restrict buffer BoundaryBuffer {
    int data[];
} boundary;

layout(set = 0, binding = 3, std430) restrict buffer TempsBuffer {
    float data[];
} temperatures;

layout(set = 0, binding = 4, std430) restrict buffer SubstanceTable {
    float data[];
} substances;

const int STRIDE = 12;
const int PHASE_SOLID = 0;
const int PHASE_POWDER = 1;
const int PHASE_LIQUID = 2;
const int PHASE_GAS = 3;

int get_phase(int sub_id) {
    if (sub_id <= 0) return -1;
    return int(substances.data[sub_id * STRIDE]);
}

float get_density(int sub_id) {
    if (sub_id <= 0) return 0.0;
    return substances.data[sub_id * STRIDE + 1];
}

uint hash_cell(uint x, uint y, uint frame) {
    uint h = x * 374761393u + y * 668265263u + frame * 1013904223u;
    h = (h ^ (h >> 13)) * 1274126177u;
    return h ^ (h >> 16);
}

bool falls(int phase) {
    return phase == PHASE_POWDER;
    // PHASE_LIQUID is handled by the MAC fluid shader, not falling-sand.
}

bool rises(int phase) {
    return phase == PHASE_GAS;
}

void main() {
    uint bx = gl_GlobalInvocationID.x;
    uint by = gl_GlobalInvocationID.y;

    uint offset = uint(params.frame_count) & 1u;

    uint x0 = bx * 2u + offset;
    uint y0 = by * 2u + offset;
    uint x1 = x0 + 1u;
    uint y1 = y0 + 1u;

    if (x1 >= uint(params.grid_width) || y1 >= uint(params.grid_height)) return;

    uint w = uint(params.grid_width);
    uint i00 = y0 * w + x0;
    uint i10 = y0 * w + x1;
    uint i01 = y1 * w + x0;
    uint i11 = y1 * w + x1;

    bool b00 = boundary.data[i00] == 1;
    bool b10 = boundary.data[i10] == 1;
    bool b01 = boundary.data[i01] == 1;
    bool b11 = boundary.data[i11] == 1;

    int c00 = cells.data[i00];
    int c10 = cells.data[i10];
    int c01 = cells.data[i01];
    int c11 = cells.data[i11];

    float t00 = temperatures.data[i00];
    float t10 = temperatures.data[i10];
    float t01 = temperatures.data[i01];
    float t11 = temperatures.data[i11];

    uint rng = hash_cell(x0, y0, uint(params.frame_count));
    bool prefer_left = (rng & 1u) == 0u;

    // GRAVITY: top cells fall to bottom cells
    if (c00 != 0 && c01 == 0 && b00 && b01 && falls(get_phase(c00))) {
        c01 = c00; c00 = 0;
        float tmp = t01; t01 = t00; t00 = tmp;
    }
    if (c10 != 0 && c11 == 0 && b10 && b11 && falls(get_phase(c10))) {
        c11 = c10; c10 = 0;
        float tmp = t11; t11 = t10; t10 = tmp;
    }

    // DIAGONAL FALLS
    if (c00 != 0 && c11 == 0 && b00 && b11 && falls(get_phase(c00))) {
        if (c01 != 0 && prefer_left) {
            c11 = c00; c00 = 0;
            float tmp = t11; t11 = t00; t00 = tmp;
        }
    }
    if (c10 != 0 && c01 == 0 && b10 && b01 && falls(get_phase(c10))) {
        if (c11 != 0 && !prefer_left) {
            c01 = c10; c10 = 0;
            float tmp = t01; t01 = t10; t10 = tmp;
        }
    }

    // LIQUID phase is handled by the MAC fluid shader — not here.

    // GAS RISING
    if (c01 != 0 && c00 == 0 && b01 && b00 && rises(get_phase(c01))) {
        c00 = c01; c01 = 0;
        float tmp = t00; t00 = t01; t01 = tmp;
    }
    if (c11 != 0 && c10 == 0 && b11 && b10 && rises(get_phase(c11))) {
        c10 = c11; c11 = 0;
        float tmp = t10; t10 = t11; t11 = tmp;
    }

    // GAS SIDEWAYS DRIFT
    if (c00 != 0 && c10 == 0 && b00 && b10 && rises(get_phase(c00)) && prefer_left) {
        c10 = c00; c00 = 0;
    }
    if (c10 != 0 && c00 == 0 && b10 && b00 && rises(get_phase(c10)) && !prefer_left) {
        c00 = c10; c10 = 0;
    }

    // DENSITY DISPLACEMENT
    if (c00 != 0 && c01 != 0 && b00 && b01) {
        if (falls(get_phase(c00)) && get_density(c00) > get_density(c01) * 1.5) {
            int tmp_c = c01; c01 = c00; c00 = tmp_c;
            float tmp_t = t01; t01 = t00; t00 = tmp_t;
        }
    }
    if (c10 != 0 && c11 != 0 && b10 && b11) {
        if (falls(get_phase(c10)) && get_density(c10) > get_density(c11) * 1.5) {
            int tmp_c = c11; c11 = c10; c10 = tmp_c;
            float tmp_t = t11; t11 = t10; t10 = tmp_t;
        }
    }

    // GAS DISSIPATION at top
    if (y0 <= 2u) {
        if (rises(get_phase(c00)) && (rng & 255u) < 2u) { c00 = 0; t00 = 20.0; }
        if (rises(get_phase(c10)) && ((rng >> 8) & 255u) < 2u) { c10 = 0; t10 = 20.0; }
    }

    // Write back
    cells.data[i00] = c00;
    cells.data[i10] = c10;
    cells.data[i01] = c01;
    cells.data[i11] = c11;

    temperatures.data[i00] = t00;
    temperatures.data[i10] = t10;
    temperatures.data[i01] = t01;
    temperatures.data[i11] = t11;
}
