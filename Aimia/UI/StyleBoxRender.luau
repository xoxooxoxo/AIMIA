--!strict
--!optimize 2

--[[
	Godot 4.7.2 StyleBoxFlat (scene/resources/style_box_flat.cpp) as the triangles draw() submits, and as RGBA8 pixels
	for UI/Style, which shows the result as a 9-slice image (Roblox UICorner/UIStroke cannot draw per-corner radii,
	borders that follow the rounded corners, or the anti-aliasing feather). Roblox-free.

	Triangles: the vertices, colors and indices of canvas_item_add_triangle_array, in the C++ order. Every C float
	operation is Numbers.F32, so the vertices are Godot's float32 values (oracle: external/Oracle/Cpp/StyleBoxRender).
	Render models the GPU: pixel centers, top-left fill rule, barycentric colors, premultiplied "over" in submission
	order, one un-premultiply and 8-bit rounding at the end (a framebuffer rounds after every triangle, so pixels where
	triangles overlap can differ by one level).

	Assumed header defaults (style_box_flat.h is not in reference/engine; Godot 4.x values): bg_color (0.6, 0.6, 0.6, 1),
	border_color (0.8, 0.8, 0.8, 1), shadow_color (0, 0, 0, 0.6), corner_detail 8, draw_center true, anti_aliasing true,
	anti_aliasing_size 1; other numbers 0, flags false, skew and shadow_offset (0, 0). Canvas oversampling is 1.
	Math::PI is the double constant. Coordinates are relative to the control's top-left corner (0, 0).

	Nine-slice: SliceSize is the smallest size from which the drawing only translates at the right and bottom edges
	(left and top keep their pixels, the middle repeats), with a stretchable column and row; SliceCenter gives that
	1 px column and row in the image rendered at SliceSize.
]]

const Numbers = require("../Numbers")

export type Color = { R: number, G: number, B: number, A: number }

export type Rect = { X: number, Y: number, W: number, H: number }

-- Triangle list in submission order. Points: x, y per vertex; Colors: r, g, b, a per vertex; Indices: three 0-based
-- vertex numbers per triangle (stored 1-based in the Lua array).
export type Mesh = {
	Points: { number },
	Colors: { number },
	Indices: { number },
	Count: number,
}

-- Pixel rows top to bottom, RGBA8. The image's top-left pixel is at (OffsetX, OffsetY) in control pixels.
export type Image = {
	Pixels: buffer,
	Width: number,
	Height: number,
	OffsetX: number,
	OffsetY: number,
}

type Point = { X: number, Y: number }

type Style = {
	BgColor: Color,
	BorderColor: Color,
	ShadowColor: Color,
	BorderWidth: { number }, -- by Side
	CornerRadius: { number }, -- by Corner
	ExpandMargin: { number }, -- by Side
	CornerDetail: number,
	DrawCenter: boolean,
	BorderBlend: boolean,
	AntiAliased: boolean,
	AntiAliasingSize: number,
	SkewX: number,
	SkewY: number,
	ShadowSize: number,
	ShadowOffsetX: number,
	ShadowOffsetY: number,
}

type Slice = {
	Sliceable: boolean,
	SizeX: number,
	SizeY: number,
	Left: number,
	Top: number,
}

-- Accumulator: premultiplied RGBA per pixel, 1-based (pixel p at 4p - 3 .. 4p).
type Raster = {
	Accumulator: { number },
	Width: number,
	Height: number,
	OffsetX: number,
	OffsetY: number,
}

-- Godot's Side and Corner enums (SIDE_LEFT = 0, CORNER_TOP_LEFT = 0, ...), kept as table indices.
const SideLeft = 0
const SideTop = 1
const SideRight = 2
const SideBottom = 3

const CornerTopLeft = 0
const CornerTopRight = 1
const CornerBottomRight = 2
const CornerBottomLeft = 3

const FloatEpsilon = 1.1920928955078125e-7 -- FLT_EPSILON, exact in float32
const ZeroApproxEpsilon = 0.00001 -- Math::is_zero_approx (CMP_EPSILON)
const UnboundedAdaptation = 1000000 -- initial adapted_border / adapted_corner in draw()
const TranslationTolerance = 0.0001

-- C MIN and MAX macros (Godot core/math/math_defs.h): ties and NaN return the second operand.
const function Minimum(A: number, B: number): number
	if A < B then
		return A
	end

	return B
end

const function Maximum(A: number, B: number): number
	if A > B then
		return A
	end

	return B
end

const function IsZeroApprox(Value: number): boolean
	return math.abs(Value) < ZeroApproxEpsilon
end

const function Flag(Value: boolean): number
	if Value then
		return 1
	end

	return 0
end

-- A per-side or per-corner table with the same value everywhere.
const function NewQuad(Value: number): { number }
	return {
		[0] = Value,
		[1] = Value,
		[2] = Value,
		[3] = Value,
	}
end

-- Rect2::grow_individual: the position moves by the left and top amounts, the size grows by each opposite pair.
const function GrowIndividual(Area: Rect, Left: number, Top: number, Right: number, Bottom: number): Rect
	return {
		X = Numbers.F32(Area.X - Left),
		Y = Numbers.F32(Area.Y - Top),
		W = Numbers.F32(Area.W + Numbers.F32(Left + Right)),
		H = Numbers.F32(Area.H + Numbers.F32(Top + Bottom)),
	}
end

-- Rect2::grow_side: only the given side moves.
const function GrowSide(Area: Rect, Side: number, Amount: number): Rect
	const Left = if Side == SideLeft then Amount else 0
	const Top = if Side == SideTop then Amount else 0
	const Right = if Side == SideRight then Amount else 0
	const Bottom = if Side == SideBottom then Amount else 0

	return GrowIndividual(Area, Left, Top, Right, Bottom)
end

-- Rect2::merge: the smallest rect holding both.
const function Merge(First: Rect, Second: Rect): Rect
	const X = Minimum(Second.X, First.X)
	const Y = Minimum(Second.Y, First.Y)
	const Right = Maximum(Numbers.F32(Second.X + Second.W), Numbers.F32(First.X + First.W))
	const Bottom = Maximum(Numbers.F32(Second.Y + Second.H), Numbers.F32(First.Y + First.H))

	return { X = X, Y = Y, W = Numbers.F32(Right - X), H = Numbers.F32(Bottom - Y) }
end

-- @src engine/resources/style_box_flat.cpp:adapt_values L439-445
const function AdaptValues(IndexA: number, IndexB: number, Adapted: { number }, Values: { number }, Width: number, MaxA: number, MaxB: number)
	const ValueA = Values[IndexA]
	const ValueB = Values[IndexB]
	const Factor = Minimum(1, Numbers.F32(Width / Numbers.F32(ValueA + ValueB)))

	Adapted[IndexA] = Minimum(Minimum(Numbers.F32(ValueA * Factor), MaxA), Adapted[IndexA])
	Adapted[IndexB] = Minimum(Minimum(Numbers.F32(ValueB * Factor), MaxB), Adapted[IndexB])
