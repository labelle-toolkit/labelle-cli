/// Shared SDL2 C import — all backend modules import this to avoid opaque type mismatch.
pub const c = @cImport(@cInclude("SDL2/SDL.h"));
