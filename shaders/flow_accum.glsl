#[compute]
#version 450

layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;

layout(std430, set = 0, binding = 0) buffer FlowDirBuf { int flow_dir[]; } Flow;
layout(std430, set = 0, binding = 1) buffer AccumBuf { uint accum[]; } Accum; // read/write as uint for atomic

layout(push_constant) uniform Params { int total; } PC;

void main(){
    uint i = gl_GlobalInvocationID.x;
    if (i >= uint(PC.total)) return;
    int to = Flow.flow_dir[i];
    if (to >= 0 && to < PC.total) {
        atomicAdd(Accum.accum[to], Accum.accum[i]);
    }
}