end

-- Inner corner radius of one rect inside the style rect: the radius minus the smaller adjacent border.
-- @src engine/resources/style_box_flat.cpp:set_inner_corner_radius L231-241
const function SetInnerCornerRadius(StyleRect: Rect, InnerRect: Rect, CornerRadius: { number }): { number }
	const BorderLeft = Numbers.F32(InnerRect.X - StyleRect.X)
	const BorderTop = Numbers.F32(InnerRect.Y - StyleRect.Y)
	const BorderRight = Numbers.F32(Numbers.F32(StyleRect.W - InnerRect.W) - BorderLeft)
	const BorderBottom = Numbers.F32(Numbers.F32(StyleRect.H - InnerRect.H) - BorderTop)

	return {
		[CornerTopLeft] = Maximum(Numbers.F32(CornerRadius[CornerTopLeft] - Minimum(BorderTop, BorderLeft)), 0),
		[CornerTopRight] = Maximum(Numbers.F32(CornerRadius[CornerTopRight] - Minimum(BorderTop, BorderRight)), 0),
		[CornerBottomRight] = Maximum(Numbers.F32(CornerRadius[CornerBottomRight] - Minimum(BorderBottom, BorderRight)), 0),
		[CornerBottomLeft] = Maximum(Numbers.F32(CornerRadius[CornerBottomLeft] - Minimum(BorderBottom, BorderLeft)), 0),
	}
end

-- (Radius - Reduction - First - Second) per float32 operation, then maxf(0).
const function Shrunken(Radius: number, Reduction: number, First: number, Second: number): number
	return Maximum(Numbers.F32(Numbers.F32(Numbers.F32(Radius - Reduction) - First) - Second), 0)
end

-- Per-corner scale of the circle arcs, so that radii that do not fit shrink along the overflowing edges.
-- @src engine/resources/style_box_flat.cpp:set_corner_scale L243-314
const function SetCornerScale(StyleRect: Rect, InnerRect: Rect, CornerRadius: { number }): { Point }
	const BorderLeft = Numbers.F32(InnerRect.X - StyleRect.X)
	const BorderTop = Numbers.F32(InnerRect.Y - StyleRect.Y)
	const BorderRight = Numbers.F32(Numbers.F32(StyleRect.W - InnerRect.W) - BorderLeft)
	const BorderBottom = Numbers.F32(Numbers.F32(StyleRect.H - InnerRect.H) - BorderTop)

	-- Amount of overflow along an edge, between the two corners of that edge.
	const EdgeOverflow = {
		[SideLeft] = -Minimum(0, Numbers.F32(Numbers.F32(InnerRect.H - CornerRadius[CornerTopLeft]) - CornerRadius[CornerBottomLeft])),
		[SideTop] = -Minimum(0, Numbers.F32(Numbers.F32(InnerRect.W - CornerRadius[CornerTopLeft]) - CornerRadius[CornerTopRight])),
		[SideRight] = -Minimum(0, Numbers.F32(Numbers.F32(InnerRect.H - CornerRadius[CornerTopRight]) - CornerRadius[CornerBottomRight])),
		[SideBottom] = -Minimum(0, Numbers.F32(Numbers.F32(InnerRect.W - CornerRadius[CornerBottomLeft]) - CornerRadius[CornerBottomRight])),
	}

	const HorizontalBorders = Numbers.F32(BorderLeft + BorderRight)
	const VerticalBorders = Numbers.F32(BorderTop + BorderBottom)

	-- Ratio of each side to the sum of itself and its opposite side (0 when that sum is 0).
	const Ratios = {
		[SideLeft] = if HorizontalBorders > 0 then Numbers.F32(BorderLeft / HorizontalBorders) else 0,
		[SideTop] = if VerticalBorders > 0 then Numbers.F32(BorderTop / VerticalBorders) else 0,
		[SideRight] = if HorizontalBorders > 0 then Numbers.F32(BorderRight / HorizontalBorders) else 0,
		[SideBottom] = if VerticalBorders > 0 then Numbers.F32(BorderBottom / VerticalBorders) else 0,
	}

	-- Raw amount each corner should shrink.
	const Reduction = {
		[CornerTopLeft] = {
				X = Numbers.F32(EdgeOverflow[SideTop] * Ratios[SideLeft]),
				Y = Numbers.F32(EdgeOverflow[SideLeft] * Ratios[SideTop]),
			},
		[CornerTopRight] = {
				X = Numbers.F32(EdgeOverflow[SideTop] * Ratios[SideRight]),
				Y = Numbers.F32(EdgeOverflow[SideRight] * Ratios[SideTop]),
			},
		[CornerBottomRight] = {
				X = Numbers.F32(EdgeOverflow[SideBottom] * Ratios[SideRight]),
				Y = Numbers.F32(EdgeOverflow[SideRight] * Ratios[SideBottom]),
			},
		[CornerBottomLeft] = {
				X = Numbers.F32(EdgeOverflow[SideBottom] * Ratios[SideLeft]),
				Y = Numbers.F32(EdgeOverflow[SideLeft] * Ratios[SideBottom]),
			},
	}

	-- If corner radii are too small, they do not shrink the full amount; the adjacent corners take the leftovers.
	const Leftover: { Point } = {}

	for Corner = CornerTopLeft, CornerBottomLeft do
		Leftover[Corner] = {
			X = -Minimum(Numbers.F32(CornerRadius[Corner] - Reduction[Corner].X), 0),
			Y = -Minimum(Numbers.F32(CornerRadius[Corner] - Reduction[Corner].Y), 0),
		}
	end

	-- New shrunken radii after distributing the leftovers.
	const Distributed = {
		[CornerTopLeft] = {
				X = Shrunken(CornerRadius[CornerTopLeft], Reduction[CornerTopLeft].X, Leftover[CornerBottomLeft].X, Leftover[CornerTopRight].X),
				Y = Shrunken(CornerRadius[CornerTopLeft], Reduction[CornerTopLeft].Y, Leftover[CornerBottomLeft].Y, Leftover[CornerTopRight].Y),
			},
		[CornerTopRight] = {
				X = Shrunken(CornerRadius[CornerTopRight], Reduction[CornerTopRight].X, Leftover[CornerTopLeft].X, Leftover[CornerBottomRight].X),
				Y = Shrunken(CornerRadius[CornerTopRight], Reduction[CornerTopRight].Y, Leftover[CornerTopLeft].Y, Leftover[CornerBottomRight].Y),
			},
		[CornerBottomRight] = {
				X = Shrunken(CornerRadius[CornerBottomRight], Reduction[CornerBottomRight].X, Leftover[CornerTopRight].X, Leftover[CornerBottomLeft].X),
				Y = Shrunken(CornerRadius[CornerBottomRight], Reduction[CornerBottomRight].Y, Leftover[CornerTopRight].Y, Leftover[CornerBottomLeft].Y),
			},
		[CornerBottomLeft] = {
				X = Shrunken(CornerRadius[CornerBottomLeft], Reduction[CornerBottomLeft].X, Leftover[CornerBottomRight].X, Leftover[CornerTopLeft].X),
				Y = Shrunken(CornerRadius[CornerBottomLeft], Reduction[CornerBottomLeft].Y, Leftover[CornerBottomRight].Y, Leftover[CornerTopLeft].Y),
			},
	}

	-- How much each curve scales to reach its shrunken radius; the unshrinkable leftover is excluded.
	const Scale: { Point } = {}

	for Corner = CornerTopLeft, CornerBottomLeft do
		const Next = (Corner + 1) % 4
		const Previous = (Corner + 3) % 4
		const UnshrinkableX = Maximum(Numbers.F32(Numbers.F32(Leftover[Next].X + Leftover[Previous].X) - Distributed[Corner].X), 0)
		const UnshrinkableY = Maximum(Numbers.F32(Numbers.F32(Leftover[Next].Y + Leftover[Previous].Y) - Distributed[Corner].Y), 0)

		Scale[Corner] = {
			X = Numbers.F32(Distributed[Corner].X / Maximum(Numbers.F32(CornerRadius[Corner] - UnshrinkableX), FloatEpsilon)),
			Y = Numbers.F32(Distributed[Corner].Y / Maximum(Numbers.F32(CornerRadius[Corner] - UnshrinkableY), FloatEpsilon)),
		}
	end

	return Scale
