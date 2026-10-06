# The image's file is protected at creation and waited for when locked

Status: accepted, 2026-10-06. Serves
[Honest data](../principles/honest-data.md) and
[What earns a concept](../principles/what-earns-a-concept.md). Answers what
[An image belongs to one store](an-image-belongs-to-one-store.md) left to
the image: whether the delete gets a marker. Reopen if a platform offers a
protection class SQLite's open cannot give the log, or if an app shows work
waiting for a locked file longer than its store holds.

## Context

The first adopter asked ([#9](https://github.com/shergin/baton/issues/9))
for the image to carry the platform's protection class, chosen rather than
inherited from its directory, and for a sign-out's deletion to survive a
crash. Under `.complete` a file cannot be opened while the device is locked.
As built, a batch the file could not take was dropped and a marker made the
next open discard the image, so that it never served rows older than memory
knew: under `.complete`, every background refresh on a locked device would
have emptied the cache.

## Decision

- The protection is a value given when the image is made,
  `Persistence(url:version:sizeLimit:protection:)` and the `name:` form, a
  `FileProtectionType` or nil for the directory's default. Apple's SQLite
  takes it as an open flag and gives the write-ahead log the same class; a
  class the open has no flag for is set on the file and its log once they
  exist. The image records the class it was made under and starts again
  under another, so that what the image states is true of its file.
- A file that cannot be taken is waited for, not discarded. Work the file
  cannot take, at the open or in the transaction, goes back to the front of
  the queue and is written at the next drain, which the next commit or read
  brings, not sooner than a second after a failed open. A read meanwhile
  misses. Only a damaged file is discarded, with its work. Work that
  outgrows what a store holds at the bench's largest scale, 50,000 rows, is
  dropped and the image marked, as every lost batch was before.
- At the close, work the file cannot take is lost: the store it was for is
  ending, and nothing is behind what memory no longer holds.
- A marker beside the file covers a crash inside the delete and no more:
  written before the file goes and removed after, it has the next open
  finish the deletion. A file that cannot be opened at the removal, locked,
  is marked for the next open to tell and delete. A crash before the removal
  is the image's identity's to cover, as decided. The log is deleted before
  the database file: a database left alone is a consistent older image,
  where a log left alone would be replayed into the next file made at the
  path.

## Evidence

- On macOS 26.5, a file Apple's SQLite makes under
  `SQLITE_OPEN_FILEPROTECTION_COMPLETE` reports `.complete`, and so does its
  write-ahead log; the shared-memory file keeps the directory's default (a
  probe in the step; the persistence tests check the file and the log).
- The persistence tests: work the file cannot take waits and lands when the
  file can be taken again; an image made under another protection starts
  again; a marker left by an interrupted removal is finished at the next
  open and one beside a database of another kind leaves it alone; a removal
  of a file that cannot be opened is marked and finished later; work past
  the wait limit is dropped and the image starts again.
- The open gained one read of the image's `meta` table. Run side by side
  with the commit before it on the quick suite, under the same load, the
  launch entries of `BENCHMARKS.md` do not move beyond the run's noise.

## Not chosen

- Dropping work the file cannot take and discarding the image, as built:
  right for a damaged file, and ruinous under `.complete`.
- Setting the class with `FileManager` after creation: it leaves the log to
  the directory's default and a window in which the file has none; the
  library's own flag has neither.
- A sync of the marker before the delete: the marker covers a crash of the
  process, which the kernel's view of the file survives; power loss in the
  middle of a sign-out is beyond it, as the decision says.
- A retry the writer schedules for itself: on a locked device the app is
  suspended with it, and the next commit or read tries again.
- Encrypting the content: the system's protection is the first answer; an
  encrypted engine would be weighed against
  [the image being the system's SQLite](the-image-is-sqlite.md).
