local ACF		= ACF
local Clock		= ACF.Utilities.Clock
local Queued	= {}

include("shared.lua")

do	-- NET SURFER
	net.Receive("ACF_InvalidateTurretInfo", function()
		local Turret	= net.ReadEntity()

		if not IsValid(Turret) then return end

		Turret.HasData	= false
	end)

	net.Receive("ACF_RequestTurretInfo", function()
		local Entity	= net.ReadEntity()
		local Rotator	= net.ReadEntity()
		local Data		= {
			LocalCoM	= net.ReadVector(),
			Mass		= net.ReadFloat(),
			MinDeg		= net.ReadFloat(),
			MaxDeg		= net.ReadFloat(),
			CoMDist		= net.ReadFloat(),
			Type		= net.ReadString()
		}

		if not IsValid(Entity) then return end

		Entity.Rotator	= Rotator
		Entity.LocalCoM = Data.LocalCoM
		Entity.Mass		= Data.Mass
		Entity.MinDeg	= Data.MinDeg
		Entity.MaxDeg	= Data.MaxDeg
		Entity.CoMDist	= Data.CoMDist
		Entity.Type		= Data.Type

		local Arc = Data.MaxDeg - Data.MinDeg
		local HasArc	= Arc ~= 360

		Entity.HasArc	= HasArc
		if HasArc then
			local Fidelity = math.ceil(Arc / 15)
			local ArcPos = {}

			local Wedge = Arc / Fidelity
			for I = 0, Fidelity do
				local Ang = math.rad(Data.MinDeg + (Wedge * I))
				ArcPos[I] = Vector(math.cos(Ang), -math.sin(Ang), 0)
			end

			Entity.ArcPos	= ArcPos
			Entity.Fidelity	= Fidelity

			local MinRad	= math.rad(Data.MinDeg)
			Entity.MinPos	= Vector(math.cos(MinRad - math.rad(1)), -math.sin(MinRad - math.rad(1)), 0)
			Entity.MinPos2	= Vector(math.cos(MinRad), -math.sin(MinRad), 0)

			local MaxRad	= math.rad(Data.MaxDeg)
			Entity.MaxPos	= Vector(math.cos(MaxRad), -math.sin(MaxRad), 0)
			Entity.MaxPos2	= Vector(math.cos(MaxRad + math.rad(1)), -math.sin(MaxRad + math.rad(1)), 0)
		end

		Entity.HasData	= true
		Entity.Age		= Clock.CurTime + 5

		if Queued[Entity] then Queued[Entity] = nil end
	end)

	function ENT:RequestTurretInfo()
		if Queued[self] then return end

		Queued[self] = true

		timer.Simple(5, function() Queued[self] = nil end)

		net.Start("ACF_RequestTurretInfo")
			net.WriteEntity(self)
		net.SendToServer()
	end
end

do	-- Turret drive drawing
	local HideInfo = ACF.HideInfoBubble

	function ENT:Draw()
		-- Partial from base_wire_entity, need the tooltip but without the model drawing since we're drawing our own
		local LocalPly = LocalPlayer()
		local LookedAt = self:BeingLookedAtByLocalPlayer() and not LocalPly:InVehicle()

		if LookedAt then
			self:DrawEntityOutline()
		end

		local Rotator = self:GetNWEntity("ACF.Rotator")
		local RenderMatrix = self.Matrix

		if IsValid(Rotator) and RenderMatrix then
			RenderMatrix:SetAngles(self:WorldToLocalAngles(Rotator:GetAngles()))
			self:EnableMatrix("RenderMultiply", RenderMatrix)
		end

		self:DrawModel()

		if LookedAt and not HideInfo() then
			local Weapon = LocalPly:GetActiveWeapon()

			self:AddWorldTip()

			if (not LocalPly:InVehicle()) and (IsValid(Weapon) and Weapon:GetClass() == "weapon_physgun") then
				self:DrawHome()
			end
		end
	end
end

