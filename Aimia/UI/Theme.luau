--!strict
--!optimize 2

--[[
	Godot theme item lookup over converted scene data (docs/port/ui.md), Roblox-free.

	Design Notes
		Order, as Godot's ThemeOwner: the node's own `theme_override_<kind>/<name>`; then each theme owner from the
		node up through its Control ancestors (a non-Control parent ends the chain), trying the node's type chain
		(theme_type_variation, then its class and base classes) in each owner's `theme`; then Godot's default theme
		(UI/DefaultTheme). Fonts and font sizes fall back to the nearest owner theme's `default_font` /
		`default_font_size`, then the default theme's.
		A value stays paired with the file it came from, because `SubResource` ids are local to a file and
		`ExtResource` paths resolve through the scene index (UI/SceneData).
]]

const DefaultTheme = require("./DefaultTheme")

export type File = {
	Path: string,
	Kind: string,
	External: { [string]: { Type: string, Path: string } },
	Resources: { [string]: { Type: string, Properties: { [string]: unknown } } },
	Resource: { [string]: unknown }?,
	Nodes: { { [string]: unknown } }?,
}

-- A resource and the file whose ids its properties use.
export type Resource = {
	Type: string,
	Path: string?,
	Properties: { [string]: unknown },
	File: File,
}

-- Files maps a property key to the file it was written in when that differs from File (an instanced scene's
-- root properties overridden by the outer scene).
export type Context = {
	Class: string,
	IsControl: boolean,
	File: File,
	Files: { [string]: File },
	Properties: { [string]: unknown },
	Parent: Context?,
}

const Bases = {
	BaseButton = "Control",
	Button = "BaseButton",
	CheckBox = "Button",
	CheckButton = "Button",
	OptionButton = "Button",
	MenuButton = "Button",
	ColorPickerButton = "Button",
	LinkButton = "BaseButton",
	TextureButton = "BaseButton",
	Label = "Control",
	RichTextLabel = "Control",
	LineEdit = "Control",
	TextEdit = "Control",
	Panel = "Control",
	ColorRect = "Control",
	TextureRect = "Control",
	NinePatchRect = "Control",
	ReferenceRect = "Control",
	VideoStreamPlayer = "Control",
	Container = "Control",
	BoxContainer = "Container",
	HBoxContainer = "BoxContainer",
	VBoxContainer = "BoxContainer",
	FlowContainer = "Container",
	HFlowContainer = "FlowContainer",
	VFlowContainer = "FlowContainer",
	MarginContainer = "Container",
	PanelContainer = "Container",
	ScrollContainer = "Container",
	AspectRatioContainer = "Container",
	CenterContainer = "Container",
	GridContainer = "Container",
	SubViewportContainer = "Container",
	TabContainer = "Container",
	Range = "Control",
	Slider = "Range",
	HSlider = "Slider",
	VSlider = "Slider",
	ScrollBar = "Range",
	HScrollBar = "ScrollBar",
	VScrollBar = "ScrollBar",
	ProgressBar = "Range",
	TextureProgressBar = "Range",
	SpinBox = "Range",
	Separator = "Control",
	HSeparator = "Separator",
	VSeparator = "Separator",
	Window = "Viewport",
	Popup = "Window",
	PopupMenu = "Popup",
	PopupPanel = "Popup",
	AcceptDialog = "Window",
	ConfirmationDialog = "AcceptDialog",
	FileDialog = "ConfirmationDialog",
}

