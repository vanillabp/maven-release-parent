#!/usr/bin/env bash
# Versions in a release build. A release works on a release branch, and main keeps its
# SNAPSHOT dependencies on the other VanillaBP repositories until those are on Maven
# Central. This script is how the release branch gets the released versions instead. It is
# no tool of the release train alone: a single release uses it as well. See the README of
# maven-release-parent.
#
# The release workflows of the other repositories download this file at a fixed commit of
# maven-release-parent, so a later change here cannot break an older release branch.
#
#   release-versions.sh raise [<train>]
#       In a release build, after the own version is set and after
#       'release-train.sh prepare', before the build. In every pom.xml of the repository, a
#       version 'x-SNAPSHOT' of an artifact of a group 'io.vanillabp*' which this repository
#       does not build becomes 'x'. That works for a literal version and for a property
#       like 'adapter-platform.version'. 'x' is taken when the bundles of the train hold it
#       or when Maven Central has it. If one artifact has neither, nothing is changed, and
#       the message names the artifact and the repository which has to be released first.
#       The changed versions are printed and written to $RUNNER_TEMP/raised-versions.txt
#       for the release commit.
#   release-versions.sh unpublished <version>...
#       In a release build, before anything leaves the build. Stops if Maven Central has
#       one of the given versions of an artifact this repository builds. Below that line a
#       release may move its tag and replace its release branch, because nothing of that
#       version can be used by anybody yet.
#   release-versions.sh no-snapshots [<directory>]
#       In a release build, after 'raise', before the build. Stops if a pom.xml of the
#       repository still names a SNAPSHOT. 'raise' changes those of io.vanillabp* only, so
#       this is the step which finds a SNAPSHOT of anybody else, for example of a library
#       which is not on Maven Central yet. A property which holds the version of the
#       repository itself, like 'revision', is left out, because the build overrides it.
#       With a directory it reads every *.pom below it instead, which is what
#       release-train.yaml does with the merged bundle before the upload.
#
# The bundles of a train are the ones 'release-train.sh prepare' downloaded to
# $RUNNER_TEMP/release-train-work. They are read there and not in ~/.m2/repository, because
# the local repository may come from the cache of an older run and hold a build which is
# not part of this train.
#
# Environment, for tests: CENTRAL_URL (default https://repo1.maven.org/maven2),
# SNAPSHOTS_URL (default https://central.sonatype.com/repository/maven-snapshots),
# RELEASE_TRAIN_WORK (default $RUNNER_TEMP/release-train-work).
set -euo pipefail

command=${1:-}
shift || true
case "$command" in
  raise) [ $# -le 1 ] || { echo "::error::usage: release-versions.sh raise [<train>]" >&2; exit 1; } ;;
  unpublished) [ $# -ge 1 ] || { echo "::error::usage: release-versions.sh unpublished <version>..." >&2; exit 1; } ;;
  no-snapshots) [ $# -le 1 ] || { echo "::error::usage: release-versions.sh no-snapshots [<directory>]" >&2; exit 1; } ;;
  *) echo "::error::usage: release-versions.sh raise|unpublished|no-snapshots ..." >&2; exit 1 ;;
esac

exec python3 -I - "$command" "$@" <<'PYTHON'
import glob
import os
import re
import sys
import time
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
import zipfile

GROUP = "io.vanillabp"
SUFFIX = "-SNAPSHOT"
CENTRAL = os.environ.get("CENTRAL_URL", "https://repo1.maven.org/maven2").rstrip("/")
SNAPSHOTS = os.environ.get(
    "SNAPSHOTS_URL", "https://central.sonatype.com/repository/maven-snapshots").rstrip("/")
TEMP = os.environ.get("RUNNER_TEMP", "/tmp")
WORK = os.environ.get("RELEASE_TRAIN_WORK", os.path.join(TEMP, "release-train-work"))
PROPERTY_ONLY = re.compile(r"\$\{([^}]+)\}")


