--!strict
--!optimize 2

--[[
	The note mesh (the skin's .obj, read as Godot's OBJ importer reads it): its triangles as an EditableMesh, made into a MeshPart
	that the note pool clones. The mesh is drawn unshaded (Neon) and as it is in Godot units: Place scales the part by the note's
	basis, so the mesh's own extents (the squircle's 2 x 2 x 0.25) are its size at scale 1.

	Design Notes
		Only positions and faces are used: the notes are unshaded and take their color per instance, so normals, texture
		coordinates and the material file do not change how they look. A face of more than three vertices is a fan.
		Both windings of each triangle are added, so the part is seen from either side whatever the importer's winding is.
		Load yields (CreateMeshPartAsync), so it runs on its own thread at the start of a run; the pool takes its parts from the
		part Load answers.
]]

const AssetService = game:GetService("AssetService")

const FileSystem = require("../../Util/FileSystem")
const MeshFiles = require("../../../AimiaData/Meshes")

-- The part made of an OBJ file's text, or nil when it has no triangle. Yields.
const function Build(Text: string): MeshPart?
	const Positions: { Vector3 } = {}
	const Triangles: { { number } } = {}

	for Line in string.gmatch(Text, "[^\r\n]+") do
		const X, Y, Z = string.match(Line, "^v%s+(%S+)%s+(%S+)%s+(%S+)")

		if X and Y and Z then
			table.insert(Positions, Vector3.xAxis * (tonumber(X) or 0) + Vector3.yAxis * (tonumber(Y) or 0) + Vector3.zAxis * (tonumber(Z) or 0))
		elseif string.sub(Line, 1, 2) == "f " then
			const Corners: { number } = {}

			for Reference in string.gmatch(Line, "%S+") do
				const Index = tonumber(string.match(Reference, "^(-?%d+)"))

				if Index then
					table.insert(Corners, if Index < 0 then #Positions + 1 + Index else Index)
				end
			end

			for Index = 2, #Corners - 1 do
				table.insert(Triangles, { Corners[1], Corners[Index], Corners[Index + 1] })
			end
		end
	end

	if #Triangles == 0 then
		return nil
	end

	const Mesh = AssetService:CreateEditableMesh()
	const Vertices: { number } = {}

	for Index, Position in Positions do
		Vertices[Index] = Mesh:AddVertex(Position)
	end

	for _, Corner in Triangles do
		Mesh:AddTriangle(Vertices[Corner[1]], Vertices[Corner[2]], Vertices[Corner[3]])
		Mesh:AddTriangle(Vertices[Corner[3]], Vertices[Corner[2]], Vertices[Corner[1]])
	end

	return AssetService:CreateMeshPartAsync(Content.fromObject(Mesh))
end

-- The part of a skin's note mesh path ("user/meshes/squircle.obj", or the default's "res://user/meshes/squircle.obj"). Yields.
const function Load(Path: string): MeshPart?
	const Name = string.match(Path, "[^/]*$") :: string
	const Text = if FileSystem.Exists(Path) then buffer.tostring(FileSystem.ReadAllBytes(Path)) else MeshFiles[Name]

	if Text == nil then
		return nil
	end

	return Build(Text)
end

return Load
