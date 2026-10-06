# GPU submission timing diagnostic

Run the matching build with `--sync-submit-done --game PATH/eboot.bin` to wait
for queued command submissions before finishing each guest frame. The wait
uses the existing command-processor idle predicate, with a five-second limit.
Timeouts are reported at warning level and continue through the normal path.
This does not force Vulkan device idle or manufacture completed fences.

The flag defaults off. It is a timing experiment, not a confirmed fix or a
hardware-validated implementation of PS4 submission behavior. Games with
cross-frame dependencies may hit the wait limit; disable the flag to compare
against the baseline. Performance can change substantially.

Windows unhandled exceptions additionally report access type, target address,
registers, and the fault instruction when process memory can be read safely.
Instruction bytes are copied with ReadProcessMemory before decoding; no guest
stack pointers are dereferenced. This distinguishes an intentional guest trap
from an invalid data access without suppressing either exception.

Local native build and diff checks passed. Automated tests were not run at the
user's request. In-game reproduction and comparison are still required before
claiming that a crash or rendering defect is fixed.

## Bounded RenderDoc capture

`--renderdoc-present-capture` makes F12 request RenderDoc's automatic
present-to-present capture rather than spanning the command-processor drain.
It defaults off and does not change guest rendering. The original manual path
did not complete during a local CUSA03281 trial and grew to about 22 GB of RAM.
The present-based trial completed and gameplay continued, producing a capture
with 612 draw calls and 1624 dispatches while the process used about 3.8 GB.
These figures describe that trial only, not a hard memory guarantee.

For a portable Windows RenderDoc, supply its manifest directory through
`VK_ADD_IMPLICIT_LAYER_PATH` and set `ENABLE_VULKAN_RENDERDOC_CAPTURE=1` only
for the launched process. Launch through `renderdoccmd capture` so the app API
is available before Vulkan initialization. Verify a Vulkan frame capturer in
the runtime log; loading renderdoc.dll alone does not establish Vulkan capture.

## Zero-times-NaN investigation

`--diagnose-zero-nan-products` is an opt-in diagnostic intervention, not a PS4 arithmetic fix. It makes FP32 multiply return positive zero only when one operand compares equal to zero (including negative zero) and the other operand is NaN. Ordinary IEEE multiplication is unchanged without the flag; zero times infinity and nonzero times NaN remain IEEE operations. It does not change FP64 or fused multiply-add.

The flag selects a separate recorded-cache root, cache/zero-nan-diagnostic-v1/<serial> (or its .zip form), before opening the storage database. Diagnostic modules can be recorded and warmed there; normal recorded modules are never loaded or replaced by this mode. Pipeline cache must be enabled to use this isolated warmup. Driver cache behavior is unchanged.

Evidence: local RenderDoc 1.46 capture of CUSA03281, draw event 10526, primitive 416, fragment hash 0x90d1b3c4. The material flat constant words 74..76 are 0xffc00000; their shared multiplier is zero. NaN propagates to all RGB outputs before postprocessing. GPU probes inspected 732 scalar intermediate values. Isolating these three products in replay restored weapon surface detail. Original GCN contains ordinary MAD, so using legacy-MAD semantics as a production fix would be unjustified. A separately identified legacy MAD translation issue is deferred.

Manual verification of the diagnostic intervention in the running game is required. It may hide upstream invalid material data and must not be presented as resolving the source of that data, aiming blur, or crashes. Automated tests are deferred at the user's explicit request; build and local GPU replay verification are recorded separately. Captures, shader bytes, and game data are not committed.

The first live diagnostic run crashed while loading the scene with the existing guest FrameBegin assertion m_gfxEopTick, line 234, followed by int 0x41. It did not validate weapon appearance. Cache isolation replaces the initial always-cold diagnostic approach so repeat runs can reuse modules compiled under this intervention.


Local cache seeding experiment: copied 3298 files into the isolated diagnostic root, instrumenting scalar FP32 OpFMul in 1147 of 1176 modules (114471 products). No normal cache files were modified. All resource interfaces, metadata and pipeline keys remain unchanged. A representative rewritten weapon module was accepted by RenderDoc BuildTargetShader and produced finite RGB (0.0166168, 0.0165405, 0.0120163) at event 10526 instead of NaN. This local binary experiment is not distributed or committed; fresh native compilation implements the same predicate. Seed counts do not measure driver cache hits or whole-game coverage.

Live verification after isolated warmup (945/945, exit 0): user reports partial improvement, with Drake's weapon almost entirely normal. Remaining weapon defects, aiming blur and sustained stability are still unverified. This confirms an effect of the intervention without establishing an upstream fix.
