local ACF       = ACF
local Classes   = ACF.Classes
local Damage    = ACF.Damage
local Debug		= ACF.Debug
local AmmoTypes = Classes.AmmoTypes
local Ammo      = AmmoTypes.Register("HEAT", "AP")


function Ammo:OnLoaded()
	Ammo.BaseClass.OnLoaded(self)

	self.Name		 = "High Explosive Anti-Tank"
	self.SpawnIcon   = "acf/icons/shell_heat.png"
	self.Model		 = "models/munitions/round_100mm_shot.mdl"
	self.Description = "#acf.descs.ammo.heat"
	self.Blacklist = {}
end

function Ammo:ConeCalc(ConeAngle, Radius)
	local Height     = Radius / math.tan(math.rad(ConeAngle))
	local ConeArea   = math.pi * Radius * math.sqrt(Height ^ 2 + Radius ^ 2)
	local ConeVol    = (math.pi * Radius ^ 2 * Height) / 3

	local AngleMult  = math.Remap(ConeAngle ^ 4, 0, 90 ^ 4, 1, 5) -- Shallower cones need thicker liners to survive being made into EFPs
	local LinerThick = ACF.LinerThicknessMult * Radius * AngleMult + 0.1
	local LinerVol   = ConeArea * LinerThick
	local LinerMass  = LinerVol * ACF.CopperDensity

	return LinerMass, ConeVol, Height
end

function Ammo:GetPenetration(Bullet, Standoff)
	if not isnumber(Standoff) then
		return 1 -- Does not matter, just so calls to damage functions don't go sneedmode
	end

	local BreakupT      = Bullet.BreakupTime
	local MaxVel        = Bullet.JetMaxVel
	local PenMul        = Bullet.PenMul or 1
	local Gamma         = 1 --math.sqrt(TargetDensity / ACF.CopperDensity) (Set to 1 to maintain continuity)

	local Penetration = 0
	if Standoff < Bullet.BreakupDist then
		local JetTravel = BreakupT * MaxVel
		local K1 = 1 + Gamma
		local K2 = 1 / K1
		Penetration = (K1 * (JetTravel * Standoff) ^ K2 - math.sqrt(K1 * ACF.HEATMinPenVel * BreakupT * JetTravel ^ K2 * Standoff ^ (Gamma * K2))) / Gamma - Standoff
	else
		Penetration = (MaxVel * BreakupT - math.sqrt(ACF.HEATMinPenVel * BreakupT * (MaxVel * BreakupT + Gamma * Standoff))) / Gamma
	end

	return math.max(Penetration * ACF.HEATPenMul * PenMul * 1e3, 0) -- m to mm
end

function Ammo:GetDisplayData(Data)
	local Fragments  = math.max(math.floor((Data.BoomFillerMass / Data.CasingMass) * ACF.HEFrag), 2)
	local Display    = {
		BoomFillerMass = Data.BoomFillerMass,
		MaxPen         = self:GetPenetration(Data, Data.Standoff, ACF.SteelDensity),
		TotalFragMass  = Data.CasingMass,
		BlastRadius    = Data.BoomFillerMass ^ 0.33 * 8,
		Fragments      = Fragments,
		FragMass       = Data.CasingMass / Fragments,
		FragVel        = (Data.BoomFillerMass * ACF.HEPower * 1000 / Data.CasingMass) ^ 0.5,
	}

	hook.Run("ACF_OnRequestDisplayData", self, Data, Display)

	return Display
end

