#[compute]
#version 450

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(std430, set = 0, binding = 0) readonly buffer LabelBuf { int labels[]; } Lbl;
layout(std430, set = 0, binding = 1) buffer FlagsBuf { int flags[]; } Flags;

layout(push_constant) uniform Params { int width; int height; } PC;

int idx(int x, int y) { return x + y * PC.width; }

void mark_if_valid(int i){
    int lbl = Lbl.labels[i];
    if (lbl > 0) {
        Flags.flags[lbl] = 1;
    }
}

void main(){
    uint x = gl_GlobalInvocationID.x;
    uint y = gl_GlobalInvocationID.y;
    if (x >= uint(PC.width) || y >= uint(PC.height)) return;
    int W = PC.width; int H = PC.height;
    int xi = int(x); int yi = int(y);
    if (yi == 0 || yi == H - 1 || xi == 0 || xi == W - 1){
        int i = idx(xi, yi);
        mark_if_valid(i);
    }
}


