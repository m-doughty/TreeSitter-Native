#| Build.rakumod for TreeSitter::Native.
#|
#| Mirrors the two-path install flow used by the other native dists in
#| this family:
#|
#|   1. Prebuilt binary download from GitHub Releases for the detected
#|      (OS, arch) pair. A couple of seconds on a decent connection, no
#|      compiler and no network round-trips to nine upstream
#|      repositories. The artefact has no dependencies beyond libc.
#|
#|   2. Fallback: compile from source. This one is heavier than most —
#|      the library is the tree-sitter runtime plus nine generated
#|      grammars, whose C sources total ~56MB and therefore cannot be
#|      vendored in the distribution tarball. So the source path first
#|      downloads nine pinned tag archives (SOURCE_PINS at the dist
#|      root), verifies each against its recorded SHA-256, extracts
#|      them into a cache, and then compiles 17 translation units and
#|      links them into one shared library. Budget one to three
#|      minutes on a cold cache; the compile itself is fast (the bulk
#|      of a generated parser.c is static tables), the download is
#|      what you wait for.
#|
#| Linux prebuilts are built on ubuntu-22.04 (glibc 2.35 — see the
#| $MIN-GLIBC constant). On systems with older glibc the prebuilt
#| .so loads but dies at first symbol use with "GLIBC_2.xx not
#| found". Build detects this via `ldd --version` and short-circuits
#| to source compile before the download.
#|
#| ---------------------------------------------------------------------
#| The include hazard
#| ---------------------------------------------------------------------
#|
#| Read this before touching the compile step. Every generated grammar
#| ships its own copy of `src/tree_sitter/parser.h`, and the copy is
#| ABI-specific: tree-sitter-cpp, -java and -typescript are generated at
#| language ABI 14, the rest at ABI 15, and the two headers describe
#| different TSLanguage layouts. Compiling the grammars in one `cc`
#| invocation with a shared `-I` list would let one grammar's parser.h
#| satisfy another grammar's include and produce a library that links
#| cleanly and then reads garbage out of a language struct at runtime.
#|
#| So: one compiler invocation per translation unit, and each gets only
#| the include directories it is entitled to.
#|
#|   runtime lib.c   -I<src>/lib/src -I<src>/lib/include
#|   ts_shim.c       -I<src>/lib/include        (public api.h only)
#|   <lang>/parser.c  no -I at all — its quoted #include "tree_sitter/
#|                    parser.h" resolves beside parser.c on gcc, clang
#|                    and MSVC alike, which is exactly the copy we want
#|   <lang>/scanner.c ditto, with one exception below
#|
#| The exception is typescript and tsx. Their scanner.c files are
#| three-line wrappers around a shared `common/scanner.h` one directory
#| up, and a quoted include resolves relative to the file doing the
#| including — so `common/scanner.h`'s own `#include "tree_sitter/
#| parser.h"` looks in `common/`, finds nothing, and falls through to
#| the (empty) -I path. Those two TUs therefore get `-I` pointing at
#| their OWN grammar's `src/` directory. That is a self-include, not a
#| cross-grammar one: each of the two still sees only its own parser.h,
#| so the hazard above is untouched.
#|
#| Env-var knobs:
#|
#|   TREESITTER_NATIVE_BUILD_FROM_SOURCE=1
#|       skip the prebuilt path, always compile.
#|   TREESITTER_NATIVE_BINARY_ONLY=1
#|       refuse to fall back to source compile.
#|   TREESITTER_NATIVE_BINARY_URL=<url>
#|       override the GitHub release base URL (mirrors,
#|       air-gapped repos).
#|   TREESITTER_NATIVE_CACHE_DIR=<path>
#|       override cache dir (default $XDG_CACHE_HOME / ~/.cache).
#|       Covers both the binary cache and the source cache.
#|   TREESITTER_NATIVE_VENDOR_DIR=<path>
#|       use a pre-staged source tree instead of downloading. See
#|       !ensure-sources for the expected layout.
#|
#| (TREESITTER_NATIVE_LIB, which points the bindings at a specific
#| already-built library, is a runtime knob read by
#| lib/TreeSitter/Native/FFI.rakumod, not a build-time one.)
#|
#| Binary artefacts are versioned independently of the Raku dist:
#| the Raku dist version moves for binding / Raku-side fixes; the
#| binary tag in BINARY_TAG only moves when the shim, the pins in
#| SOURCE_PINS, or the link recipe change. Raku bugfix releases keep
#| pointing at the same binary tag so existing caches stay valid.

class Build {

    # --- Constants ------------------------------------------------------

    constant $DEFAULT-BASE-URL =
        'https://github.com/m-doughty/TreeSitter-Native/releases/download';

    # Minimum glibc the prebuilt Linux archives are compatible with.
    # Bump in lockstep with the CI runner OS in
    # .github/workflows/build-binaries.yml.
    constant $MIN-GLIBC = v2.35;

    # Base name of the library, without the platform's lib prefix
    # conventions or extension. Kept in one place because it appears in
    # the artefact name, the staged name, the macOS install_name and the
    # stub list.
    constant $LIB-STEM = 'libtreesitter-native';

    # Map (OS, hardware) → platform slug used in both the release
    # artefact filename and the cache directory layout. Both Darwin
    # arches share the macos-universal slug: CI publishes one fat
    # dylib with arm64 + x86_64 slices, and the source path below
    # builds the same fat dylib locally.
    my %PLATFORM-SLUGS =
        'darwin-arm64'    => 'macos-universal',
        'darwin-x86_64'   => 'macos-universal',
        'linux-x86_64'    => 'linux-x86_64-glibc',
        'linux-aarch64'   => 'linux-aarch64-glibc',
        'win32-x86_64'    => 'windows-x86_64',
        'win32-aarch64'   => 'windows-arm64',
        'mswin32-x86_64'  => 'windows-x86_64',
        'mswin32-aarch64' => 'windows-arm64',
    ;

