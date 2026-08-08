# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- graphics: **a game can draw with its own shaders.** `boom.graphics.shader` takes a pair of SPIR-V modules and gives back a `Shader`; `pass_draw_shaded` and `pass_draw_shaded_skinned` draw with it. This is the supported way to do lighting: boom ships one lit program as a default and does not intend to grow a lighting system, because how a surface responds to light is the game's decision and an engine that decided it would be wrong for the next game.

  A `Shader` owns its pipelines rather than exposing them, so a game never names a `Pipeline`, a `RenderPass` or a descriptor set, and never imports `vk`. A Vulkan pipeline bakes the stages together with the vertex layout and the render pass it is used in, so one pair of shaders needs a different pipeline for every mesh layout and every target it is drawn into; those are built underneath the `Shader` on first use, keyed by the pass and the layout each draw actually needs. `shader_pipelines` reports how many, which is the cheapest signal that something is generating render targets or vertex layouts per frame. Exhausting the cache drops the draw and counts it rather than evicting a pipeline a command buffer may still be executing.

  Before this, the documented path was "build a `Pipeline` against a pass", which was not callable: there was no way to get a pass handle, `set_layout_full` was not exported, and no draw call took a pipeline. The claim had no executing coverage, which is where every defect found in this engine so far has been.

- graphics: `pass_set_user`, a game-owned uniform block delivered at binding 4. Without it a custom shader can only shade with constants baked in at compile time, which does not cover the case it exists for. The block is copied per draw, so a game may change the struct between draws and each draw keeps what it was submitted with. A uniform slot grew from 512 to 768 bytes to hold it, since a 256-byte alignment leaves only two usable offsets in 512; that is 384 KB of uniform ring across both frames, up from 256 KB.

- examples/shader: two cubes side by side, one through the built-in program and one through a `Shader`, with a light block set through `pass_set_user`.

### Added
- graphics: frustum culling. A pass resolves what it can see when it opens and skips draws whose bounds fall outside it. On by default, since a draw that cannot be seen is not worth submitting and a game should not have to remember to ask; `PassDesc.cull = 0` turns it off for a pass whose output is not what the camera sees, such as a shadow map, or for a game culling upstream. `renderer_culled` reports the count.

  `Mesh` gains a local-space `bounds`, computed once at upload from the POSITION attribute, since that is the only moment the vertices are on the CPU. Skinned meshes are bounded by their pose rather than their rest position, by transforming the rest box through each joint matrix and unioning: a character who reaches or is flung leaves the box it was authored in, and culling against that box pops it out of view while it is plainly still on screen. The joint matrices are already built for the palette upload, so this reuses them.

  2D sprites are culled against the camera's visible rectangle before expansion rather than after, because the cost avoided is the six vertices in the frame's arena, not the draw: a large world is mostly off screen and expanding all of it fills the arena with geometry nothing can see.

- math: `boom.math.aabb` and `boom.math.frustum`. Planes are extracted from the view-projection by the Gribb-Hartmann identity rather than rebuilt from camera parameters, so there is one description of what is visible and it is the same one the GPU clips against; a projection the extraction does not understand cannot exist. The box test is conservative: it rejects only a box wholly outside a plane, so it can keep something invisible but never removes something visible.
- graphics: `rect_overlaps`.

### Added
- graphics: `camera2d_height`, a camera that holds a fixed world height and lets the horizontal extent follow the viewport's aspect. A wider window then shows more world rather than the same world magnified, and every window shows the same distance vertically, which is what keeps a game fair across differently shaped monitors. All of the camera's conversions route through one `camera2d_scale`, so the projection, both point conversions and the visible rectangle cannot disagree about it.
- graphics: `boom.graphics.fit`, which computes where a fixed-size image belongs inside a window: stretch, contain, cover and whole-number scaling, plus `fit_scale` and `fit_unproject`. The engine does not pick a policy, because rendering at a fixed low resolution, laying out to the window, and letterboxing are all legitimate and different choices. It provides the arithmetic, because every game that scales needs it and the aspect-correct cases are easy to get subtly wrong in a way nothing reports until a window is an unusual shape.
- graphics: `renderer_width` and `renderer_height`. The swapchain adopts the surface's extent when it rebuilds, so it can differ from the window's reported size for the frame in which a resize is applied, and anything placed in framebuffer pixels has to use the renderer's.
- graphics: `material_texture_named`. The built-in programs sample one albedo texture, but a glTF material routinely carries normal, metallic-roughness and emissive maps too, and a game supplying its own pipeline needs them. The extra slots are storage for the game's use rather than a promise the built-in shader reads them, which the documentation now says outright.

