class Build {
	method build($dist-path) {
		my Str:D $os = $*KERNEL.name.lc;
		my Str:D $vendor = "$dist-path/vendor/croaring";

		my Str $lib-ext;
		my Str $compile-cmd;

		my Str:D $sources = "$vendor/roaring.c $vendor/helpers.c";
		if $os ~~ /darwin/ {
			$lib-ext = 'dylib';
			$compile-cmd = "cc -O3 -dynamiclib -fPIC -I$vendor -o $vendor/libcroaring.dylib $sources";
		} elsif $os ~~ /win/ {
			$lib-ext = 'dll';
			$compile-cmd = "cl /O2 /LD /I$vendor /Fe:$vendor/libcroaring.dll $sources";
		} else {
			$lib-ext = 'so';
			$compile-cmd = "cc -O3 -shared -fPIC -I$vendor -o $vendor/libcroaring.so $sources";
		}

		# Build the C library
		shell $compile-cmd;

		# Stage into resources
		"$dist-path/resources/lib".IO.mkdir;
		copy "$vendor/libcroaring.$lib-ext",
			"$dist-path/resources/lib/libcroaring.$lib-ext";

		# Create empty stubs for other platforms
		for <libcroaring.dylib libcroaring.so libcroaring.dll> -> Str:D $name {
			my Str:D $path = "$dist-path/resources/lib/$name";
			$path.IO.spurt("") unless $path.IO.f;
		}

		True;
	}
}
