package filtering

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/AdguardTeam/golibs/logutil/slogutil"
	"github.com/stretchr/testify/require"
)

func TestDNSFilter_validateFilterURL_localFiles(t *testing.T) {
	workDir := t.TempDir()
	d := &DNSFilter{
		conf: &Config{
			WorkDir:        workDir,
			DataDir:        filepath.Join(workDir, "data"),
			SafeFSPatterns: []string{filepath.Join(workDir, "userfilters", "*")},
			Logger:         slogutil.NewDiscardLogger(),
		},
	}

	t.Run("absolute_path_within_safe_pattern_creates_file", func(t *testing.T) {
		p := filepath.Join(workDir, "userfilters", "newlist.txt")
		err := d.validateFilterURL(p)
		require.NoError(t, err)

		data, readErr := os.ReadFile(p)
		require.NoError(t, readErr)
		require.Empty(t, string(data))
	})

	t.Run("existing_absolute_path_within_safe_pattern", func(t *testing.T) {
		p := filepath.Join(workDir, "userfilters", "existing.txt")
		require.NoError(t, os.WriteFile(p, []byte("||example.org^\n"), 0o644))

		err := d.validateFilterURL(p)
		require.NoError(t, err)
	})

	t.Run("absolute_path_outside_safe_pattern_fails", func(t *testing.T) {
		p := filepath.Join(workDir, "evil.txt")
		require.NoError(t, os.WriteFile(p, []byte("||example.org^\n"), 0o644))

		err := d.validateFilterURL(p)
		require.Error(t, err)
		require.ErrorContains(t, err, "does not match safe patterns")
	})

	t.Run("absolute_path_outside_safe_pattern_missing_fails", func(t *testing.T) {
		p := filepath.Join(workDir, "missing.txt")
		err := d.validateFilterURL(p)
		require.Error(t, err)
	})

	t.Run("relative_file_name_resolves_to_userfilters", func(t *testing.T) {
		err := d.validateFilterURL("mylist.txt")
		require.NoError(t, err)

		p := filepath.Join(workDir, "userfilters", "mylist.txt")
		require.FileExists(t, p)
	})

	t.Run("relative_nested_file_name", func(t *testing.T) {
		err := d.validateFilterURL("sub/nested.txt")
		require.NoError(t, err)

		p := filepath.Join(workDir, "userfilters", "sub", "nested.txt")
		require.FileExists(t, p)
	})

	t.Run("relative_path_traversal_rejected", func(t *testing.T) {
		err := d.validateFilterURL("../escape.txt")
		require.Error(t, err)
		require.ErrorContains(t, err, "not allowed")
	})
}
