with p as (select upid, pid from process where name in ('baton.sample.android', 'baton.sample.apollo') limit 1),
main as (select utid from thread, p where thread.upid = p.upid and thread.tid = p.pid),
r as (select s.ts, s.dur from slice s join thread_track tt on s.track_id = tt.id, main where tt.utid = main.utid and s.name = 'Compose:recompose' order by s.ts limit 1),
frame as (select s.ts, s.dur from slice s join thread_track tt on s.track_id = tt.id, main where tt.utid = main.utid and s.depth = 0 and s.name like 'Choreographer#doFrame%' order by s.ts limit 1),
mains as (select sum(case when x.state = 'S' then min(x.ts + x.dur, r.ts + r.dur) - max(x.ts, r.ts) else 0 end) as sleeping, sum(case when x.state = 'Running' then min(x.ts + x.dur, r.ts + r.dur) - max(x.ts, r.ts) else 0 end) as running from thread_state x, r, main where x.utid = main.utid and x.ts < r.ts + r.dur and x.ts + x.dur > r.ts),
others as (select sum(min(x.ts + x.dur, r.ts + r.dur) - max(x.ts, r.ts)) as d from thread_state x join thread t on t.utid = x.utid, r, p where t.upid = p.upid and t.tid != p.pid and x.state = 'D' and x.ts < r.ts + r.dur and x.ts + x.dur > r.ts)
select frame.dur / 1000 as frame_us, r.dur / 1000 as recompose_us, mains.sleeping / 1000 as main_sleep_us, mains.running / 1000 as main_run_us, ifnull(others.d, 0) / 1000 as others_d_us from frame, r, mains, others;
