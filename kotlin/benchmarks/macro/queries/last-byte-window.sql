with w as (select ts as start, ts + dur as finish from slice where name = 'ListLastByteToStore' limit 1),
f as (select ts + dur as finish from slice where name = 'ListStoreToFrame' limit 1),
p as (select upid, pid from process where name in ('baton.sample.android', 'baton.sample.apollo') limit 1),
main as (select utid from thread, p where thread.upid = p.upid and thread.tid = p.pid),
frame as (select s.ts, s.dur from slice s join thread_track tt on s.track_id = tt.id, main, w where tt.utid = main.utid and s.depth = 0 and s.name like 'Choreographer#doFrame%' and s.ts < w.start and s.ts + s.dur > w.start limit 1),
workers as (select sum(x.dur) as cpu, max(x.ts + x.dur) as last_running from thread_state x join thread t on t.utid = x.utid, p, w where t.upid = p.upid and t.tid != p.pid and (t.name like 'Default%' or t.name like 'OkHttp%') and x.state = 'Running' and x.ts >= w.start and x.ts + x.dur <= w.finish),
mainwork as (select sum(x.dur) as cpu from thread_state x, main, w where x.utid = main.utid and x.state = 'Running' and x.ts >= w.start and x.ts + x.dur <= w.finish)
select (w.finish - w.start) / 1000 as to_store_us, (f.finish - w.finish) / 1000 as to_frame_us, (frame.ts - w.start) / 1000 as frame_start_us, (frame.ts + frame.dur - w.start) / 1000 as frame_end_us, workers.cpu / 1000 as worker_cpu_us, (workers.last_running - w.start) / 1000 as worker_done_us, mainwork.cpu / 1000 as main_cpu_us from w, f, workers, mainwork left join frame;
