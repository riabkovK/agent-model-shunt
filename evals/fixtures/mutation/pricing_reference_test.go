// This is a deliberately strong, hand-written test suite for pricing.go.
// It exists to prove the mutation-check pipeline has no equivalent
// mutants left in its default operator set: `evals/mutation-check.sh
// --self-test` runs this file against every mutant of pricing.go and
// must report 100% killed. It is never built by evals/gotest's go.mod
// and is not the code-writer's own output.
package pricing

import (
	"errors"
	"testing"
)

func TestTier(t *testing.T) {
	cases := []struct {
		qty  int
		want string
	}{
		{0, "retail"},
		{1, "retail"},
		{9, "retail"},
		{10, "volume"},
		{50, "volume"},
		{99, "volume"},
		{100, "bulk"},
		{500, "bulk"},
	}
	for _, c := range cases {
		if got := Tier(c.qty); got != c.want {
			t.Errorf("Tier(%d) = %q, want %q", c.qty, got, c.want)
		}
	}
}

func TestDiscountPercent(t *testing.T) {
	cases := []struct {
		tier         string
		loyaltyYears int
		want         int
		wantErr      error
	}{
		{"retail", 0, 0, nil},
		{"retail", 1, 2, nil},
		{"volume", 0, 8, nil},
		{"volume", 2, 12, nil},
		{"bulk", 0, 15, nil},
		{"bulk", 5, 25, nil},
		{"bulk", 10, 30, nil},
		{"bulk", 100, 30, nil},
		{"unknown", 0, 0, ErrUnknownTier},
	}
	for _, c := range cases {
		got, err := DiscountPercent(c.tier, c.loyaltyYears)
		if !errors.Is(err, c.wantErr) {
			t.Fatalf("DiscountPercent(%q, %d) error = %v, want %v", c.tier, c.loyaltyYears, err, c.wantErr)
		}
		if got != c.want {
			t.Errorf("DiscountPercent(%q, %d) = %d, want %d", c.tier, c.loyaltyYears, got, c.want)
		}
	}
}

func TestLineTotalCents(t *testing.T) {
	cases := []struct {
		unitCents, qty, discountPct int
		want                        int
		wantErr                     error
	}{
		{100, 1, 0, 100, nil},
		{0, 1, 0, 0, nil},
		{100, 2, 0, 200, nil},
		{100, 1, 50, 50, nil},
		{100, 1, 100, 0, nil},
		{1000, 3, 10, 2700, nil},
		{100, 0, 0, 0, ErrInvalidQty},
		{100, -1, 0, 0, ErrInvalidQty},
		{-1, 1, 0, 0, ErrInvalidQty},
		{100, 1, -1, 0, ErrInvalidDiscount},
		{100, 1, 101, 0, ErrInvalidDiscount},
	}
	for _, c := range cases {
		got, err := LineTotalCents(c.unitCents, c.qty, c.discountPct)
		if !errors.Is(err, c.wantErr) {
			t.Fatalf("LineTotalCents(%d,%d,%d) error = %v, want %v", c.unitCents, c.qty, c.discountPct, err, c.wantErr)
		}
		if got != c.want {
			t.Errorf("LineTotalCents(%d,%d,%d) = %d, want %d", c.unitCents, c.qty, c.discountPct, got, c.want)
		}
	}
}

func TestOrderTotalCents(t *testing.T) {
	items := []LineItem{
		{SKU: "a", UnitCents: 100, Qty: 5},
		{SKU: "b", UnitCents: 200, Qty: 0},
		{SKU: "c", UnitCents: 50, Qty: 20},
	}
	got, err := OrderTotalCents(items, 0)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	// a: retail (qty 5), 0% discount -> 500
	// b: skipped (qty 0)
	// c: volume (qty 20), 8% discount on 1000 -> 920
	want := 500 + 920
	if got != want {
		t.Errorf("OrderTotalCents = %d, want %d", got, want)
	}

	bad := []LineItem{{SKU: "x", UnitCents: -1, Qty: 1}}
	if got, err := OrderTotalCents(bad, 0); err == nil {
		t.Errorf("expected error for invalid line item, got total=%d", got)
	} else if got != 0 {
		t.Errorf("OrderTotalCents on error = %d, want 0", got)
	}
}
