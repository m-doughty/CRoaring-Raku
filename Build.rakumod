#| Build.rakumod for CRoaring.
#|
#| Two paths, tried in order:
#|
#|   1. Prebuilt binary download from GitHub Releases for the detected
#|      (OS, arch) pair. ~2–5 seconds on a decent connection, no compiler
#|      needed. Artefacts are stripped static libraries that don't
#|      depend on anything beyond libc.
#|
#|   2. Fallback: compile the vendored CRoaring amalgamation from source
#|      with `cc` (or `cl` on Windows/MSVC). Takes ~20–30 seconds, needs
#|      a C toolchain but no other system deps — CRoaring has zero
#|      transitive deps beyond libc.
#|
#| Env-var knobs:
#|
#|   CROARING_BUILD_FROM_SOURCE=1   skip the prebuilt path, always compile
#|   CROARING_BINARY_ONLY=1         refuse to fall back to compile
#|   CROARING_BINARY_URL=<url>      override the GH release base URL
#|                                  (mirrors, air-gapped repos)
#|   CROARING_CACHE_DIR=<path>      override cache dir
#|                                  (default $XDG_CACHE_HOME / ~/.cache)
#|
#| Binary artefacts are versioned independently of the Raku dist: the
#| Raku dist version moves for binding / Raku-side fixes; the
#| $BINARY-TAG below only moves when the vendored CRoaring version or
#| the static-link recipe changes. Raku bugfix releases keep pointing
#| at the same binary tag so existing caches stay valid.

class Build {

    # --- Constants ------------------------------------------------------

    # The binary tag lives in a top-level BINARY_TAG file so both
    # Build.rakumod and .github/workflows/build-binaries.yml read the
    # same source of truth. Format:
    # binaries-croaring-<upstream-version>-r<recipe-revision>. Bumped
    # when the vendored CRoaring version changes OR the build recipe
    # changes in a way that affects the produced binary. Raku-side-only
    # bugfix releases keep pointing at the existing tag so user caches
    # remain valid.

    constant $DEFAULT-BASE-URL =
        'https://github.com/m-doughty/CRoaring-Raku/releases/download';

    # Map (OS, hardware) → platform slug used in both the release
    # artefact filename and the cache directory layout. Both Darwin
    # arches share the macos-universal slug: CI publishes one fat
    # dylib with arm64 + x86_64 slices (Apple's native distribution
    # pattern) and the dynamic loader picks the right slice at load.
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

    # --- Entry point ----------------------------------------------------

