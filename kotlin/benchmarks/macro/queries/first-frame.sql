with w as (select ts as start from slice where name = 'ListLastByteToStore' limit 1),
p as (select upid, pid from process where name in ('baton.sample.android', 'baton.sample.apollo') limit 1),
main as (select utid from thread, p where thread.upid = p.upid and thread.tid = p.pid),
frame as (select s.ts, s.dur from slice s join thread_track tt on s.track_id = tt.id, main where tt.utid = main.utid and s.depth = 0 and s.name like 'Choreographer#doFrame%' order by s.ts limit 1)
select (s.ts - w.start) / 1000 as rel_us, s.dur / 1000 as dur_us, s.depth, s.name from w, frame, main, slice s join thread_track tt on s.track_id = tt.id where tt.utid = main.utid and s.ts >= frame.ts and s.ts < frame.ts + frame.dur and s.depth <= 5 and s.dur >= 400000 order by s.ts;
