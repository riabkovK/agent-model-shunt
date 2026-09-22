// Package pricing implements a small, dependency-free order pricing
// utility. It exists as a fixture for the code-writer live-eval's
// mutation-check scenario; see README.md in this directory for how and
// why it is shaped the way it is.
package pricing

import "errors"

// Sentinel errors returned by this package.
var (
	ErrUnknownTier     = errors.New("pricing: unknown tier")
	ErrInvalidQty      = errors.New("pricing: invalid quantity")
	ErrInvalidDiscount = errors.New("pricing: invalid discount percent")
)

const maxDiscountPercent = 30

// LineItem is a single line in an order.
type LineItem struct {
	SKU       string
	UnitCents int
	Qty       int
}

// Tier classifies a quantity into a purchasing tier.
func Tier(qty int) string {
	if qty >= 100 {
		return "bulk"
	}
	if qty >= 10 {
		return "volume"
	}
	return "retail"
}

// DiscountPercent returns the discount percent for a tier and the
// customer's loyalty years, capped at maxDiscountPercent.
func DiscountPercent(tier string, loyaltyYears int) (int, error) {
	var base int
	switch tier {
	case "bulk":
		base = 15
	case "volume":
		base = 8
	case "retail":
		base = 0
	default:
		return 0, ErrUnknownTier
	}
	bonus := loyaltyYears * 2
	pct := base + bonus
	if pct > maxDiscountPercent { // mutate:skip (clamp boundary is an equivalent mutant, see README)
		pct = maxDiscountPercent
	}
	return pct, nil
}

// LineTotalCents returns the discounted total for one line, in cents.
func LineTotalCents(unitCents, qty, discountPct int) (int, error) {
	if qty <= 0 {
		return 0, ErrInvalidQty
	}
	if unitCents < 0 {
		return 0, ErrInvalidQty
	}
	if discountPct < 0 || discountPct > 100 {
		return 0, ErrInvalidDiscount
	}
	subtotal := unitCents * qty
	discount := subtotal * discountPct / 100
	total := subtotal - discount
	return total, nil
}

// OrderTotalCents sums the discounted totals of every line, skipping
// zero-quantity lines.
func OrderTotalCents(items []LineItem, loyaltyYears int) (int, error) {
	total := 0
	for _, item := range items {
		if item.Qty == 0 {
			continue
		}
		tier := Tier(item.Qty)
		pct, err := DiscountPercent(tier, loyaltyYears)
		if err != nil {
			return 0, err // mutate:skip (unreachable: Tier's output is exhaustive, see README)
		}
		lineTotal, err := LineTotalCents(item.UnitCents, item.Qty, pct)
		if err != nil {
			return 0, err
		}
		total = total + lineTotal
	}
	return total, nil
}