function Ammo:UpdateRoundData(ToolData, Data, GUIData)
	GUIData = GUIData or Data

	ACF.UpdateRoundSpecs(ToolData, Data, GUIData)

	local CapLength       = GUIData.MinProjLength * 0.5
	local BodyLength      = Data.ProjLength - CapLength
	local FreeVol, FreeLength, FreeRadius = ACF.RoundShellCapacity(Data.PropMass, Data.ProjArea, Data.Caliber, BodyLength)
	-- Considering most of the cap gets crushed (early HEAT suffered from this)
	local Standoff        = (0.3 * CapLength + FreeLength * ToolData.StandoffRatio) * 1e-2 * ACF.HEATStandOffMul -- cm to m
	local WarheadVol      = FreeVol * (1 - ToolData.StandoffRatio)
	local WarheadLength   = FreeLength * (1 - ToolData.StandoffRatio)
	local WarheadDiameter = 2 * FreeRadius
	local MinConeAng      = math.deg(math.atan(FreeRadius / WarheadLength))
	local LinerAngle      = math.Clamp(ToolData.LinerAngle, MinConeAng, 90) -- Cone angle is angle between cone walls, not between a wall and the center line
	local LinerMass, ConeVol, ConeLength = self:ConeCalc(LinerAngle, FreeRadius)

	-- Charge length increases jet velocity, but with diminishing returns. All explosive sorrounding the cone has 100% effectiveness,
	--  but the explosive behind it sees it reduced. Most papers put the maximum useful head length (explosive length behind the
	--  cone) at around 1.5-1.8 times the charge's diameter. Past that, adding more explosive won't do much.
	local RearFillLen  = WarheadLength - ConeLength  -- Length of explosive behind the liner
	local Exponential  = math.exp(2 * RearFillLen / (WarheadDiameter * ACF.MaxChargeHeadLen))
	local EquivFillLen = WarheadDiameter * ACF.MaxChargeHeadLen * ((Exponential - 1) / (Exponential + 1)) -- Equivalent length of explosive
	local FrontFillVol = WarheadVol * ConeLength / WarheadLength - ConeVol -- Volume of explosive sorounding the liner
	local RearFillVol  = WarheadVol * RearFillLen / WarheadLength -- Volume behind the liner
	local EquivFillVol = WarheadVol * EquivFillLen / WarheadLength + FrontFillVol -- Equivalent total explosive volume
	local LengthPct    = math.min(Data.ProjLength / (Data.Caliber * 7.8), 1)
	local OverEnergy   = math.min(math.Remap(LengthPct, 0.4, 1, 1, 0.2), 1) -- Excess explosive power makes the jet lose velocity
	local FillerEnergy = OverEnergy * EquivFillVol * ACF.CompBDensity * 1e3 * ACF.TNTPower * ACF.CompBEquivalent * ACF.HEATEfficiency
	local FillerVol    = FrontFillVol + RearFillVol
	local FillerMass   = FillerVol * ACF.CompBDensity

	-- At lower cone angles, the explosive crushes the cone inward, expelling a jet. The steeper the cone, the faster the jet, but the less mass expelled
	local MinVelMult = math.Remap(LinerAngle, 0, 90, 0.5, 0.99)
	local JetMass    = LinerMass * math.Remap(LinerAngle, 0, 90, 0.25, 1)
	local JetAvgVel  = (2 * FillerEnergy / JetMass) ^ 0.5  -- Average velocity of the copper jet
	local JetMinVel  = JetAvgVel * MinVelMult              -- Minimum velocity of the jet (the rear)
	-- Calculates the maximum velocity, considering the velocity distribution is linear from the rear to the tip (integrated this by hand, pain :) )
	local JetMaxVel  = 0.5 * (3 ^ 0.5 * (8 * FillerEnergy - JetMass * JetMinVel ^ 2) ^ 0.5 / JetMass ^ 0.5 - JetMinVel) -- Maximum velocity of the jet (the tip)

	-- Both the "magic numbers" are unitless, tuning constants that were used to fit the breakup time to real world values, I suggest they not be messed with
	local BreakupTime    = 1.6e-6 * (5e9 * JetMass / (JetMaxVel - JetMinVel)) ^ 0.3333 * ACF.HEATBreakUpMul -- Jet breakup time in seconds
	local BreakupDist    = JetMaxVel * BreakupTime

	GUIData.MinConeAng = MinConeAng

	Data.ConeAng        = LinerAngle
	Data.MinConeAng     = MinConeAng
	Data.FillerMass     = FillerMass
	local NonCasingVol  = ACF.RoundShellCapacity(Data.PropMass, Data.ProjArea, Data.Caliber, Data.ProjLength)
	Data.CasingMass		= (GUIData.ProjVolume - NonCasingVol) * ACF.SteelDensity
	Data.ProjMass       = Data.FillerMass + Data.CasingMass + LinerMass
	Data.MuzzleVel      = ACF.MuzzleVelocity(Data.PropMass, Data.ProjMass, Data.Efficiency)
	Data.BoomFillerMass	= Data.FillerMass * ACF.HEATBoomConvert * ACF.CompBEquivalent * 1.25 -- In TNT equivalent
	Data.LinerMass      = LinerMass
	Data.JetMass        = JetMass
	Data.JetMinVel      = JetMinVel
	Data.JetMaxVel      = JetMaxVel
	Data.JetAvgVel	  	= JetAvgVel
	Data.BreakupTime    = BreakupTime
	Data.Standoff       = Standoff
	Data.BreakupDist    = BreakupDist
	Data.DragCoef		= Data.ProjArea * 0.0001 / Data.ProjMass
	Data.CartMass		= Data.PropMass + Data.ProjMass

	hook.Run("ACF_OnUpdateRound", self, ToolData, Data, GUIData)

	-- Recalculate the standoff for missiles
	if Data.MissileStandoff then
		Data.Standoff = (FreeLength * ToolData.StandoffRatio + Data.MissileStandoff) * 1e-2 * ACF.HEATStandOffMul
	end
	-- God weeped when this spaghetto was written (for missile roundinject)
	if Data.FillerMul or Data.LinerMassMul then
		local LinerMassMul = Data.LinerMassMul or 1
		Data.LinerMass     = LinerMass * LinerMassMul
		local FillerMul    = Data.FillerMul or 1
		Data.FillerEnergy  = OverEnergy * EquivFillVol * ACF.CompBDensity * 1e3 * ACF.TNTPower * ACF.CompBEquivalent * ACF.HEATEfficiency * FillerMul
		local _FillerEnergy = Data.FillerEnergy
		local _LinerAngle   = Data.ConeAng
		local _MinVelMult   = math.Remap(_LinerAngle, 0, 90, 0.5, 0.99)
		local _JetMass      = LinerMass * math.Remap(_LinerAngle, 0, 90, 0.25, 1)
		local _JetAvgVel    = (2 * _FillerEnergy / _JetMass) ^ 0.5
		local _JetMinVel    = _JetAvgVel * _MinVelMult
		local _JetMaxVel    = 0.5 * (3 ^ 0.5 * (8 * _FillerEnergy - _JetMass * _JetMinVel ^ 2) ^ 0.5 / _JetMass ^ 0.5 - JetMinVel)
		Data.BreakupTime   = 1.6e-6 * (5e9 * _JetMass / (_JetMaxVel - _JetMinVel)) ^ 0.3333 * ACF.HEATBreakUpMul
		Data.BreakupDist   = _JetMaxVel * Data.BreakupTime
		Data.JetMass       = _JetMass
		Data.JetMinVel     = _JetMinVel
		Data.JetMaxVel     = _JetMaxVel
		Data.JetAvgVel	  	= _JetAvgVel
	end

	for K, V in pairs(self:GetDisplayData(Data)) do
		GUIData[K] = V
	end