    # The nine grammars linked into the library, in the order their
    # translation units are compiled.
    #
    #   lang     — the name the shim's tsn_lang_<lang> getter uses.
    #   pin      — which SOURCE_PINS row the sources come from.
    #   dir      — subdirectory of that source tree holding src/;
    #              empty for a single-grammar repository. Only
    #              tree-sitter-typescript ships two grammars, and it
    #              keeps them in typescript/ and tsx/.
    #   scanner  — whether the grammar has a hand-written external
    #              scanner (a second TU). c, go and java don't.
    #
    # Six scanners + nine parsers + the runtime + the shim = the 17
    # translation units the compile step reports.
    my @GRAMMARS =
        %( lang => 'c',          pin => 'tree-sitter-c',          dir => '',           scanner => False ),
        %( lang => 'cpp',        pin => 'tree-sitter-cpp',        dir => '',           scanner => True  ),
        %( lang => 'python',     pin => 'tree-sitter-python',     dir => '',           scanner => True  ),
        %( lang => 'javascript', pin => 'tree-sitter-javascript', dir => '',           scanner => True  ),
        %( lang => 'typescript', pin => 'tree-sitter-typescript', dir => 'typescript', scanner => True  ),
        %( lang => 'tsx',        pin => 'tree-sitter-typescript', dir => 'tsx',        scanner => True  ),
        %( lang => 'go',         pin => 'tree-sitter-go',         dir => '',           scanner => False ),
        %( lang => 'rust',       pin => 'tree-sitter-rust',       dir => '',           scanner => True  ),
        %( lang => 'java',       pin => 'tree-sitter-java',       dir => '',           scanner => False ),
    ;

    # --- Entry point ----------------------------------------------------

    method build($dist-path) {
        my Bool $force-source = ?%*ENV<TREESITTER_NATIVE_BUILD_FROM_SOURCE>;
        my Bool $binary-only  = ?%*ENV<TREESITTER_NATIVE_BINARY_ONLY>;

        my Str $binary-tag = self!binary-tag($dist-path);
        my Str $plat = self!detect-platform;
        without $plat {
            note "⚠️  Unknown platform ({$*KERNEL.name}-{$*KERNEL.hardware}); "
                ~ "falling back to source build.";
            self!compile-from-source($dist-path);
            return True;
        }

        # Glibc guard: fall back to source compile before even attempting
        # the prebuilt download on systems older than $MIN-GLIBC, where
        # the prebuilt would load but fail at first symbol use.
        if !$force-source && $plat.ends-with('-glibc') {
            my Version $have = self!detect-glibc-version;
            if $have.defined && $have cmp $MIN-GLIBC == Less {
                if $binary-only {
                    die "TREESITTER_NATIVE_BINARY_ONLY=1 set but system glibc "
                      ~ "$have is older than prebuilt target $MIN-GLIBC "
                      ~ "($plat / $binary-tag).";
                }
                note "⚠️  System glibc $have is older than prebuilt "
                   ~ "target $MIN-GLIBC — falling back to source build "
                   ~ "to avoid runtime loader errors.";
                self!compile-from-source($dist-path);
                say "✅ Compiled TreeSitter::Native from source.";
                return True;
            }
        }

        unless $force-source {
            if self!try-prebuilt($dist-path, $plat, $binary-tag) {
                say "✅ Installed prebuilt TreeSitter::Native binary "
                   ~ "($plat) for $binary-tag.";
                return True;
            }
            if $binary-only {
                die "TREESITTER_NATIVE_BINARY_ONLY=1 set but prebuilt "
                  ~ "download failed for $plat ($binary-tag).";
            }
            note "⚠️  Prebuilt binary unavailable for $plat ($binary-tag) "
               ~ "— compiling from source.";
        }

        self!compile-from-source($dist-path);
        say "✅ Compiled TreeSitter::Native from source.";
        True;
    }

    # --- Prebuilt binary path -------------------------------------------

    #| Attempt to download, verify, and install the prebuilt artefact
    #| for $plat. Returns True on success, False on any failure — Build
    #| falls back to source compile on False (unless BINARY_ONLY is set).
    method !try-prebuilt($dist-path, Str $plat, Str $binary-tag --> Bool) {
        my Str $artifact = self!artifact-name($plat);
        my IO::Path $cache-dir = self!cache-dir($binary-tag);
        my IO::Path $cached = $cache-dir.add($artifact);
        my Str $base-url = %*ENV<TREESITTER_NATIVE_BINARY_URL>
            // $DEFAULT-BASE-URL;
        my Str $url = "$base-url/$binary-tag/$artifact";

        unless $cached.e {
            $cache-dir.mkdir;
            say "⬇️  Fetching $artifact from $url";
            # `run` with arg list avoids shell quoting entirely.
            # Essential on Windows where cmd.exe treats single quotes
            # as literals and a quoted Windows path looks like a
            # malformed URL to curl.
            my $rc = run 'curl', '-fL', '--progress-bar',
                         '-o', $cached.Str, $url;
            unless $rc.exitcode == 0 {
                $cached.unlink if $cached.e;
                return False;
            }
        }

        my Str $expected = self!expected-sha($dist-path, $artifact);
        without $expected {
            note "No checksum recorded for $artifact in resources/checksums.txt "
                ~ "— refusing prebuilt (bundled checksums are a hard security boundary).";
            return False;
        }

        my Str $actual = self!sha256($cached);
        unless $actual.defined && $actual.lc eq $expected.lc {
            note "Checksum mismatch for $artifact "
                ~ "(expected $expected, got {$actual // 'unknown'}).";
            $cached.unlink;
            return False;
        }

        self!install-artefact($cached, $dist-path, $plat);
        self!stage-stubs($dist-path);
        True;
    }

