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

## Noteworthy & Contributors

VanillaBP was developed by [Phactum](https://www.phactum.at) with the intention of giving back to the community as it has benefited the community in the past.

![Phactum](./readme/phactum.png)

## License

Copyright 2022 Phactum Softwareentwicklung GmbH

Licensed under the Apache License, Version 2.0
