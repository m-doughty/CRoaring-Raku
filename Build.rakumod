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

    # Bumped when the vendored CRoaring version changes OR the build
    # recipe changes in a way that affects the produced binary. Format:
    # binaries-croaring-<upstream-version>-r<recipe-revision>.
    constant $BINARY-TAG = 'binaries-croaring-0.6.0-r1';

    constant $DEFAULT-BASE-URL =
        'https://github.com/m-doughty/CRoaring-Raku/releases/download';

    # Map (OS, hardware) → platform slug used in both the release
    # artefact filename and the cache directory layout.
    my %PLATFORM-SLUGS =
        'darwin-arm64'    => 'macos-arm64',
        'darwin-x86_64'   => 'macos-x86_64',
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

        my Str $plat = self!detect-platform;
        without $plat {
            note "⚠️  Unknown platform ({$*KERNEL.name}-{$*KERNEL.hardware}); "
                ~ "falling back to source build.";
            self!compile-from-source($dist-path);
            return True;
        }

        unless $force-source {
            if self!try-prebuilt($dist-path, $plat) {
                say "✅ Installed prebuilt CRoaring binary ($plat).";
                return True;
            }
            if $binary-only {
                die "CROARING_BINARY_ONLY=1 set but prebuilt download failed for $plat.";
            }
            note "⚠️  Prebuilt binary unavailable for $plat — compiling from source.";
        }

        self!compile-from-source($dist-path);
        say "✅ Compiled CRoaring from vendored source.";
        True;
    }

    # --- Prebuilt binary path -------------------------------------------

    #| Attempt to download, verify, and install the prebuilt artefact
    #| for $plat. Returns True on success, False on any failure — Build
    #| falls back to source compile on False (unless BINARY_ONLY is set).
    method !try-prebuilt($dist-path, Str $plat --> Bool) {
        my Str $artifact = self!artifact-name($plat);
        my IO::Path $cache-dir = self!cache-dir;
        my IO::Path $cached = $cache-dir.add($artifact);
        my Str $base-url = %*ENV<CROARING_BINARY_URL> // $DEFAULT-BASE-URL;
        my Str $url = "$base-url/$BINARY-TAG/$artifact";

        unless $cached.e {
            $cache-dir.mkdir;
            say "⬇️  Fetching $artifact from $url";
            my $rc = shell "curl -fL --progress-bar '$url' -o '$cached'";
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

    method !cache-dir(--> IO::Path) {
        my Str $base = %*ENV<CROARING_CACHE_DIR>
            // %*ENV<XDG_CACHE_HOME>
            // "{%*ENV<HOME> // '.'}/.cache";
        "$base/CRoaring-binaries/$BINARY-TAG".IO;
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
        # shasum on macOS/Linux; Windows uses certutil.
        if $*DISTRO.is-win {
            my $out = qqx{certutil -hashfile "$file" SHA256 2>NUL};
            # certutil output: 3 lines; the middle one is the hex digest.
            my @lines = $out.lines.grep(*.chars);
            return @lines.elems >= 2 ?? @lines[1].trim !! Str;
        }
        my $out = qqx{shasum -a 256 '$file'};
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
            # it's copied into resources/lib/.
            $build-cmd = qq{cc -O3 -dynamiclib -fPIC }
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
