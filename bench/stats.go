package main

import (
	"math"
	"math/rand/v2"
	"slices"
)

type Summary struct {
	N      int     `json:"n"`
	Median float64 `json:"median"`
	Stddev float64 `json:"stddev"`
}

func quantile(values []float64, p float64) float64 {
	if len(values) == 0 {
		return math.NaN()
	}
	x := slices.Clone(values)
	slices.Sort(x)
	i := p * float64(len(x)-1)
	lo, hi := int(math.Floor(i)), int(math.Ceil(i))
	return x[lo] + (x[hi]-x[lo])*(i-float64(lo))
}

func summarize(x []float64) Summary {
	s := Summary{N: len(x), Median: quantile(x, 0.5)}
	var mean, m2 float64
	for i, v := range x {
		d := v - mean
		mean += d / float64(i+1)
		m2 += d * (v - mean)
	}
	if len(x) > 1 {
		s.Stddev = math.Sqrt(m2 / float64(len(x)-1))
	}
	return s
}

// Resample experimental units, never individual timer wakes or I/O requests.
func bootstrap(a, b []float64, paired bool) (float64, float64) {
	rng := rand.New(rand.NewPCG(42, 17))
	deltas := make([]float64, 20000)
	x, y := make([]float64, len(a)), make([]float64, len(b))
	for r := range deltas {
		for i := range x {
			j := rng.IntN(len(a))
			x[i] = a[j]
			if paired {
				y[i] = b[j] - a[j]
			}
		}
		if paired {
			deltas[r] = quantile(y, 0.5)
		} else {
			for i := range y {
				y[i] = b[rng.IntN(len(b))]
			}
			deltas[r] = quantile(y, 0.5) - quantile(x, 0.5)
		}
	}
	return quantile(deltas, 0.025), quantile(deltas, 0.975)
}