end

-- Centers of the four corner arcs of a rect (outer_points / inner_points in draw_rounded_rectangle).
const function CornerCenters(Area: Rect, CornerRadius: { number }, Scale: { Point }): { Point }
	const Right = Numbers.F32(Area.X + Area.W)
	const Bottom = Numbers.F32(Area.Y + Area.H)

	return {
		[CornerTopLeft] = {
				X = Numbers.F32(Area.X + Numbers.F32(CornerRadius[CornerTopLeft] * Scale[CornerTopLeft].X)),
				Y = Numbers.F32(Area.Y + Numbers.F32(CornerRadius[CornerTopLeft] * Scale[CornerTopLeft].Y)),
			},
		[CornerTopRight] = {
				X = Numbers.F32(Right - Numbers.F32(CornerRadius[CornerTopRight] * Scale[CornerTopRight].X)),
				Y = Numbers.F32(Area.Y + Numbers.F32(CornerRadius[CornerTopRight] * Scale[CornerTopRight].Y)),
			},
		[CornerBottomRight] = {
				X = Numbers.F32(Right - Numbers.F32(CornerRadius[CornerBottomRight] * Scale[CornerBottomRight].X)),
				Y = Numbers.F32(Bottom - Numbers.F32(CornerRadius[CornerBottomRight] * Scale[CornerBottomRight].Y)),
			},
		[CornerBottomLeft] = {
				X = Numbers.F32(Area.X + Numbers.F32(CornerRadius[CornerBottomLeft] * Scale[CornerBottomLeft].X)),
				Y = Numbers.F32(Bottom - Numbers.F32(CornerRadius[CornerBottomLeft] * Scale[CornerBottomLeft].Y)),
			},
	}
end

-- The skew of a vertex: both offsets read the unskewed coordinates.
const function SkewPoint(X: number, Y: number, SkewX: number, SkewY: number, CenterX: number, CenterY: number): (number, number)
	const XSkew = Numbers.F32(Numbers.F32(-SkewX) * Numbers.F32(Y - CenterY))
	const YSkew = Numbers.F32(Numbers.F32(-SkewY) * Numbers.F32(X - CenterX))

	return Numbers.F32(X + XSkew), Numbers.F32(Y + YSkew)
end

const function AppendVertex(Mesh: Mesh, X: number, Y: number, Color: Color)
	table.insert(Mesh.Points, X)
	table.insert(Mesh.Points, Y)
	table.insert(Mesh.Colors, Color.R)
	table.insert(Mesh.Colors, Color.G)
	table.insert(Mesh.Colors, Color.B)
	table.insert(Mesh.Colors, Color.A)
	Mesh.Count += 1
end

-- A rounded ring (between ring_rect and inner_rect), or a filled rounded rect when IsFilled (inner ring only).
-- @src engine/resources/style_box_flat.cpp:draw_rounded_rectangle L316-437
const function DrawRoundedRectangle(Mesh: Mesh, StyleRect: Rect, CornerRadius: { number }, RingRect: Rect, InnerRect: Rect, InnerColor: Color, OuterColor: Color, CornerDetail: number, SkewX: number, SkewY: number, IsFilled: boolean)
	const VertOffset = Mesh.Count
	const HasRadius = CornerRadius[CornerTopLeft] > 0 or CornerRadius[CornerTopRight] > 0 or CornerRadius[CornerBottomRight] > 0 or CornerRadius[CornerBottomLeft] > 0
	const AdaptedCornerDetail = if HasRadius then CornerDetail else 1
	const DrawBorder = not IsFilled

	const RingCornerRadius = SetInnerCornerRadius(StyleRect, RingRect, CornerRadius)
	const RingScale = SetCornerScale(StyleRect, RingRect, RingCornerRadius)
	const OuterCenters = CornerCenters(RingRect, RingCornerRadius, RingScale)

	const InnerCornerRadius = SetInnerCornerRadius(StyleRect, InnerRect, CornerRadius)
	const InnerScale = SetCornerScale(StyleRect, InnerRect, InnerCornerRadius)
	const InnerCenters = CornerCenters(InnerRect, InnerCornerRadius, InnerScale)

	const CenterX = Numbers.F32(StyleRect.X + Numbers.F32(StyleRect.W * 0.5))
	const CenterY = Numbers.F32(StyleRect.Y + Numbers.F32(StyleRect.H * 0.5))

	-- quarter_arc_rad is a real_t; the angle is a double product of it, stored as real_t.
	const QuarterArcRad = Numbers.F32(math.pi / 2)

	for CornerIndex = CornerTopLeft, CornerBottomLeft do
		for Detail = 0, AdaptedCornerDetail do
			const PointAngle = Numbers.F32((CornerIndex + Detail / AdaptedCornerDetail) * QuarterArcRad + math.pi)
			const AngleCosine = Numbers.F32(math.cos(PointAngle))
			const AngleSine = Numbers.F32(math.sin(PointAngle))

			const InnerX = Numbers.F32(Numbers.F32(Numbers.F32(InnerCornerRadius[CornerIndex] * AngleCosine) * InnerScale[CornerIndex].X) + InnerCenters[CornerIndex].X)
			const InnerY = Numbers.F32(Numbers.F32(Numbers.F32(InnerCornerRadius[CornerIndex] * AngleSine) * InnerScale[CornerIndex].Y) + InnerCenters[CornerIndex].Y)
			const InnerSkewedX, InnerSkewedY = SkewPoint(InnerX, InnerY, SkewX, SkewY, CenterX, CenterY)

			AppendVertex(Mesh, InnerSkewedX, InnerSkewedY, InnerColor)

			if DrawBorder then
				const OuterX = Numbers.F32(Numbers.F32(Numbers.F32(RingCornerRadius[CornerIndex] * AngleCosine) * RingScale[CornerIndex].X) + OuterCenters[CornerIndex].X)
				const OuterY = Numbers.F32(Numbers.F32(Numbers.F32(RingCornerRadius[CornerIndex] * AngleSine) * RingScale[CornerIndex].Y) + OuterCenters[CornerIndex].Y)
				const OuterSkewedX, OuterSkewedY = SkewPoint(OuterX, OuterY, SkewX, SkewY, CenterX, CenterY)

				AppendVertex(Mesh, OuterSkewedX, OuterSkewedY, OuterColor)
			end
		end
	end

	const RingVertCount = Mesh.Count - VertOffset

	if DrawBorder then
		for Index = 0, RingVertCount - 1 do
			table.insert(Mesh.Indices, VertOffset + Index % RingVertCount)
			table.insert(Mesh.Indices, VertOffset + (Index + 2) % RingVertCount)
			table.insert(Mesh.Indices, VertOffset + (Index + 1) % RingVertCount)
		end
	end

	if IsFilled then
		-- Vertical stripes of two triangles each.
		const StripesCount = RingVertCount // 2 - 1
		const LastVertId = RingVertCount - 1

		for Stripe = 0, StripesCount - 1 do
			table.insert(Mesh.Indices, VertOffset + Stripe)
			table.insert(Mesh.Indices, VertOffset + LastVertId - Stripe - 1)
			table.insert(Mesh.Indices, VertOffset + Stripe + 1)
			table.insert(Mesh.Indices, VertOffset + Stripe)
			table.insert(Mesh.Indices, VertOffset + LastVertId - Stripe)
			table.insert(Mesh.Indices, VertOffset + LastVertId - Stripe - 1)
		end
	end
