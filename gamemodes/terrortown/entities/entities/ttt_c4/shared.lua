---
-- @class ENT
-- @desc c4 explosive
-- @section C4

local math = math
local hook = hook
local table = table
local net = net
local IsValid = IsValid

if SERVER then
	AddCSLuaFile("cl_init.lua")
	AddCSLuaFile("shared.lua")
end

if CLIENT then
	-- this entity can be DNA-sampled so we need some display info
	ENT.Icon = "vgui/ttt/icon_c4"
	ENT.PrintName = "C4"

	local GetPTranslation = LANG.GetParamTranslation
	local hint_params = {usekey = Key("+use", "USE")}

	ENT.TargetIDHint = {
		name = "C4",
		hint = "c4_hint",
		fmt  = function(ent, txt)
			return GetPTranslation(txt, hint_params)
		end
	}
end

C4_WIRE_COUNT	= 6
C4_MINIMUM_TIME = 45
C4_MAXIMUM_TIME = 600

ENT.Type = "anim"
ENT.Model = Model("models/weapons/w_c4_planted.mdl")

ENT.CanHavePrints = true
ENT.CanUseKey = true
ENT.Avoidable = true

---
-- @accessor Entity
-- @realm shared
AccessorFunc(ENT, "thrower", "Thrower")

---
-- @accessor number
-- @realm shared
AccessorFunc(ENT, "radius", "Radius", FORCE_NUMBER)

---
-- @accessor number
-- @realm shared
AccessorFunc(ENT, "dmg", "Dmg", FORCE_NUMBER)

---
-- @accessor number
-- @realm shared
AccessorFunc(ENT, "arm_time", "ArmTime", FORCE_NUMBER)

---
-- @accessor number
-- @realm shared
AccessorFunc(ENT, "timer_length", "TimerLength", FORCE_NUMBER)

-- Generate accessors for DT vars. This way all consumer code can keep accessing
-- the vars as they always did, the only difference is that behind the scenes
-- they are set up as DT vars.

---
-- @accessor number
-- @realm shared
AccessorFuncDT(ENT, "explode_time", "ExplodeTime")

---
-- @accessor boolean
-- @realm shared
AccessorFuncDT(ENT, "armed", "Armed", FORCE_BOOL)

ENT.Beep = 0
ENT.DetectiveNearRadius = 300
ENT.SafeWires = nil

---
-- Initializes the data
-- @realm shared
function ENT:SetupDataTables()
	self:DTVar("Int", 0, "explode_time")
	self:DTVar("Bool", 0, "armed")
end

---
-- Initializes the C4
-- @realm shared
function ENT:Initialize()
	self:SetModel(self.Model)

	if SERVER then
		self:PhysicsInit(SOLID_VPHYSICS)
	end

	self:SetMoveType(MOVETYPE_VPHYSICS)
	self:SetSolid(SOLID_BBOX)
	self:SetCollisionGroup(COLLISION_GROUP_WEAPON)

	if SERVER then
		self:SetUseType(SIMPLE_USE)
	end

	self.SafeWires = nil
	self.Beep = 0
	self.DisarmCausedExplosion = false

	self:SetTimerLength(0)
	self:SetExplodeTime(0)
	self:SetArmed(false)

	if not self:GetThrower() then
		self:SetThrower(nil)
	end

	if not self:GetRadius() then
		self:SetRadius(1000)
	end

	if not self:GetDmg() then
		self:SetDmg(200)
	end
end

---
-- @param number length time
-- @realm shared
function ENT:SetDetonateTimer(length)
	self:SetTimerLength(length)
	self:SetExplodeTime(CurTime() + length)
end

---
-- @param Entity activator
-- @realm shared
function ENT:UseOverride(activator)
	if IsValid(activator) and activator:IsPlayer() then
		self:ShowC4Config(activator)
	end
end

