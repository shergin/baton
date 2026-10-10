# Reading the macrobenchmark's traces

The SQL here reads a trace `EndToEndBenchmark` leaves under
`/sdcard/Android/media/baton.macro/` with Perfetto's trace processor, run
on the phone itself: the Macrobenchmark library ships `trace_processor_shell`
in the benchmark's assets, so nothing is downloaded.

```bash
gradle :benchmarks:macro:assembleBenchmark
adb push build/intermediates/assets/benchmark/mergeBenchmarkAssets/trace_processor_shell_aarch64 /data/local/tmp/trace_processor_shell
adb push queries /data/local/tmp/queries
adb shell chmod +x /data/local/tmp/trace_processor_shell
adb shell '/data/local/tmp/trace_processor_shell -q /data/local/tmp/queries/last-byte-window.sql /sdcard/Android/media/baton.macro/<trace>.perfetto-trace'
```

Each query answers for one trace of a cold start, Baton's sample or the
Apollo twin, with times in microseconds:

- `last-byte-window.sql`: the response's last byte to the data in the
  store and to the list's frame; where the main thread's first
  `Choreographer#doFrame` begins and ends relative to the last byte; the
  running time of the dispatcher and OkHttp threads inside that window and
  when it ends; and the main thread's running time in it.
- `first-composition.sql`: the first frame's length, the first
  `Compose:recompose` inside it, and how long the main thread runs and
  sleeps during that composition while other threads of the process wait
  on the kernel.
- `first-frame.sql`: the slices of the first frame on the main thread,
  relative to the last byte.
- `main-thread-timeline.sql`: the main thread's top-level slices from the
  process's start to the list's frame, relative to the last byte, for
  Baton's sample.