end

-- StyleBoxFlat::draw: the triangles for the control rect Canvas (the StyleRect is Canvas grown by the expand margins).
-- @src engine/resources/style_box_flat.cpp:draw L459-647
const function Draw(Style: Style, Canvas: Rect, Mesh: Mesh)
	const BorderWidth = Style.BorderWidth
	const DrawBorder = BorderWidth[SideLeft] > 0 or BorderWidth[SideTop] > 0 or BorderWidth[SideRight] > 0 or BorderWidth[SideBottom] > 0
	const DrawShadow = Style.ShadowSize > 0

	if not DrawBorder and not Style.DrawCenter and not DrawShadow then
		return
	end

	const ExpandMargin = Style.ExpandMargin
	const StyleRect = GrowIndividual(Canvas, ExpandMargin[SideLeft], ExpandMargin[SideTop], ExpandMargin[SideRight], ExpandMargin[SideBottom])

	if IsZeroApprox(StyleRect.W) or IsZeroApprox(StyleRect.H) then
		return
	end

	const CornerRadius = Style.CornerRadius
	const RoundedCorners = CornerRadius[CornerTopLeft] > 0 or CornerRadius[CornerTopRight] > 0 or CornerRadius[CornerBottomRight] > 0 or CornerRadius[CornerBottomLeft] > 0
	const SkewIsZero = IsZeroApprox(Style.SkewX) and IsZeroApprox(Style.SkewY)

	-- Anti-aliasing only where it is needed: rounded corners or a skew.
	const AaOn = (RoundedCorners or not SkewIsZero) and Style.AntiAliased
	const BlendOn = Style.BorderBlend and DrawBorder
	const CornerDetail = Style.CornerDetail
	const SkewX = Style.SkewX
	const SkewY = Style.SkewY

	const BgColor = Style.BgColor
	const BorderColor = Style.BorderColor
	const BorderColorAlpha = { R = BorderColor.R, G = BorderColor.G, B = BorderColor.B, A = 0 }
	const BorderColorBlend = if Style.DrawCenter then BgColor else BorderColorAlpha
	const BorderColorInner = if BlendOn then BorderColorBlend else BorderColor

	-- Adapt borders (prevent weird overlapping/glitchy drawings).
	const Width = Maximum(StyleRect.W, 0)
	const Height = Maximum(StyleRect.H, 0)
	const AdaptedBorder = NewQuad(UnboundedAdaptation)

	AdaptValues(SideTop, SideBottom, AdaptedBorder, BorderWidth, Height, Height, Height)
	AdaptValues(SideLeft, SideRight, AdaptedBorder, BorderWidth, Width, Width, Width)

	-- Adapt corners (prevent weird overlapping/glitchy drawings).
	const AdaptedCorner = NewQuad(UnboundedAdaptation)
	const BottomLimit = Numbers.F32(Height - AdaptedBorder[SideBottom])
	const TopLimit = Numbers.F32(Height - AdaptedBorder[SideTop])
	const RightLimit = Numbers.F32(Width - AdaptedBorder[SideRight])
	const LeftLimit = Numbers.F32(Width - AdaptedBorder[SideLeft])

	AdaptValues(CornerTopRight, CornerBottomRight, AdaptedCorner, CornerRadius, Height, BottomLimit, TopLimit)
	AdaptValues(CornerTopLeft, CornerBottomLeft, AdaptedCorner, CornerRadius, Height, BottomLimit, TopLimit)
	AdaptValues(CornerTopLeft, CornerTopRight, AdaptedCorner, CornerRadius, Width, RightLimit, LeftLimit)
	AdaptValues(CornerBottomLeft, CornerBottomRight, AdaptedCorner, CornerRadius, Width, RightLimit, LeftLimit)

	const InfillRect = GrowIndividual(StyleRect, -AdaptedBorder[SideLeft], -AdaptedBorder[SideTop], -AdaptedBorder[SideRight], -AdaptedBorder[SideBottom])

	local BorderStyleRect = StyleRect

	-- Oversampling is 1, so the feather is the anti-aliasing size itself.
	local AaSizeScaled = 1

	if AaOn then
		AaSizeScaled = Style.AntiAliasingSize
	end

	if AaOn then
		for Side = SideLeft, SideBottom do
			if BorderWidth[Side] > 0 then
				BorderStyleRect = GrowSide(BorderStyleRect, Side, -AaSizeScaled)
			end
		end
	end

	-- Shadow.
	if DrawShadow then
		const ShadowOffsetX = Style.ShadowOffsetX
		const ShadowOffsetY = Style.ShadowOffsetY
		const ShadowSize = Style.ShadowSize
		const ShadowColor = Style.ShadowColor
		const ShadowColorTransparent = { R = ShadowColor.R, G = ShadowColor.G, B = ShadowColor.B, A = 0 }
		const ShadowInnerRect = {
			X = Numbers.F32(StyleRect.X + ShadowOffsetX),
			Y = Numbers.F32(StyleRect.Y + ShadowOffsetY),
			W = StyleRect.W,
			H = StyleRect.H,
		}
		const ShadowGrown = GrowIndividual(StyleRect, ShadowSize, ShadowSize, ShadowSize, ShadowSize)
		const ShadowRect = {
			X = Numbers.F32(ShadowGrown.X + ShadowOffsetX),
			Y = Numbers.F32(ShadowGrown.Y + ShadowOffsetY),
			W = ShadowGrown.W,
			H = ShadowGrown.H,
		}

		DrawRoundedRectangle(Mesh, ShadowInnerRect, AdaptedCorner, ShadowRect, ShadowInnerRect, ShadowColor, ShadowColorTransparent, CornerDetail, SkewX, SkewY, false)

		if Style.DrawCenter then
			DrawRoundedRectangle(Mesh, ShadowInnerRect, AdaptedCorner, ShadowInnerRect, ShadowInnerRect, ShadowColor, ShadowColor, CornerDetail, SkewX, SkewY, true)
		end
	end

	-- Border (no anti-aliasing).
	if DrawBorder and not AaOn then
		DrawRoundedRectangle(Mesh, BorderStyleRect, AdaptedCorner, BorderStyleRect, InfillRect, BorderColorInner, BorderColor, CornerDetail, SkewX, SkewY, false)
	end

	-- Infill (no anti-aliasing).
	if Style.DrawCenter and (not AaOn or BlendOn) then
		DrawRoundedRectangle(Mesh, BorderStyleRect, AdaptedCorner, InfillRect, InfillRect, BgColor, BgColor, CornerDetail, SkewX, SkewY, true)
	end

	if AaOn then
		const AaBorderWidth = NewQuad(0)
		const AaBorderHalf = NewQuad(0)
		const AaFillWidth = NewQuad(0)
		const AaFillHalf = NewQuad(0)

		for Side = SideLeft, SideBottom do
			const IsBorder = DrawBorder and BorderWidth[Side] > 0

			AaBorderWidth[Side] = if IsBorder then AaSizeScaled else 0
			AaBorderHalf[Side] = if IsBorder then Numbers.F32(AaSizeScaled * 0.5) else 0
			AaFillWidth[Side] = if IsBorder then 0 else AaSizeScaled
			AaFillHalf[Side] = if IsBorder then 0 else Numbers.F32(AaSizeScaled * 0.5)
		end

		if Style.DrawCenter then
			-- Transparent side of the feather: the infill grown by half the feather; colored side: shrunk by the feather.
			const InfillAaTransparent = GrowIndividual(InfillRect, AaFillHalf[SideLeft], AaFillHalf[SideTop], AaFillHalf[SideRight], AaFillHalf[SideBottom])
			const InfillAaColored = GrowIndividual(InfillAaTransparent, -AaFillWidth[SideLeft], -AaFillWidth[SideTop], -AaFillWidth[SideRight], -AaFillWidth[SideBottom])

			if not BlendOn then
				DrawRoundedRectangle(Mesh, BorderStyleRect, AdaptedCorner, InfillAaColored, InfillAaColored, BgColor, BgColor, CornerDetail, SkewX, SkewY, true)
			end

			if not BlendOn or not DrawBorder then
				const AlphaBg = { R = BgColor.R, G = BgColor.G, B = BgColor.B, A = 0 }

				DrawRoundedRectangle(Mesh, BorderStyleRect, AdaptedCorner, InfillAaTransparent, InfillAaColored, BgColor, AlphaBg, CornerDetail, SkewX, SkewY, false)
			end
		end

		if DrawBorder then
			const InnerAaColored = GrowIndividual(InfillRect, AaBorderHalf[SideLeft], AaBorderHalf[SideTop], AaBorderHalf[SideRight], AaBorderHalf[SideBottom])
			const InnerAaTransparent = GrowIndividual(InnerAaColored, -AaBorderWidth[SideLeft], -AaBorderWidth[SideTop], -AaBorderWidth[SideRight], -AaBorderWidth[SideBottom])
			const OuterAaTransparent = GrowIndividual(StyleRect, AaBorderHalf[SideLeft], AaBorderHalf[SideTop], AaBorderHalf[SideRight], AaBorderHalf[SideBottom])
			const OuterAaColored = GrowIndividual(BorderStyleRect, AaBorderHalf[SideLeft], AaBorderHalf[SideTop], AaBorderHalf[SideRight], AaBorderHalf[SideBottom])

			DrawRoundedRectangle(Mesh, BorderStyleRect, AdaptedCorner, OuterAaColored, if BlendOn then InfillRect else InnerAaColored, BorderColorInner, BorderColor, CornerDetail, SkewX, SkewY, false)

			if not BlendOn then
				DrawRoundedRectangle(Mesh, BorderStyleRect, AdaptedCorner, InnerAaColored, InnerAaTransparent, BorderColorBlend, BorderColor, CornerDetail, SkewX, SkewY, false)
			end

			DrawRoundedRectangle(Mesh, BorderStyleRect, AdaptedCorner, OuterAaTransparent, OuterAaColored, BorderColor, BorderColorAlpha, CornerDetail, SkewX, SkewY, false)
		end
	end