    #| Built by concatenation rather than interpolation on purpose: in a
    #| double-quoted string, `$plat.{ ... }` is an associative subscript
    #| of $plat, not an interpolated block after it, and Str doesn't do
    #| associative indexing. Concatenation says what it means.
    method !artifact-name(Str $plat --> Str) {
        $LIB-STEM ~ '-' ~ $plat ~ '.' ~ self!lib-extension($plat);
    }

    method !install-artefact(IO::Path $src, $dist-path, Str $plat) {
        my IO::Path $dest-dir = "$dist-path/resources/lib".IO;
        $dest-dir.mkdir;
        my IO::Path $dest =
            $dest-dir.add($LIB-STEM ~ '.' ~ self!lib-extension($plat));
        copy $src, $dest;
    }

    #| Shared-library extension for a platform slug. Used for both the
    #| release artefact name and the staged name, which differ only in
    #| the embedded slug.
    method !lib-extension(Str $plat --> Str) {
        $plat.starts-with('windows') ?? 'dll'
            !! $plat.starts-with('macos') ?? 'dylib'
            !! 'so';
    }

    method !cache-dir(Str $binary-tag --> IO::Path) {
        self!cache-base.add("TreeSitter-Native-binaries").add($binary-tag);
    }

    #| Root of every cache this Build touches. TREESITTER_NATIVE_CACHE_DIR
    #| overrides it wholesale (binaries and sources alike), which is what
    #| CI uses to point both at a restorable directory.
    method !cache-base(--> IO::Path) {
        my Str $base = %*ENV<TREESITTER_NATIVE_CACHE_DIR>
            // %*ENV<XDG_CACHE_HOME>
            // "{%*ENV<HOME> // '.'}/.cache";
        $base.IO;
    }

    #| Read the binary tag from the top-level BINARY_TAG file. Same
    #| file is read by .github/workflows/build-binaries.yml so there
    #| is one source of truth for which release tag this Build expects.
    method !binary-tag($dist-path --> Str) {
        my IO::Path $file = "$dist-path/BINARY_TAG".IO;
        unless $file.e {
            die "❌ Missing BINARY_TAG file at { $file }. This file must "
              ~ "contain the pinned binary release tag "
              ~ "(e.g. 'binaries-treesitter-native-0.1.0-r1') and "
              ~ "ship with the distribution.";
        }
        my Str $tag = $file.slurp.trim;
        die "❌ BINARY_TAG file is empty." unless $tag.chars;
        $tag;
    }

    method !expected-sha($dist-path, Str $artifact --> Str) {
        my IO::Path $file = "$dist-path/resources/checksums.txt".IO;
        return Str unless $file.e;
        for $file.slurp.lines -> Str $line {
            my Str $trimmed = $line.trim;
            next if $trimmed eq '' || $trimmed.starts-with('#');
            my @parts = $trimmed.words;
            next unless @parts.elems >= 2;
            return @parts[0] if @parts[1] eq $artifact;
        }
        Str;
    }

    #| Compute a file's SHA-256 hex digest, shelling out to whatever
    #| the platform actually ships. On POSIX this is a fallback chain,
    #| not a single tool — the platform matrix is:
    #|
    #|   Linux (incl. minimal containers: manylinux, EL, Alpine)
    #|     → `sha256sum` only (GNU/BusyBox coreutils; no `shasum`
    #|       binary on a stock manylinux_2_28 image).
    #|   macOS / BSD
    #|     → `shasum -a 256` only (Perl tool from the base install;
    #|       no `sha256sum` unless coreutils was brew-installed).
    #|
    #| `sha256sum` is tried first since it's the more common case in
    #| CI (Linux runners/containers); a tool that's missing, un-
    #| spawnable, exits non-zero, or produces no recognizable digest
    #| falls through to the next rather than aborting the chain. Both
    #| exhausted → Str (undefined). Every caller treats that as
    #| "unverifiable" and refuses the bytes, which is the correct
    #| fail-closed behaviour for both the prebuilt artefact and a
    #| source tarball.
    #|
    #| The digest is parsed as the first 64-char lowercase-hex run in
    #| the first output line, rather than assuming a fixed column
    #| layout — GNU coreutils prefixes a bare `\` fused to the hex
    #| when the input path contains a backslash (irrelevant on POSIX
    #| paths, but harmless to tolerate rather than choke on).
    method !sha256(IO::Path $file --> Str) {
        if $*DISTRO.is-win {
            my $proc = run 'certutil', '-hashfile', $file.Str, 'SHA256',
                           :out, :err;
            my $out = $proc.out.slurp(:close);
            $proc.err.slurp(:close);
            # certutil output: header line, hex digest (one line per
            # locale — sometimes space-separated bytes "AB CD EF…"
            # on older Windows, no spaces on Win10+), trailer line.
            for $out.lines -> Str $line {
                my Str $t = $line.subst(/\s+/, '', :g).lc;
                return $t if $t.chars == 64 && $t ~~ /^ <[0..9a..f]>+ $/;
            }
            return Str;
        }

        for ('sha256sum', $file.Str), ('shasum', '-a', '256', $file.Str)
            -> @cmd
        {
            my $proc = try run |@cmd, :out, :err;
            next without $proc;
            my Str $out = $proc.out.slurp(:close);
            $proc.err.slurp(:close);
            next unless $proc.exitcode == 0;
            my Str $first = $out.lines.head // '';
            if $first ~~ / (<[0..9a..f]> ** 64) / {
                return ~$0;
            }
        }
        Str;
    }

    # --- Source pins ----------------------------------------------------

