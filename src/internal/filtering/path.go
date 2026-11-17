package filtering

import (
	"fmt"
	"path/filepath"
	"strings"
)

// pathMatchesAny returns true if filePath matches one of globs.  globs must be
// valid.  filePath must be absolute and clean.  If globs are empty,
// pathMatchesAny returns false.
//
// TODO(a.garipov): Move to golibs?
func pathMatchesAny(globs []string, filePath string) (ok bool) {
	if len(globs) == 0 {
		return false
	}

	clean, err := filepath.Abs(filePath)
	if err != nil {
		panic(fmt.Errorf("pathMatchesAny: %w", err))
	} else if clean != filePath {
		panic(fmt.Errorf("pathMatchesAny: filepath %q is not absolute", filePath))
	}

	for _, g := range globs {
		ok, err = filepath.Match(g, filePath)
		if err != nil {
			panic(fmt.Errorf("pathMatchesAny: bad pattern: %w", err))
		}

		if ok {
			return true
		}

		// Standard filepath.Match globs don't match across separators, so
		// treat a trailing "/*" as a directory-prefix match as well; this
		// lets a pattern like "/sdcard/*" cover nested rule files such as
		// "/sdcard/Download/rules/list.txt".
		if dir := strings.TrimSuffix(g, "/*"); dir != g && strings.HasPrefix(filePath, dir+"/") {
			return true
		}
	}

	return false
}