---
-- @param number t
-- @return number
-- @realm shared
function ENT.SafeWiresForTime(t)
	local m = t / 60

	if m > 4 then
		return 1
	elseif m > 3 then
		return 2
	elseif m > 2 then
		return 3
	elseif m > 1 then
		return 4
	else
		return 5
	end
end

---
-- @param boolean state
-- @realm shared
function ENT:WeldToGround(state)
	if self.IsOnWall then return end

	if state then
		-- getgroundentity does not work for non-players
		-- so sweep ent downward to find what we're lying on
		local ignore = player.GetAll()
		ignore[#ignore + 1] = self

		local tr = util.TraceEntity({
			start = self:GetPos(),
			endpos = self:GetPos() - Vector(0, 0, 16),
			filter = ignore,
			mask = MASK_SOLID
		}, self)

		-- Start by increasing weight/making uncarryable
		local phys = self:GetPhysicsObject()

		if IsValid(phys) then
			-- Could just use a pickup flag for this. However, then it's easier to
			-- push it around.
			self.OrigMass = phys:GetMass()

			phys:SetMass(150)
		end

		if tr.Hit and (IsValid(tr.Entity) or tr.HitWorld) then
			-- "Attach" to a brush if possible
			if IsValid(phys) and tr.HitWorld then
				phys:EnableMotion(false)
			end

			-- Else weld to objects we cannot pick up
			local entphys = tr.Entity:GetPhysicsObject()

			if IsValid(entphys) and entphys:GetMass() > CARRY_WEIGHT_LIMIT then
				constraint.Weld(self, tr.Entity, 0, 0, 0, true)
			end

			-- Worst case, we are still uncarryable
		end
	else
		constraint.RemoveConstraints(self, "Weld")

		local phys = self:GetPhysicsObject()

		if IsValid(phys) then
			phys:EnableMotion(true)
			phys:SetMass(self.OrigMass or 10)
		end
	end
end

---
-- @param Entity dmgowner
-- @param Vector center
-- @param number radius
-- @realm shared
function ENT:SphereDamage(dmgowner, center, radius)
	-- It seems intuitive to use FindInSphere here, but that will find all ents
	-- in the radius, whereas there exist only ~16 players. Hence it is more
	-- efficient to cycle through all those players and do a Lua-side distance
	-- check.

	local r = radius * radius -- square so we can compare with dot product directly

	-- pre-declare to avoid realloc
	local d = 0.0
	local diff = nil
	local dmg = 0
	local plys = player.GetAll()

	for i = 1, #plys do
		local ply = plys[i]

		if ply:Team() ~= TEAM_TERROR then continue end

		-- dot of the difference with itself is distance squared
		diff = center - ply:GetPos()
		d = diff:Dot(diff)

		if d >= r then continue end

		-- deadly up to a certain range, then a quick falloff within 100 units
		d = math.max(0, math.sqrt(d) - 490)
		dmg = -0.01 * (d * d) + 125

		local dmginfo = DamageInfo()
		dmginfo:SetDamage(dmg)
		dmginfo:SetAttacker(dmgowner)
		dmginfo:SetInflictor(self)
		dmginfo:SetDamageType(DMG_BLAST)
		dmginfo:SetDamageForce(center - ply:GetPos())
		dmginfo:SetDamagePosition(ply:GetPos())

		ply:TakeDamageInfo(dmginfo)
	end
end

local c4boom = Sound("c4.explode")

---
-- @param table tr Trace Structure
-- @realm shared
function ENT:Explode(tr)
	---
	-- @realm shared
	hook.Run("TTTC4Explode", self)

	if SERVER then
		self:SetNoDraw(true)
		self:SetSolid(SOLID_NONE)

		-- pull out of the surface
		if tr.Fraction ~= 1.0 then
			self:SetPos(tr.HitPos + tr.HitNormal * 0.6)
		end

		local pos = self:GetPos()

		if util.PointContents(pos) == CONTENTS_WATER or GetRoundState() ~= ROUND_ACTIVE then
			self:Remove()
			self:SetExplodeTime(0)

			return
		end

		local dmgowner = self:GetThrower()
		dmgowner = IsValid(dmgowner) and dmgowner or self

		local r_inner = 750
		local r_outer = self:GetRadius()

		if self.DisarmCausedExplosion then
			r_inner = r_inner / 2.5
			r_outer = r_outer / 2.5
		end

		-- damage through walls
		self:SphereDamage(dmgowner, pos, r_inner)

		-- explosion damage
		util.BlastDamage(self, dmgowner, pos, r_outer, self:GetDmg())

		local effect = EffectData()
		effect:SetStart(pos)
		effect:SetOrigin(pos)

		-- these don't have much effect with the default Explosion
		effect:SetScale(r_outer)
		effect:SetRadius(r_outer)
		effect:SetMagnitude(self:GetDmg())

		if tr.Fraction ~= 1.0 then
			effect:SetNormal(tr.HitNormal)
		end

		effect:SetOrigin(pos)

		util.Effect("Explosion", effect, true, true)
		util.Effect("HelicopterMegaBomb", effect, true, true)

		timer.Simple(0.1, function()
			sound.Play(c4boom, pos, 100, 100)
		end)

		-- extra push
		local phexp = ents.Create("env_physexplosion")
		phexp:SetPos(pos)
		phexp:SetKeyValue("magnitude", self:GetDmg())
		phexp:SetKeyValue("radius", r_outer)
		phexp:SetKeyValue("spawnflags", "19")
		phexp:Spawn()
		phexp:Fire("Explode", "", 0)

		-- few fire bits to ignite things
		timer.Simple(0.2, function()
			StartFires(pos, tr, 4, 5, true, dmgowner)
		end)

		self:SetExplodeTime(0)

		events.Trigger(EVENT_C4EXPLODE, dmgowner)

		self:Remove()
	else
		local spos = self:GetPos()
		local trs = util.TraceLine({
			start = spos + Vector(0, 0, 64),
			endpos = spos + Vector(0, 0, -128),
			filter = self
		})

		util.Decal("Scorch", trs.HitPos + trs.HitNormal, trs.HitPos - trs.HitNormal)

		self:SetExplodeTime(0)
	end
end

---
-- @return[default=false] boolean
-- @realm shared
function ENT:IsDetectiveNear()
	local center = self:GetPos()
	local r = self.DetectiveNearRadius * self.DetectiveNearRadius
	local d = 0.0
	local diff = nil
	local plys = player.GetAll()

	for i = 1, #plys do
		local ply = plys[i]

		if not ply:IsActiveDetective() then continue end

		-- dot of the difference with itself is distance squared
		diff = center - ply:GetPos()
		d = diff:Dot(diff)

		if d < r and ply:HasWeapon("weapon_ttt_defuser") then
			return true
		end
	end

	return false
end

local beep = Sound("weapons/c4/c4_beep1.wav")
local MAX_MOVE_RANGE = 1000000 -- sq of 1000

---
-- @realm shared
function ENT:Think()
	if not self:GetArmed() then return end

	if SERVER then
		local curpos = self:GetPos()

		if self.LastPos and self.LastPos:DistToSqr(curpos) > MAX_MOVE_RANGE then
			self:Disarm(nil)

			return
		end

		self.LastPos = curpos
	end

	local etime = self:GetExplodeTime()

	if self:GetArmed() and etime ~= 0 and etime < CurTime() then
		-- find the ground if it's near and pass it to the explosion
		local spos = self:GetPos()
		local tr = util.TraceLine({
			start = spos,
			endpos = spos + Vector(0, 0, -32),
			mask = MASK_SHOT_HULL,
			filter = self:GetThrower()
		})

		local success, err = pcall(self.Explode, self, tr)
		if not success then
			-- prevent effect spam on Lua error
			self:Remove()

			ErrorNoHalt("ERROR CAUGHT: ttt_c4: " .. err .. "\n")
		end
	elseif self:GetArmed() and CurTime() > self.Beep then
		local amp = 48

		if self:IsDetectiveNear() then
			amp = 65

			local dlight = CLIENT and DynamicLight(self:EntIndex())
			if dlight then
				dlight.Pos = self:GetPos()
				dlight.r = 255
				dlight.g = 0
				dlight.b = 0
				dlight.Brightness = 1
				dlight.Size = 128
				dlight.Decay = 500
				dlight.DieTime = CurTime() + 0.1
			end
		elseif SERVER then
			-- volume lower for long fuse times, bottoms at 50 at +5mins
			amp = amp + math.max(0, 12 - (0.03 * self:GetTimerLength()))
		end

		if SERVER then
			sound.Play(beep, self:GetPos(), amp, 100)
		end

		local btime = (etime - CurTime()) / 30

		self.Beep = CurTime() + btime
	end
end

---
-- @return boolen
-- @see ENT:GetArmed
-- @realm shared
function ENT:Defusable()
	return self:GetArmed()
end

-- Timer configuration handlign

if SERVER then
	---
	-- Inform traitors about us
	-- @param boolean armed
	-- @realm server
	function ENT:SendWarn(armed)
		net.Start("TTT_C4Warn")
		net.WriteUInt(self:EntIndex(), 16)
		net.WriteBit(armed)

		if armed then
			net.WriteVector(self:GetPos())
			net.WriteFloat(self:GetExplodeTime())
			net.WriteString(self:GetOwner():GetTeam())
		end

		--net.Send(GetTeamFilter(self:GetOwner():GetTeam(), true))
		net.Broadcast()
	end

	---
	-- @realm server
	function ENT:OnRemove()
		self:SendWarn(false)
	end

	---
	-- @param Player ply
	-- @realm server
	function ENT:Disarm(ply)
		local owner = self:GetOwner()

		events.Trigger(EVENT_C4DISARM, owner, ply, true)

		if ply ~= owner and IsValid(owner) then
			LANG.Msg(owner, "c4_disarm_warn")
		end

		self:SetExplodeTime(0)
		self:SetArmed(false)
		self:WeldToGround(false)
		self:SendWarn(false)

		self.DisarmCausedExplosion = false
	end

	---
	-- @param Player ply
	-- @realm server
	function ENT:FailedDisarm(ply)
		self.DisarmCausedExplosion = true

		events.Trigger(EVENT_C4DISARM, self:GetOwner(), ply, false)

		-- tiny moment of zen and realization before the bang
		self:SetExplodeTime(CurTime() + 0.1)
	end

	---
	-- @param Player ply
	-- @param number time
	-- @realm server
	function ENT:Arm(ply, time)
		-- Initialize armed state
		self:SetDetonateTimer(time)
		self:SetArmTime(CurTime())

		self:SetArmed(true)
		self:WeldToGround(true)

		self.DisarmCausedExplosion = false

		-- ply may be a different player than he who dropped us.
		-- Arming player should be the damage owner = "thrower"
		self:SetThrower(ply)

		-- Owner determines who gets messages and can quick-disarm if traitor,
		-- make that the armer as well for now. Theoretically the dropping player
		-- should also be able to quick-disarm, but that's going to be rare.
		self:SetOwner(ply)

		-- Wire stuff:

		self.SafeWires = {}

		-- list of possible wires to make safe
		local choices = {}

		for i = 1, C4_WIRE_COUNT do
			choices[#choices + 1] = i
		end

		-- random selection process, lot like traitor selection
		local safe_count = self.SafeWiresForTime(time)
		local picked = 0

		while picked < safe_count do
			local pick = math.random(#choices)
			local w = choices[pick]

			if not self.SafeWires[w] then
				self.SafeWires[w] = true

				table.remove(choices, pick)

				-- owner will end up having the last safe wire on his corpse
				ply.bomb_wire = w

				picked = picked + 1
			end
		end

		events.Trigger(EVENT_C4PLANT, ply)

		-- send indicator to traitors
		self:SendWarn(true)
	end

	---
	-- @param Player ply
	-- @realm server
	function ENT:ShowC4Config(ply)
		-- show menu to player to configure or disarm us
		net.Start("TTT_C4Config")
		net.WriteEntity(self)
		net.Send(ply)
	end

	local function ReceiveC4Config(ply, cmd, args)
		if not (IsValid(ply) and ply:IsTerror() and #args == 2) then return end

		local idx = tonumber(args[1])
		local time = tonumber(args[2])

		if not idx or not time then return end

		local bomb = ents.GetByIndex(idx)

		if IsValid(bomb) and bomb:GetClass() == "ttt_c4" and (not bomb:GetArmed()) then
			if bomb:GetPos():Distance(ply:GetPos()) > 256 then
				-- These cases should never arise in normal play, so no messages
				return
			elseif time < C4_MINIMUM_TIME or time > C4_MAXIMUM_TIME then
				return
			elseif IsValid(bomb:GetPhysicsObject()) and bomb:GetPhysicsObject():HasGameFlag(FVPHYSICS_PLAYER_HELD) then
				return
			else
				LANG.Msg(ply, "c4_armed")

				bomb:Arm(ply, time)

				---
				-- @realm server
				hook.Run("TTTC4Arm", bomb, ply)
			end
		end
	end
	concommand.Add("ttt_c4_config", ReceiveC4Config)

	local function SendDisarmResult(ply, bomb, result)
		---
		-- @realm server
		hook.Run("TTTC4Disarm", bomb, result, ply)

		net.Start("TTT_C4DisarmResult")
		net.WriteEntity(bomb)
		net.WriteBit(result) -- this way we can squeeze this bit into 16
		net.Send(ply)
	end

	local function ReceiveC4Disarm(ply, cmd, args)
		if not (IsValid(ply) and ply:IsTerror() and #args == 2) then return end

		local idx = tonumber(args[1])
		local wire = tonumber(args[2])

		if not idx or not wire then return end

		local bomb = ents.GetByIndex(idx)

		if IsValid(bomb) and bomb:GetClass() == "ttt_c4" and not bomb.DisarmCausedExplosion and bomb:GetArmed() then
			if bomb:GetPos():Distance(ply:GetPos()) > 256 then
				return
			elseif bomb.SafeWires[wire] or ply:IsTraitor() or ply == bomb:GetOwner() then
				LANG.Msg(ply, "c4_disarmed")

				bomb:Disarm(ply)

				-- only case with success net message
				SendDisarmResult(ply, bomb, true)
			else
				SendDisarmResult(ply, bomb, false)

				-- wrong wire = bomb goes boom
				bomb:FailedDisarm(ply)
			end
		end
	end
	concommand.Add("ttt_c4_disarm", ReceiveC4Disarm)

	local function ReceiveC4Pickup(ply, cmd, args)
		if not (IsValid(ply) and ply:IsTerror() and #args == 1) then return end

		local idx = tonumber(args[1])
		if not idx then return end

		local bomb = ents.GetByIndex(idx)

		if IsValid(bomb) and bomb:GetClass() == "ttt_c4" and not bomb:GetArmed() then
			if bomb:GetPos():Distance(ply:GetPos()) > 256 then
				return
			else
				local prints = bomb.fingerprints or {}

				---
				-- @realm server
				hook.Run("TTTC4Pickup", bomb, ply)

				-- picks up weapon, switches if possible and needed, returns weapon if successful
				local wep = ply:SafePickupWeaponClass("weapon_ttt_c4", true)

				if not IsValid(wep) then
					LANG.Msg(ply, "c4_no_room")

					return
				end

				wep.fingerprints = wep.fingerprints or {}

				table.Add(wep.fingerprints, prints)

				bomb:Remove()
			end
		end
	end
	concommand.Add("ttt_c4_pickup", ReceiveC4Pickup)

	local function ReceiveC4Destroy(ply, cmd, args)
		if not (IsValid(ply) and ply:IsTerror() and #args == 1) then return end

		local idx = tonumber(args[1])
		if not idx then return end

		local bomb = ents.GetByIndex(idx)

		if IsValid(bomb) and bomb:GetClass() == "ttt_c4" and not bomb:GetArmed() then
			if bomb:GetPos():Distance(ply:GetPos()) > 256 then
				return
			else
				-- spark to show onlookers we destroyed this bomb
				util.EquipmentDestroyed(bomb:GetPos())

				---
				-- @realm server
				hook.Run("TTTC4Destroyed", bomb, ply)

				bomb:Remove()
			end
		end
	end
	concommand.Add("ttt_c4_destroy", ReceiveC4Destroy)
else -- CLIENT
	local TryT = LANG.TryTranslation
	local GetPT = LANG.GetParamTranslation

	local key_params = {
		usekey = Key("+use", "USE"),
		walkkey = Key("+walk", "WALK")
	}

	surface.CreateFont("C4ModelTimer", {
		font = "Default",
		size = 13,
		weight = 0,
		antialias = false
	})

	---
	-- @return table pos
	-- @realm client
	function ENT:GetTimerPos()
		local att = self:GetAttachment(self:LookupAttachment("controlpanel0_ur"))
		if att then
			return att
		else
			local ang = self:GetAngles()

			ang:RotateAroundAxis(self:GetUp(), -90)

			local pos = self:GetPos() + self:GetForward() * 4.5 + self:GetUp() * 9.0 + self:GetRight() * 7.8
			return {
				Pos = pos,
				Ang = ang
			}
		end
	end

	local strtime = util.SimpleTime
	local max = math.max

	---
	-- @realm client
	function ENT:Draw()
		self:DrawModel()

		if not self:GetArmed() then return end

		local angpos_ur = self:GetTimerPos()
		if not angpos_ur then return end

		cam.Start3D2D(angpos_ur.Pos, angpos_ur.Ang, 0.2)

		draw.DrawText(strtime(max(0, self:GetExplodeTime() - CurTime()), "%02i:%02i"), "C4ModelTimer", -1, 1, COLOR_RED, TEXT_ALIGN_RIGHT)

		cam.End3D2D()
	end

	-- handle looking at C4
	hook.Add("TTTRenderEntityInfo", "HUDDrawTargetIDC4", function(tData)
		local client = LocalPlayer()
		local ent = tData:GetEntity()
		local c_wep = client:GetActiveWeapon()

		if not IsValid(client) or not client:IsTerror() or not client:Alive()
		or not IsValid(ent) or tData:GetEntityDistance() > 100 or ent:GetClass() ~= "ttt_c4" then
			return
		end

		local defuser_useable = (IsValid(c_wep) and ent:GetArmed()) and c_wep:GetClass() == "weapon_ttt_defuser" or false

		-- enable targetID rendering
		tData:EnableText()
		tData:EnableOutline()
		tData:SetOutlineColor(client:GetRoleColor())

		tData:SetTitle(TryT(ent.PrintName))

		if ent:GetArmed() and defuser_useable then
			tData:SetSubtitle(GetPT("target_c4_armed_defuser", key_params))
		elseif ent:GetArmed() then
			tData:SetSubtitle(GetPT("target_c4_armed", key_params))
		else
			tData:SetSubtitle(GetPT("target_c4", key_params))
		end

		tData:SetKeyBinding(defuser_useable and "+attack" or "+use")
		tData:AddDescriptionLine(TryT("c4_short_desc"))
	end)
end