### Fixed
- graphics: **a window resize was not applied at all** unless the driver happened to report the swapchain out of date. Measured on lavapipe under Wayland: a window taken from 1280x720 to 640x640 left the renderer at 1280x720 for as long as it ran, stretched, with no validation error anywhere. The renderer now compares the framebuffer size at the top of each frame and rebuilds when it differs, because the swapchain has to match the surface or presentation is undefined, so it is not a policy a game is entitled to decide differently, and anything a game must remember to call every frame is something it will one day forget. `renderer_resize` is now idempotent, so the per-frame check costs nothing when the size is unchanged.
- graphics: the joint palette ring was a flat 32 entries, so **the thirty-third skinned draw in a frame was refused**. Refusal is in submission order, so a crowd lost whichever characters were submitted last, silently: the same failure the sprite path had. The ring now grows in blocks of 32 up to 512 and retains them, so a game with a handful of characters pays for 32 forever and a game with a crowd pays for the crowd once.

### Added
- graphics: `Camera2D` and `pass_world`, so a 2D pass can pan, zoom and roll. See below for why a hand-rolled camera fails quietly.
- graphics: `camera2d_screen_to_world`, `camera2d_world_to_screen` and `camera2d_visible`. A pointer arrives in target pixels and a game has to answer world questions with it, so without these every game inverts the camera by hand; `camera2d_visible` is what bounds a tile field or a cull to what is actually on screen rather than to the target size, which is only the visible area at zoom 1.
- graphics: `camera_orthographic`, a 3D camera without foreshortening. Isometric and 2.5D views are not expressible by a perspective camera at any field of view, and `camera_perspective` was the only constructor.
- graphics: `camera_ray`, the ray through a viewport pixel, for picking and aiming. Built from the camera basis rather than by inverting the view-projection, so it needs no general 4x4 inverse and cannot go singular. Perspective and orthographic differ in the way they should: one fans out from a fixed origin, the other keeps one direction from a moving origin.
- math: `boom.math.ray`, with `Ray`, `ray_at` and `ray_plane_y`. A camera ray against a plane at constant height is what clicking on the ground, placing a building and aiming at a floor all reduce to. It reports whether it hit rather than returning a sentinel, so a click on the sky is distinguishable from a click at the origin.
- math: `mat4_project_point`, which divides through by w.

### Fixed
- math: `cos64` was `sin64(x + pi/2)`, which is exact in arithmetic and wrong in practice: shifting by a quarter turn lands every small angle on the far end of sine's reduced range, exactly where the truncated series is least accurate. **`cos(0)` returned 1.0000035, greater than one.** A rotation matrix built from it is not orthonormal and feeding it to `acos` is outside the domain. Cosine now evaluates its own series, so the common case of a small angle sits where the series is exact and `cos(0)` is exactly 1. Worst-case error over sixteen pi improves from 3.5e-6 to 4.6e-7.

  Sine gained a fifth term at the same time. Its worst case was the same 3.5e-6, about thirty ulp in f32, so it was visible through the f32 wrappers everything else calls; it is now 5.6e-8, below what f32 can represent. Found because a camera test that should have been exact was not.

- math: `mat4_transform_point` silently returned unclipped coordinates when handed a projection, because it applies no perspective divide. That is correct for a model or view matrix and wrong by a factor of w for a projection, and the error approaches zero near the view axis, so it looks right exactly where it is checked first. The contract is now documented and `mat4_project_point` does the divide. Two call sites had already hand-rolled it.

### Changed
- graphics: 2D draws are batched. A sprite used to be a draw of its own holding a uniform slot for its model matrix, tint and source rectangle. The slot ring is a fixed per-frame reservation shared by every draw in the frame, so a few hundred sprites exhausted it, and because draws are refused in submission order the ones lost were whichever came last. In a game that renders its world to an offscreen target and composites it afterwards, the last draws are the composite and the UI, so **a screenful of sprites did not lose some sprites, it lost the picture** and the drop counters that would have explained it were part of the UI that vanished. Measured in the onslaughter testbed: 600 drones submitted 687 draws against 512 slots, refused 175, and rendered a black window.

  A sprite is now expanded to six vertices in the frame's vertex arena and a run of sprites sharing a texture is drawn as one call holding one slot, which is the path `pass_draw_triangles` already used for immediate-mode geometry. This collapses the sprite path into that one rather than adding a third: sprites, text and UI share a buffer, a shader and a pipeline, and geometry from the same atlas coalesces across them. A run breaks on a texture change so submission order is never altered. The same testbed now draws 16000 drones in 6 draw calls with nothing refused, against the 16087 the old path would have submitted: one per sheet, one where the drone run crosses an arena block boundary, plus the composite and the UI.

