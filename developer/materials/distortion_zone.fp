varying mediump vec2 var_texcoord0;
varying mediump vec2 var_world_xy;

uniform lowp sampler2D texture_sampler;
uniform lowp vec4 tint;
uniform mediump vec4 distortion_params;

void main()
{
    mediump float strength = distortion_params.x;
    mediump float frequency = max(distortion_params.y, 0.001);
    mediump float phase = distortion_params.z;
    mediump float alpha = distortion_params.w;
    mediump float wobble = sin((var_world_xy.x + var_world_xy.y) * frequency + phase) * strength;
    mediump vec2 uv = var_texcoord0.xy + vec2(wobble, wobble * 0.5);
    lowp vec4 color = texture2D(texture_sampler, uv) * tint;
    color.a *= alpha;
    gl_FragColor = color;
}