    #| Parse SOURCE_PINS at the dist root. Returns an ordered list of
    #| Maps with `name`, `tag`, `sha256` and `url`. Lines starting with
    #| `#` and blank lines are ignored; every other line must have
    #| exactly four whitespace-separated columns. Dies on a missing
    #| file, a malformed row, a digest that isn't 64 hex characters, or
    #| a duplicate name — all of which would otherwise surface much
    #| later as a confusing compile error.
    method !source-pins($dist-path --> Array) {
        my IO::Path $file = "$dist-path/SOURCE_PINS".IO;
        unless $file.e {
            die "❌ Missing SOURCE_PINS file at { $file }. This file must "
              ~ "list the upstream tarballs (name, tag, sha256, url) the "
              ~ "source build compiles, and ship with the distribution.";
        }

        my @pins;
        my %seen;
        for $file.slurp.lines -> Str $line {
            my Str $trimmed = $line.trim;
            next if $trimmed eq '' || $trimmed.starts-with('#');
            my @parts = $trimmed.words;
            unless @parts.elems == 4 {
                die "❌ Malformed line in SOURCE_PINS: '$line' "
                  ~ "(expected `<name> <tag> <sha256> <url>`, got "
                  ~ "{ @parts.elems } columns).";
            }
            my (Str $name, Str $tag, Str $sha, Str $url) = @parts;
            unless $sha ~~ /^ <[0..9a..f]> ** 64 $/ {
                die "❌ SOURCE_PINS row '$name' has a sha256 column that "
                  ~ "is not 64 lowercase hex characters: '$sha'.";
            }
            unless $url.starts-with('http://') || $url.starts-with('https://') {
                die "❌ SOURCE_PINS row '$name' has a url column that is "
                  ~ "not an http(s) URL: '$url'.";
            }
            if %seen{$name}:exists {
                die "❌ SOURCE_PINS lists '$name' twice; names double as "
                  ~ "cache directory stems and must be unique.";
            }
            %seen{$name} = True;
            @pins.push: %( :$name, :$tag, sha256 => $sha, :$url ).Map;
        }

        die "❌ SOURCE_PINS contains no pins." unless @pins.elems;

        # Every grammar in @GRAMMARS must have somewhere to come from,
        # and so must the runtime. Checking here turns a typo into one
        # clear message instead of nine confusing ones.
        for ('tree-sitter', |@GRAMMARS.map(*<pin>)).unique -> Str $needed {
            unless %seen{$needed}:exists {
                die "❌ SOURCE_PINS has no row named '$needed', which the "
                  ~ "build requires.";
            }
        }

        @pins;
    }

    #| Resolve every pinned upstream to an on-disk source tree. Returns
    #| a Hash of pin name → IO::Path of that tree's root. Two paths:
    #|
    #|   1. TREESITTER_NATIVE_VENDOR_DIR=<path> — use pre-staged trees,
    #|      no download, no SHA check. The directory must be laid out
    #|      exactly like the cache: one `<name>-<tag>/` subdirectory per
    #|      SOURCE_PINS row, each holding that upstream's repository
    #|      root (so e.g. `tree-sitter-c-v0.24.2/src/parser.c` exists).
    #|      This is the airgapped-install path and the escape hatch for
    #|      the day GitHub re-archives a tag and the digests stop
    #|      matching. Caller owns the contents; we still sanity-check
    #|      that the files we're about to compile are there.
    #|
    #|   2. (default) download each tag archive, verify its SHA-256
    #|      against SOURCE_PINS, and extract it into
    #|      `<cache>/TreeSitter-Native-source/<name>-<tag>/`. Cached per
    #|      name+tag, so bumping a pin invalidates only that entry.
    method !ensure-sources($dist-path --> Hash) {
        my @pins = self!source-pins($dist-path);

        with %*ENV<TREESITTER_NATIVE_VENDOR_DIR> -> Str $local {
            my IO::Path $root = $local.IO;
            unless $root.d {
                die "❌ TREESITTER_NATIVE_VENDOR_DIR=$local is not a "
                  ~ "directory.";
            }
            say "Using TREESITTER_NATIVE_VENDOR_DIR=$local as source root.";
            my %trees;
            for @pins -> %pin {
                my IO::Path $tree = $root.add("%pin<name>-%pin<tag>");
                unless $tree.d {
                    die "❌ TREESITTER_NATIVE_VENDOR_DIR=$local has no "
                      ~ "'%pin<name>-%pin<tag>' subdirectory. Every "
                      ~ "SOURCE_PINS row needs one.";
                }
                self!verify-source-tree(%pin<name>, $tree);
                %trees{%pin<name>} = $tree;
            }
            return %trees;
        }

        self!check-fetch-tools;

        my IO::Path $src-base =
            self!cache-base.add('TreeSitter-Native-source');
        $src-base.mkdir;

        my %trees;
        for @pins -> %pin {
            %trees{%pin<name>} = self!ensure-one-source($src-base, %pin);
        }
        %trees;
    }

