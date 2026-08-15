# TCP-check scale test

A synthetic fleet for answering "how many TCP-checked devices can one poller
carry" without owning thousands of devices. The whole fleet is one Linux box:
a dummy interface holding N addresses, and three response classes by port -
identical on every address, so two of the three need no server at all.

| port | class | behavior |
|---|---|---|
| 9101 | accept | one `0.0.0.0` listener answers for every address (fast up) |
| 9102 | rst | nothing listens; the kernel refuses (fast, cheap down) |
| 9103 | drop | nftables swallows the SYN (slow down: full client timeout) |

## Run

On the fleet box (needs sudo for the interface and nftables; pwsh for the
poller - the run script drives the real `pingcanvas-poller.ps1` locally):

```
./run-test.sh 1000 90,5,5 140
```

N devices, accept/rst/drop mix, observation window in seconds. Prints one
line per poller cycle (write time + fleet TIME_WAIT count), then joins the
board against the status file and asserts every class landed on its expected
state. `sudo ./tcp-fleet.sh down` tears everything out.

The mix is assigned as `k % 100` against the thresholds, so every poller
batch of 100 consecutive devices carries exactly the mix - uniform batch
poisoning, the worst case for the batch-wait design and therefore the honest
default.

## Measured (2026-08-15, defaults: interval 30s, timeoutMs 1000, throttleLimit 100)

Ubuntu 24.04 VM, poller and fleet co-resident. These figures are dominated by
timeout arithmetic, not hardware, which is why a shared VM could produce them.

| N | mix | first cycle | steady cadence | classes |
|---|---|---|---|---|
| 100 | 90/5/5 | ~3s | 30s | all correct |
| 500 | 90/5/5 | ~9s | 30s | all correct |
| 1,000 | 90/5/5 | ~18s | 30s | all correct |
| 2,000 | 90/5/5 | ~36s | **36s - interval breached** | all correct |
| 4,000 | 90/5/5 | ~72s | 71s | all correct |
| 4,000 | all-accept | **~2s** | 30s | all correct |

**The model, confirmed at every point:** the poller polls in sequential
batches of `throttleLimit`, and each batch waits on its slowest member,
capped at `timeoutMs + 750`. Any batch containing one timing-out device
costs the full ~1.75s; an all-healthy batch costs milliseconds. So with a
realistic down-fraction spread across the fleet:

```
cycle ≈ ceil(N / throttleLimit) x (timeoutMs + 750 ms)
```

which breaches a 30s interval near **N ≈ 1,700** at the defaults. The count
itself is nearly free (4,000 healthy targets: 2-second cycles) - **the
down-fraction is the entire cost.** Correctness never degraded: every class
was reported correctly at every N.

Levers, in order of effect: raise `throttleLimit` (fewer batches - 400 takes
the breach point to ~6,800), lower `timeoutMs`, lengthen the interval.

**TIME_WAIT:** only the accept class leaves sockets behind (refused connects
fault before establishing; dropped ones are aborted mid-SYN). Steady state
plateaued at ~12,000 for 4,000 healthy targets on a 30s cycle - 43% of
Linux's default ephemeral range, projecting exhaustion near ~9,000 targets.
Windows arithmetic is tighter (TIME_WAIT up to 120s against a ~16k default
range): expect the wall near ~4,000 there. Measured on Linux only.
