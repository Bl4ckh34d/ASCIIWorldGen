#[compute]
#version 450
// File: res://shaders/world_data1_from_buffers.glsl
// Pack base world data (height, temperature, moisture, light) from buffers into RGBA32F texture.

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(std430, set = 0, binding = 0) buffer HeightBuf { float height[]; } Height;
layout(std430, set = 0, binding = 1) buffer TempBuf { float temp[]; } Temp;
layout(std430, set = 0, binding = 2) buffer MoistBuf { float moist[]; } Moist;
layout(std430, set = 0, binding = 3) buffer LightBuf { float light[]; } Light;
layout(rgba32f, set = 0, binding = 4) uniform image2D out_tex;

layout(push_constant) uniform Params {
    int width;
    int height;
} PC;

void main() {
    uint x = gl_GlobalInvocationID.x;
    uint y = gl_GlobalInvocationID.y;
    if (x >= uint(PC.width) || y >= uint(PC.height)) return;
    int i = int(x) + int(y) * PC.width;
    float h = Height.height[i];
    float t = Temp.temp[i];
    float m = Moist.moist[i];
    float l = Light.light[i];
    float h_norm = clamp(h * 0.5 + 0.5, 0.0, 1.0);
    float t_norm = clamp(t, 0.0, 1.0);
    float m_norm = clamp(m, 0.0, 1.0);
    float l_norm = clamp(l, 0.0, 1.0);
    imageStore(out_tex, ivec2(int(x), int(y)), vec4(h_norm, t_norm, m_norm, l_norm));
}
