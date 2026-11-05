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
change for that long loses its snapshot, and the next build which depends on it fails and says so.
None of the repositories publishes on a schedule today. That was decided on purpose: a push to
`main` publishes again, and a missing snapshot shows up in the first build which needs it.

## Releasing several repositories as one deployment

Sonatype limits what the `io.vanillabp` namespace may publish: 2500 files, 100 MB and 9
deployments a month. Every release of a repository is one deployment, and an update of all
repositories is 13 of them. A release train uploads the releases of several repositories as one
deployment.

First run the release workflow of each repository with the input `train`, for example `2.0`.
The build signs everything as usual but does not upload. It keeps its bundle as an Actions
artifact. Tag, draft GitHub release and the pull request back into `main` come as usual. Before
its build, a train release unpacks the bundles of the train which are already there into its
local Maven repository. That is how it finds a version of another repository which is not on
Maven Central yet, and it is why the releases of a train follow the order of the dependencies.

Then run `release-train.yaml` in this repository with the same `train`. It merges the bundles and
prints the files and MB per repository. It stops if a file is in two bundles or if the sum breaks
the limits. With `dry_run` it stops before the upload. Without it, it uploads the merged bundle
once and waits until Maven Central has published it.

A train needs version 0.12.0 of `central-publishing-maven-plugin`, which comes with
release-parent 2.0.0. A repository which still names 1.3.0 stops its train release before the
build. The workflows read the other repositories with the organization secret
`VANILLABP_USER_TOKEN`, which needs `actions:read` there.

Each repository has one slot per train. The Camunda 8 adapter and the Business Cockpit Camunda 8
adapter have one slot per release line. If a slot is built twice, the newest build counts. So a failed validation is fixed
like this: fix the repository, run its release workflow again with the same `train`, then run
`release-train.yaml` again. The fix may be a new patch version or the same version again. For the
same version the workflow moves the tag and reuses the release branch and its pull request.
Nothing is on Maven Central before the upload, so moving the tag is safe.

The order for 2.0:

1. `maven-release-parent` alone, without a train. Every other repository names the new version on
   `main` first, and its pull request needs that version on Maven Central to build.
2. Train one: `spi-for-java`, `adapter-platform-integration`, `business-cockpit`. Then
   `release-train.yaml`.
3. Outside the trains: the Camunda 7 adapter in the Camunda Community Hub, which publishes under
   `org.camunda.community`. It needs train one on Maven Central.
4. Train two, in this order: `camunda8-adapter` (one run releases all three lines),
   `cibseven-adapter`, `operaton-adapter`, `hazelcast-shared-election-cache`,
   `businesscockpit-camunda7-adapter`,
   `businesscockpit-camunda8-adapter` (one run releases all three lines),
   `businesscockpit-cibseven-adapter`, `businesscockpit-operaton-adapter`. Then
   `release-train.yaml`.

Train two comes after the Camunda Community Hub because it needs the Camunda 7 adapter on Maven
Central. The migration tests of `cibseven-adapter` and `operaton-adapter` run it next to their own
engine, and the tests of `hazelcast-shared-election-cache` boot with it. The cockpit adapters of CIB
seven and Operaton build on the engine adapters of the same train, so those two come first.

The Camunda 8 adapter publishes as `io.vanillabp` since version 2, so it rides in train two. It
comes before `businesscockpit-camunda8-adapter`, which builds each of its lines against the line of
the Camunda 8 adapter with the same name and reads it from the bundle of the same train.

`process-engine-api-adapter` and `businesscockpit-process-engine-api-adapter` are not part of 2.0.

## Noteworthy & Contributors

VanillaBP was developed by [Phactum](https://www.phactum.at) with the intention of giving back to the community as it has benefited the community in the past.

![Phactum](./readme/phactum.png)

## License

Copyright 2022 Phactum Softwareentwicklung GmbH

Licensed under the Apache License, Version 2.0
