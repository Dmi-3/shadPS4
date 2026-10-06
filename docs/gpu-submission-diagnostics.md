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