    #| The argv prefix for a tar that can cope with the paths we hand
    #| it. Unix is just `tar`; Windows is where this earns its keep.
    #|
    #| GNU tar reads an argument like `D:/a/_temp/ts-native-cache/x.tar.gz`
    #| as a REMOTE archive spec — `host:path` — and tries to rsh to a
    #| machine called `D`, dying with "Cannot connect to D: resolve
    #| failed" before it reads a byte. Every absolute path on Windows
    #| starts with a drive letter, so this is not an edge case: on a
    #| GitHub Windows runner bare `tar` resolves to Git Bash's GNU tar
    #| and extraction fails 100% of the time.
    #|
    #| So on Windows, prefer the bsdtar that ships in
    #| %SystemRoot%\System32 on every Windows 10 1803+ — by ABSOLUTE
    #| path, so PATH order can't put GNU tar back in front of it. It
    #| understands drive letters natively and supports both -xzf and
    #| --strip-components (it is the same libarchive tar macOS uses,
    #| where this exact argv has always worked).
    #|
    #| Only if that binary is absent do we fall back to whatever `tar`
    #| is on PATH with `--force-local` prepended — GNU tar's escape
    #| hatch meaning "that colon is a drive letter, not a host". The
    #| ladder is this way round and not the other because bsdtar
    #| REJECTS --force-local, so the flag is usable only on the
    #| fallback leg, while System32 bsdtar is deterministic on any
    #| supported Windows.
    method !tar-argv(--> List) {
        return ('tar',) unless $*DISTRO.is-win;

        # %*ENV lookups are case-sensitive and Windows' own spelling of
        # this one varies by how the process was launched, so try each
        # before falling back to the documented default location.
        my Str $root = %*ENV<SystemRoot> // %*ENV<SYSTEMROOT>
                    // %*ENV<systemroot> // 'C:\\Windows';
        my IO::Path $bsdtar = $root.IO.add('System32').add('tar.exe');
        return ($bsdtar.absolute,) if $bsdtar.f;

        ('tar', '--force-local');
    }

    #| curl and tar have to exist before the first download, not after
    #| it. Both ship with Windows 10 1803+ (bsdtar) and with every Unix
    #| we target, but minimal containers do sometimes omit them, and the
    #| failure they produce otherwise — a zero-byte tarball, or an
    #| extraction that silently yields nothing — is much harder to read
    #| than this. Only called on the download path: a
    #| TREESITTER_NATIVE_VENDOR_DIR install is expected to work on a
    #| machine that has neither.
    method !check-fetch-tools() {
        # Probe the tar we will actually invoke, not a bare `tar` that
        # may be a different binary from the one !ensure-one-source
        # picks — see !tar-argv.
        self!check-fetch-tool('curl', ('curl', '--version'));
        self!check-fetch-tool('tar',  (|self!tar-argv, '--version'));
    }

    method !check-fetch-tool(Str $name, @argv) {
        my $proc = try run |@argv, :out, :err;
        my Bool $ok = False;
        with $proc {
            .out.slurp(:close);
            .err.slurp(:close);
            $ok = .exitcode == 0;
        }
        unless $ok {
            die "❌ `$name` is required for the source build (it "
              ~ "downloads and unpacks the pinned tree-sitter "
              ~ "sources) but could not be run as "
              ~ "`{ @argv.join(' ') }`. Install it, or set "
              ~ "TREESITTER_NATIVE_VENDOR_DIR to a directory of "
              ~ "pre-staged source trees.";
        }
    }

    #| Fetch, verify and extract one pinned tarball, or reuse the
    #| already-extracted tree. Returns the tree root.
    method !ensure-one-source(IO::Path $src-base, %pin --> IO::Path) {
        my Str $stem = "%pin<name>-%pin<tag>";
        my IO::Path $tree = $src-base.add($stem);

        # Fast path: a previous install already extracted this exact
        # name+tag. The tree is content-addressed by the pin, so there
        # is nothing to re-verify — but do confirm the files we're
        # about to compile are present, which catches a half-extracted
        # tree left behind by an interrupted install.
        if $tree.d && self!source-tree-ok(%pin<name>, $tree) {
            say "  Reusing cached %pin<name> %pin<tag>.";
            return $tree;
        }
        if $tree.e {
            note "⚠️  Cached source at $tree is incomplete; re-extracting.";
            self!rm-rf($tree);
        }

        my IO::Path $tarball = $src-base.add("$stem.tar.gz");

        # A cached tarball is re-hashed rather than trusted: it may be a
        # truncated download from an install that was killed mid-fetch,
        # or (the case this really guards) a tarball whose pin was
        # updated without the cache being cleared. A mismatch is not
        # fatal here — we throw the bytes away and fetch again, and only
        # a second mismatch, on freshly downloaded bytes, aborts the
        # build.
        if $tarball.e {
            my Str $have = self!sha256($tarball);
            unless $have.defined && $have.lc eq %pin<sha256>.lc {
                note "⚠️  Cached tarball $stem.tar.gz has digest "
                   ~ "{ $have // 'unknown' }, expected %pin<sha256> "
                   ~ "— discarding and re-fetching.";
                $tarball.unlink;
            }
        }

        unless $tarball.e {
            say "⬇️  Fetching %pin<name> %pin<tag> from %pin<url>";
            my $rc = run 'curl', '-fL', '--progress-bar',
                         '-o', $tarball.Str, %pin<url>;
            unless $rc.exitcode == 0 {
                $tarball.unlink if $tarball.e;
                die "❌ Failed to download %pin<name> %pin<tag> from "
                  ~ "%pin<url>.\n"
                  ~ "If you're offline or behind a firewall that blocks "
                  ~ "github.com, set TREESITTER_NATIVE_VENDOR_DIR to a "
                  ~ "directory holding pre-staged '$stem' source trees "
                  ~ "(see docs/Readme.rakudoc), or install a prebuilt "
                  ~ "binary release instead.";
            }
        }

        my Str $actual = self!sha256($tarball);
        unless $actual.defined && $actual.lc eq %pin<sha256>.lc {
            $tarball.unlink;
            die "❌ SHA-256 mismatch for %pin<name> %pin<tag>.\n"
              ~ "    expected %pin<sha256>\n"
              ~ "    got      { $actual // 'unknown (no working sha256 tool)' }\n"
              ~ "Refusing to compile unverified source. GitHub tag "
              ~ "archives are not guaranteed byte-stable across "
              ~ "archiver upgrades, so if this persists the pin needs "
              ~ "refreshing in SOURCE_PINS (see the notes in that "
              ~ "file); TREESITTER_NATIVE_VENDOR_DIR bypasses the "
              ~ "download entirely in the meantime.";
        }

        # Extract with --strip-components=1: the archive's single top
        # level is `<repo>-<version-without-v>/`, which is close to but
        # not the same as our `<name>-<tag>` stem, and we'd rather own
        # the directory name than parse GitHub's.
        $tree.mkdir;
        say "  Extracting $stem…";
        # NOT a bare `tar`: on Windows that is Git Bash's GNU tar, which
        # would read the drive letter in $tarball as a remote host. See
        # !tar-argv.
        my @tar = self!tar-argv;
        my $tar = run |@tar, '-xzf', $tarball.Str,
                      '--strip-components=1', '-C', $tree.Str, :err;
        my Str $tar-err = $tar.err.slurp(:close);
        unless $tar.exitcode == 0 {
            self!rm-rf($tree);
            die "❌ Failed to extract $stem.tar.gz using "
              ~ "`{ @tar.join(' ') }`:\n$tar-err";
        }

        self!verify-source-tree(%pin<name>, $tree);
        $tree;
    }

