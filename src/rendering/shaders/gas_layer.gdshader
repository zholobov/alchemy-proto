shader_type canvas_item;
render_mode blend_add;

uniform float blur_amount = 3.0;
uniform float distortion_strength = 0.01;
uniform float fade_strength = 0.7;

void fragment() {
	vec2 ps = TEXTURE_PIXEL_SIZE;

	vec4 sum = vec4(0.0);
	float count = 0.0;
	for (int dy = -3; dy <= 3; dy++) {
		for (int dx = -3; dx <= 3; dx++) {
			vec2 offset = vec2(float(dx), float(dy)) * ps * blur_amount;
			float weight = 1.0 / (1.0 + float(dx * dx + dy * dy) * 0.5);
			sum += texture(TEXTURE, UV + offset) * weight;
			count += weight;
		}
	}
	vec4 blurred = sum / count;

	if (blurred.a < 0.01) {
		discard;
	}

	float dist_x = sin(UV.y * 20.0 + TIME * 2.0) * distortion_strength;
	float dist_y = cos(UV.x * 15.0 + TIME * 1.5) * distortion_strength;
	vec4 distorted = texture(TEXTURE, UV + vec2(dist_x, dist_y));

	vec3 color = mix(blurred.rgb, distorted.rgb, 0.5);
	float alpha = blurred.a * fade_strength;

	COLOR = vec4(color, alpha);
}