end

-- StyleBoxFlat::get_draw_rect: the rect grown by the expand margins, and merged with the shadow.
-- @src engine/resources/style_box_flat.cpp:get_draw_rect L447-457
const function DrawRectOf(Style: Style, Area: Rect): Rect
	const ExpandMargin = Style.ExpandMargin
	local DrawArea = GrowIndividual(Area, ExpandMargin[SideLeft], ExpandMargin[SideTop], ExpandMargin[SideRight], ExpandMargin[SideBottom])

	if Style.ShadowSize > 0 then
		const ShadowArea = GrowIndividual(DrawArea, Style.ShadowSize, Style.ShadowSize, Style.ShadowSize, Style.ShadowSize)
		const ShadowRect = {
			X = Numbers.F32(ShadowArea.X + Style.ShadowOffsetX),
			Y = Numbers.F32(ShadowArea.Y + Style.ShadowOffsetY),
			W = ShadowArea.W,
			H = ShadowArea.H,
		}

		DrawArea = Merge(DrawArea, ShadowRect)
	end

	return DrawArea
end

-- Property reading. Absent properties take Godot's defaults; present ones are float32 like the Godot resource values.
const function ReadNumber(Properties: { [string]: unknown }, Name: string, Default: number): number
	const Value = Properties[Name] :: number?

	if Value == nil then
		return Default
	end

	return Numbers.F32(Value)
end

const function ReadFlag(Properties: { [string]: unknown }, Name: string, Default: boolean): boolean
	const Value = Properties[Name] :: boolean?

	if Value == nil then
		return Default
	end

	return Value
end