    #| The files each pin has to provide for the compile step to work.
    #| Deliberately narrow: these are exactly the paths
    #| !translation-units will hand to the compiler, so a tarball whose
    #| internal layout moved upstream fails here with a clear message
    #| rather than as a "no such file" from cc.
    method !expected-source-files(Str $name --> Array) {
        if $name eq 'tree-sitter' {
            return ['lib/src/lib.c', 'lib/include/tree_sitter/api.h'];
        }
        my @files;
        for @GRAMMARS.grep(*<pin> eq $name) -> %g {
            my Str $prefix = %g<dir> eq '' ?? 'src' !! "%g<dir>/src";
            @files.push: "$prefix/parser.c";
            @files.push: "$prefix/tree_sitter/parser.h";
            @files.push: "$prefix/scanner.c" if %g<scanner>;
        }
        # tree-sitter-typescript's two scanners are three-line wrappers
        # around this shared header; losing it in extraction is the one
        # failure mode that would otherwise show up as a confusing
        # include error deep in the compile.
        @files.push: 'common/scanner.h' if $name eq 'tree-sitter-typescript';
        @files;
    }

    method !source-tree-ok(Str $name, IO::Path $tree --> Bool) {
        my @missing = self!expected-source-files($name)
                          .grep({ !$tree.add($_).e });
        !@missing.elems;
    }

    method !verify-source-tree(Str $name, IO::Path $tree) {
        my @missing = self!expected-source-files($name)
                          .grep({ !$tree.add($_).e });
        return unless @missing;
        die "❌ Source tree for '$name' at $tree is missing "
          ~ "{ @missing.elems } expected file(s): { @missing.join(', ') }. "
          ~ "The upstream layout may have changed, or the tree was "
          ~ "staged by hand and is incomplete.";
    }

    #| Recursive delete that works on both sides of the platform split.
    #| IO::Path.rmdir refuses non-empty directories and Raku has no
    #| built-in recursive remove, so shell out — `rm -rf` on POSIX,
    #| `rd /s /q` on Windows (via cmd, since rd is a shell builtin).
    method !rm-rf(IO::Path $path) {
        return unless $path.e;
        if $*DISTRO.is-win {
            if $path.d {
                run 'cmd', '/c', 'rd', '/s', '/q', $path.absolute;
            }
            else {
                $path.unlink;
            }
        }
        else {
            run 'rm', '-rf', $path.absolute;
        }
    }

    # --- Source compile path --------------------------------------------

    #| Every translation unit in the library, in compile order. Each is
    #| a Map of:
    #|
    #|   name     — object file stem; must be unique across the list
    #|   src      — absolute path to the .c file
    #|   includes — the ONLY -I directories this TU gets (see the
    #|              include hazard in this file's header comment)
    #|   warn     — enable -Wall -Wextra. True only for our own shim:
    #|              the generated parsers and the vendored runtime are
    #|              not ours to keep warning-clean, and drowning a
    #|              user's install log in upstream warnings hides the
    #|              ones that matter.
    method !translation-units($dist-path, %trees --> Array) {
        my IO::Path $runtime = %trees<tree-sitter>;
        my @tus;

        # The runtime is an amalgamation: lib/src/lib.c is a stub that
        # #includes the other thirteen .c files, so this single TU is
        # the whole of tree-sitter.
        @tus.push: %(
            name     => 'runtime-lib',
            src      => $runtime.add('lib/src/lib.c').absolute,
            includes => [ $runtime.add('lib/src').absolute,
                          $runtime.add('lib/include').absolute ],
            warn     => False,
        ).Map;

        for @GRAMMARS -> %g {
            my IO::Path $root = %trees{%g<pin>};
            my IO::Path $src  = %g<dir> eq ''
                ?? $root.add('src')
                !! $root.add(%g<dir>).add('src');

            @tus.push: %(
                name     => "%g<lang>-parser",
                src      => $src.add('parser.c').absolute,
                includes => [],
                warn     => False,
            ).Map;

            next unless %g<scanner>;

            # The self-include exception: only the two grammars whose
            # scanner.c delegates to a shared header outside its own
            # directory need one, and they need their OWN src/ — never
            # another grammar's.
            my @inc = %g<dir> eq '' ?? [] !! [ $src.absolute ];
            @tus.push: %(
                name     => "%g<lang>-scanner",
                src      => $src.add('scanner.c').absolute,
                includes => @inc,
                warn     => False,
            ).Map;
        }

        # The shim sees the public api.h and nothing else — no grammar
        # headers, no runtime internals.
        @tus.push: %(
            name     => 'ts-shim',
            src      => "$dist-path/src/ts_shim.c".IO.absolute,
            includes => [ $runtime.add('lib/include').absolute ],
            warn     => True,
        ).Map;

        @tus;
    }