def fail(message):
    print(f"::error::{message}", file=sys.stderr)
    sys.exit(1)


def local(tag):
    return tag.rsplit("}", 1)[-1] if isinstance(tag, str) else ""


def text(element):
    return (element.text or "").strip() if element is not None else ""


def pom_files():
    """Every pom.xml of the repository, as the SNAPSHOT check of the workflows sees them."""
    found = []
    for directory, subdirectories, files in os.walk("."):
        subdirectories[:] = sorted(
            d for d in subdirectories if d not in (".git", "target", "node_modules", "src"))
        if "pom.xml" in files:
            found.append(os.path.join(directory, "pom.xml")[2:])
    return sorted(found)


class Pom:
    def __init__(self, path):
        self.path = path
        try:
            self.root = ET.parse(path).getroot()
        except ET.ParseError as error:
            fail(f"{path} is no valid XML: {error}")
        children = {local(c.tag): c for c in self.root}
        parent = {local(c.tag): text(c) for c in children.get("parent", [])}
        self.group = text(children.get("groupId")) or parent.get("groupId", "")
        self.artifact = text(children.get("artifactId"))

    def group_of(self, value):
        if value in ("${project.groupId}", "${pom.groupId}", "${groupId}"):
            return self.group
        return value

    def references(self):
        """(groupId, artifactId, version) of everything which names a version: dependency,
        parent, plugin, extension, annotation processor path and the like."""
        for element in self.root.iter():
            if element is self.root:
                continue
            children = {}
            for child in element:
                children.setdefault(local(child.tag), child)
            if "artifactId" not in children or "version" not in children:
                continue
            group = self.group_of(text(children.get("groupId")))
            yield group, text(children["artifactId"]), text(children["version"])

    def properties(self):
        for element in self.root.iter():
            if local(element.tag) == "properties":
                for child in element:
                    if isinstance(child.tag, str):
                        yield local(child.tag), text(child)


def analyse(poms):
    """What has to change: properties and literal versions which hold a SNAPSHOT of an
    io.vanillabp* artifact this repository does not build."""
    own = {(p.group, p.artifact) for p in poms}
    definitions = {}
    for pom in poms:
        for name, value in pom.properties():
            definitions.setdefault(name, []).append((pom, value))
    users = {}  # property -> artifacts whose version it decides
    literals = []  # (pom, group, artifact, version)
    for pom in poms:
        for group, artifact, version in pom.references():
            if not group.startswith(GROUP) or (group, artifact) in own:
                continue
            match = PROPERTY_ONLY.fullmatch(version)
            if match:
                users.setdefault(match.group(1), set()).add((group, artifact))
            elif version.endswith(SUFFIX):
                literals.append((pom, group, artifact, version))
    # a property may stand for another one, e.g. a line property of a Camunda 8 line
    changed = True
    while changed:
        changed = False
        for name, artifacts in list(users.items()):
            for _, value in definitions.get(name, []):
                for inner in PROPERTY_ONLY.findall(value):
                    known = users.setdefault(inner, set())
                    if not artifacts <= known:
                        known |= artifacts
                        changed = True
    properties = []  # (pom, name, version, artifacts)
    for name, artifacts in sorted(users.items()):
        for pom, value in definitions.get(name, []):
            if value.endswith(SUFFIX) and "${" not in value:
                properties.append((pom, name, value, sorted(artifacts)))
    return properties, literals


def path_of(group, artifact, version, extension="pom"):
    return f"{group.replace('.', '/')}/{artifact}/{version}/{artifact}-{version}.{extension}"