- graphics: The vertex arena grows. It was a single fixed 1 MiB reservation per frame in flight, which after batching became the next hard ceiling at roughly 5400 sprites with the same failure mode. It is now a chain of blocks that doubles up to a 32 MiB step, so a frame that needs more room gets another block. Blocks are retained rather than freed, since a frame that needed the room will need it again and releasing memory the GPU may still be reading is the race the arena exists to prevent, so growth is paid once in the first frames. `renderer_stream_blocks` and `renderer_stream_reserved` report what it has grown to.

### Added
- graphics: `renderer_draws` reports the draw calls recorded in the most recent frame, which after batching is the number worth watching: a count that tracks the sprite count means something is breaking the run. `renderer_stream_blocks` and `renderer_stream_reserved` report the arena's growth and what it costs in host-visible memory.

### Fixed
- build: The compiled SPIR-V is committed under `res/spv/` instead of being gitignored. **boom could not be consumed as a git dependency at all**: the modules are `#[embed]`ed, an embed is not an edge in the build graph, so nothing ran the `build-shaders` step on a consumer's behalf and every `#[embed]` failed with "no such file or directory" (mach#2887). Every example resolves boom by path into a tree that had already been built locally, so all three passed CI for weeks while the library was unbuildable downstream. The first consumer that pulled it over git found it immediately.

  CI asserts the committed modules match a fresh build, which is the cost of committing a generated file and the reason the check had to exist.
- graphics: `texture_load`, `mesh_load` and `model_load` resolve their path through `boom.vfs`. They took a raw filesystem path while `sound_load` and `font_load` resolved `res://`, so the same spelling loaded a sound and failed for a texture with nothing but "no such file or directory" to go on. A path with no scheme is still passed through unchanged.


### Added
- graphics: `pass_draw_triangles`, for a stream of already-placed, per-vertex-coloured triangles. A sprite is one rectangle placed by a model matrix, which is the wrong shape for an immediate-mode UI, a particle system or a debug overlay: those produce thousands of triangles that are already in the right place, each with its own colour, rebuilt every frame, and they belong in one draw. Geometry goes through a new per-frame vertex arena (`boom.graphics.stream`), one per frame in flight, because writing this frame's list into memory the GPU is still reading for the last one is a race whose symptom is a UI that flickers under load and looks correct when you stop to inspect it.
- graphics: `vertex_format_ui`, the layout that path takes: position in pixels, uv, then rgba, eight f32 at a 32-byte stride. **This is blit's `Vert` exactly**, so a blit draw list uploads with no repacking, and a test asserts the two agree rather than leaving it to luck.
- shaders: `ui_vert.mach` and `ui_frag.mach`. One shader draws both solid and textured geometry, which is what lets a whole UI reach the GPU in one draw: a solid quad samples a reserved white texel so `colour * texel` is the flat colour, and a glyph samples its cell. No tint uniform, because a tint is per draw and this is one draw for a whole list.
- graphics: `renderer_stream_dropped`, counting draws the vertex arena refused. Separate from `renderer_dropped`, which counts uniform slots: they run out for different reasons and the fix differs.


### Added
- examples: `audio`, a runnable smoke test for the sound path. It generates a mono 44.1 kHz clip and a stereo 48 kHz one, writes them to disk, loads them back through `res://`, and checks that each plays to its end and returns its voice, that two overlap, and that a looping voice can be taken back. `boom.audio` had a full API and no executing coverage at all, which is how a mono clip being silent forever went unnoticed.

### Fixed
- vfs: `vfs_register` refuses `res` and `user` rather than accepting them and doing nothing. `vfs_resolve` answers those two from `res_root` and `user_root` before it consults the table, so an entry under either name could never be used, and returning true told the caller it had redirected `res://` when every asset would still load from the old root. Assign `res_root` or `user_root`; both are public.