    #| Fetch the pinned sources, compile all 17 translation units, and
    #| link them into resources/lib/libtreesitter-native.<ext>.
    #|
    #| Object files land in build/obj/ under the dist root (gitignored)
    #| rather than beside the sources: the source cache is shared
    #| between installs and may be read-only, and keeping objects with
    #| the dist means a failed link leaves everything needed to retry
    #| in one place.
    method !compile-from-source($dist-path) {
        self!check-toolchain;

        my %trees = self!ensure-sources($dist-path);
        my @tus   = self!translation-units($dist-path, %trees);

        my Str $os = $*KERNEL.name.lc;
        my Bool $darwin = so $os ~~ /darwin/;
        my Bool $win    = so $*DISTRO.is-win;

        my IO::Path $objdir = "$dist-path/build/obj".IO;
        $objdir.mkdir;
        my Str $objext = $win ?? 'obj' !! 'o';

        my @objects;
        my Int $n = @tus.elems;
        for @tus.kv -> $i, %tu {
            my IO::Path $obj = $objdir.add("%tu<name>.$objext");
            @objects.push: $obj.absolute;

            my @cmd;
            if $win {
                # /bigobj is not optional: the larger generated
                # parser.c files (tree-sitter-cpp is 17MB) blow past
                # the default 65,536-section limit and fail with C1128.
                # /utf-8 pins the source charset, because several
                # grammars carry non-ASCII bytes in string literals and
                # MSVC would otherwise decode them in the machine's
                # ANSI codepage.
                @cmd = 'cl', '/nologo', '/O2', '/bigobj', '/utf-8', '/c';
                @cmd.append: %tu<includes>.map({ "/I$_" });
                @cmd.append: %tu<src>, "/Fo:{ $obj.absolute }";
            }
            else {
                # -D_DEFAULT_SOURCE is load-bearing on glibc. The
                # runtime's lib/src/unicode.h expands le16toh() inside
                # U16_NEXT_LE (via lib/src/portable/endian.h, which is
                # just #include <endian.h> on Linux), and glibc gates
                # le16toh and friends behind __USE_MISC — which
                # -std=c11 switches OFF by defining __STRICT_ANSI__.
                # The macro then never exists, le16toh becomes an
                # implicit function declaration, and because a shared
                # link tolerates undefined symbols by default the .so
                # builds clean and explodes at the FIRST dlopen with
                # "undefined symbol: le16toh". Upstream sidesteps this
                # by building gnu11; we ask for exactly the one feature
                # set we need instead, keeping strict ISO C11 for our
                # own code. Inert on macOS (Apple's OSSwap* branch) and
                # never reached on MSVC, and applied to every TU rather
                # than just the runtime because the external scanners
                # include the same runtime headers.
                @cmd = 'cc', '-O2', '-fPIC', '-std=c11', '-D_DEFAULT_SOURCE';
                # A universal binary built the same way CI builds it,
                # so the source path and the prebuilt path produce
                # interchangeable artefacts. clang compiles each arch
                # and lipos the results into one fat object file.
                @cmd.append: '-arch', 'arm64', '-arch', 'x86_64' if $darwin;
                @cmd.append: '-Wall', '-Wextra' if %tu<warn>;
                @cmd.append: %tu<includes>.map({ "-I$_" });
                @cmd.append: '-c', %tu<src>, '-o', $obj.absolute;
            }

            say "  [{ $i + 1 }/$n] { %tu<name> }";
            my $rc = run |@cmd;
            unless $rc.exitcode == 0 {
                die "❌ Failed compiling { %tu<name> } "
                  ~ "({ %tu<src> }).\n"
                  ~ "    { @cmd.join(' ') }";
            }
        }

        my IO::Path $outdir = "$dist-path/resources/lib".IO;
        $outdir.mkdir;
        my Str $ext = $darwin ?? 'dylib' !! $win ?? 'dll' !! 'so';
        my IO::Path $out = $outdir.add("$LIB-STEM.$ext");

        my @link;
        my @strip;
        if $win {
            # src/exports.def is the authoritative export list; without
            # it the DLL would export only what __declspec(dllexport)
            # marked, which is the same set, but the .def is what keeps
            # the two in provable agreement.
            #
            # cl-as-linker-driver, NOT a bare `link`: on a Git Bash
            # runner `link` resolves to GNU coreutils' link(1) (the
            # hard-link utility), which greets /DEF:… with "extra
            # operand". `cl` survives the same PATH because nothing else
            # is called cl — and cl invokes its OWN sibling link.exe,
            # located next to itself rather than searched for on PATH,
            # so this is immune by construction. Same shadowing class as
            # the GNU-tar trap in !tar-argv; don't "simplify" it back.
            #
            # /LD makes it a DLL (cl passes /DLL on for us). Everything
            # after /link goes to the linker verbatim, so /link MUST be
            # last, with only linker options behind it.
            @link = 'cl', '/nologo', '/LD', |@objects,
                    "/Fe:{ $out.absolute }",
                    '/link',
                    "/DEF:{ "$dist-path/src/exports.def".IO.absolute }";
            # MSVC Release doesn't embed a PDB by default; nothing to strip.
        }
        elsif $darwin {
            # `-install_name @rpath/…` keeps the dylib relocatable after
            # it's copied into resources/lib/ and again when the whole
            # dist is installed into the Raku repository.
            @link = 'cc', '-dynamiclib',
                    '-arch', 'arm64', '-arch', 'x86_64',
                    '-install_name', "\@rpath/$LIB-STEM.dylib",
                    '-o', $out.absolute, |@objects;
            @strip = 'strip', '-x', $out.absolute;
        }
        else {
            # -lm -lpthread -ldl mirrors upstream's own CMake link
            # interface for non-Apple Unix.
            #
            # -Wl,--no-undefined turns "this .so references a symbol
            # nothing provides" from an install-time dlopen failure
            # into a build failure here, where the log says which
            # symbol and which object. ELF shared links allow undefined
            # symbols by default, which is how a missing le16toh once
            # linked cleanly and only died when zef staged the library;
            # macOS has no such hole (-dynamiclib errors on undefined
            # symbols unless told otherwise), so this restores the same
            # guarantee on Linux. The library is self-contained apart
            # from libc, so nothing legitimately resolves late.
            @link = 'cc', '-shared', '-Wl,--no-undefined',
                    '-o', $out.absolute, |@objects,
                    '-lm', '-lpthread', '-ldl';
            @strip = 'strip', '--strip-unneeded', $out.absolute;
        }

        say "  Linking { $out.basename } from { @objects.elems } objects…";
        my $rc = run |@link;
        unless $rc.exitcode == 0 {
            die "❌ Failed linking { $out.basename }.\n"
              ~ "    { @link.join(' ') }";
        }

        # Non-fatal: strip failing just leaves a slightly larger lib.
        run |@strip if @strip;

        self!stage-stubs($dist-path);
    }

