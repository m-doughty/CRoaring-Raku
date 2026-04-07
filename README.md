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

The C library is vendored as an amalgamation and compiled on install via `Build.rakumod`. No system dependencies required.

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

