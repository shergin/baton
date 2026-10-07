# An image belongs to one store

Status: accepted, 2026-10-04; supersedes the README's sign-out, one image
removed and handed from environment to environment, which stands until the
end it rests on is built. Serves
[What earns a concept](../principles/what-earns-a-concept.md). Reopen if
two stores have to share an image at once: a second process, as
[The image is the system's SQLite](the-image-is-sqlite.md) names, or two
environments of one account.

## Context

As built, a `Persistence` outlives its stores. A sign-out is `removeAll()`
on the image and the same image for the next environment. A store made
before the removal must read, write and date nothing after it, so the
image counts its removals, a store notes the count when it is made, and
eight of the image's functions take it. The count is there because nothing
says when the old store is done with the file.

The first adopter asked for more
([#9](https://github.com/shergin/baton/issues/9)): a purge that survives a
crash, by a marker written before the delete, and an image per account.
The issue's own case is a process that dies after the credentials are
removed and before the image is deleted. A marker does not cover it: the
purge had not begun.

## Decision

- An image is made for one store and lives as long as it (built 2026-10-06).
  The environment's end closes it and gives the file back
  ([The environment is the session](the-environment-is-the-session.md));
  the next environment makes its own, on that file or another. The count
  of removals and its parameters go.
- What keeps one account's rows from the next is the image's identity, not
  the purge. Either the account is in the path, so each account has a
  file, caches coexist and a switch of accounts keeps them; or it is in
  `version`, so one file serves, and opened for another account it is
  emptied before anything is read. Both work today.
- Deleting the file is then hygiene: it can be interrupted and repeated. A
  switch of accounts ends the environment and keeps the file; a sign-out
  ends it and removes the file.
- The order of a sign-out is the app's: end the environment, remove the
  image, forget the credential last. A crash before the last step leaves
  the account signed in, with or without its cache, and nothing readable
  by another.
- Added 2026-10-06: the close is final. As built, a commit or a read that
  reached a closed image opened its file again and took it back, so that a
  store still settling after its environment's end could take the file
  from the next environment's image, which then ran without one for the
  process, or tripped the assertion that one image holds a file in a debug
  build. A closed image drops the work queued after its close and misses
  every read; a removal still deletes the file. The next image is the next
  store's, and nothing the ending store asks reaches the file.

## Evidence

- The image's open: an image written under another `version` has
  its rows deleted in the transaction that opens it, before any read. The
  persistence test "an unreadable image is a miss: garbage, another
  version and a removed image start over" covers it.
- The persistence tests on the count: a response the user who signed out
  was waiting for lands after `removeAll()` and reaches neither the image
  nor the next user, and a store made before the removal reads nothing
  from the image after it. An ended store that commits nothing proves the
  same with no count.
- The persistence test of an image closed right behind its commit: it
  gives its file to the next. The hand-over the end needs exists, as
  `close()`.
- The close made final: CI's floor job twice ended in the assertion of
  `Disk.init`, an image made on a file a closed image had taken back. The
  persistence test of a store that commits and reads after its image
  closed reaches neither the file nor the next image.
- The marker's limit is an argument, not a test: in the issue's case no
  purge ran, so there was nothing for a marker to record.

## Not chosen

- One image for successive stores, fenced by a count of removals, as
  built: correct, and paid on everything a store asks of the image, for
  want of an end.
- A sign-out made durable by a marker beside the file. It covers a crash
  inside the delete and none before it. Whether the delete itself gets a
  marker is the image's own question, and is not decided here.
- A parameter for the account: the path and `version` already spell it.