const function ReadColor(Properties: { [string]: unknown }, Name: string, Default: Color): Color
	const Value = Properties[Name] :: { Color: { number } }?

	if Value == nil then
		return Default
	end

	return {
		R = Numbers.F32(Value.Color[1]),
		G = Numbers.F32(Value.Color[2]),
		B = Numbers.F32(Value.Color[3]),
		A = Numbers.F32(Value.Color[4]),
	}
end

const function ReadVector(Properties: { [string]: unknown }, Name: string): (number, number)
	const Value = Properties[Name] :: { Vector2: { number } }?

	if Value == nil then
		return 0, 0
	end

	return Numbers.F32(Value.Vector2[1]), Numbers.F32(Value.Vector2[2])
end

-- @src engine/resources/style_box_flat.cpp:set_corner_detail L132-135
const function ClampCornerDetail(Value: number): number
	return math.clamp(Value, 1, 20)
end

-- @src engine/resources/style_box_flat.cpp:set_aa_size L222-225
const function ClampAntiAliasingSize(Value: number): number
	return Numbers.F32(math.clamp(Value, 0.01, 10))
end

const function Resolve(Properties: { [string]: unknown }): Style
	const SkewX, SkewY = ReadVector(Properties, "skew")
	const ShadowOffsetX, ShadowOffsetY = ReadVector(Properties, "shadow_offset")

	return {
		BgColor = ReadColor(Properties, "bg_color", { R = Numbers.F32(0.6), G = Numbers.F32(0.6), B = Numbers.F32(0.6), A = 1 }),
		BorderColor = ReadColor(Properties, "border_color", { R = Numbers.F32(0.8), G = Numbers.F32(0.8), B = Numbers.F32(0.8), A = 1 }),
		ShadowColor = ReadColor(Properties, "shadow_color", { R = 0, G = 0, B = 0, A = Numbers.F32(0.6) }),
		BorderWidth = {
				[SideLeft] = ReadNumber(Properties, "border_width_left", 0),
				[SideTop] = ReadNumber(Properties, "border_width_top", 0),
				[SideRight] = ReadNumber(Properties, "border_width_right", 0),
				[SideBottom] = ReadNumber(Properties, "border_width_bottom", 0),
			},
		CornerRadius = {
				[CornerTopLeft] = ReadNumber(Properties, "corner_radius_top_left", 0),
				[CornerTopRight] = ReadNumber(Properties, "corner_radius_top_right", 0),
				[CornerBottomRight] = ReadNumber(Properties, "corner_radius_bottom_right", 0),
				[CornerBottomLeft] = ReadNumber(Properties, "corner_radius_bottom_left", 0),
			},
		ExpandMargin = {
				[SideLeft] = ReadNumber(Properties, "expand_margin_left", 0),
				[SideTop] = ReadNumber(Properties, "expand_margin_top", 0),
				[SideRight] = ReadNumber(Properties, "expand_margin_right", 0),
				[SideBottom] = ReadNumber(Properties, "expand_margin_bottom", 0),
			},
		CornerDetail = ClampCornerDetail(ReadNumber(Properties, "corner_detail", 8)),
		DrawCenter = ReadFlag(Properties, "draw_center", true),
		BorderBlend = ReadFlag(Properties, "border_blend", false),
		AntiAliased = ReadFlag(Properties, "anti_aliasing", true),
		AntiAliasingSize = ClampAntiAliasingSize(ReadNumber(Properties, "anti_aliasing_size", 1)),
		SkewX = SkewX,
		SkewY = SkewY,
		ShadowSize = ReadNumber(Properties, "shadow_size", 0),
		ShadowOffsetX = ShadowOffsetX,
		ShadowOffsetY = ShadowOffsetY,
	}
end

const function NewMesh(): Mesh
	return { Points = {}, Colors = {}, Indices = {}, Count = 0 }
end

const function BuildMesh(Style: Style, Width: number, Height: number): Mesh
	const Mesh = NewMesh()

	Draw(Style, { X = 0, Y = 0, W = Width, H = Height }, Mesh)

	return Mesh
end

-- Rasterization. A pixel is covered when its center is inside the triangle, with the top-left rule on the edges.
-- An edge P -> Q of a counter-clockwise triangle (positive area, y down) is top-left when it runs up, or runs right
-- along the top.
const function IsTopLeft(DeltaX: number, DeltaY: number): boolean
	return DeltaY < 0 or (DeltaY == 0 and DeltaX > 0)
end

const function Covers(Weight: number, TopLeft: boolean): boolean
	return Weight > 0 or (Weight == 0 and TopLeft)
end

