varying mediump vec2 var_texcoord0;

uniform lowp sampler2D texture_sampler;
uniform lowp sampler2D palette;
uniform lowp vec4 tint;
uniform mediump vec4 palette_params;

void main()
{
    lowp vec4 color = texture2D(texture_sampler, var_texcoord0.xy);

    if (palette_params.x > 0.5) {
        mediump float luminance = dot(color.rgb, vec3(0.299, 0.587, 0.114));
        color.rgb = texture2D(palette, vec2(luminance, 0.5)).rgb;
    }

    lowp vec4 tint_pm = vec4(tint.xyz * tint.w, tint.w);
    gl_FragColor = color * tint_pm;
}
