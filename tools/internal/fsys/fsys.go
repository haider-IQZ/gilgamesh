// Package fsys isolates filesystem effects. Root is / in production and a private
// fixture tree in tests. Installer device operations go exclusively through Runner.
package fsys

import (
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

type FS struct {
	Root    string
	Dry     bool
	Preview func(string)
}

func (f FS) Path(p string) string {
	if f.Root == "" || f.Root == "/" {
		return p
	}
	return filepath.Join(f.Root, strings.TrimPrefix(filepath.Clean(p), "/"))
}
func (f FS) Read(p string) ([]byte, error) { return os.ReadFile(f.Path(p)) }
func (f FS) Exists(p string) bool          { _, e := os.Stat(f.Path(p)); return e == nil }
func (f FS) Write(p string, b []byte, m fs.FileMode) error {
	if f.Dry {
		if f.Preview != nil {
			f.Preview(fmt.Sprintf("write %s (%04o):\n%s", p, m, b))
		}
		return nil
	}
	path := f.Path(p)
	if e := os.MkdirAll(filepath.Dir(path), 0755); e != nil {
		return e
	}
	if e := os.WriteFile(path, b, m); e != nil {
		return e
	}
	return os.Chmod(path, m)
}
func (f FS) Remove(p string) error {
	if f.Dry {
		return nil
	}
	e := os.Remove(f.Path(p))
	if os.IsNotExist(e) {
		return nil
	}
	return e
}
func (f FS) Resolve(p string) (string, error) {
	v, e := filepath.EvalSymlinks(f.Path(p))
	if e != nil {
		return "", e
	}
	if f.Root != "" && f.Root != "/" {
		r, e := filepath.Rel(f.Root, v)
		if e != nil || strings.HasPrefix(r, "..") {
			return "", fmt.Errorf("path escapes fixture: %s", p)
		}
		return "/" + r, nil
	}
	return v, nil
}
