/* Instantiates the stb single-header implementations for texpack:
   stb_image (PNG decode) and stb_image_write (PNG encode). Both are
   used in no-stdio mode — texpack feeds bytes in and out itself.

   TGA/BMP decode is on for cli#356: `labelle run --screenshot=x.png`
   can land at `x.png.tga` because the bgfx backend appends its own
   extension, and `src/cli/screenshot_format.zig` re-encodes that
   capture into the format the user asked for. Those two are the only
   extensions `pipeline.zig`'s `screenshot_suffixes` list allows a
   backend to append (PNG is already decodable). */

#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_PNG
#define STBI_ONLY_TGA
#define STBI_ONLY_BMP
#define STBI_NO_STDIO
#include "stb_image.h"

#define STB_IMAGE_WRITE_IMPLEMENTATION
#define STBI_WRITE_NO_STDIO
#include "stb_image_write.h"
