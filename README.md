![](./readme/vanillabp-headline.png)

## What a build produces

Every build runs the javadoc check in the `package` phase. It breaks on an error, which is a
reference javadoc cannot resolve or broken HTML. It lets a warning pass, which is mostly a missing
comment.

The `release` profile adds to that. It packs the sources jar and the javadoc jar, and it signs
what the build produced. The release workflows use it together with `central-portal`.

A snapshot is deployed without that profile, so it carries no javadoc jar. That changed with
version 1.2.1, which moved the `attach-javadocs` execution into the profile. Before that the
execution sat in the managed section, and a repository which named the javadoc plugin in its own
build got a javadoc jar out of every build it ran.

This is not an oversight. Nobody here reads javadoc from a snapshot. The local Maven repository of
a development machine was searched for it: it holds many sources jars fetched from a remote, and
markers of many more that were asked for and did not exist, and not one entry of either kind for
javadoc. An IDE which offers to download sources and documentation asks for the sources.

If that ever changes, the two ways out are to give the snapshot deploy `-P release` or to bind
`attach-javadocs` back into the managed section.

Sources are the other half of that question, and they got the other answer. This POM attaches
them in the `release` profile as well, so a snapshot got none out of it, and for sources somebody
does ask: an IDE which jumps into a class offers to fetch them, and the local Maven repository of
a development machine is full of markers of sources jars which were asked for and were not there.
Every repository which publishes snapshots therefore binds `maven-source-plugin` in its own build,
the way `adapter-platform-integration` always has.

That binding is not in this POM, although here it would be written once. It would not reach
everyone: `camunda7-adapter` and `camunda8-adapter` have no parent POM at all, the Business
Cockpit repositories still name version 1.1.1, and every other repository would have to wait for
a release of this POM and then raise its parent version. All five would go on publishing
snapshots without sources until that was done, and two of them for good. A build which packs its
sources costs about a tenth of a second per module.

## Where snapshots are published and read

Snapshots live on Maven Central, in the snapshot repository
`https://central.sonatype.com/repository/maven-snapshots/`. This POM names it under
`<repositories>`, so every repository which inherits this POM resolves the snapshots of the others
from there. Reading needs no login. That is what lets the build of a pull request from a fork
resolve the snapshots it depends on, because GitHub gives such a build no secrets.

One repository serves every namespace which has snapshots switched on in the Central Portal. It
answers for `io.vanillabp` and for `com.phactum` alike, so there is no second entry for the second
namespace.

To publish a snapshot, run `mvn deploy -P central-portal` on a version ending in `-SNAPSHOT`. The
publishing plugin looks at the version: a release goes to the Central Portal as a deployment, a
snapshot goes straight to the snapshot repository. Both use the server id `vanillabp-central` and
the same Central Portal token. A snapshot needs neither a signature nor a javadoc jar, so the
`release` profile is not needed for it.

Central removes a snapshot about 90 days after it was published. A repository whose `main` does not
change for that long loses its snapshot, and every build which depends on it fails. A repository
which changes rarely therefore publishes its snapshot on a schedule as well, not only on a push to
`main`.

## Noteworthy & Contributors

VanillaBP was developed by [Phactum](https://www.phactum.at) with the intention of giving back to the community as it has benefited the community in the past.

![Phactum](./readme/phactum.png)

## License

Copyright 2022 Phactum Softwareentwicklung GmbH

Licensed under the Apache License, Version 2.0
