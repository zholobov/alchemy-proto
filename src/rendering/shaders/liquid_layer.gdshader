shader_type canvas_item;

uniform float blur_amount = 1.5;
uniform float refraction_strength = 0.003;
uniform float time_speed = 1.0;

void fragment() {
	vec2 ps = TEXTURE_PIXEL_SIZE;
	vec4 sum = vec4(0.0);
	float count = 0.0;

	for (int dy = -2; dy <= 2; dy++) {
		for (int dx = -2; dx <= 2; dx++) {
			vec2 offset = vec2(float(dx), float(dy)) * ps * blur_amount;
			vec4 sample_color = texture(TEXTURE, UV + offset);
			float weight = 1.0 / (1.0 + float(dx * dx + dy * dy));
			sum += sample_color * weight;
			count += weight;
		}
	}
	vec4 blurred = sum / count;

	if (blurred.a < 0.05) {
		discard;
	}

	float alpha = smoothstep(0.1, 0.4, blurred.a);

	float wobble_x = sin(UV.y * 30.0 + TIME * time_speed) * refraction_strength;
	float wobble_y = cos(UV.x * 25.0 + TIME * time_speed * 0.8) * refraction_strength;
	vec2 refracted_uv = UV + vec2(wobble_x, wobble_y);
	vec4 refracted = texture(TEXTURE, refracted_uv);

	vec3 color = mix(blurred.rgb, refracted.rgb, 0.3);

	COLOR = vec4(color, alpha * blurred.a);
}