def request(url, method="HEAD", tolerant=False):
    """The body of the answer, b'' for HEAD, or None if the server does not have it. A
    server which cannot answer stops the script, unless the question is a tolerant one."""
    for attempt in range(4):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, method=method), timeout=30) as answer:
                return answer.read() if method == "GET" else b""
        except urllib.error.HTTPError as error:
            if error.code == 404:
                return None
            problem = f"HTTP {error.code}"
        except (urllib.error.URLError, TimeoutError) as error:
            problem = str(error)
        time.sleep(2 ** attempt)
    if tolerant:
        return None
    fail(f"Cannot ask {url}: {problem}")


def bundles():
    """Path in a bundle -> the slot whose bundle holds it."""
    content = {}
    for bundle in sorted(glob.glob(os.path.join(WORK, "*", "central-bundle.zip"))):
        slot = os.path.basename(os.path.dirname(bundle))
        with zipfile.ZipFile(bundle) as archive:
            for entry in archive.namelist():
                content.setdefault(entry, slot)
    return content


def repository_of(group, artifact, snapshot):
    """The GitHub repository which builds an artifact, read from the <scm> of its snapshot
    POM or of the parents in the same repository. None if that cannot be found."""
    for _ in range(5):
        directory = f"{SNAPSHOTS}/{group.replace('.', '/')}/{artifact}/{snapshot}"
        metadata = request(f"{directory}/maven-metadata.xml", "GET", tolerant=True)
        if metadata is None:
            return None
        values = re.findall(
            rb"<extension>pom</extension>\s*<value>([^<]+)</value>", metadata)
        if not values:
            return None
        pom = request(f"{directory}/{artifact}-{values[0].decode()}.pom", "GET", tolerant=True)
        if pom is None:
            return None
        found = re.search(rb"github\.com[/:]([\w.-]+/[\w.-]+?)(?:\.git)?[/<]", pom.split(b"<scm>", 1)[-1]) \
            if b"<scm>" in pom else None
        if found:
            return found.group(1).decode()
        parent = re.search(rb"<parent>(.*?)</parent>", pom, re.S)
        if not parent:
            return None
        coordinates = {k.decode(): v.decode() for k, v in
                       re.findall(rb"<(groupId|artifactId|version)>\s*([^<\s]+)\s*</", parent.group(1))}
        if not coordinates.get("version", "").endswith(SUFFIX):
            return None  # release-parent, which is not where the artifact is built
        group, artifact, snapshot = coordinates["groupId"], coordinates["artifactId"], coordinates["version"]
    return None


def replace_property(content, name, old, new):
    pattern = re.compile(r"(<" + re.escape(name) + r">\s*)" + re.escape(old) + r"(\s*</" + re.escape(name) + r">)")
    return pattern.subn(lambda m: m.group(1) + new + m.group(2), content)


def replace_literal(content, group, artifact, old, new):
    """The version of each element which names the artifact, wherever groupId and version
    stand in it. Elements which nest others (plugin) are cut at the first inner element."""
    block = re.compile(
        r"<(dependency|parent|plugin|extension|path|artifactItem)>((?:(?!<(?:dependency|parent|plugin|extension|path|artifactItem|dependencies|configuration|executions)>).)*?)</\1>|"
        r"<(plugin)>((?:(?!<(?:dependencies|configuration|executions)>).)*?)<(?:dependencies|configuration|executions)>",
        re.S)
    count = 0

    def one(match):
        nonlocal count
        whole = match.group(0)
        if not re.search(r"<artifactId>\s*" + re.escape(artifact) + r"\s*</artifactId>", whole):
            return whole
        groups = [re.escape(group), r"\$\{project\.groupId\}", r"\$\{pom\.groupId\}", r"\$\{groupId\}"]
        if not re.search(r"<groupId>\s*(?:" + "|".join(groups) + r")\s*</groupId>", whole):
            return whole
        changed, n = re.subn(r"(<version>\s*)" + re.escape(old) + r"(\s*</version>)",
                             lambda m: m.group(1) + new + m.group(2), whole)
        count += n
        return changed

    return block.sub(one, content), count


