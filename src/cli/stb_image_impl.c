/* Instantiates the stb single-header implementations for texpack:
   stb_image (PNG decode) and stb_image_write (PNG encode). Both are
   used in no-stdio mode — texpack feeds bytes in and out itself. */

#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_PNG
#define STBI_NO_STDIO
#include "stb_image.h"

#define STB_IMAGE_WRITE_IMPLEMENTATION
#define STBI_WRITE_NO_STDIO
#include "stb_image_write.h"
