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