def raise_versions(train):
    poms = [Pom(p) for p in pom_files()]
    properties, literals = analyse(poms)
    if not properties and not literals:
        print(f"No version of an {GROUP}* artifact from outside this repository is a SNAPSHOT.")
        return
    in_bundles = bundles() if train else {}
    source = {}

    def find(group, artifact, version):
        key = (group, artifact, version)
        if key not in source:
            slot = in_bundles.get(path_of(group, artifact, version))
            if slot:
                source[key] = f"bundle of {slot}"
            elif request(f"{CENTRAL}/{path_of(group, artifact, version)}") is not None:
                source[key] = "Maven Central"
            else:
                source[key] = None
        return source[key]

    changes = []  # (pom, kind, name, old, new, artifacts)
    seen = set()
    for pom, name, old, artifacts in properties:
        if (pom.path, name, old) not in seen:  # a property may be set in a profile again
            seen.add((pom.path, name, old))
            changes.append((pom, "property", name, old, old[:-len(SUFFIX)], artifacts))
    for pom, group, artifact, old in literals:
        if (pom.path, artifact, old) not in seen:  # one replacement changes every place in the file
            seen.add((pom.path, artifact, old))
            changes.append((pom, "version", f"{group}:{artifact}", old, old[:-len(SUFFIX)], [(group, artifact)]))

    missing = {}
    for _, _, _, old, new, artifacts in changes:
        for group, artifact in artifacts:
            if find(group, artifact, new) is None:
                missing[(group, artifact, new)] = old
    if missing:
        where = f"in the bundles of the train '{train}' or on Maven Central" if train else "on Maven Central"
        print(f"::error::{len(missing)} released versions which this release needs are not {where}:", file=sys.stderr)
        if train:
            slots = sorted(set(in_bundles.values()))
            print(f"  (bundles of the train read: {', '.join(slots) or 'none'})", file=sys.stderr)
        repositories = set()
        for (group, artifact, version), snapshot in sorted(missing.items()):
            repository = repository_of(group, artifact, snapshot)
            repositories.add(repository or f"the repository which builds {group}:{artifact}")
            print(f"  {group}:{artifact}:{version}, built by {repository or 'an unknown repository'}", file=sys.stderr)
        first = ", ".join(sorted(repositories))
        if train:
            fail(f"Release {first} in the train '{train}' before this repository, then run this release again. "
                 "Nothing was changed, tagged or pushed.")
        fail(f"Release {first} first and wait until Maven Central has it, or release both in one train. "
             "Nothing was changed, tagged or pushed.")

    edits = {}
    for pom, kind, name, old, new, artifacts in changes:
        if pom.path not in edits:
            with open(pom.path, encoding="utf-8") as f:
                edits[pom.path] = f.read()
        if kind == "property":
            edits[pom.path], n = replace_property(edits[pom.path], name, old, new)
        else:
            edits[pom.path], n = replace_literal(edits[pom.path], *name.split(":"), old, new)
        if n == 0:
            fail(f"Cannot find the {kind} {name} = {old} in {pom.path} to change it")
    for path, content in edits.items():
        with open(path, "w", encoding="utf-8") as f:
            f.write(content)

    left_properties, left_literals = analyse([Pom(p) for p in pom_files()])
    if left_properties or left_literals:
        for pom, name, value, _ in left_properties:
            print(f"  {pom.path}: property {name} = {value}", file=sys.stderr)
        for pom, group, artifact, value in left_literals:
            print(f"  {pom.path}: {group}:{artifact} = {value}", file=sys.stderr)
        fail("Some SNAPSHOT versions could not be changed, see above")

    lines = []
    for pom, kind, name, old, new, artifacts in changes:
        froms = sorted({source[(g, a, new)] for g, a in artifacts})
        lines.append(f"- {pom.path}: {kind} {name} {old} -> {new} ({', '.join(froms)})")
    report = "Released versions of VanillaBP dependencies:\n" + "\n".join(lines) + "\n"
    print(report, end="")
    with open(os.path.join(TEMP, "raised-versions.txt"), "w", encoding="utf-8") as f:
        f.write(report)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as f:
            f.write("## " + report.replace(":\n", "\n\n", 1) + "\n")


