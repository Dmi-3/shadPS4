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

## Remaining weapon material source probe

A second local capture (frame 2351) reproduced the remaining black weapon parts while zero-times-NaN intervention was active. Draw 10071, primitive 13, fragment hash 0x90d1b3c4 produced NaN RGB at scene pixel (1117,571). GPU probes measured multiplier 817 as 0.748535 and material values 1256/1260/1266 as NaN. Thus the zero-product predicate correctly does not cover this fragment. Replacing only these three material values with zero in offline replay yielded finite RGB (0.00226593, 0.00224113, 0.00141811) and visible weapon detail. This establishes influence, not the origin or intended values of these constants.

`--diagnose-uncharted-material-source` adds a Windows-only, read-only probe immediately before flat-buffer upload for this captured shader hash. It follows the observed user-data register 0 pointer and its first nested pointer through bounded ReadProcessMemory calls, compares guest words with flat-buffer words 74..76, and logs at most eight samples containing NaN. Failed reads are explicitly reported. It does not change guest data, shaders, cache selection, or synchronization. Other platforms perform no probe. Addresses and values remain in local runtime logs; captures and game assets are not committed. The inferred pointer path is specific to this capture and must be checked against its generated SRT walker, not treated as a generic material layout.

Automated tests remain deferred at the user's request. Native build and diff checks validate the diagnostic implementation; a live scene run is needed to collect the source comparison. No upstream cause is claimed yet.

Live source comparison: seven complete samples read the same nested source address successfully through different root tables. Guest and flat-buffer words 74..76 all matched 0xffc00000. This rules out a mismatch during those CPU snapshots, but does not rule out newer GPU-side contents. The probe now also reports IsRegionGpuModified for the 12-byte source range; it does not synchronize or modify the range. Static ReadConst loads currently use the CPU flat buffer even with DMA enabled. GPU freshness remains a hypothesis pending this additional run.

The follow-up live run produced seven complete samples with successful pointer reads, matching guest/flat NaN words and gpu_modified=false. This gives no evidence of a newer tracked GPU version at those sample times; tracker coverage is not independently established. A bounded read of the surrounding source block found NaN only in the first three floats, followed by ordinary values including 0, 0.1 and 1. The original GCN has no decoded conditional SOPP branch; it loads the nested pointer from user-data base 0 at offset 0, then 16 dwords from that pointer at offset 0. The next investigation must identify the guest writer or an earlier source for these three values. Source corruption is still not attributed to a specific CPU operation.

## Windows guest writer trace

The standalone tools/diagnostics/windows-write-watch.cpp utility launches an executable under the Windows debug API and watches one aligned four-byte address on existing and newly created threads. Invocation: windows-write-watch ADDRESS EXE LOG [arguments...]. It logs up to the first 16 writes and stops at a NaN write, a 512-hit bound, a four-minute timeout, or process exit. On a NaN write it records the post-store instruction pointer, registers, nearby instruction bytes and stack words. It clears its watch and detaches while leaving the game running. It passes unrelated guest exceptions through rather than swallowing crashes. This changes execution timing and uses hardware debug register slot 0; it is a local diagnostic tool, not a rendering fix. The watched address must be checked against current material source logs after launch, since a heap address can change. Automated tests are deferred; native helper compilation is the implementation gate, with live writer collection separately required.