do	-- Overlay
	local red = Color(255, 0, 0)
	local green = Color(0, 255, 0)
	local orange = Color(255, 127, 0)
	local magenta = Color(255, 0, 255)
	local arcColor = Color(0, 255, 255, 128)
	local curColor = Color(125, 255, 0)
	local Mat	= Material("vgui/white")

	function ENT:DrawHome()
		if not self.HasData then
			self:RequestTurretInfo()

			return
		elseif Clock.CurTime > self.Age then
			self:RequestTurretInfo()
		end

		render.SetMaterial(Mat)

		local FWD = self:GetForward()
		local X = math.max(self:OBBMaxs().x, self:OBBMaxs().z)
		local UX = X / 10
		local LocPos = self:WorldToLocal(EyePos())

		local LocalRightDir = Vector(0, LocPos.y, LocPos.z):GetNormalized()
		LocalRightDir:Rotate(Angle(0, 0, 90))
		local WorldRightDir = self:LocalToWorld(LocalRightDir) - self:GetPos()

		if self.Type == "Turret-V" then
			X = self:OBBMaxs().z
		end

		local Pos = self:LocalToWorld(self:OBBCenter())
		local Origin = Pos + (FWD * X * 1.1)

		render.DrawQuad(Pos, Pos, Pos + (FWD * X * 1.1) + (WorldRightDir * -UX / 4), Pos + (FWD * X * 1.1) + (WorldRightDir * UX / 4), orange)
		render.DrawQuad(Origin + FWD * UX, Origin + WorldRightDir * UX + FWD * (-UX / 2), Origin, Origin + WorldRightDir * -UX + FWD * (-UX / 2), orange)
	end

	local NoAng = Angle(0, 0, 0)
	function ENT:DrawOverlay(Trace)
		local SelfTbl = self:GetTable()

		if not SelfTbl.HasData then
			self:RequestTurretInfo()

			return
		elseif Clock.CurTime > SelfTbl.Age then
			self:RequestTurretInfo()
		end

		render.SetMaterial(Mat)

		local Up = self:GetUp()
		local FWD = self:GetForward()

		local LocEyePos = self:WorldToLocal(EyePos())
		local LocalRightDir = Vector(0, LocEyePos.y, LocEyePos.z):GetNormalized()
		LocalRightDir:Rotate(Angle(0, 0, 90))
		local WorldRightDir = self:LocalToWorld(LocalRightDir) - self:GetPos()

		local X = math.max(self:OBBMaxs().x, self:OBBMaxs().z)
		local UX = X / 10
		local Pos = self:LocalToWorld(self:OBBCenter())

		local Rotation = Up:Angle()

		local Rotate = false
		if SelfTbl.Type == "Turret-V" then
			Up = self:GetRight()

			Rotation = self:GetRight():Angle()
			Rotate = true
		end

		local Sign = (Rotation:Forward():Dot((EyePos() - Pos):GetNormalized()) < 0) and -1 or 1

		local LocPos = self:WorldToLocal(Trace.HitPos)
		local LocDir = Vector(LocPos.x, LocPos.y, 0):GetNormalized()
		local AimAng = -math.Round(self:WorldToLocalAngles(self:LocalToWorldAngles(LocDir:Angle())).yaw, 2)
		local CurAng = -math.Round(self:WorldToLocalAngles(SelfTbl.Rotator:GetAngles()).yaw, 2)

		if Rotate then
			LocDir = Vector(LocPos.x, 0, LocPos.z):GetNormalized()
			AimAng = -math.Round(self:WorldToLocalAngles(self:LocalToWorldAngles(LocDir:Angle())).pitch, 2)
			CurAng = -math.Round(self:WorldToLocalAngles(SelfTbl.Rotator:GetAngles()).pitch, 2)
		end

		ACF.DrawOutlineBeam(0.25, red, self:LocalToWorld(self:OBBCenter()), SelfTbl.Rotator:LocalToWorld(SelfTbl.LocalCoM))

		render.OverrideDepthEnable(true, true)
			render.DrawWireframeSphere(SelfTbl.Rotator:LocalToWorld(SelfTbl.LocalCoM), 1.5, 4, 3, red)
		render.OverrideDepthEnable(false, false)

		local MinArcPos = {}
		local MaxArcPos = {}
		if SelfTbl.HasArc then
			local MinDir = Vector(X * 0.95, 0, 0)
			local MaxDir = Vector(X * 0.95, 0, 0)

			if Rotate then
				MinDir:Rotate(Angle(-SelfTbl.MinDeg, 0, 0))
				MaxDir:Rotate(Angle(-SelfTbl.MaxDeg, 0, 0))
			else
				MinDir:Rotate(Angle(0, -SelfTbl.MinDeg, 0))
				MaxDir:Rotate(Angle(0, -SelfTbl.MaxDeg, 0))
			end

			local ArcPos = SelfTbl.ArcPos
			local ArcAngle = self:LocalToWorldAngles(Angle(0, 0, Rotate and -90 or 0))
			local NearDist	= X * (1 + (0.025 * -Sign)) * 0.95
			local FarDist	= X * (1 + (0.025 * Sign)) * 0.95

			if Rotate then
				NearDist	= X * (1 + (0.025 * Sign)) * 0.95
				FarDist		= X * (1 + (0.025 * -Sign)) * 0.95
			end

			for I = 0, SelfTbl.Fidelity - 1 do
				local Arc1 = LocalToWorld(ArcPos[I], NoAng, Pos, ArcAngle) - Pos
				local Arc2 = LocalToWorld(ArcPos[I + 1], NoAng, Pos, ArcAngle) - Pos

				render.DrawQuad(Pos + Arc1 * NearDist, Pos + Arc1 * FarDist, Pos + Arc2 * FarDist, Pos + Arc2 * NearDist, arcColor)
			end

			local NearLineDist	= X * (1 + (0.05 * -Sign)) * 0.95
			local FarLineDist	= X * (1 + (0.05 * Sign)) * 0.95

			if Rotate then
				NearLineDist	= X * (1 + (0.05 * Sign)) * 0.95
				FarLineDist		= X * (1 + (0.05 * -Sign)) * 0.95
			end

			local MinArc1	= LocalToWorld(SelfTbl.MinPos, NoAng, Pos, ArcAngle) - Pos
			local MinArc2	= LocalToWorld(SelfTbl.MinPos2, NoAng, Pos, ArcAngle) - Pos
			render.DrawQuad(Pos + MinArc1 * NearLineDist, Pos + MinArc1 * FarLineDist, Pos + MinArc2 * FarLineDist, Pos + MinArc2 * NearLineDist, red)

			local MaxArc1	= LocalToWorld(SelfTbl.MaxPos, NoAng, Pos, ArcAngle) - Pos
			local MaxArc2	= LocalToWorld(SelfTbl.MaxPos2, NoAng, Pos, ArcAngle) - Pos
			render.DrawQuad(Pos + MaxArc1 * NearLineDist, Pos + MaxArc1 * FarLineDist, Pos + MaxArc2 * FarLineDist, Pos + MaxArc2 * NearLineDist, green)

			MinArcPos = (self:LocalToWorld(self:OBBCenter() + MinDir)):ToScreen()
			MaxArcPos = (self:LocalToWorld(self:OBBCenter() + MaxDir)):ToScreen()
		end

		local Origin = Pos + (self:GetForward() * X * 1.1)
		render.DrawQuad(Origin + FWD * UX, Origin + WorldRightDir * UX + FWD * (-UX / 2), Origin, Origin + WorldRightDir * -UX + FWD * (-UX / 2), orange)

		if IsValid(SelfTbl.Rotator) then
			local Rotator = SelfTbl.Rotator
			local RotFWD = Rotator:GetForward()
			local RotRGT = Rotator:GetRight() * Sign
			if Rotate then
				RotRGT = Rotator:GetUp() * -Sign
			end
			local RotOrigin	= Pos + Rotator:GetForward() * X

			render.DrawQuad(RotOrigin + RotRGT * UX * 0.25 + RotFWD * UX * -1.5, RotOrigin + -RotRGT * UX * 0.25 + RotFWD * UX * -1.5, RotOrigin, RotOrigin, curColor)
		end

		ACF.DrawOutlineBeam(0.25, magenta, Pos, self:LocalToWorld(self:OBBCenter() + LocDir * X * 2))

		local HomePos = (Pos + self:GetForward() * X * 1.125):ToScreen()
		local CurPos = (Pos + SelfTbl.Rotator:GetForward() * X * 0.925):ToScreen()
		local AimPos = (self:LocalToWorld(self:OBBCenter() + LocDir * X)):ToScreen()

		local CoMPos = (self.Rotator:LocalToWorld(self.LocalCoM) - Vector(0, 0, 2)):ToScreen()

		cam.Start2D()
			draw.SimpleTextOutlined("Home", "ACF_Title", HomePos.x, HomePos.y, orange, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, 1, color_black)
			draw.SimpleTextOutlined("Current: " .. CurAng, "ACF_Title", CurPos.x, CurPos.y, curColor, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, 1, color_black)
			draw.SimpleTextOutlined("Aim: " .. AimAng, "ACF_Title", AimPos.x, AimPos.y, magenta, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, 1, color_black)

			draw.SimpleTextOutlined("Mass: " .. SelfTbl.Mass .. "kg", "ACF_Control", CoMPos.x, CoMPos.y, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, 1, color_black)
			draw.SimpleTextOutlined("Lateral Distance: " .. SelfTbl.CoMDist .. "u", "ACF_Control", CoMPos.x, CoMPos.y + 16, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, 1, color_black)

			if SelfTbl.HasArc then
				draw.SimpleTextOutlined("Min: " .. SelfTbl.MinDeg, "ACF_Control", MinArcPos.x, MinArcPos.y, red, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, 1, color_black)
				draw.SimpleTextOutlined("Max: " .. SelfTbl.MaxDeg, "ACF_Control", MaxArcPos.x, MaxArcPos.y, green, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, 1, color_black)
			end
		cam.End2D()
	end
end