end

function Ammo:BaseConvert(ToolData)
	local Data, GUIData = ACF.RoundBaseGunpowder(ToolData, {})

	GUIData.MinConeAng	 = 0
	GUIData.MinFillerVol = 0

	Data.ShovePower		= 0.1
	Data.LimitVel		= 100 -- Most efficient penetration speed in m/s
	Data.Ricochet		= 60 -- Base ricochet angle
	Data.DetonatorAngle	= 75
	Data.CanFuze		= Data.Caliber * 10 > ACF.MinFuzeCaliber -- Can fuze on calibers > 20mm

	self:UpdateRoundData(ToolData, Data, GUIData)

	return Data, GUIData
end

function Ammo:VerifyData(ToolData)
	Ammo.BaseClass.VerifyData(self, ToolData)

	if not isnumber(ToolData.StandoffRatio) then
		ToolData.StandoffRatio = 0
	else
		ToolData.StandoffRatio = math.Clamp(ToolData.StandoffRatio, 0, self.MaxStandoffRatio or 0.2)
	end

	if not isnumber(ToolData.LinerAngle) then
		ToolData.LinerAngle = 90
	end
end

if SERVER then
	local Ballistics = ACF.Ballistics
	local Entities   = Classes.Entities
	local Objects    = Damage.Objects

	Entities.AddArguments("acf_ammo", "LinerAngle", "StandoffRatio") -- Adding extra info to ammo crates

	function Ammo:OnLast(Entity)
		Ammo.BaseClass.OnLast(self, Entity)

		Entity.LinerAngle  = nil

		-- Cleanup the leftovers aswell
		Entity.FillerMass = nil
		Entity.RoundData5 = nil
		Entity.RoundData6 = nil

		Entity:SetNW2Float("FillerMass", 0)
	end

	function Ammo:Network(Entity, BulletData)
		Ammo.BaseClass.Network(self, Entity, BulletData)

		Entity:SetNW2String("AmmoType", "HEAT")
		Entity:SetNW2Float("FillerMass", BulletData.BoomFillerMass)
	end

	function Ammo:GetCrateText(BulletData)
		local Text = "Muzzle Velocity: %s m/s\nMax Penetration: %s mm\nBlast Radius: %s m\n", "Blast Energy: %s KJ"
		local Data = self:GetDisplayData(BulletData)

		return Text:format(math.Round(BulletData.MuzzleVel, 2), math.Round(Data.MaxPen, 2), math.Round(Data.BlastRadius, 2), math.Round(Data.BoomFillerMass * ACF.HEPower, 2))
	end

	function Ammo:Detonate(Bullet, HitPos)
		if Bullet.Detonated then return end	-- Prevents GLATGM spawned HEAT projectiles from detonating twice, or for that matter this running twice at all
		Bullet.Detonated = true

		local Filler    = Bullet.BoomFillerMass
		local Fragments = Bullet.CasingMass
		local DmgInfo   = Objects.DamageInfo(Bullet.Owner, Bullet.Gun)

		Damage.createExplosion(HitPos, Filler, Fragments, nil, DmgInfo)

		-- Move the jet start to the impact point and back it up by the passive standoff
		local Start		= Bullet.Standoff * ACF.MeterToInch
		local End		= Bullet.BreakupDist * 10 * ACF.MeterToInch
		local Direction = Bullet.Flight:GetNormalized()
		local JetStart  = HitPos - Direction * Start
		local JetEnd    = HitPos + Direction * End

		Debug.Cross(JetStart, 15, 15, Color(0, 255, 0), true)
		Debug.Cross(JetEnd, 15, 15, Color(255, 0, 0), true)

		local TraceData = {start = JetStart, endpos = JetEnd, filter = {}, mask = Bullet.Mask}
		local Penetrations = 0
		local JetMassPct   = 1
		-- Main jet penetrations
		while Penetrations < 20 do
			local TraceRes  = ACF.trace(TraceData)
			local PenHitPos = TraceRes.HitPos
			local Ent       = TraceRes.Entity

			if TraceRes.Fraction == 1 and not IsValid(Ent) then break end

			Debug.Line(JetStart, PenHitPos, 15, ColorRand(100, 255))

			if not Ballistics.TestFilter(Ent, Bullet) then TraceData.filter[#TraceData.filter + 1] = TraceRes.Entity continue end

			-- Get the (full jet's) penetration
			local Standoff    = (PenHitPos - JetStart):Length() * ACF.InchToMeter -- Back to m
			local Penetration = self:GetPenetration(Bullet, Standoff) * math.max(0, JetMassPct)
			-- If it's out of range, stop here
			if Penetration == 0 then break end

			-- Get the effective armor thickness
			local BaseArmor = 0
			local DamageDealt
			if TraceRes.HitWorld or TraceRes.Entity and TraceRes.Entity:IsWorld() then
				-- Get the surface and calculate the RHA equivalent
				local Surface = util.GetSurfaceData(TraceRes.SurfaceProps)
				local Density = ((Surface and Surface.density * 0.5 or 500) * math.Rand(0.9, 1.1)) ^ 0.9 / 10000
				local Penetrated, Exit = Ballistics.DigTrace(PenHitPos + Direction, PenHitPos + Direction * math.max(Penetration / Density, 1) / ACF.InchToMm)
				-- Base armor is the RHAe if penetrated, or simply more than the penetration so the jet loses all mass and penetration stops
				BaseArmor = Penetrated and ((Exit - PenHitPos):Length() * Density * ACF.InchToMm) or (Penetration + 1)
				-- Update the starting position of the trace because world is not filterable
				TraceData.start = Exit
			--elseif Ent:CPPIGetOwner() == game.GetWorld() then
				-- TODO: Fix world entity penetration
				--BaseArmor = Penetration + 1
			elseif TraceRes.Hit then
				BaseArmor = Ent.GetArmor and Ent:GetArmor(TraceRes) or Ent.ACF and Ent.ACF.Armour or 0
				-- Enable damage if a valid entity is hit
				DamageDealt = 0
			end

			local Angle          = ACF.GetHitAngle(TraceRes, Direction)
			local EffectiveArmor = Ent.GetArmor and BaseArmor or BaseArmor / math.abs(math.cos(math.rad(Angle)))

			-- Percentage of total jet mass lost to this penetration
			local LostMassPct =  EffectiveArmor / Penetration
			-- Deal damage based on the volume of the lost mass
			local Cavity = ACF.HEATCavityMul * math.min(LostMassPct, JetMassPct) * Bullet.JetMass / ACF.CopperDensity -- in cm^3
			local _Cavity = Cavity -- Remove when health scales with armor
			if DamageDealt == 0 then
				-- This should probably be consolidated with damageresults later: lua\acf\damage\objects_sv\damage_result.lua
				_Cavity = Cavity * (Penetration / EffectiveArmor) * 0.35

				-- Damage result, Damage info
				local JetDmg, JetInfo = Damage.getBulletDamage(Bullet, TraceRes)

				JetInfo:SetType(DMG_BULLET)
				JetDmg:SetDamage(_Cavity)

				-- local Speed = Bullet.JetAvgVel

				-- Bullet.Energy = {}
				-- Bullet.Energy.Kinetic = ACF.Kinetic(Speed, Bullet.JetMass * JetMassPct).Kinetic * 1000
				local JetResult = Damage.dealDamage(Ent, JetDmg, JetInfo)

				-- if not Bullet.IsSpall and not Bullet.IsCookOff then
				-- 	Ballistics.DoSpall(Bullet, TraceRes, JetResult, Speed)
				-- end

				if JetResult.Kill then
					ACF.APKill(Ent, Direction, 0, JetInfo)
				end
			end
			-- Reduce the jet mass by the lost mass
			JetMassPct = JetMassPct - LostMassPct

			if JetMassPct < 0 then break end

			-- Filter the hit entity
			if TraceRes.Entity then TraceData.filter[#TraceData.filter + 1] = TraceRes.Entity end

			Penetrations = Penetrations + 1
		end
	end

	local function OnRicochet(Bullet, Trace, Ricochet)
		if Ricochet > 0 and Bullet.Ricochets < 3 then
			local Direction = Ballistics.GetRicochetVector(Bullet.Flight, Trace.HitNormal) + VectorRand() * 0.025

			Bullet.Ricochets = Bullet.Ricochets + 1
			Bullet.NextPos = Trace.HitPos
			Bullet.Flight = Direction:GetNormalized() * Bullet.Flight:Length() * Ricochet
		end
	end

	function Ammo:PropImpact(Bullet, Trace)
		local Target = Trace.Entity

		if ACF.Check(Target) then
			local Ricochet = Ballistics.CalculateRicochet(Bullet, Trace)

			if Ricochet ~= 0 then
				OnRicochet(Bullet, Trace, Ricochet)
				return "Ricochet"
			else
				self:Detonate(Bullet, Trace.HitPos)
				return false
			end
		else
			table.insert(Bullet.Filter, Target)

			return "Penetrated"
		end
	end

	function Ammo:WorldImpact(Bullet, Trace)
		local Ricochet = Ballistics.CalculateRicochet(Bullet, Trace)

		if Ricochet ~= 0 then
			OnRicochet(Bullet, Trace, Ricochet)
			return "Ricochet"
		else
			self:Detonate(Bullet, Trace.HitPos)
			return false
		end
	end

else
	ACF.RegisterAmmoDecal("HEAT", "damage/heat_pen", "damage/heat_rico", function(Caliber) return Caliber * 0.1667 end)
	local DecalIndex = ACF.GetAmmoDecalIndex
	local Effects    = ACF.Utilities.Effects

	function Ammo:ImpactEffect(Effect, Bullet)
		if not Bullet.Detonated then
			self:PenetrationEffect(Effect, Bullet)
		end

		Ammo.BaseClass.ImpactEffect(self, Effect, Bullet)
	end

	function Ammo:PenetrationEffect(Effect, Bullet)
		local Detonated   = Bullet.Detonated
		local EffectName  = Detonated and "ACF_Penetration" or "ACF_HEAT_Explosion"
		local Radius      = Detonated and Bullet.Caliber or math.max(Bullet.FillerMass ^ 0.33 * 8 * ACF.MeterToInch, 1)
		local EffectTable = {
			Origin = Bullet.SimPos,
			Normal = Bullet.SimFlight:GetNormalized(),
			Radius = Radius,
			Magnitude = Detonated and Bullet.RoundMass or nil,
			Scale = Detonated and Bullet.SimFlight:Length() or nil,
			DamageType = Detonated and DecalIndex(Bullet.AmmoType) or nil,
		}

		Effects.CreateEffect(EffectName, EffectTable)

		if not Detonated then
			Bullet.Detonated = true
			Bullet.LimitVel  = 999999

			Effect:SetModel("models/Gibs/wood_gib01e.mdl")
		end
	end

	function Ammo:RicochetEffect(_, Bullet)
		local EffectTable = {
			Origin = Bullet.SimPos,
			Normal = Bullet.SimFlight:GetNormalized(),
			Scale = Bullet.SimFlight:Length(),
			Magnitude = Bullet.RoundMass,
			Radius = Bullet.Caliber,
			DamageType = DecalIndex(Bullet.AmmoType),
		}

		Effects.CreateEffect("ACF_Ricochet", EffectTable)
	end

	function Ammo:OnCreateAmmoControls(Base, ToolData, BulletData)
		local LinerAngle = Base:AddSlider("#acf.menu.ammo.liner_angle", BulletData.MinConeAng, 90, 1)
		LinerAngle:SetClientData("LinerAngle", "OnValueChanged")
		LinerAngle:TrackClientData("Projectile")
		LinerAngle:DefineSetter(function(Panel, _, Key, Value)
			if Key == "LinerAngle" then
				ToolData.LinerAngle = math.Round(Value, 2)
			end

			self:UpdateRoundData(ToolData, BulletData)

			Panel:SetMin(BulletData.MinConeAng)
			Panel:SetValue(BulletData.ConeAng)

			return BulletData.ConeAng
		end)

		-- Capped the max standoff at 0.4 for historical reasons
		local StandoffRatio = Base:AddSlider("#acf.menu.ammo.standoff_ratio", 0, 0.2, 2)
		StandoffRatio:SetClientData("StandoffRatio", "OnValueChanged")
		StandoffRatio:DefineSetter(function(_, _, _, Value)
			ToolData.StandoffRatio = math.Round(Value, 2)

			self:UpdateRoundData(ToolData, BulletData)

			return ToolData.StandoffRatio
		end)
	end

	function Ammo:OnCreateCrateInformation(Base, Label, ...)
		Ammo.BaseClass.OnCreateCrateInformation(self, Base, Label, ...)

		Label:TrackClientData("LinerAngle")
		Label:TrackClientData("StandoffRatio")
	end

	function Ammo:OnCreateAmmoInformation(Base, ToolData, BulletData)
		local RoundStats = Base:AddLabel()
		RoundStats:TrackClientData("Projectile", "SetText")
		RoundStats:TrackClientData("Propellant")
		RoundStats:TrackClientData("LinerAngle")
		RoundStats:TrackClientData("StandoffRatio")
		RoundStats:DefineSetter(function()
			self:UpdateRoundData(ToolData, BulletData)

			local Text		= language.GetPhrase("acf.menu.ammo.round_stats_he")
			local MuzzleVel	= math.Round(BulletData.MuzzleVel * ACF.Scale, 2)
			local ProjMass	= ACF.GetProperMass(BulletData.ProjMass)
			local PropMass	= ACF.GetProperMass(BulletData.PropMass)
			local Filler	= ACF.GetProperMass(BulletData.FillerMass)

			return Text:format(MuzzleVel, ProjMass, PropMass, Filler)
		end)

		local FillerStats = Base:AddLabel()
		FillerStats:TrackClientData("Projectile", "SetText")
		FillerStats:TrackClientData("Propellant")
		FillerStats:TrackClientData("LinerAngle")
		FillerStats:TrackClientData("StandoffRatio")
		FillerStats:DefineSetter(function()
			self:UpdateRoundData(ToolData, BulletData)

			local Text	   = language.GetPhrase("acf.menu.ammo.filler_stats_he")
			local Blast	   = math.Round(BulletData.BlastRadius, 2)
			local FragMass = ACF.GetProperMass(BulletData.FragMass)
			local FragVel  = math.Round(BulletData.FragVel, 2)

			return Text:format(Blast, BulletData.Fragments, FragMass, FragVel)
		end)

		local Penetrator = Base:AddLabel()
		Penetrator:TrackClientData("Projectile", "SetText")
		Penetrator:TrackClientData("Propellant")
		Penetrator:TrackClientData("LinerAngle")
		Penetrator:TrackClientData("StandoffRatio")
		Penetrator:DefineSetter(function()
			self:UpdateRoundData(ToolData, BulletData)

			local Text     = language.GetPhrase("acf.menu.ammo.penetrator_heat")
			local CuMass   = math.Round(BulletData.LinerMass * 1e3, 0)
			local JetMass  = math.Round(BulletData.JetMass * 1e3, 0)
			local MinVel   = math.Round(BulletData.JetMinVel, 0)
			local MaxVel   = math.Round(BulletData.JetMaxVel, 0)

			return Text:format(CuMass, JetMass, MinVel, MaxVel)
		end)

		local PenStats = Base:AddLabel()
		PenStats:TrackClientData("Projectile", "SetText")
		PenStats:TrackClientData("Propellant")
		PenStats:TrackClientData("LinerAngle")
		PenStats:TrackClientData("StandoffRatio")
		PenStats:DefineSetter(function()
			self:UpdateRoundData(ToolData, BulletData)

			local Text   = language.GetPhrase("acf.menu.ammo.pen_stats_heat")
			local Standoff1 = math.Round(BulletData.Standoff * 1e3, 0)
			local Pen1 = math.Round(self:GetPenetration(BulletData, BulletData.Standoff), 1)
			local Standoff2 = math.Round(BulletData.BreakupDist * 1e3, 0)
			local Pen2 = math.Round(self:GetPenetration(BulletData, BulletData.BreakupDist), 1)

			return Text:format(Standoff1, Pen1, Standoff2, Pen2)
		end)
	end
end