-- Theme item kinds (Godot's property segment) to the DefaultTheme groups.
const Groups = {
	["colors"] = "Colors",
	["constants"] = "Constants",
	["font_sizes"] = "FontSizes",
	["fonts"] = "Fonts",
	["styles"] = "StyleBoxes",
	["icons"] = "Icons",
}

const function FileOf(Context: Context, Key: string): File
	return Context.Files[Key] or Context.File
end

-- Whether a Godot class is a Control (its type chain reaches Control).
const function IsControlClass(Class: string): boolean
	local Current: string? = Class

	while Current do
		if Current == "Control" then
			return true
		end

		Current = (Bases :: { [string]: string })[Current]
	end

	return false
end

-- Resolves a property value that names a resource ({ Ext = id } or { Sub = id }) in its file.
const function ResolveResource(File: File, Value: unknown, Scenes: { [string]: File }): Resource?
	if type(Value) ~= "table" then
		return nil
	end

	const Reference = Value :: { Ext: string?, Sub: string? }

	if Reference.Sub then
		const Found = File.Resources[Reference.Sub]

		if not Found then
			return nil
		end

		return {
			Type = Found.Type,
			Properties = Found.Properties,
			File = File,
		}
	elseif Reference.Ext then
		const External = File.External[Reference.Ext]

		if not External then
			return nil
		end

		const Converted = Scenes[External.Path]

		if Converted and Converted.Resource then
			return {
				Type = Converted.Kind,
				Path = External.Path,
				Properties = Converted.Resource,
				File = Converted,
			}
		end

		return {
			Type = External.Type,
			Path = External.Path,
			Properties = {},
			File = File,
		}
	end

	return nil
end

const function TypeChain(Context: Context): { string }
	const Chain: { string } = {}
	const Variation = Context.Properties["theme_type_variation"]

	if type(Variation) == "string" and #Variation > 0 then
		table.insert(Chain, Variation)
	end

	local Class: string? = Context.Class

	while Class do
		table.insert(Chain, Class)
		Class = (Bases :: { [string]: string })[Class]
	end

	return Chain
end

-- Memos for GetItem, which runs thousands of times whenever a menu lays out: remaking the same key strings, type chains and
-- theme resources on every call was most of the stutter when a song is picked (2026-11-07). Everything memoized comes from
-- fixed data (class names, the converted scene files) or is keyed by the property value itself, so a changed property
-- (a new theme_type_variation string, a new theme table) is simply a new key.
const OverrideKeys: { [string]: { [string]: string } } = {}
const ItemKeys: { [string]: { [string]: { [string]: string } } } = {}
const Chains: { [string]: { [string]: { string } } } = {}
const ThemeMemo: { [any]: any } = setmetatable({}, { __mode = "k" }) :: any

const function OverrideKeyOf(Kind: string, Name: string): string
	local ByKind = OverrideKeys[Kind]

	if ByKind == nil then
		ByKind = {}
		OverrideKeys[Kind] = ByKind
	end

	local Key = ByKind[Name]

	if Key == nil then
		Key = `theme_override_{Kind}/{Name}`
		ByKind[Name] = Key
	end

	return Key
end

const function ItemKeyOf(Type: string, Kind: string, Name: string): string
	local ByType = ItemKeys[Type]

	if ByType == nil then
		ByType = {}
		ItemKeys[Type] = ByType
	end

	local ByKind = ByType[Kind]

	if ByKind == nil then
		ByKind = {}
		ByType[Kind] = ByKind
	end

	local Key = ByKind[Name]

	if Key == nil then
		Key = `{Type}/{Kind}/{Name}`
		ByKind[Name] = Key
	end

	return Key
end

-- TypeChain, shared between calls (read only: TypeChain itself still hands out a fresh table)
const function ChainOf(Context: Context): { string }
	const Variation = Context.Properties["theme_type_variation"]
	const VariationKey = if type(Variation) == "string" then Variation else ""
	local ByClass = Chains[Context.Class]

	if ByClass == nil then
		ByClass = {}
		Chains[Context.Class] = ByClass
	end

	local Chain = ByClass[VariationKey]

	if Chain == nil then
		Chain = TypeChain(Context)
		ByClass[VariationKey] = Chain
	end

	return Chain
end

-- A theme resource, resolved once per (scene index, file, property value): all three are fixed converted data.
const function ThemeResourceOf(File: File, Value: unknown, Scenes: { [string]: File }): Resource?
	if type(Value) ~= "table" then
		return nil
	end

	local ByScenes = ThemeMemo[Scenes]

	if ByScenes == nil then
		ByScenes = setmetatable({}, { __mode = "k" })
		ThemeMemo[Scenes] = ByScenes
	end

	local ByFile = ByScenes[File]

	if ByFile == nil then
		ByFile = setmetatable({}, { __mode = "k" })
		ByScenes[File] = ByFile
	end

	local Found = ByFile[Value]

	if Found == nil then
		Found = ResolveResource(File, Value, Scenes) or false
		ByFile[Value] = Found
	end

	return if Found then Found else nil
end

-- The owner themes from the node up, nearest first.
const function OwnerThemes(Context: Context, Scenes: { [string]: File }): { Resource }
	const Themes: { Resource } = {}
	local Current: Context? = Context

	while Current and Current.IsControl do
		const Theme = ThemeResourceOf(FileOf(Current, "theme"), Current.Properties["theme"], Scenes)

		if Theme then
			table.insert(Themes, Theme)
		end

		Current = Current.Parent
	end

	return Themes
end

-- Answers the item value and the file its references resolve in, or nil.
const function GetItem(Context: Context, Kind: string, Name: string, Scenes: { [string]: File }): (unknown, File?)
	const OverrideKey = OverrideKeyOf(Kind, Name)
	const Override = Context.Properties[OverrideKey]

	if Override ~= nil then
		return Override, FileOf(Context, OverrideKey)
	end

	const Chain = ChainOf(Context)
	const Themes = OwnerThemes(Context, Scenes)

	for _, Theme in Themes do
		for _, Type in Chain do
			const Value = Theme.Properties[ItemKeyOf(Type, Kind, Name)]

			if Value ~= nil then
				return Value, Theme.File
			end
		end
	end

	if Kind == "fonts" or Kind == "font_sizes" then
		const DefaultKey = if Kind == "fonts" then "default_font" else "default_font_size"

		for _, Theme in Themes do
			const Value = Theme.Properties[DefaultKey]

			if Value ~= nil then
				return Value, Theme.File
			end
		end
	end

	const Group = (Groups :: { [string]: string })[Kind]

	for _, Type in Chain do
		const Items = (DefaultTheme.Types :: { [string]: { [string]: { [string]: unknown } } })[Type]
		const Value = if Items and Group then Items[Group][Name] else nil

		if Value ~= nil then
			return Value, nil
		end
	end

	if Kind == "font_sizes" then
		return DefaultTheme.DefaultFontSize, nil
	end

	return nil, nil
end

return {
	FileOf = FileOf,
	IsControlClass = IsControlClass,
	ResolveResource = ResolveResource,
	TypeChain = TypeChain,
	GetItem = GetItem,
}