### Fixed
- audio: A decoded clip is conformed to the device's format at load. mach-audio's `pull` emits silence and does not advance its cursor when a stream's channel count differs from the device's, and it does not look at sample rate at all. So **a mono clip against a stereo device was silent forever and its voice was never reclaimed**, and a 44.1 kHz clip on a 48 kHz device played sharp. Both are the common case: sound effects are usually mono and usually 44.1.

  Neither is a bug below this layer. `pull` is a primitive that says what it does; boom is what opens a device at a chosen format and then accepts arbitrary files against it. The conversion happens at load rather than in the render callback, which must not allocate, so it costs one pass per clip and nothing per frame. Linear interpolation for rate; a mono source fans out, and a source with more channels than the device is averaged rather than truncated to its first.


## [0.3.1] - 2026-08-08

### Fixed
- graphics: The device was created with `pEnabledFeatures = nil`, so the two optional features the skinned vertex stage requires were never enabled and **every skinned draw was invalid usage on every device**. It drew correctly and reported nothing. `vk_init` now checks for `shaderInt64` and `vertexPipelineStoresAndAtomics`, requests them by name, and refuses to start with a message naming the missing one rather than proceeding.

  Neither requirement comes from anything the shaders ask for. The palette index arithmetic is written in `u32` and lowers to 64-bit locals, declaring the `Int64` capability (mach#2878), and a storage buffer that is only ever read is not decorated `NonWritable`, so the driver must assume a vertex stage might write to it (mach#2879). Both requests can go once either is fixed.

### Added
- ci: `tools/check-uniform-layout.py` asserts which SPIR-V capabilities each module declares. A capability is a hardware requirement, and both of the above arrived from codegen without anyone choosing them; this is the check that catches the next one, and it needs no GPU.
- examples: The `vulkan` smoke test draws a skinned mesh and checks where it lands. Every vertex is weighted half to an identity joint and half to a translated one, so the cube must land at half the translation. A palette that never arrived, a wrong joint index and a wrong weight all draw a perfectly good cube in the wrong place, which is how the skinned path went unverified through a release.


## [0.3.0] - 2026-08-08

### Added
- graphics: `render_target_read` and `image_read`, which copy a rendered target back to host memory. Presenting a frame proves the calls succeeded and nothing about what was drawn, and this is the same operation a screenshot is.
- graphics: `render_target_bgra`, reporting the channel order a readback comes back in. It follows the surface format, which is the surface's choice, and a caller that guesses gets red and blue swapped with no diagnostic.
- graphics: `boom.graphics.pass`, the one render pass description every pass is built from. Render pass compatibility covers the subpass dependencies as well as the attachments, and a pipeline may only be used inside a compatible pass, so a pass that would be incompatible with the shared pipelines is no longer expressible.
- graphics: A pipeline cache (`boom.graphics.cache`), keyed by program and vertex layout. Vulkan bakes vertex input into a pipeline, and a glTF primitive decides its own layout, so pipelines are built on demand rather than once at startup.
- graphics: Skinned draws reach the GPU. `pass_draw_skinned` and `pass_draw_skinned_material` upload the pose's joint matrices into a per-frame storage buffer that `shaders/src/skinned_vert.mach` reads.
- graphics: `boom.graphics.device.Device`, the upload context every resource constructor now takes, since Vulkan has no implicit current context.
- graphics: A shared depth attachment helper (`boom.graphics.image.depth_attachment_init`), used by both the frame loop and offscreen targets.
- shaders: `skinned_vert.mach`, and texturing plus a base colour in `lit_frag.mach`.
- ci: The examples are built on every pull request. They resolve boom by path, so a change to the public API fails the build that made it rather than the next one.

### Changed
- graphics: The instance requests Vulkan 1.3, clamped by `vkEnumerateInstanceVersion` where that entry point exists. The SPIR-V version a driver accepts is fixed by the API version the instance declared, and 1.0 permits only SPIR-V 1.0 while mach emits 1.6, so every `vkCreateShaderModule` was invalid usage.
- graphics: The surface colour format is chosen once, in `vk_init`, and stored on `Vk`. The swapchain and any offscreen target must agree on it, because two render passes are compatible only when their attachment formats match and boom shares one set of pipelines between them.
- graphics: `image_init` takes a Vulkan format and an intended use rather than a colour space. A texture derives its format from what its bytes mean and a target derives it from the surface, and neither is expressible in terms of the other. An offscreen target's colour image now also carries `COLOR_ATTACHMENT_BIT` and `TRANSFER_SRC_BIT`.
- graphics: The transition to a presentable layout belongs to `frame_end` rather than to a render pass. A frame runs one pass, or three when the game renders into an offscreen target part way through, and no pass knows whether it is the last one.
- graphics: The render-finished semaphore is per swapchain image rather than per in-flight frame. It is waited on by the present of one specific image and is known to have retired only when that image is acquired again, and two frames against three images do not divide.
- graphics: Resource deletes wait for the device to go idle. A resource may still be referenced by a submitted command buffer; a deletion queue retired behind the frame fences is the eventual design, and a wait costs nothing where deletion happens today.
- graphics: **The renderer is Vulkan.** The OpenGL backend is gone, along with `boom.graphics.shader` and the `mach-gl` dependency. Shaders are Mach source under `shaders/`, compiled to SPIR-V at build time and embedded, so there is no runtime shader compilation and no shader source in a shipped binary.
- graphics: One `Renderer` per window, and it presents. A Vulkan frame is bracketed by an acquire and a present around one command buffer, so compositing several sources into a frame is done with passes and render targets rather than with several renderers.
- graphics: `renderer_begin_frame` reports through an out parameter whether a frame opened. A `false` is an out-of-date swapchain that was rebuilt, which every resize causes.
- graphics: Resources are created against the `Device` that `renderer_device` returns: `texture`, `texture_load`, `mesh`, `mesh_load`, `model_load`, `render_target`, and their deletes.
- graphics: `Material` no longer carries a shader; `material()` takes no arguments and `material_texture` replaces `material_bind`.
- graphics: The window's render pass has a depth attachment, so 3D drawn straight to the window depth-tests and its pipelines are compatible with an offscreen target's pass.
- graphics: A draw's slot is two 256-aligned sub-slots rather than two packed blocks. A uniform descriptor's buffer offset must satisfy `minUniformBufferOffsetAlignment`, which is up to 256, so a colour block packed at 144 bytes into the slot is accepted on hardware reporting 16 and rejected on hardware reporting 256.
- graphics: `descriptors_bind_slot` refuses a nil image view rather than leaving binding 1 unwritten. Every fragment stage boom ships samples, so the untextured case is the renderer's 1x1 white texture, not a skipped write.
- graphics: `mesh_load` conforms a glTF primitive to one of two canonical vertex layouts, standard or skinned, filling in attributes the asset omits. A shader input with no vertex attribute behind it is invalid rather than merely unused.
- math: `mat4_perspective` and `mat4_orthographic` target the Vulkan clip volume: depth in [0, 1] and Y increasing downward. Under the OpenGL forms the near half of every frustum was clipped away and everything rendered vertically mirrored. The Y flip does not change the winding the rasterizer sees, since Vulkan's framebuffer is already Y-down, so `frontFace` stays counter-clockwise.
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

### Fixed
- graphics: `frontFace` was CLOCKWISE, on the reasoning that the projection's Y flip reverses winding. It does not: Vulkan's framebuffer already has Y increasing downward, so negating Y converts a Y-up view space into that convention rather than mirroring what the rasterizer sees. It culled part of every closed mesh, invisibly, because the faces behind the culled ones are drawn instead and reach the same silhouette.
- graphics: `load_device` was passed `vkGetDeviceProcAddr`, which is the global `load_device` itself sets, so the bootstrap was nil and was called: a jump to address zero on the first device created.
- graphics: `VK_INCOMPLETE` was treated as an enumeration failure. It means the array was smaller than the full result, which is exactly as useful here, and it is invisible on hardware with short lists and fatal on hardware with long ones.
- graphics: The window's render pass and an offscreen target's differed in subpass dependency count, which is enough on its own to make every draw into a target invalid.
- graphics: The window pass declared `PRESENT_SRC_KHR` as its final layout, so the resume pass used after an offscreen excursion began with the image in a layout its `initialLayout` contradicted.

### Removed
- graphics: `Shader`, `shader`, `shader_delete`, `SKINNED_VERTEX_SRC`, and every GLSL string.

## [0.2.0] - 2026-07-07

### Changed
- manifest: Migrated root and example manifest layouts (`mach.toml`) and dependencies to the V2 manifest specification.
