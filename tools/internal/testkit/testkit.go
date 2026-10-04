// Package testkit creates fixtures only beneath tools/.test-work.
package testkit

import (
	"os"
	"path/filepath"
	"runtime"
	"testing"

	"github.com/haider-IQZ/gilgamesh/tools/internal/fsys"
)

func FS(t testing.TB) fsys.FS {
	t.Helper()
	_, file, _, _ := runtime.Caller(0)
	base := filepath.Join(filepath.Dir(file), "../..", ".test-work")
	if e := os.MkdirAll(base, 0755); e != nil {
		t.Fatal(e)
	}
	root, e := os.MkdirTemp(base, "case-")
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() {
		if e := os.RemoveAll(root); e != nil {
			t.Error(e)
		}
	})
	return fsys.FS{Root: root}
}
func Write(t testing.TB, f fsys.FS, p, s string) {
	t.Helper()
	if e := f.Write(p, []byte(s), 0644); e != nil {
		t.Fatal(e)
	}
}
func Dir(t testing.TB, f fsys.FS, p string) {
	t.Helper()
	if e := os.MkdirAll(f.Path(p), 0755); e != nil {
		t.Fatal(e)
	}
}
