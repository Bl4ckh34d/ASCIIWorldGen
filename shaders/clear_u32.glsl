#[compute]
#version 450

layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;

layout(std430, set = 0, binding = 0) buffer DataBuf { uint data[]; } Data;

layout(push_constant) uniform Params { int total; } PC;

void main(){
    uint i = gl_GlobalInvocationID.x;
    if (i >= uint(PC.total)) return;
    Data.data[i] = 0u;
}