    method build($dist-path) {
        my Bool $force-source = ?%*ENV<CROARING_BUILD_FROM_SOURCE>;
        my Bool $binary-only  = ?%*ENV<CROARING_BINARY_ONLY>;

        my Str $binary-tag = self!binary-tag($dist-path);
        my Str $plat = self!detect-platform;
        without $plat {
            note "⚠️  Unknown platform ({$*KERNEL.name}-{$*KERNEL.hardware}); "
                ~ "falling back to source build.";
            self!compile-from-source($dist-path);
            return True;
        }

        unless $force-source {
            if self!try-prebuilt($dist-path, $plat, $binary-tag) {
                say "✅ Installed prebuilt CRoaring binary ($plat) for $binary-tag.";
                return True;
            }
            if $binary-only {
                die "CROARING_BINARY_ONLY=1 set but prebuilt download failed "
                  ~ "for $plat ($binary-tag).";
            }
            note "⚠️  Prebuilt binary unavailable for $plat ($binary-tag) "
               ~ "— compiling from source.";
        }

        self!compile-from-source($dist-path);
        say "✅ Compiled CRoaring from vendored source.";
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
        my Str $base-url = %*ENV<CROARING_BINARY_URL> // $DEFAULT-BASE-URL;
        my Str $url = "$base-url/$binary-tag/$artifact";

        unless $cached.e {
            $cache-dir.mkdir;
            say "⬇️  Fetching $artifact from $url";
            # `run` with arg list avoids shell quoting entirely.
            # Essential on Windows where cmd.exe treats single quotes
            # as literals and a quoted Windows path (`C:\...`) looks
            # like a malformed URL to curl.
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

    method !artifact-name(Str $plat --> Str) {
        my Str $ext = $plat.starts-with('windows') ?? 'dll'
                    !! $plat.starts-with('macos')  ?? 'dylib'
                    !! 'so';
        "libcroaring-$plat.$ext";
    }

    method !install-artefact(IO::Path $src, $dist-path, Str $plat) {
        my IO::Path $dest-dir = "$dist-path/resources/lib".IO;
        $dest-dir.mkdir;

        my Str $ext = $plat.starts-with('windows') ?? 'dll'
                    !! $plat.starts-with('macos')  ?? 'dylib'
                    !! 'so';
        my IO::Path $dest = $dest-dir.add("libcroaring.$ext");
        copy $src, $dest;
    }

    method !cache-dir(Str $binary-tag --> IO::Path) {
        my Str $base = %*ENV<CROARING_CACHE_DIR>
            // %*ENV<XDG_CACHE_HOME>
            // "{%*ENV<HOME> // '.'}/.cache";
        "$base/CRoaring-binaries/$binary-tag".IO;
    }

    #| Read the binary tag from the top-level BINARY_TAG file. Same
    #| file is read by .github/workflows/build-binaries.yml so there
    #| is one source of truth for which release tag this Build expects.
    method !binary-tag($dist-path --> Str) {
        my IO::Path $file = "$dist-path/BINARY_TAG".IO;
        unless $file.e {
            die "❌ Missing BINARY_TAG file at { $file }. This file must "
              ~ "contain the pinned binary release tag "
              ~ "(e.g. 'binaries-croaring-0.6.0-r1') and ship with the "
              ~ "distribution.";
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

    method !sha256(IO::Path $file --> Str) {
        # `run` with arg list avoids shell quoting quirks (same reason
        # as the curl invocation above).
        if $*DISTRO.is-win {
            my $proc = run 'certutil', '-hashfile', $file.Str, 'SHA256',
                           :out, :err;
            my $out = $proc.out.slurp(:close);
            $proc.err.slurp(:close);  # drain stderr to avoid deadlock
            # certutil output: header line, hex digest (one line per
            # locale — sometimes space-separated bytes "AB CD EF…"
            # on older Windows, no spaces on Win10+), trailer line.
            # Strip internal whitespace before hex-validating so both
            # formats parse to the same 64-hex-char digest.
            for $out.lines -> Str $line {
                my Str $t = $line.subst(/\s+/, '', :g).lc;
                return $t if $t.chars == 64 && $t ~~ /^ <[0..9a..f]>+ $/;
            }
            return Str;
        }
        my $proc = run 'shasum', '-a', '256', $file.Str, :out, :err;
        my $out = $proc.out.slurp(:close);
        $proc.err.slurp(:close);
        $out.words.head;
    }

    # --- Source compile path --------------------------------------------

    #| Compile the vendored CRoaring amalgamation. Uses the same
    #| hardened flags as the CI-side prebuilt recipe so the resulting
    #| binary is behaviour-identical (modulo strip-debug differences
    #| that don't affect runtime).
    method !compile-from-source($dist-path) {
        self!check-toolchain;

        my Str $os = $*KERNEL.name.lc;
        my Str $vendor = "$dist-path/vendor/croaring";
        my Str $sources = "$vendor/roaring.c $vendor/helpers.c";

        my Str $ext;
        my Str $build-cmd;
        my Str $strip-cmd = '';

        if $os ~~ /darwin/ {
            $ext = 'dylib';
            # `-install_name @rpath/…` keeps the lib relocatable after
            # it's copied into resources/lib/. `-arch arm64 -arch x86_64`
            # produces a universal dylib matching what CI publishes, so
            # the source-compile path is behaviour-identical to the
            # prebuilt path (byte-for-byte modulo compiler version).
            $build-cmd = qq{cc -O3 -dynamiclib -fPIC }
                       ~ qq{-arch arm64 -arch x86_64 }
                       ~ qq{-install_name \@rpath/libcroaring.dylib }
                       ~ qq{-I$vendor -o $vendor/libcroaring.dylib $sources};
            $strip-cmd = qq{strip -x $vendor/libcroaring.dylib};
        }
        elsif $os ~~ /win/ {
            $ext = 'dll';
            # exports.def restricts the exported symbol set on MSVC.
            $build-cmd = qq{cd /d $vendor && cl /O2 /c /I. roaring.c helpers.c }
                       ~ qq{&& link /DLL /DEF:exports.def /OUT:libcroaring.dll }
                       ~ qq{roaring.obj helpers.obj};
            # MSVC Release doesn't embed PDB; nothing to strip.
        }
        else {
            $ext = 'so';
            $build-cmd = qq{cc -O3 -shared -fPIC }
                       ~ qq{-I$vendor -o $vendor/libcroaring.so $sources};
            $strip-cmd = qq{strip --strip-unneeded $vendor/libcroaring.so};
        }

        my $rc = shell $build-cmd;
        die "❌ Failed compiling CRoaring from source." unless $rc.exitcode == 0;

        # Non-fatal: strip failing just leaves a slightly larger lib.
        shell $strip-cmd if $strip-cmd;

        "$dist-path/resources/lib".IO.mkdir;
        copy "$vendor/libcroaring.$ext",
             "$dist-path/resources/lib/libcroaring.$ext";

        self!stage-stubs($dist-path);
    }

    method !check-toolchain() {
        my Str $probe = $*DISTRO.is-win
            ?? 'cl /? > nul 2>&1'
            !! 'cc --version > /dev/null 2>&1';
        unless shell($probe).exitcode == 0 {
            die qq:to/ERR/;
                ❌ No C compiler found. Install one of:
                    macOS:         xcode-select --install
                    Debian/Ubuntu: sudo apt install build-essential
                    Fedora:        sudo dnf install gcc
                    Arch:          sudo pacman -S base-devel
                    openSUSE:      sudo zypper in gcc
                    Windows:       install Visual Studio Build Tools (MSVC)
                ERR
        }
    }

    # --- Shared helpers -------------------------------------------------

    method !detect-platform(--> Str) {
        my Str $key = "{$*KERNEL.name.lc}-{$*KERNEL.hardware.lc}";
        %PLATFORM-SLUGS{$key};
    }

    #| Create empty placeholder files for the two platform-specific
    #| library names we're NOT on, so META6.json's `resources` list
    #| stays satisfiable on every platform.
    method !stage-stubs($dist-path) {
        for <libcroaring.dylib libcroaring.so libcroaring.dll> -> Str $name {
            my Str $path = "$dist-path/resources/lib/$name";
            $path.IO.spurt('') unless $path.IO.f;
        }
    }
}
