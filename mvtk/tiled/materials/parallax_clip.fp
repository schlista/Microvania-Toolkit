varying mediump vec2 var_texcoord0;
varying mediump vec3 var_world_pos;

uniform lowp sampler2D texture_sampler;
uniform mediump vec4 clip_rect; // x_min, y_min, x_max, y_max in world space
uniform lowp vec4 tint;

void main()
{
    // Only apply clipping if bounds are reasonable (not at disabled defaults)
    bool clipping_enabled = (clip_rect.z - clip_rect.x) < 1000000.0;

    if (clipping_enabled) {
        if (var_world_pos.x < clip_rect.x ||
            var_world_pos.y < clip_rect.y ||
            var_world_pos.x > clip_rect.z ||
            var_world_pos.y > clip_rect.w) {
            discard;
        }
    }

    // Pre-multiply alpha to match Defold's built-in sprite rendering
    lowp vec4 tint_pm = vec4(tint.xyz * tint.w, tint.w);
    gl_FragColor = texture2D(texture_sampler, var_texcoord0.xy) * tint_pm;
}
