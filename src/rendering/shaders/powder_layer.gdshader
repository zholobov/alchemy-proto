shader_type canvas_item;

uniform sampler2D noise_texture : repeat_enable;
uniform float grain_scale = 8.0;
uniform float grain_strength = 0.15;
uniform float time_offset = 0.0;

void fragment() {
	vec4 base = texture(TEXTURE, UV);
	if (base.a < 0.01) {
		discard;
	}

	vec2 noise_uv = UV * grain_scale + vec2(time_offset * 0.01, 0.0);
	float noise_val = texture(noise_texture, noise_uv).r;

	vec3 color = base.rgb;
	color *= 0.85 + noise_val * grain_strength * 2.0;

	float edge = smoothstep(0.0, 0.15, base.a);
	color *= 0.8 + edge * 0.2;

	COLOR = vec4(color, base.a);
}
