# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- graphics: A pipeline cache (`boom.graphics.cache`), keyed by program and vertex layout. Vulkan bakes vertex input into a pipeline, and a glTF primitive decides its own layout, so pipelines are built on demand rather than once at startup.
- graphics: Skinned draws reach the GPU. `pass_draw_skinned` and `pass_draw_skinned_material` upload the pose's joint matrices into a per-frame storage buffer that `shaders/src/skinned_vert.mach` reads.
- graphics: `boom.graphics.device.Device`, the upload context every resource constructor now takes, since Vulkan has no implicit current context.
- graphics: A shared depth attachment helper (`boom.graphics.image.depth_attachment_init`), used by both the frame loop and offscreen targets.
- shaders: `skinned_vert.mach`, and texturing plus a base colour in `lit_frag.mach`.
- ci: The examples are built on every pull request. They resolve boom by path, so a change to the public API fails the build that made it rather than the next one.

### Changed
- graphics: **The renderer is Vulkan.** The OpenGL backend is gone, along with `boom.graphics.shader` and the `mach-gl` dependency. Shaders are Mach source under `shaders/`, compiled to SPIR-V at build time and embedded, so there is no runtime shader compilation and no shader source in a shipped binary.
- graphics: One `Renderer` per window, and it presents. A Vulkan frame is bracketed by an acquire and a present around one command buffer, so compositing several sources into a frame is done with passes and render targets rather than with several renderers.
- graphics: `renderer_begin_frame` reports through an out parameter whether a frame opened. A `false` is an out-of-date swapchain that was rebuilt, which every resize causes.
- graphics: Resources are created against the `Device` that `renderer_device` returns: `texture`, `texture_load`, `mesh`, `mesh_load`, `model_load`, `render_target`, and their deletes.
- graphics: `Material` no longer carries a shader; `material()` takes no arguments and `material_texture` replaces `material_bind`.
- graphics: The window's render pass has a depth attachment, so 3D drawn straight to the window depth-tests and its pipelines are compatible with an offscreen target's pass.
- graphics: A draw's slot is two 256-aligned sub-slots rather than two packed blocks. A uniform descriptor's buffer offset must satisfy `minUniformBufferOffsetAlignment`, which is up to 256, so a colour block packed at 144 bytes into the slot is accepted on hardware reporting 16 and rejected on hardware reporting 256.
- graphics: `descriptors_bind_slot` refuses a nil image view rather than leaving binding 1 unwritten. Every fragment stage boom ships samples, so the untextured case is the renderer's 1x1 white texture, not a skipped write.
- graphics: `mesh_load` conforms a glTF primitive to one of two canonical vertex layouts, standard or skinned, filling in attributes the asset omits. A shader input with no vertex attribute behind it is invalid rather than merely unused.
- math: `mat4_perspective` and `mat4_orthographic` target the Vulkan clip volume: depth in [0, 1] and Y increasing downward. Under the OpenGL forms the near half of every frustum was clipped away and everything rendered vertically mirrored. `frontFace` is CLOCKWISE to match the Y flip.
- window: `window_open` creates a window with no client API; `window_open_vulkan` and `window_swap` are gone.
- examples: `cube` and `animation` are ported; `vulkan` is now a renderer-level smoke test rather than a parallel hand-built path. All three resolve boom by path.
- manifest: Re-touched root and example manifests (`mach.toml`) to RFC-exact totality per mach#1964/mach#1979.

- window: `window_open` records the framebuffer size in pixels rather than the requested size in screen coordinates, which differ on a scaled display. `window_refresh_size` re-reads it, and the engine loop calls it once per frame, so `ctx.window.width` is true after a resize instead of frozen at startup.
- graphics: `renderer_resize` adopts the extent the surface actually granted rather than the one requested. A surface reporting a concrete `currentExtent` overrides the request, so recording the request left the viewport and the 2D projection sized for a window that no longer existed.
- examples: `cube` and `animation` recompute their camera aspect each frame and skip drawing while minimized.

- graphics: `skeleton_pose` fills the joints past `count` with identity. A skinned draw uploads the whole `MAX_JOINTS` palette in one copy, so an out-of-range joint index would otherwise transform a vertex by uninitialized floats.

- graphics: **Colours look different.** The swapchain is an sRGB format, which encodes on write, but textures were UNORM, so the shader received raw sRGB bytes as though they were linear and the result was encoded a second time. Textures and offscreen colour attachments are now sRGB formats, so sampling decodes to linear, the shaders work in linear light, and the surface encodes once. Output was washed out before this and is correct after it.
- graphics: `texture` takes a `ColorSpace`. `COLOR_SRGB` for anything authored to be looked at, `COLOR_LINEAR` for data stored in an image. `texture_load` picks `COLOR_SRGB`, since QOI and TGA carry nothing else.
- graphics: The swapchain accepts either sRGB surface format rather than only `B8G8R8A8_SRGB`. `renderer_is_srgb` reports a surface that offers neither, which renders darker than authored and is otherwise indistinguishable from a shader bug.

- graphics: `model_load` rejects a model whose vertices reference a joint the skin does not have. The skinned vertex stage indexes a fixed-size palette with whatever `JOINTS_0` holds, so an out-of-range index reads outside it.

- graphics: A render target's colour image is put into a readable layout at creation. A game may sample a target before its first render, at which point the image was in `UNDEFINED` while the descriptor claimed `SHADER_READ_ONLY_OPTIMAL` — a lie about the layout, not merely undefined contents.

### Removed
- graphics: `Shader`, `shader`, `shader_delete`, `SKINNED_VERTEX_SRC`, and every GLSL string.

## [0.2.0] - 2026-07-07

### Changed
- manifest: Migrated root and example manifest layouts (`mach.toml`) and dependencies to the V2 manifest specification.
