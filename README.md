[![Actions Status](https://github.com/m-doughty/CRoaring-Raku/actions/workflows/test.yml/badge.svg)](https://github.com/m-doughty/CRoaring-Raku/actions)

NAME
====

CRoaring - Raku bindings for CRoaring compressed bitmap library

SYNOPSIS
========

```raku
use CRoaring;

# Create bitmaps
my CRoaring $a = CRoaring.from-array([1, 2, 3, 4, 5]);
my CRoaring $b = CRoaring.from-range(3, 7);
my CRoaring $c = CRoaring.new;
$c.add(10);
$c.add-many([11, 12, 13]);

# Set operations (return new owned bitmaps)
my CRoaring $union     = $a.or($b);       # {1,2,3,4,5,6,7}
my CRoaring $intersect = $a.and($b);      # {3,4,5}
my CRoaring $diff      = $a.andnot($b);   # {1,2}
my CRoaring $sym-diff  = $a.xor($b);      # {1,2,6,7}

# Query
say $union.cardinality;   # 7
say $union.elems;          # 7 (alias)
say $a.contains(3);       # True
say $a.is-empty;           # False
say 3 ~~ $a;              # True (smartmatch)

# Comparison
say $a.equals($b);         # False
say $a.is-subset-of($union); # True

# Clone
my CRoaring $copy = $a.clone;

# Conversion
say $a.to-array;           # (1, 2, 3, 4, 5)
say $a.list;               # Same as to-array

# Pagination (O(log n) per element, no full materialization)
say $a.select(0);              # 1 (element at rank 0)
say $a.select(4);              # 5 (element at rank 4)
say $a.slice(1, 3);            # (2, 3, 4) (3 elements starting at offset 1)
say $a.slice-reverse(0, 3);    # (5, 4, 3) (newest 3, descending)
say $a.slice-reverse(3, 3);    # (2, 1) (next page, partial)

# Serialize / deserialize (portable format)
my Buf $data = $a.serialize;
my CRoaring $restored = CRoaring.deserialize($data);

# Optimize storage
$a.optimize;

# Deterministic cleanup (also called automatically by GC via DESTROY)
$copy.dispose;
```

DESCRIPTION
===========

CRoaring provides Raku bindings for the CRoaring compressed bitmap library (Roaring Bitmaps). Roaring bitmaps are compressed bitsets that support fast set operations — ideal for tagging, filtering, and indexing millions of items.

The C library is vendored as an amalgamation. No system dependencies are required beyond libc.

INSTALLATION
============

    zef install CRoaring

On install, `Build.rakumod` tries two paths in order:

  * **Prebuilt binary download** from this repo's GitHub Releases for the detected (OS, arch) pair. Verified against a SHA256 bundled in the distribution (`resources/checksums.txt`). Statically-linked, stripped, no transitive dependencies. ~2–5 seconds on a decent connection. This is the default path when a matching release exists.

  * **Source compile fallback** via `cc` (or `cl` on Windows/MSVC). Used when no prebuilt is available for the platform, when the download fails, when the checksum doesn't match, or when the user has opted out of prebuilts via env var. Takes ~20–30 seconds and needs a C toolchain but no other system libraries.

Supported prebuilt platforms
----------------------------

  * macOS arm64 (Apple Silicon)

  * macOS x86_64 (Intel)

  * Linux x86_64 glibc

  * Linux aarch64 glibc

  * Windows x86_64

  * Windows arm64 (Copilot+ PCs, Snapdragon X)

On platforms outside this list (Alpine musl, BSDs, i686, etc.) the fallback compile path runs automatically.

Environment variables
---------------------

  * `CROARING_BUILD_FROM_SOURCE=1` — skip the prebuilt path and always compile. Useful for reproducible builds or when auditing what's going into the dylib.

  * `CROARING_BINARY_ONLY=1` — refuse to fall back to compile if the prebuilt is unavailable. Useful in CI where a 10× slower install via surprise compile is worse than a loud failure.

  * `CROARING_BINARY_URL=<url>` — override the GitHub Releases base URL. For private mirrors, air-gapped setups, or testing a pre-release build.

  * `CROARING_CACHE_DIR=<path>` — override the download cache location. Defaults to `$XDG_CACHE_HOME/CRoaring-binaries/` or `~/.cache/CRoaring-binaries/`.

  * `CROARING_LIB=<path>` — bypass `%?RESOURCES` entirely and load the library from an explicit path. Undocumented escape hatch for custom notcurses builds and similar; you take full responsibility for ABI compatibility.

Binary release versioning
-------------------------

Prebuilt binaries are tagged independently of the Raku distribution:

    binaries-croaring-<upstream-version>-r<recipe-revision>

e.g. `binaries-croaring-0.6.0-r1`. The `upstream-version` tracks the vendored CRoaring amalgamation; `recipe-revision` bumps only when build flags change (compiler flags, strip options, platform additions) while the upstream library stays the same.

`Build.rakumod` hardcodes which binary tag it expects, so a Raku- side bugfix release of `CRoaring` can ship without rebuilding binaries. Users upgrading within the same binary tag get their download from the cache, not the network.

Performance
-----------

Union/intersection of two 1M-element bitmaps: under 1ms. 100K contains lookups in a 1M bitmap: 15ms. Serialize+deserialize 1M contiguous values: 6ms, 230 bytes.

Memory management
-----------------

Every `CRoaring` object owns its underlying C bitmap handle. Set operations (`and`, `or`, `xor`, `andnot`) return new owned instances. The handle is freed automatically by Raku's GC via `DESTROY`, or deterministically by calling `.dispose`. After dispose, the handle is set to `Nil` and further operations are safe (no double-free).

Value range
-----------

CRoaring uses uint32 document IDs (0 to 4,294,967,295).

AUTHOR
======

Matt Doughty <matt@apogee.guru>

COPYRIGHT AND LICENSE
=====================

Copyright 2026 Matt Doughty

This library is free software; you can redistribute it and/or modify it under the Artistic License 2.0.

CRoaring C library is licensed under Apache 2.0 / MIT.

