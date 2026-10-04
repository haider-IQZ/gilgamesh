package main

import (
	"math"
	"reflect"
	"testing"
)

func TestSummary(t *testing.T) {
	x := []float64{4, 1, 3, 2}
	s := summarize(x)
	if s.N != 4 || s.Median != 2.5 || math.Abs(s.Stddev-math.Sqrt(5.0/3)) > 1e-12 {
		t.Fatalf("unexpected summary: %+v", s)
	}
	if !reflect.DeepEqual(x, []float64{4, 1, 3, 2}) {
		t.Fatal("summary mutated samples")
	}
	if s := summarize([]float64{7}); s.Stddev != 0 || s.Median != 7 {
		t.Fatal(s)
	}
	if !math.IsNaN(quantile(nil, .5)) || quantile(x, 0) != 1 || quantile(x, 1) != 4 {
		t.Fatal("quantile boundary handling")
	}
}

func TestBootstrap(t *testing.T) {
	for _, paired := range []bool{false, true} {
		lo, hi := bootstrap([]float64{1, 1, 1, 1}, []float64{3, 3, 3, 3}, paired)
		if lo != 2 || hi != 2 {
			t.Fatalf("constant shift: [%g, %g]", lo, hi)
		}
		lo, hi = bootstrap([]float64{1, 2, 3, 4, 5}, []float64{1, 2, 3, 4, 5}, paired)
		if lo > 0 || hi < 0 {
			t.Fatalf("identical data excluded zero: [%g, %g]", lo, hi)
		}
	}
	a, b := []float64{2, 7, 10, 20, 30}, []float64{3, 8, 11, 21, 31}
	lo, hi := bootstrap(a, b, true)
	if lo != 1 || hi != 1 {
		t.Fatalf("pairing lost: [%g, %g]", lo, hi)
	}
	l1, h1 := bootstrap(a, b, false)
	l2, h2 := bootstrap(a, b, false)
	if l1 != l2 || h1 != h2 || l1 >= h1 {
		t.Fatal("bootstrap must be deterministic and nondegenerate")
	}
}
