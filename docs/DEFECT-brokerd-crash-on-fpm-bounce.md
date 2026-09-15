# brokerd segfaults on every FPM session bounce

FIXED. `vyatta-route-broker` commit 659f67a, "Stop the kernel consumer instead
of cancelling it".

Found while measuring what a drift repair costs at scale. Not in the component
being worked on, and more serious than anything the measurement set out to
find.

## What happens

Bounce the FPM session -- `no fpm address`, then `fpm address` -- and brokerd
dies with SIGSEGV. Twenty-one cores in one session, no exceptions.

The data plane does not crash. It is restarted, because brokerd is the thing
feeding it: `terminating core 1`, `stopped core 1`, fresh start. Twenty-six
start/stop events in forty minutes on the probed box. The visible consequence
is that the forwarding table empties and refills.

## What the trigger actually is

The heading of this file used to say "under bulk route load", because both
crashes seen first were during bulk route operations. That was a coincidence of
where the probes bounced the session. Three separated phases:

```
A. bulk load only, 2000 routes, add and delete   cores stayed 2   NO CRASH
B. FPM bounce only, small table                  cores 3, 4, 5    EVERY TIME
C. bulk load with the session down, reconnect    crashed at the load-while-down step
```

The route count is irrelevant. The session teardown is the whole trigger.

## Root cause

`route_broker_kernel_shutdown()` ran `pthread_cancel()` on the consumer thread,
and is called on every FPM teardown rather than at process exit.

The consumer blocks in `route_broker_client_get_data()`, which waits on a
condition variable. That is a cancellation point, and one that reacquires
`route_broker_mutex` before it returns. There is no `pthread_cleanup_push`
anywhere in this library. So the cancel could land on a thread holding that
mutex, between taking an object and freeing it, or inside a ZMQ send. The
process then carried on with a mutex that would never be released and ZMQ state
torn half-way, and the next publish faulted inside the allocator.

That matches the cores exactly:

```
#0  in ?? () from libc.so.6
#2  _mid_memalign (...) at ./malloc/malloc.c:3738
#4  in ?? () from libczmq.so.4
#6  zmq_close () from libzmq.so.5
#13 broker_dp_client_publish ()
#21 route_broker_kernel_shutdown () at ./broker/route_broker_kernel.c:72
```

Everything between those frames is unrecoverable, and that was itself a finding
while it lasted: the dbgsym matched the binary exactly -- build ID
`c2336f164d8236b6f209cb2949ced31b21c24238` on both -- and the frames still did
not resolve, because they are not return addresses. `0x5584afaa29a8` is about
11 MB past `main`, and brokerd's text is 51 KB. Those are heap addresses
sitting on the stack, which is what corruption looks like from gdb. The two
frames that did resolve turned out to be enough.

The fix is a stop flag. The consumer's wait times out after a second, so the
flag is noticed within that and the thread leaves by its own route, with its
locks released and its client deleted.

```
ten FPM bounces before the fix:  ten cores
ten FPM bounces after:           none
```

## The first diagnosis, which was wrong

`dp_data_sock` was a function-local static in `broker_dp_data_client()`, which
`start_new_dp_data_thread()` runs as a new zactor per data plane session. Every
invocation shared one variable, so a departing thread could destroy an arriving
one's socket -- a use-after-free reached through `zmq_close()`, which is exactly
the frame at the top of the stack.

It was plausible, it survived a code review, it explained the backtrace, and it
was wrong. Rebuilt, md5-confirmed as the running binary, ten bounces, ten
cores.

It is fixed anyway, in the same commit, because it is still a bug. But it is
recorded here as a wrong answer, because a wrong answer that explains all the
available evidence is worth having written down.

## What this defect cost, twice

**"An FPM resync empties the forwarding table."** Drawn from the scale probe
catching `routes 0` across a reconnect. It would have been written down as an
architectural constraint on the repair primitive. It was the crash: the empty
table is a restarted data plane. What separated them was one command -- the age
of the dataplane process, 126 seconds on a box that had been up for hours.

**"An FPM reconnect is a repair primitive, 20/20."** Twenty routes were missing
from the data plane, the session was bounced, and all twenty arrived. What
actually happened is that brokerd crashed on the bounce, systemd restarted it,
and `broker_dump_routes()` re-seeded the whole table from the kernel FIB at
startup. The routes did arrive. The mechanism was not the one named, and the
name is what would have been built on.

Both are withdrawn. See below for what replaced them.

## What is true after the fix

The table still empties on an FPM bounce. Measured with the fixed binary, 500
routes, sampled every two seconds, zero cores produced:

```
sample 3: routes 508
sample 4: routes 0
sample 5: routes 508
```

This is not the crash and not a resync gap. brokerd `accept()`s one FPM
connection and immediately `close()`s its listening socket: **one FPM session
per brokerd process, by design.** A bounce therefore ends the process, systemd
restarts it, the data plane's feed dies with it and the data plane restarts.
`Deactivated successfully` in the journal, exit 0, no core.

So the conclusion that the crash was hiding survives the crash being fixed, and
now rests on a clean measurement rather than an inference from a fault:

> An FPM bounce blanks the forwarding table. It cannot be an automatic repair
> primitive, whatever its end state looks like.

Three readings of the same `routes 0`, in order: a design property (wrong), a
crash (right, and not the whole answer), a design property again -- a different
one, for a different reason, and this time measured with the crash out of the
way.

## Reproducer

`toolkit/vm/probe-brokerd-crash.sh` -- separates load from bounce, counts cores
per phase. Pre-fix it produces a core per bounce in phase B.

Cores from the original session preserved at `build-iso/crash-tmp/` on the build
host, with the matching binary and dbgsym, since the VM is ephemeral.

## Also recorded: the measurement that proved nothing

`probe-resync-outage.sh` was written to time the window and confirm the traffic
loss. It established neither.

Its path never came up -- `100% packet loss` in its own first step -- so the
ping it ran across the window was aimed at an unreachable address, and the
traffic result is void. Its route samples were taken in a loop with no sleep,
each iteration costing an ssh round trip, so its `t+Ns` labels are not seconds.

It replaced an earlier check that was worse: a ping *after* the window, to an
address reached over the management interface, which is kernel-owned and never
crosses the data plane. That one reported `0% packet loss` under a heading
asking whether forwarding survived.

Both are kept as written. A probe that measured the wrong thing twice in two
different ways is worth more on the page than in memory.

## Still not measured

How long the blanked window lasts, and what traffic sees inside it. The
sampling above brackets it between two and four seconds at 500 routes, which is
a bound, not a measurement, and says nothing about the shape of it at a real
table size. The probe that was supposed to answer this is the one described
directly above.