    #| Assert a usable C compiler exists before starting a source
    #| build, and say something actionable when there isn't one.
    #|
    #| The probe spawns the compiler DIRECTLY — never via shell(). A CI
    #| runner that reaches Raku through bash and GITHUB_ENV can arrive
    #| with no ComSpec in %*ENV, and then shell() fails to start the
    #| *interpreter*, which is indistinguishable from "no compiler
    #| installed" unless you look closely (the symptom is a Proc that
    #| was never spawned, which warns about uninitialized $!path/@!args
    #| the moment anything touches it). run() needs no interpreter, so
    #| the only thing left that can fail is the compiler itself.
    method !check-toolchain() {
        my Bool $win = so $*DISTRO.is-win;

        # Bare `cl` prints its usage banner and exits non-zero, so on
        # MSVC a successful SPAWN is the signal, not the exit code.
        # `cc --version` is expected to exit 0.
        my @probe = $win ?? ('cl',) !! ('cc', '--version');

        my Str $thrown;
        my $proc = try run |@probe, :out, :err;
        $thrown = .message with $!;

        # Drain both pipes before looking at .exitcode: an undrained
        # child can block writing and never be reaped.
        my Str $out = '';
        my Str $err = '';
        with $proc {
            $out = .out.slurp(:close) // '';
            $err = .err.slurp(:close) // '';
        }

        # MoarVM reports a spawn that never happened as exitcode -1
        # rather than throwing when :out/:err are in play, so ">= 0"
        # is what "a real process ran and exited" looks like.
        my Bool $spawned = $proc.defined && $proc.exitcode >= 0;
        my Bool $found   = $spawned && ($win || $proc.exitcode == 0);
        return if $found;

        my Str $detail = ($err.lines.grep(*.trim).head
                          // $out.lines.grep(*.trim).head) // '';
        my Str $why =
            $thrown.defined ?? "spawn threw: $thrown"
            !! $spawned     ?? "{@probe[0]} ran but exited { $proc.exitcode }"
                                 ~ ($detail ?? " — $detail" !! '')
            !!                 "{@probe[0]} could not be spawned"
                                 ~ " (no process started"
                                 ~ ($proc.defined
                                     ?? ", exitcode { $proc.exitcode })"
                                     !! ')');

        # Windows spells it `Path` and %*ENV lookups are case-sensitive,
        # so try every spelling before reporting an empty search path.
        my Str $raw = %*ENV<PATH> // %*ENV<Path> // %*ENV<path> // '';
        my @head    = $raw.split($win ?? ';' !! ':', :skip-empty).head(4);
        my Str $path-note = @head ?? @head.join('  ') !! '(empty or unset)';

        die qq:to/ERR/;
            ❌ No C compiler found.
                probe:   { @probe.join(' ') }
                why:     $why
                path[4]: $path-note
            Install one of:
                macOS:         xcode-select --install
                Debian/Ubuntu: sudo apt install build-essential
                Fedora:        sudo dnf install gcc
                Arch:          sudo pacman -S base-devel
                openSUSE:      sudo zypper in gcc
                Windows:       install Visual Studio Build Tools (MSVC),
                               then build from a Developer Command
                               Prompt so cl.exe is on Path (Windows
                               spells it `Path`, and %*ENV lookups in
                               Raku are case-sensitive).
            ERR
    }

    # --- Shared helpers -------------------------------------------------

    method !detect-platform(--> Str) {
        my Str $key = "{$*KERNEL.name.lc}-{$*KERNEL.hardware.lc}";
        %PLATFORM-SLUGS{$key};
    }

    #| Parse `ldd --version` for the system's glibc version. Returns a
    #| Version on glibc systems, Nil on musl (ldd --version exits
    #| non-zero) or when ldd is absent / unparseable. Only meaningful
    #| on Linux.
    method !detect-glibc-version(--> Version) {
        my $proc = try { run 'ldd', '--version', :out, :err };
        return Version without $proc;
        my $out = $proc.out.slurp(:close);
        $proc.err.slurp(:close);
        return Version unless $proc.exitcode == 0;
        my $first = $out.lines.head // '';
        if $first ~~ / (\d+ '.' \d+ [ '.' \d+ ]?) \s* $ / {
            return Version.new(~$0);
        }
        Version;
    }

    #| Create empty placeholder files for the two platform-specific
    #| library names we're NOT on, so META6.json's `resources` list
    #| stays satisfiable on every platform.
    method !stage-stubs($dist-path) {
        for "$LIB-STEM.dylib", "$LIB-STEM.so", "$LIB-STEM.dll" -> Str $name {
            my Str $path = "$dist-path/resources/lib/$name";
            $path.IO.spurt('') unless $path.IO.f;
        }
    }
}
