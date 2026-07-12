from pathlib import Path

from PIL import Image


PROJECT_ROOT = Path(__file__).resolve().parents[1]
ATLAS_PATH = PROJECT_ROOT / "resources" / "texture" / "动态瓦片.png"
ATLAS_WIDTH = 64
ORIGINAL_ATLAS_HEIGHT = 96
OUTPUT_ATLAS_HEIGHT = 128
FRAME_WIDTH = 16
FRAME_HEIGHT = 32
FRAME_COUNT = 4
HOME_GATE_Y = 96

# Sampled from the image-generation reference, then kept constant so the
# original red gate's alpha pulse remains the only animation change.
BLUE_GATE_RGB = (1, 135, 254)
BLUE_TRANSPARENT_EDGE_RGB = (0, 101, 191)
# Keep the original center exclamation mark, but remove the surrounding warning
# decoration so the home gate remains visually distinct from the red gate.
WARNING_DECORATION_PIXELS = {
	(2, 11),
	(13, 11),
	(3, 12),
	(12, 12),
	(3, 19),
	(12, 19),
	(2, 20),
	(13, 20),
}


def main() -> None:
	image = Image.open(ATLAS_PATH).convert("RGBA")
	if image.width != ATLAS_WIDTH or image.height not in (
		ORIGINAL_ATLAS_HEIGHT,
		OUTPUT_ATLAS_HEIGHT,
	):
		raise ValueError(f"Unexpected dynamic tile atlas size: {image.size}")

	base_atlas = image.crop((0, 0, ATLAS_WIDTH, ORIGINAL_ATLAS_HEIGHT))
	red_gate_strip = base_atlas.crop((0, 0, ATLAS_WIDTH, FRAME_HEIGHT))
	blue_gate_strip = _build_blue_gate_strip(red_gate_strip)

	output = Image.new("RGBA", (ATLAS_WIDTH, OUTPUT_ATLAS_HEIGHT), (0, 0, 0, 0))
	output.alpha_composite(base_atlas, (0, 0))
	output.alpha_composite(blue_gate_strip, (0, HOME_GATE_Y))
	output.save(ATLAS_PATH, optimize=True)
	print(f"Wrote blue home-gate animation to {ATLAS_PATH}")


def _build_blue_gate_strip(red_gate_strip: Image.Image) -> Image.Image:
	blue_gate_strip = red_gate_strip.copy()
	for frame_index in range(FRAME_COUNT):
		frame_x = frame_index * FRAME_WIDTH
		for y in range(FRAME_HEIGHT):
			for local_x in range(FRAME_WIDTH):
				x = frame_x + local_x
				red, green, blue, alpha = red_gate_strip.getpixel((x, y))
				if _is_warning_decoration_pixel(local_x, y):
					blue_gate_strip.putpixel((x, y), (0, 0, 0, 0))
				elif alpha > 0:
					blue_gate_strip.putpixel((x, y), (*BLUE_GATE_RGB, alpha))
				elif red != 0 or green != 0 or blue != 0:
					blue_gate_strip.putpixel(
						(x, y),
						(*BLUE_TRANSPARENT_EDGE_RGB, 0),
					)
	return blue_gate_strip


def _is_warning_decoration_pixel(x: int, y: int) -> bool:
	return (x, y) in WARNING_DECORATION_PIXELS


if __name__ == "__main__":
	main()