-- Premultiplied "over" of one triangle onto the raster, interpolating the vertex colors barycentrically.
const function PaintTriangle(Raster: Raster, Mesh: Mesh, Triangle: number)
	const Points = Mesh.Points
	const Colors = Mesh.Colors
	const First = Mesh.Indices[3 * Triangle + 1]
	local Second = Mesh.Indices[3 * Triangle + 2]
	local Third = Mesh.Indices[3 * Triangle + 3]

	-- A transparent triangle leaves the raster unchanged.
	if Colors[4 * First + 4] <= 0 and Colors[4 * Second + 4] <= 0 and Colors[4 * Third + 4] <= 0 then
		return
	end

	const Ax = Points[2 * First + 1] - Raster.OffsetX
	const Ay = Points[2 * First + 2] - Raster.OffsetY
	local Bx = Points[2 * Second + 1] - Raster.OffsetX
	local By = Points[2 * Second + 2] - Raster.OffsetY
	local Cx = Points[2 * Third + 1] - Raster.OffsetX
	local Cy = Points[2 * Third + 2] - Raster.OffsetY

	local Area = (Bx - Ax) * (Cy - Ay) - (By - Ay) * (Cx - Ax)

	if Area == 0 then
		return
	end

	-- Both windings are drawn; the edge tests use the counter-clockwise order.
	if Area < 0 then
		Second, Third = Third, Second
		Bx, Cx = Cx, Bx
		By, Cy = Cy, By
		Area = -Area
	end

	-- Weight of A is the edge B -> C, of B the edge C -> A, of C the edge A -> B.
	const DeltaAX = Cx - Bx
	const DeltaAY = Cy - By
	const DeltaBX = Ax - Cx
	const DeltaBY = Ay - Cy
	const DeltaCX = Bx - Ax
	const DeltaCY = By - Ay
	const TopLeftA = IsTopLeft(DeltaAX, DeltaAY)
	const TopLeftB = IsTopLeft(DeltaBX, DeltaBY)
	const TopLeftC = IsTopLeft(DeltaCX, DeltaCY)

	const FirstColumn = Maximum(math.ceil(Minimum(Minimum(Ax, Bx), Cx) - 0.5), 0)
	const LastColumn = Minimum((Maximum(Maximum(Ax, Bx), Cx) - 0.5) // 1, Raster.Width - 1)
	const FirstRow = Maximum(math.ceil(Minimum(Minimum(Ay, By), Cy) - 0.5), 0)
	const LastRow = Minimum((Maximum(Maximum(Ay, By), Cy) - 0.5) // 1, Raster.Height - 1)

	const RedA = Colors[4 * First + 1]
	const GreenA = Colors[4 * First + 2]
	const BlueA = Colors[4 * First + 3]
	const AlphaA = Colors[4 * First + 4]
	const RedB = Colors[4 * Second + 1]
	const GreenB = Colors[4 * Second + 2]
	const BlueB = Colors[4 * Second + 3]
	const AlphaB = Colors[4 * Second + 4]
	const RedC = Colors[4 * Third + 1]
	const GreenC = Colors[4 * Third + 2]
	const BlueC = Colors[4 * Third + 3]
	const AlphaC = Colors[4 * Third + 4]

	const Accumulator = Raster.Accumulator
	const Width = Raster.Width

	for Row = FirstRow, LastRow do
		const PixelY = Row + 0.5

		for Column = FirstColumn, LastColumn do
			const PixelX = Column + 0.5
			const WeightA = DeltaAX * (PixelY - By) - DeltaAY * (PixelX - Bx)
			const WeightB = DeltaBX * (PixelY - Cy) - DeltaBY * (PixelX - Cx)
			const WeightC = DeltaCX * (PixelY - Ay) - DeltaCY * (PixelX - Ax)

			if Covers(WeightA, TopLeftA) and Covers(WeightB, TopLeftB) and Covers(WeightC, TopLeftC) then
				const LambdaA = WeightA / Area
				const LambdaB = WeightB / Area
				const LambdaC = WeightC / Area
				const Alpha = LambdaA * AlphaA + LambdaB * AlphaB + LambdaC * AlphaC

				if Alpha > 0 then
					const Red = LambdaA * RedA + LambdaB * RedB + LambdaC * RedC
					const Green = LambdaA * GreenA + LambdaB * GreenB + LambdaC * GreenC
					const Blue = LambdaA * BlueA + LambdaB * BlueB + LambdaC * BlueC
					const Base = (Row * Width + Column) * 4 + 1
					const Keep = 1 - Alpha

					Accumulator[Base] = Red * Alpha + Accumulator[Base] * Keep
					Accumulator[Base + 1] = Green * Alpha + Accumulator[Base + 1] * Keep
					Accumulator[Base + 2] = Blue * Alpha + Accumulator[Base + 2] * Keep
					Accumulator[Base + 3] = Alpha + Accumulator[Base + 3] * Keep
				end
			end
		end
	end
end

const function ToByte(Value: number): number
	return math.clamp((Value * 255 + 0.5) // 1, 0, 255)
end

-- The triangles to RGBA8: the image covers every vertex, rounded outwards to whole pixels.
const function Rasterize(Mesh: Mesh): Image
	if Mesh.Count == 0 then
		return { Pixels = buffer.create(0), Width = 0, Height = 0, OffsetX = 0, OffsetY = 0 }
	end

	local MinX = math.huge
	local MinY = math.huge
	local MaxX = -math.huge
	local MaxY = -math.huge

	for Vertex = 0, Mesh.Count - 1 do
		const X = Mesh.Points[2 * Vertex + 1]
		const Y = Mesh.Points[2 * Vertex + 2]

		MinX = Minimum(MinX, X)
		MinY = Minimum(MinY, Y)
		MaxX = Maximum(MaxX, X)
		MaxY = Maximum(MaxY, Y)
	end

	const OffsetX = MinX // 1
	const OffsetY = MinY // 1
	const Width = math.ceil(MaxX) - OffsetX
	const Height = math.ceil(MaxY) - OffsetY
	const Raster = {
		Accumulator = table.create(Width * Height * 4, 0),
		Width = Width,
		Height = Height,
		OffsetX = OffsetX,
		OffsetY = OffsetY,
	}

	for Triangle = 0, #Mesh.Indices // 3 - 1 do
		PaintTriangle(Raster, Mesh, Triangle)
	end

	const Pixels = buffer.create(Width * Height * 4)
	const Accumulator = Raster.Accumulator

	for Pixel = 0, Width * Height - 1 do
		const Base = Pixel * 4 + 1
		const Alpha = Accumulator[Base + 3]

		if Alpha > 0 then
			buffer.writeu8(Pixels, Pixel * 4, ToByte(Accumulator[Base] / Alpha))
			buffer.writeu8(Pixels, Pixel * 4 + 1, ToByte(Accumulator[Base + 1] / Alpha))
			buffer.writeu8(Pixels, Pixel * 4 + 2, ToByte(Accumulator[Base + 2] / Alpha))
		end

		buffer.writeu8(Pixels, Pixel * 4 + 3, ToByte(Alpha))
	end

	return { Pixels = Pixels, Width = Width, Height = Height, OffsetX = OffsetX, OffsetY = OffsetY }
end

-- Cache key of everything that changes the pixels: the resolved style and the modulate (none means white).
const function KeyOf(Style: Style, Modulate: { number }?): string
	const Values = {
		Style.BgColor.R,
		Style.BgColor.G,
		Style.BgColor.B,
		Style.BgColor.A,
		Style.BorderColor.R,
		Style.BorderColor.G,
		Style.BorderColor.B,
		Style.BorderColor.A,
		Style.ShadowColor.R,
		Style.ShadowColor.G,
		Style.ShadowColor.B,
		Style.ShadowColor.A,
		Style.BorderWidth[SideLeft],
		Style.BorderWidth[SideTop],
		Style.BorderWidth[SideRight],
		Style.BorderWidth[SideBottom],
		Style.CornerRadius[CornerTopLeft],
		Style.CornerRadius[CornerTopRight],
		Style.CornerRadius[CornerBottomRight],
		Style.CornerRadius[CornerBottomLeft],
		Style.ExpandMargin[SideLeft],
		Style.ExpandMargin[SideTop],
		Style.ExpandMargin[SideRight],
		Style.ExpandMargin[SideBottom],
		Style.CornerDetail,
		Flag(Style.DrawCenter),
		Flag(Style.BorderBlend),
		Flag(Style.AntiAliased),
		Style.AntiAliasingSize,
		Style.SkewX,
		Style.SkewY,
		Style.ShadowSize,
		Style.ShadowOffsetX,
		Style.ShadowOffsetY,
	}

	for Channel = 1, 4 do
		table.insert(Values, if Modulate ~= nil then Modulate[Channel] else 1)
	end

	const Parts: { string } = {}

	for Index = 1, #Values do
		table.insert(Parts, string.format("%.17g", Values[Index]))
	end

	return table.concat(Parts, " ")
end

-- Slice bound: every size threshold of the drawing is a sum of radii, borders, margins, shadow and feather terms.
const function SliceBound(Style: Style): number
	local Total = Style.AntiAliasingSize + 2 * Style.ShadowSize + math.abs(Style.ShadowOffsetX) + math.abs(Style.ShadowOffsetY) + 1

	for Side = SideLeft, SideBottom do
		Total += Style.BorderWidth[Side] + math.abs(Style.ExpandMargin[Side]) + Style.CornerRadius[Side]
	end

	return math.ceil(4 * Total) + 16
end

-- Whether a drawing equals the reference with its right (bottom) vertices moved by ShiftX (ShiftY).
const function Translated(Mesh: Mesh, Reference: Mesh, RightOf: { boolean }, BelowOf: { boolean }, ShiftX: number, ShiftY: number): boolean
	if Mesh.Count ~= Reference.Count then
		return false
	end

	for Vertex = 0, Reference.Count - 1 do
		const ExpectedX = Reference.Points[2 * Vertex + 1] + (if RightOf[Vertex] then ShiftX else 0)
		const ExpectedY = Reference.Points[2 * Vertex + 2] + (if BelowOf[Vertex] then ShiftY else 0)

		if math.abs(Mesh.Points[2 * Vertex + 1] - ExpectedX) > TranslationTolerance or math.abs(Mesh.Points[2 * Vertex + 2] - ExpectedY) > TranslationTolerance then
			return false
		end
	end

	return true
end

-- Smallest size in one direction from which the drawing only translates (monotone in the size: binary search).
const function SaturationStart(Style: Style, Bound: number, Reference: Mesh, RightOf: { boolean }, BelowOf: { boolean }, IsX: boolean): number
	local Low = 1
	local High = Bound

	while Low < High do
		const Middle = (Low + High) // 2
		const Shift = Middle - Bound
		const Candidate = if IsX then BuildMesh(Style, Middle, Bound) else BuildMesh(Style, Bound, Middle)
		const Matches = if IsX then Translated(Candidate, Reference, RightOf, BelowOf, Shift, 0) else Translated(Candidate, Reference, RightOf, BelowOf, 0, Shift)

		if Matches then
			High = Middle
		else
			Low = Middle + 1
		end
	end

	return Low
end

const function ComputeSlice(Style: Style): Slice
	const Unsliceable = { Sliceable = false, SizeX = 0, SizeY = 0, Left = 0, Top = 0 }

	if Style.SkewX ~= 0 or Style.SkewY ~= 0 then
		return Unsliceable
	end

	const Bound = SliceBound(Style)
	const Reference = BuildMesh(Style, Bound, Bound)
	const WidthStep = BuildMesh(Style, Bound + 1, Bound)
	const HeightStep = BuildMesh(Style, Bound, Bound + 1)

	if Reference.Count == 0 or WidthStep.Count ~= Reference.Count or HeightStep.Count ~= Reference.Count then
		return Unsliceable
	end

	-- A vertex belongs to the right (bottom) structure when it moves with that edge.
	const RightOf: { boolean } = {}
	const BelowOf: { boolean } = {}

	for Vertex = 0, Reference.Count - 1 do
		RightOf[Vertex] = WidthStep.Points[2 * Vertex + 1] - Reference.Points[2 * Vertex + 1] > 0.5
		BelowOf[Vertex] = HeightStep.Points[2 * Vertex + 2] - Reference.Points[2 * Vertex + 2] > 0.5
	end

	const StartX = SaturationStart(Style, Bound, Reference, RightOf, BelowOf, true)
	const StartY = SaturationStart(Style, Bound, Reference, RightOf, BelowOf, false)

	local LeftExtent = 0
	local TopExtent = 0
	local RightExtent = 0
	local BottomExtent = 0

	for Vertex = 0, Reference.Count - 1 do
		const X = Reference.Points[2 * Vertex + 1]
		const Y = Reference.Points[2 * Vertex + 2]

		if RightOf[Vertex] then
			RightExtent = Maximum(RightExtent, Bound - X)
		else
			LeftExtent = Maximum(LeftExtent, X)
		end

		if BelowOf[Vertex] then
			BottomExtent = Maximum(BottomExtent, Bound - Y)
		else
			TopExtent = Maximum(TopExtent, Y)
		end
	end

	const Left = math.ceil(LeftExtent)
	const Top = math.ceil(TopExtent)

	-- At least one stretchable pixel between the fixed left/top and right/bottom structure.
	return {
		Sliceable = true,
		SizeX = Maximum(StartX, Left + math.ceil(RightExtent) + 1),
		SizeY = Maximum(StartY, Top + math.ceil(BottomExtent) + 1),
		Left = Left,
		Top = Top,
	}
end

const SliceCache: { [string]: Slice } = {}

const function SliceOf(Style: Style): Slice
	const CacheKey = KeyOf(Style, nil)
	const Cached = SliceCache[CacheKey]

	if Cached ~= nil then
		return Cached
	end

	const Computed = ComputeSlice(Style)

	SliceCache[CacheKey] = Computed

	return Computed
end

-- The canvas_item_add_triangle_array input of draw() for a control of this size, in control pixels.
const function Triangles(Properties: { [string]: unknown }, Width: number, Height: number): Mesh
	return BuildMesh(Resolve(Properties), Width, Height)
end

-- Pixels of the drawing for a control of this size; Modulate multiplies every vertex color (as the canvas item does).
const function Render(Properties: { [string]: unknown }, Width: number, Height: number, Modulate: { number }?): Image
	const Mesh = BuildMesh(Resolve(Properties), Width, Height)

	if Modulate ~= nil then
		for Index = 1, #Mesh.Colors do
			Mesh.Colors[Index] = Numbers.F32(Mesh.Colors[Index] * Modulate[(Index - 1) % 4 + 1])
		end
	end

	return Rasterize(Mesh)
end

const function Key(Properties: { [string]: unknown }, Modulate: { number }?): string
	return KeyOf(Resolve(Properties), Modulate)
end

const function GetDrawRect(Properties: { [string]: unknown }, Width: number, Height: number): Rect
	return DrawRectOf(Resolve(Properties), { X = 0, Y = 0, W = Width, H = Height })
end

-- The smallest control size the drawing 9-slices at (both axes), or nil, nil when it cannot (skew, or nothing drawn).
-- Render at that size, then stretch the column and row given by SliceCenter.
const function SliceSize(Properties: { [string]: unknown }): (number?, number?)
	const Result = SliceOf(Resolve(Properties))

	if not Result.Sliceable then
		return nil, nil
	end

	return Result.SizeX, Result.SizeY
end

-- The stretchable 1 px column and row of Image (rendered at SliceSize), in image pixels: x, y, width, height.
const function SliceCenter(Properties: { [string]: unknown }, Image: Image): (number, number, number, number)
	const Result = SliceOf(Resolve(Properties))

	return Result.Left - Image.OffsetX, Result.Top - Image.OffsetY, 1, 1
end

return {
	Triangles = Triangles,
	Render = Render,
	Key = Key,
	GetDrawRect = GetDrawRect,
	SliceSize = SliceSize,
	SliceCenter = SliceCenter,
}