def unpublished(versions):
    own = sorted({(p.group, p.artifact) for p in (Pom(p) for p in pom_files())})
    found = []
    for version in versions:
        for group, artifact in own:
            if request(f"{CENTRAL}/{path_of(group, artifact, version)}") is not None:
                found.append(f"{group}:{artifact}:{version}")
    if found:
        fail("Maven Central has this version already, and a version there never changes. "
             "Release a new version. Found: " + ", ".join(found))
    print(f"Maven Central has no artifact of this repository in version {', '.join(versions)}.")


def published_poms(directory):
    found = []
    for folder, _, files in os.walk(directory):
        found += [os.path.join(folder, name) for name in files if name.endswith(".pom")]
    return sorted(found)


def properties_of_own_version(pom):
    """Names of the properties which decide the version of this POM, as ${revision} does."""
    names = set()
    for child in pom.root:
        if local(child.tag) == "version":
            names.update(PROPERTY_ONLY.findall(text(child)))
        elif local(child.tag) == "parent":
            for inner in child:
                if local(inner.tag) == "version":
                    names.update(PROPERTY_ONLY.findall(text(inner)))
    return names


def leaves(element):
    """(leaf element, name of its parent) of everything below the element."""
    for child in element:
        if not isinstance(child.tag, str):
            continue
        if len(child):
            yield from leaves(child)
        else:
            yield child, local(element.tag)


def no_snapshots(directory):
    poms = [Pom(p) for p in (published_poms(directory) if directory else pom_files())]
    read_properties = set()
    own_version = set()
    for pom in poms:
        own_version |= properties_of_own_version(pom)
        for leaf, _ in leaves(pom.root):
            read_properties.update(PROPERTY_ONLY.findall(text(leaf)))
    users = {}  # property -> artifacts whose version it decides
    for pom in poms:
        for group, artifact, version in pom.references():
            for name in PROPERTY_ONLY.findall(version):
                users.setdefault(name, set()).add(f"{group}:{artifact}")
    found = []
    for pom in poms:
        for leaf, parent in leaves(pom.root):
            value = text(leaf)
            if not value.endswith(SUFFIX):
                continue
            name = local(leaf.tag)
            if parent == "properties":
                # nothing can depend on a property nobody reads
                if name not in read_properties:
                    continue
                # a build sets the version of the repository from outside. In a published
                # POM that has already happened, so there it would be a defect.
                if not directory and name in own_version:
                    continue
                used_by = ", ".join(sorted(users.get(name, []))) or "nothing which names a version"
                found.append(f"{pom.path}: property {name} = {value}, used by {used_by}")
            else:
                found.append(f"{pom.path}: <{name}> = {value}")
    if found:
        print(f"::error::{len(found)} SNAPSHOT versions are left, and a release must not depend on "
              "something which can still change:", file=sys.stderr)
        for line in found:
            print(f"  {line}", file=sys.stderr)
        fail("Release what these versions name, wait until Maven Central has it, and name the released "
             "version on main. Versions of io.vanillabp* are raised by 'raise' and do not end up here "
             "unless the build of this repository left one behind. " +
             ("Nothing was uploaded." if directory else "Nothing was tagged or pushed."))
    print(f"No SNAPSHOT is left in the {len(poms)} POMs of this release.")


if sys.argv[1] == "raise":
    raise_versions(sys.argv[2] if len(sys.argv) > 2 else "")
elif sys.argv[1] == "no-snapshots":
    no_snapshots(sys.argv[2] if len(sys.argv) > 2 else None)
else:
    unpublished(sys.argv[2:])
PYTHON
