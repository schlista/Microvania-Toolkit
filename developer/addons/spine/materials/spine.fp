#version 140

// Adapted from Defold's extension-spine (defold-spine/assets/spine.fp), which is
// licensed under the Defold License: https://www.defold.com/license
// Modified for the Microvania Toolkit. This file remains under the Defold License
// and is free for everyone. It is never sold or charged for as part of any
// Microvania Toolkit license.

in mediump vec2 var_texcoord0;
in lowp vec4 var_color;

uniform lowp sampler2D texture_sampler;

uniform fs_uniforms
{
    mediump vec4 tint;
};

out vec4 out_fragColor;

void main()
{
    // Pre-multiply alpha since var_color and all runtime textures already are.
    lowp vec4 tint_pm = vec4(tint.xyz * tint.w, tint.w);
    lowp vec4 color_pm = var_color * tint_pm;
    out_fragColor = texture(texture_sampler, var_texcoord0.xy) * color_pm;
}
