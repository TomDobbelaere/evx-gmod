AddCSLuaFile()

-- shared
local function safeCall(f, ...) if f ~= nil then f(unpack({...})) end end

local function HasValidEVXType(ent) return ent:GetNWString("evxType", "") ~= "" end

local evxPlayerNPCs = {}

local function resetEVXFor(ent)
    ent:SetNWString("evxType", "")
    ent:SetNWInt("evxLevel", 0)
    ent:SetColor(Color(255, 255, 255, 255))
    ent:SetModelScale(1)

    evxPlayerNPCs[ent] = nil
end

local function randomEnemyLevel()
    local selectedRange = math.random(100)
    local min = 0
    local max = 0

    if selectedRange < 50 then
        min = 1
        max = 45
    elseif selectedRange < 95 then
        min = 45
        max = 75
    else
        min = 75
        max = 100
    end

    return math.random(min, max)
end

local bannedEssences = {
    ["cloaked"] = true,
    ["rogue"] = true,
    ["spidersack"] = true,
    ["motherchild"] = true,
    ["spiderbaby"] = true
}
local evxTypes = {
    "explosion", "mother", "boss", "bigboss", "knockback", "cloaked", "puller",
    "rogue", "pyro", "lifesteal", "metal", "gnome", "gas", "spidersack",
    "possessed", "mix2"
}
local deployableTypes = {
    ["gas"] = true,
    ["explosion"] = true,
    ["possessed"] = true
}
table.sort(evxTypes)
evxPendingInit = {}
-- possible evx properties and hooks:
-- color - ev-x NPC color
-- spawn(ent) - ev-x NPC spawn function 
-- entitycreated(npc, ent) - react to ANY entity being made on the map (npc = ourselves)
-- takedamage(target, dmginfo) - ev-x NPC is taking damage
-- givedamage(target, dmginfo) - ev-x NPC is giving damage
-- tick(ent) - ev-x tick, ent is the ev-x NPC itself
-- killed(ent, attacker, inflictor) - ev-x NPC was killed

local function evxExplosionKilled(ent, pos)
    local explosionMagnitude = tostring(ent:GetNWInt("evxLevel", 1) / 100 * 240) -- pre-level was 80
    local explode = ents.Create("env_explosion")
    explode:SetPos(pos)
    explode:SetOwner(ent)
    explode:Spawn()
    explode:SetKeyValue("iMagnitude", explosionMagnitude)
    explode:Fire("Explode", 0, 0)
end

local function evxGasKilled(ent, pos)
    local lvl = ent:GetNWInt("evxLevel", 1)
    local size = 'small'
    local lifetime = 0

    if lvl < 20 then
        size = 'small'
        lifetime = 15
    elseif lvl < 40 then
        size = 'medium'
        lifetime = 15
    elseif lvl < 80 then
        size = 'large'
        lifetime = 20
    else
        size = 'huge'
        lifetime = 25
    end

    local gasCloud = ents.Create("sent_evx_gascloud")
    gasCloud.size = size
    gasCloud.life = lifetime
    gasCloud:SetPos(pos)
    gasCloud:SetOwner(ent)
    gasCloud:Spawn()

    gasCloud:EmitSound(Sound("evx/gas.wav"), 100, 100)
end

local function evxPossessedKilled(ent, pos)
    local lvl = ent:GetNWInt("evxLevel", 1)
    local radius = 0
    local strength = 0

    if lvl < 40 then
        radius = 500
        strength = 1
    elseif lvl < 80 then
        radius = 1000
        strength = 2
    else
        radius = 1000
        strength = 3
    end

    local nearbyStuff = ents.FindInSphere(pos, 1000)
    for _, nearbyEnt in pairs(nearbyStuff) do
        if IsValid(nearbyEnt) and IsValid(nearbyEnt:GetPhysicsObject()) then
            local phys = nearbyEnt:GetPhysicsObject()
            phys:ApplyForceCenter((pos - nearbyEnt:GetPos()) * phys:GetMass() *
                                      3)
        end
    end

    ent:EmitSound(Sound("evx/horror3.wav"), 70, 100)
end

local function evxMotherKilled(ent, pos)
    local bmin, bmax = ent:GetModelBounds()
    local scale = ent:GetModelScale()
    local positions = {
        Vector(-bmax.x * scale, bmax.y * scale, 0),
        Vector(bmax.x * scale, bmax.y * scale, 0),
        Vector(-bmax.x * scale, -bmax.y * scale, 0),
        Vector(bmax.x * scale, -bmax.y * scale, 0)
    }

    for i, position in ipairs(positions) do
        local baby = nil
        if ent:IsPlayer() then
            baby = ents.Create("npc_citizen")
        else
            baby = ents.Create(ent:GetClass())
        end

        baby:SetPos(pos + position)

        if (ent:IsNPC() or ent:IsPlayer()) and IsValid(ent:GetActiveWeapon()) then
            baby:Give(ent:GetActiveWeapon():GetClass())
        end

        if ent:IsPlayer() then baby:Give("weapon_smg1") end

        baby:SetNWInt("evxLevel", ent:GetNWInt("evxLevel", 1))
        baby:SetNWString("evxType", "motherchild")
        baby:SetNWString("evxType2", nil)
        baby:Spawn()
        baby:Activate()

        if not ent:IsPlayer() then baby:SetModel(ent:GetModel()) end

        table.insert(evxPendingInit, baby)
    end
end

local evxConfig = {
    explosion = {
        color = Color(255, 0, 0, 255),
        killed = function(ent, attacker, inflictor)
            evxExplosionKilled(ent, ent:GetPos())
        end,
        plysecondary = function(ply)
            local trace = ply:GetEyeTrace()
            if not trace.Hit then return end

            evxExplosionKilled(ply, trace.HitPos)

            resetEVXFor(ply)
        end
    },
    gas = {
        color = Color(80, 255, 0, 255),
        killed = function(ent, attacker, inflictor)
            evxGasKilled(ent, ent:GetPos())
        end,
        plysecondary = function(ply)
            local trace = ply:GetEyeTrace()
            if not trace.Hit then return end

            evxGasKilled(ply, trace.HitPos)

            resetEVXFor(ply)
        end
    },
    spidersack = {
        color = Color(50, 100, 50, 255),
        spawn = function(ent) end,
        killed = function(ent, attacker, inflictor)
            local lvl = ent:GetNWInt("evxLevel", 1)
            local spiderCount = 0

            if lvl < 40 then
                spiderCount = 1
            elseif lvl < 80 then
                spiderCount = 2
            else
                spiderCount = 3
            end

            local bmin, bmax = ent:GetModelBounds()
            local scale = ent:GetModelScale()

            for i = -spiderCount, spiderCount do
                for j = -spiderCount, spiderCount do
                    local baby = ents.Create("npc_headcrab_fast")
                    baby:SetPos(ent:GetPos() +
                                    Vector(i * bmax.x * scale,
                                           j * bmax.y * scale, 0))

                    baby:SetNWInt("evxLevel", ent:GetNWInt("evxLevel", 1))
                    baby:SetNWString("evxType", "spiderbaby")
                    baby:SetNWString("evxType2", nil)
                    baby:Spawn()
                    baby:Activate()

                    table.insert(evxPendingInit, baby)
                end
            end
        end
    },
    spiderbaby = {
        color = Color(0, 0, 0, 255),
        spawn = function(ent)
            ent:SetModelScale(0.2)
            ent:SetHealth(1)

            if not ent.evxPermanent then
                -- clean spiders up after 1 to 5 minutes
                timer.Simple(math.Rand(60, 60 * 5), function()
                    if IsValid(ent) then
                        ent:TakeDamage(1, ent, ent)
                    end
                end)
            end
        end,
        tick = function(ent) ent:SetPlaybackRate(100) end,
        givedamage = function(target, dmginfo) dmginfo:SetDamage(1) end
    },
    possessed = {
        spawn = function(ent)
            ent:SetRenderFX(kRenderFxDistort)
            ent:SetRenderMode(RENDERMODE_TRANSCOLOR)
            ent.evxAttackTime = 0
            ent.evxPainTime = 0
        end,
        color = Color(10, 10, 10, 10),
        killed = function(ent) evxPossessedKilled(ent, ent:GetPos()) end,
        plysecondary = function(ply)
            local trace = ply:GetEyeTrace()
            if not trace.Hit then return end

            evxPossessedKilled(ply, trace.HitPos)

            resetEVXFor(ply)
        end,
        takedamage = function(target, dmginfo)
            local me = target

            if me.evxPainTime and (CurTime() - me.evxPainTime > 6) then
                me:EmitSound(Sound("evx/horror2.wav"), 70, 100)

                me.evxPainTime = CurTime()
            end
        end,
        givedamage = function(target, dmginfo)
            local me = dmginfo:GetInflictor()

            if me.evxAttackTime and (CurTime() - me.evxAttackTime > 6) then
                me:EmitSound(Sound("evx/horror4.wav"), 70, 100)

                me.evxAttackTime = CurTime()
            end
        end,
        tick = function(ent) ent:SetPlaybackRate(100) end
    },
    rogue = {
        color = Color(0, 0, 255, 255),
        entitycreated = function(npc, ent)
            if not ent:IsNPC() or ent:GetClass() == npc:GetClass() then
                return
            end

            if npc:IsNPC() then
                npc:AddEntityRelationship(ent, D_HT, 99)
            end

            ent:AddEntityRelationship(npc, D_HT, 99)

            if npc:IsNPC() then
                for i, v in ipairs(player.GetAll()) do
                    npc:AddEntityRelationship(v, D_HT, 99)
                end
            end
        end,
        spawn = function(ent)
            local enemies = ents.FindByClass("npc_*")
            for _, enemy in pairs(enemies) do
                if not enemy:IsNPC() or enemy:GetClass() == ent:GetClass() then
                    return
                end
                enemy:AddEntityRelationship(ent, D_HT, 99)

                if ent:IsNPC() then
                    ent:AddEntityRelationship(enemy, D_HT, 99)
                end
            end

            if ent:IsNPC() then
                for i, v in ipairs(player.GetAll()) do
                    ent:AddEntityRelationship(v, D_HT, 99)
                end
            end
        end
    },
    turret = {
        color = Color(128, 128, 128, 255),
        spawn = function(ent)
            ent:CapabilitiesClear()
            if IsValid(ent:GetPhysicsObject()) then
                ent:GetPhysicsObject():EnableMotion(false)
            end
        end
    },
    metal = {
        color = Color(255, 255, 255, 255),
        spawn = function(ent) ent:SetMaterial("debug/env_cubemap_model") end,
        takedamage = function(target, dmginfo)
            if not dmginfo:IsDamageType(DMG_BLAST) then
                dmginfo:ScaleDamage(0.1)
            end
            dmginfo:SetDamageType(DMG_SHOCK)
        end
    },
    gnome = {
        color = Color(0, 128, 255, 255),
        spawn = function(ent)
            ent:SetModelScale(0.4)
            ent:SetHealth(ent:Health() / 4)
        end,
        givedamage = function(target, dmginfo)
            if target:IsPlayer() or target:IsNPC() then
                if target:Health() > 1 then
                    dmginfo:SetDamage(target:Health() - 1)
                    dmginfo:GetInflictor():EmitSound(Sound("evx/gnomed.wav"),
                                                     70, 100)
                else
                    dmginfo:ScaleDamage(0)
                end
            end
        end
    },
    pyro = {
        color = Color(255, 128, 0, 255),
        givedamage = function(target, dmginfo)
            local lvl = dmginfo:GetInflictor():GetNWInt("evxLevel", 1) / 100
            local igniteTime = lvl * 4

            if target:IsPlayer() or target:IsNPC() or
                IsValid(target:GetPhysicsObject()) then
                target:Ignite(igniteTime)
            end
        end
    },
    lifesteal = {
        color = Color(0, 255, 130, 255),
        givedamage = function(target, dmginfo)
            local attacker = dmginfo:GetInflictor()

            local lvl = dmginfo:GetInflictor():GetNWInt("evxLevel", 1) / 100
            local lifestealFactor = 0
            if attacker:IsPlayer() then
                lifestealFactor = lvl * 2
            else
                lifestealFactor = lvl * 4
            end

            if target:IsPlayer() or target:IsNPC() then
                if IsValid(attacker) then
                    local lifestealDamage =
                        dmginfo:GetDamage() * lifestealFactor
                    if attacker:Health() < attacker:GetMaxHealth() then
                        attacker:SetHealth(
                            math.min(attacker:Health() + lifestealDamage,
                                     attacker:GetMaxHealth()))
                        attacker:EmitSound(Sound("items/medshot4.wav"), 75, 80)

                    end
                end
            end
        end
    },
    boss = {
        color = Color(80, 80, 100, 255),
        spawn = function(ent)
            ent:SetModelScale(1.5)
            ent:SetHealth(ent:Health() * 8)
        end,
        givedamage = function(target, dmginfo)
            local lvl = dmginfo:GetInflictor():GetNWInt("evxLevel", 1) / 100
            local dmg = lvl * 4

            dmginfo:ScaleDamage(dmg)
            dmginfo:SetDamageForce(dmginfo:GetDamageForce() * dmg)
        end
    },
    bigboss = {
        color = Color(0, 255, 255, 255),
        spawn = function(ent)
            ent:SetModelScale(2)
            ent:SetHealth(ent:Health() * 16)
        end,
        givedamage = function(target, dmginfo)
            local lvl = dmginfo:GetInflictor():GetNWInt("evxLevel", 1) / 100
            local dmg = lvl * 8

            dmginfo:ScaleDamage(dmg)
            dmginfo:SetDamageForce(dmginfo:GetDamageForce() * dmg)
        end
    },
    mother = {
        color = Color(255, 255, 0, 255),
        spawn = function(ent) ent:SetModelScale(1.5) end,
        killed = function(ent, attacker, inflictor)
            evxMotherKilled(ent, ent:GetPos())
        end,
        plysecondary = function(ply)
            local trace = ply:GetEyeTrace()
            if not trace.Hit then return end

            evxMotherKilled(ply, trace.HitPos + Vector(0, 0, 200))

            resetEVXFor(ply)
        end
    },
    motherchild = {
        color = Color(255, 128, 0, 255),
        spawn = function(ent)
            ent:SetModelScale(0.5)
            ent:SetHealth(ent:Health() / 3)
        end,
        givedamage = function(target, dmginfo)
            local lvl = dmginfo:GetInflictor():GetNWInt("evxLevel", 1) / 100
            local dmg = lvl * 2

            dmginfo:ScaleDamage(dmg)
            dmginfo:SetDamageForce(dmginfo:GetDamageForce() * dmg)
        end
    },
    knockback = {
        color = Color(255, 0, 255, 255),
        givedamage = function(target, dmginfo)
            local lvl = dmginfo:GetInflictor():GetNWInt("evxLevel", 1) / 100
            local knockback = lvl * 3

            if target:IsPlayer() or target:IsNPC() then
                target:SetVelocity(dmginfo:GetDamageForce() * knockback)
            else
                if IsValid(target:GetPhysicsObject()) then
                    target:GetPhysicsObject():SetVelocity(
                        dmginfo:GetDamageForce() * knockback)
                end
            end

        end
    },
    puller = {
        color = Color(0, 255, 0, 255),
        givedamage = function(target, dmginfo)
            local lvl = dmginfo:GetInflictor():GetNWInt("evxLevel", 1) / 100
            local pullAmount = lvl * -3
            local stunAmount = lvl * 0.4

            if target:IsPlayer() or target:IsNPC() then
                target:SetVelocity(dmginfo:GetDamageForce() * pullAmount)
                -- stun effect
                if target:IsPlayer() then
                    target:Freeze(true)
                    timer.Simple(stunAmount, function()
                        target:Freeze(false)
                    end)
                end
            else
                if IsValid(target:GetPhysicsObject()) then
                    target:GetPhysicsObject():SetVelocity(
                        dmginfo:GetDamageForce() * pullAmount)
                end
            end

        end
    },
    cloaked = {
        color = Color(255, 255, 255, 255),
        spawn = function(ent)
            ent:SetMaterial("evx/cloaked")
            ent:SetHealth(ent:Health() / 2)
        end,
        givedamage = function(target, dmginfo)
            local lvl = dmginfo:GetInflictor():GetNWInt("evxLevel", 1) / 100
            local scaledDamage = lvl * 3
            local force = lvl * 4

            dmginfo:ScaleDamage(scaledDamage)
            dmginfo:SetDamageForce(dmginfo:GetDamageForce() * force)
        end
    }
}

properties.Add("variants", {
    MenuLabel = "Variants",
    Order = 600,
    MenuIcon = "icon16/bug.png",
    Filter = function(self, ent, ply)
        if (not IsValid(ent)) then return false end
        if (not ent:IsNPC()) then return false end
        if (not gamemode.Call("CanProperty", ply, "variants", ent)) then
            return false
        end

        return true
    end,
    MenuOpen = function(self, option, ent, tr)
        local submenu = option:AddSubMenu()

        for k, v in pairs(evxTypes) do
            if v ~= 'mix2' then
                submenu:AddOption(v:gsub("^%l", string.upper),
                                  function()
                    self:SetVariant(ent, v)
                end)
            end
        end
    end,
    Action = function(self, ent) end,
    SetVariant = function(self, ent, variant)
        self:MsgStart()
        net.WriteEntity(ent)
        net.WriteString(variant)
        self:MsgEnd()
    end,
    Receive = function(self, length, player)
        local ent = net.ReadEntity()
        local variant = net.ReadString()

        if (not self:Filter(ent, player)) then return end

        if HasValidEVXType(ent) == false then
            ent:SetNWInt("evxLevel", randomEnemyLevel())
        end

        ent:SetNWString("evxType", variant)
        table.insert(evxPendingInit, ent)
    end
})

properties.Add("variants2", {
    MenuLabel = "Variants (type 2)",
    Order = 601,
    MenuIcon = "icon16/bug.png",
    Filter = function(self, ent, ply)
        if (not IsValid(ent)) then return false end
        if (not ent:IsNPC()) then return false end
        if (HasValidEVXType(ent) == false) then return false end
        if (not gamemode.Call("CanProperty", ply, "variants", ent)) then
            return false
        end

        return true
    end,
    MenuOpen = function(self, option, ent, tr)
        local submenu = option:AddSubMenu()

        for k, v in pairs(evxTypes) do
            if v ~= 'mix2' then
                submenu:AddOption(v:gsub("^%l", string.upper),
                                  function()
                    self:SetVariant(ent, v)
                end)
            end
        end
    end,
    Action = function(self, ent) end,
    SetVariant = function(self, ent, variant)
        self:MsgStart()
        net.WriteEntity(ent)
        net.WriteString(variant)
        self:MsgEnd()
    end,
    Receive = function(self, length, player)
        local ent = net.ReadEntity()
        local variant = net.ReadString()

        if (not self:Filter(ent, player)) then return end

        ent:SetNWString("evxType2", variant)
        table.insert(evxPendingInit, ent)
    end
})

properties.Add("variantslevel", {
    MenuLabel = "Variant level",
    Order = 602,
    MenuIcon = "icon16/bug_edit.png",
    Filter = function(self, ent, ply)
        if (not IsValid(ent)) then return false end
        if (not ent:IsNPC()) then return false end
        if (not gamemode.Call("CanProperty", ply, "variants", ent)) then
            return false
        end

        return true
    end,
    MenuOpen = function(self, option, ent, tr)
        local submenu = option:AddSubMenu()

        for _, v in pairs({1, 5, 15, 30, 50, 70, 90, 100}) do
            submenu:AddOption('Lv. ' .. v,
                              function() self:SetVariantLevel(ent, v) end)
        end
    end,
    Action = function(self, ent) end,
    SetVariantLevel = function(self, ent, level)
        self:MsgStart()
        net.WriteEntity(ent)
        net.WriteInt(level, 8)
        self:MsgEnd()
    end,
    Receive = function(self, length, player)
        local ent = net.ReadEntity()
        local level = net.ReadInt(8)

        if (not self:Filter(ent, player)) then return end

        ent:SetNWInt("evxLevel", level)
        table.insert(evxPendingInit, ent)
    end
})

if CLIENT then
    CreateClientConVar("evx_draw_hud", "1", true, false,
                       "Disable drawing the ev-x hud, like displaying NPC health and type",
                       0, 1)

    hook.Add("AddToolMenuCategories", "EVXCategory", function()
        spawnmenu.AddToolCategory("Utilities", "EV-X", "EV-X")
    end)

    hook.Add("PopulateToolMenu", "EVXSettings", function()
        spawnmenu.AddToolMenuOption("Utilities", "EV-X", "Spawnrates",
                                    "Spawnrates", "", "", function(panel)
            panel:ClearControls()

            panel:NumSlider("Nothing", "evx_rate_nothing", 0, 200)
            for _, v in pairs(evxTypes) do
                panel:NumSlider(v:gsub("^%l", string.upper), "evx_rate_" .. v,
                                0, 200)
            end

            panel:NumSlider("Random spiders chance",
                            "evx_random_spiders_chance", 0, 1)
            panel:NumSlider("Essence drop chance", "evx_essence_chance", 0, 1)
            panel:NumSlider("Essence timer factor", "evx_essence_timer_factor",
                            0, 100)

            panel:Button("RESET all", "evx_rate_reset_all")
        end)

        spawnmenu.AddToolMenuOption("Utilities", "EV-X", "General", "General",
                                    "", "", function(panel)
            panel:ClearControls()
            panel:CheckBox("Enabled", "evx_enabled")
            panel:CheckBox("Affect allies", "evx_affect_allies")
            panel:CheckBox("Use colors", "evx_use_colors")
            panel:CheckBox("Use color intensity for levels",
                           "evx_level_use_color_intensity")
            panel:CheckBox("Randomize on rate change",
                           "evx_randomize_on_rate_change")
            panel:CheckBox("Enable music events", "evx_allow_music")
            panel:NumSlider("Force level", "evx_level_force", 0, 100)
        end)
    end)

    hook.Add("HUDPaint", "HUDPaintEVXSelf", function()
        if not HasValidEVXType(LocalPlayer()) then return end

        local essenceStart = LocalPlayer():GetNWFloat("essenceStart", CurTime())
        local essenceTimePassed = CurTime() - essenceStart
        local essenceMax = LocalPlayer():GetNWFloat("essenceMax", 0)
        local essenceTimeLeft = essenceMax - essenceTimePassed
        local essenceTimeLeftString = " (" .. math.Round(essenceTimeLeft) ..
                                          " seconds left)"

        if essenceTimeLeft > 800 then essenceTimeLeftString = "" end

        text =
            "Active: " .. string.upper(LocalPlayer():GetNWString("evxType")) ..
                " Lv." .. LocalPlayer():GetNWInt("evxLevel", -1) ..
                essenceTimeLeftString
        evxType = LocalPlayer():GetNWString("evxType")

        local font = "DermaLarge"

        surface.SetFont(font)
        local w, h = surface.GetTextSize(text)

        local MouseX, MouseY = gui.MousePos()

        if (MouseX == 0 and MouseY == 0) then

            MouseX = ScrW() / 2
            MouseY = ScrH() - 128
        end

        local x = MouseX
        local y = MouseY

        x = x - w / 2
        y = y + 30

        -- The fonts internal drop shadow looks lousy with AA on
        draw.RoundedBox(4, x - 8, y - 8, w + 16, h + 16, Color(0, 0, 0, 200))
        draw.SimpleText(text, font, x + 2, y + 2, Color(0, 0, 0, 120))
        draw.SimpleText(text, font, x + 4, y + 4, Color(0, 0, 0, 50))
        draw.SimpleText(text, font, x, y, evxConfig[evxType].color)

        if deployableTypes[LocalPlayer():GetNWString("evxType")] then
            text = "CROUCH + SECONDARY FIRE TO DEPLOY SPECIAL"
            font = "TargetID"

            x = ScrW() / 2
            y = ScrH() / 3

            surface.SetFont(font)
            local w, h = surface.GetTextSize(text)
            local x = MouseX - w / 2

            draw.SimpleText(text, font, x + 1, y + 1, Color(0, 0, 0, 120))
            draw.SimpleText(text, font, x + 2, y + 2, Color(0, 0, 0, 50))
            draw.SimpleText(text, font, x, y,
                            evxConfig[LocalPlayer():GetNWString("evxType")]
                                .color)
        end
    end)

    hook.Add("HUDPaint", "HUDPaint_DrawABox", function()
        if not GetConVar("evx_draw_hud"):GetBool() then return end

        local tr = util.GetPlayerTrace(LocalPlayer())
        local trace = util.TraceLine(tr)
        if (not trace.Hit) then return end
        if (not trace.HitNonWorld) then return end

        local text = "ERROR"
        local font = "TargetID"
        local evxType = ""
        local evxType2 = ""

        if HasValidEVXType(trace.Entity) then
            text = string.upper(trace.Entity:GetNWString("evxType"))

            if trace.Entity:GetClass() == "sent_evx_essence" then
                text = text .. " ESSENCE"
            end

            evxType = trace.Entity:GetNWString("evxType")
        else
            return
        end

        if evxType == "cloaked" or evxType == "spiderbaby" then return end

        surface.SetFont(font)
        local w, h = surface.GetTextSize(text)

        local MouseX, MouseY = gui.MousePos()

        if (MouseX == 0 and MouseY == 0) then

            MouseX = ScrW() / 2
            MouseY = ScrH() / 2

        end

        local x = MouseX
        local y = MouseY

        x = x - w / 2
        y = y + 30

        -- The fonts internal drop shadow looks lousy with AA on
        draw.SimpleText(text, font, x + 1, y + 1, Color(0, 0, 0, 120))
        draw.SimpleText(text, font, x + 2, y + 2, Color(0, 0, 0, 50))
        draw.SimpleText(text, font, x, y, evxConfig[evxType].color)

        if trace.Entity:GetNWString("evxType2", false) then
            text = string.upper(trace.Entity:GetNWString("evxType2"))
            evxType2 = trace.Entity:GetNWString("evxType2")

            y = y + h + 5

            surface.SetFont(font)
            local w, h = surface.GetTextSize(text)
            local x = MouseX - w / 2

            draw.SimpleText(text, font, x + 1, y + 1, Color(0, 0, 0, 120))
            draw.SimpleText(text, font, x + 2, y + 2, Color(0, 0, 0, 50))
            draw.SimpleText(text, font, x, y, evxConfig[evxType2].color)
        end

        y = y + h + 5

        local level = trace.Entity:GetNWInt("evxLevel", -1)
        local text = 'Lv. ' .. level
        local font = "TargetID"
        local levelColor = Color(180, 180, 180)
        if level >= 90 then
            levelColor = Color(255, 0, 0) -- red
        elseif level >= 70 then
            levelColor = Color(255, 128, 0) -- orange
        elseif level >= 50 then
            levelColor = Color(255, 255, 0) -- yellow
        elseif level >= 30 then
            levelColor = Color(0, 128, 255) -- blue
        elseif level >= 15 then
            levelColor = Color(0, 255, 200) -- green-blue
        elseif level >= 5 then
            levelColor = Color(0, 255, 0) -- green
        end

        surface.SetFont(font)
        local w, h = surface.GetTextSize(text)
        local x = MouseX - w / 2

        draw.SimpleText(text, font, x + 1, y + 1, Color(0, 0, 0, 120))
        draw.SimpleText(text, font, x + 2, y + 2, Color(0, 0, 0, 50))
        draw.SimpleText(text, font, x, y, levelColor)

        if not (trace.Entity:GetClass() == "sent_evx_essence") then
            y = y + h + 5

            local text = trace.Entity:Health() .. " HP"
            local font = "TargetID"

            surface.SetFont(font)
            local w, h = surface.GetTextSize(text)
            local x = MouseX - w / 2

            draw.SimpleText(text, font, x + 1, y + 1, Color(0, 0, 0, 120))
            draw.SimpleText(text, font, x + 2, y + 2, Color(0, 0, 0, 50))
            draw.SimpleText(text, font, x, y, Color(255, 255, 255))
        end
    end)
end

if SERVER then
    CreateConVar("evx_enabled", "1", {FCVAR_REPLICATED, FCVAR_ARCHIVE},
                 "Enable enemy variations", 0, 1)
    CreateConVar("evx_allow_music", "1", {FCVAR_REPLICATED, FCVAR_ARCHIVE},
                 "Enable EV-X music events", 0, 1)
    CreateConVar("evx_affect_allies", "1", {FCVAR_REPLICATED, FCVAR_ARCHIVE},
                 "Include allies like Alyx, rebels or animals in getting variations",
                 0, 1)
    CreateConVar("evx_use_colors", "1", {FCVAR_REPLICATED, FCVAR_ARCHIVE},
                 "Use colors on the NPC to indicate the type of variant they are",
                 0, 1)
    CreateConVar("evx_randomize_on_rate_change", "1",
                 {FCVAR_REPLICATED, FCVAR_ARCHIVE},
                 "Re-randomize the NPC variations when the spawnrates change",
                 0, 1)
    CreateConVar("evx_rate_nothing", "50", {FCVAR_REPLICATED, FCVAR_ARCHIVE},
                 "The spawnrate of the 'no' ev-x modifier in enemies", 0, 100000)
    CreateConVar("evx_rate_knockback", "40", {FCVAR_REPLICATED, FCVAR_ARCHIVE},
                 "The spawnrate of the knockback ev-x modifier in enemies", 0,
                 100000)
    CreateConVar("evx_rate_puller", "35", {FCVAR_REPLICATED, FCVAR_ARCHIVE},
                 "The spawnrate of the puller ev-x modifier in enemies", 0,
                 100000)
    CreateConVar("evx_rate_pyro", "35", {FCVAR_REPLICATED, FCVAR_ARCHIVE},
                 "The spawnrate of the pyro ev-x modifier in enemies", 0, 100000)
    CreateConVar("evx_rate_lifesteal", "15", {FCVAR_REPLICATED, FCVAR_ARCHIVE},
                 "The spawnrate of the lifesteal ev-x modifier in enemies", 0,
                 100000)
    CreateConVar("evx_rate_explosion", "30", {FCVAR_REPLICATED, FCVAR_ARCHIVE},
                 "The spawnrate of the explosion ev-x modifier in enemies", 0,
                 100000)
    CreateConVar("evx_rate_cloaked", "30", {FCVAR_REPLICATED, FCVAR_ARCHIVE},
                 "The spawnrate of the cloaked ev-x modifier in enemies", 0,
                 100000)
    CreateConVar("evx_rate_mother", "20", {FCVAR_REPLICATED, FCVAR_ARCHIVE},
                 "The spawnrate of the mother ev-x modifier in enemies", 0,
                 100000)
    CreateConVar("evx_rate_boss", "15", {FCVAR_REPLICATED, FCVAR_ARCHIVE},
                 "The spawnrate of the boss ev-x modifier in enemies", 0, 100000)
    CreateConVar("evx_rate_rogue", "15", {FCVAR_REPLICATED, FCVAR_ARCHIVE},
                 "The spawnrate of the rogue ev-x modifier in enemies", 0,
                 100000)
    CreateConVar("evx_rate_bigboss", "5", {FCVAR_REPLICATED, FCVAR_ARCHIVE},
                 "The spawnrate of the bigboss ev-x modifier in enemies", 0,
                 100000)
    CreateConVar("evx_rate_mix2", "15", {FCVAR_REPLICATED, FCVAR_ARCHIVE},
                 "The spawnrate of the mix2 ev-x modifier in enemies", 0, 100000)
    CreateConVar("evx_rate_metal", "15", {FCVAR_REPLICATED, FCVAR_ARCHIVE},
                 "The spawnrate of the metal ev-x modifier in enemies", 0,
                 100000)
    CreateConVar("evx_rate_gnome", "2", {FCVAR_REPLICATED, FCVAR_ARCHIVE},
                 "The spawnrate of the gnome ev-x modifier in enemies", 0,
                 100000)
    CreateConVar("evx_rate_gas", "20", {FCVAR_REPLICATED, FCVAR_ARCHIVE},
                 "The spawnrate of the gas ev-x modifier in enemies", 0, 100000)
    CreateConVar("evx_rate_spidersack", "20", {FCVAR_REPLICATED, FCVAR_ARCHIVE},
                 "The spawnrate of the spidersack ev-x modifier in enemies", 0,
                 100000)
    CreateConVar("evx_rate_possessed", "15", {FCVAR_REPLICATED, FCVAR_ARCHIVE},
                 "The spawnrate of the possessed ev-x modifier in enemies", 0,
                 100000)
    CreateConVar("evx_essence_chance", "0.2", {FCVAR_REPLICATED, FCVAR_ARCHIVE},
                 "The odds of getting an essence drop from an enemy, 1 means 100% of the time",
                 0, 1)
    CreateConVar("evx_essence_timer_factor", "1",
                 {FCVAR_REPLICATED, FCVAR_ARCHIVE},
                 "Change the multiplier of the essence time calculation, 2 would result in double essence time for everything",
                 0, 100000)

    CreateConVar("evx_level_force", "0", {FCVAR_REPLICATED, FCVAR_ARCHIVE},
                 "Force a level for all ev-x enemies, 0 to disable", 0, 100)
    CreateConVar("evx_level_use_color_intensity", "1",
                 {FCVAR_REPLICATED, FCVAR_ARCHIVE},
                 "Use color intensity to display an ev-x enemy's level", 0, 1)
    CreateConVar("evx_random_spiders_chance", "0.02",
                 {FCVAR_REPLICATED, FCVAR_ARCHIVE},
                 "The odds of getting random spider babies around physics props, 1 means 100% of the time",
                 0, 1)

    local function IsEvxEnabled() return GetConVar("evx_enabled"):GetBool() end
    local function CanPlayMusic()
        return GetConVar("evx_allow_music"):GetBool()
    end
    local function IsRandomizingOnRateChange()
        return GetConVar("evx_randomize_on_rate_change"):GetBool()
    end
    local function IsAffectingAllies()
        return GetConVar("evx_affect_allies"):GetBool()
    end
    local function IsUsingColors()
        return GetConVar("evx_use_colors"):GetBool()
    end
    local function IsUsingLevelColors()
        return GetConVar("evx_level_use_color_intensity"):GetBool()
    end
    local function GetSpawnRateFor(type)
        return GetConVar("evx_rate_" .. type):GetInt()
    end
    local function GetRandomSpidersChance()
        return GetConVar("evx_random_spiders_chance"):GetFloat()
    end
    local function GetEssenceChance()
        return GetConVar("evx_essence_chance"):GetFloat()
    end
    local function GetEssenceTimerFactor()
        return GetConVar("evx_essence_timer_factor"):GetFloat()
    end
    local function GetForcedLevel()
        return GetConVar("evx_level_force"):GetInt()
    end

    local evxNPCs = {}
    local evxTickNPCs = {}
    local evxMixNPCs = {}
    local allies = {
        ["npc_alyx"] = 1,
        ["npc_magnusson"] = 1,
        ["npc_breen"] = 1,
        ["npc_kleiner"] = 1,
        ["npc_barney"] = 1,
        ["npc_crow"] = 1,
        ["npc_dog"] = 1,
        ["npc_eli"] = 1,
        ["npc_gman"] = 1,
        ["npc_monk"] = 1,
        ["npc_mossman"] = 1,
        ["npc_pigeon"] = 1,
        ["npc_vortigaunt"] = 1,
        ["npc_seagull"] = 1,
        ["npc_citizen"] = 1,
        ["npc_fisherman"] = 1,
        ["monster_barney"] = 1,
        ["monster_cockroach"] = 1,
        ["monster_scientist"] = 1
    }

    local evxChances = {}
    local evxChancesMix = {}
    local weightSum = 0
    local weightSumMix = 0

    local function GetRandomType(chances, weightSum)
        local randomWeight = math.random(weightSum)

        for k, v in pairs(chances) do
            randomWeight = randomWeight - v
            if randomWeight <= 0 then return k end
        end
    end

    local function evxApply(ent)
        if not IsEvxEnabled() then return end
        if ent.evxIgnore then return end

        if ent:GetClass() == "prop_physics" and math.random() <
            GetRandomSpidersChance() then
            local baby = ents.Create("npc_headcrab_fast")

            timer.Simple(0, function()
                if IsValid(baby) and IsValid(ent) then
                    local min, max = ent:GetCollisionBounds()

                    baby:SetPos(ent:GetPos() + Vector(0, 0, max.z))
                end
            end)

            baby.evxPermanent = true
            baby:SetNWString("evxType", "spiderbaby")
            baby:SetNWString("evxType2", nil)
            baby:Spawn()
            baby:Activate()

            table.insert(evxPendingInit, baby)
        end

        if IsValid(ent) and ent:IsNPC() then
            -- if they're an ally and the player doesn't want allies affected, bail out
            if not IsAffectingAllies() and allies[ent:GetClass()] then
                return
            end

            -- Weighted random selection
            local randomWeight = math.random(weightSum)
            for k, v in pairs(evxChances) do
                randomWeight = randomWeight - v
                if randomWeight <= 0 then
                    if k == "nothing" then break end
                    if k == "mix2" then
                        local firstType =
                            GetRandomType(evxChancesMix, weightSumMix)
                        ent:SetNWString("evxType", firstType)
                        local secondTypes = table.Copy(evxChancesMix)
                        secondTypes[firstType] = nil
                        ent:SetNWString("evxType2", GetRandomType(secondTypes,
                                                                  weightSumMix))
                        ent:SetNWInt("evxLevel", randomEnemyLevel())
                        table.insert(evxPendingInit, ent)
                        break
                    end

                    ent:SetNWString("evxType", k)

                    if GetForcedLevel() > 0 then
                        ent:SetNWInt("evxLevel", GetForcedLevel())
                    else
                        ent:SetNWInt("evxLevel", randomEnemyLevel())
                    end

                    table.insert(evxPendingInit, ent)
                    break
                end
            end
        end

        for evxNPC, _ in pairs(evxNPCs) do
            if IsValid(evxNPC) and HasValidEVXType(evxNPC) then
                safeCall(evxConfig[evxNPC:GetNWString("evxType")].entitycreated,
                         evxNPC, ent)
            end
        end
    end

    local function recalculateWeights()
        evxChances = {
            ["nothing"] = GetSpawnRateFor("nothing"),
            ["spidersack"] = GetSpawnRateFor("spidersack"),
            ["possessed"] = GetSpawnRateFor("possessed"),
            ["gas"] = GetSpawnRateFor("gas"),
            ["lifesteal"] = GetSpawnRateFor("lifesteal"),
            ["metal"] = GetSpawnRateFor("metal"),
            ["gnome"] = GetSpawnRateFor("gnome"),
            ["knockback"] = GetSpawnRateFor("knockback"),
            ["puller"] = GetSpawnRateFor("puller"),
            ["pyro"] = GetSpawnRateFor("pyro"),
            ["explosion"] = GetSpawnRateFor("explosion"),
            ["cloaked"] = GetSpawnRateFor("cloaked"),
            ["mother"] = GetSpawnRateFor("mother"),
            ["boss"] = GetSpawnRateFor("boss"),
            ["rogue"] = GetSpawnRateFor("rogue"),
            ["bigboss"] = GetSpawnRateFor("bigboss"),
            -- ["turret"] = 10000,
            ["mix2"] = GetSpawnRateFor("mix2")
        }

        evxChancesMix = table.Copy(evxChances)
        evxChancesMix["mix2"] = nil
        evxChancesMix["nothing"] = nil

        weightSum = 0
        for k, v in pairs(evxChances) do weightSum = weightSum + v end

        weightSumMix = 0
        for k, v in pairs(evxChancesMix) do
            weightSumMix = weightSumMix + v
        end

        if IsRandomizingOnRateChange() then
            for evxNPC, _ in pairs(evxNPCs) do
                if IsValid(evxNPC) and evxNPC:IsNPC() then
                    evxNPC:SetNWString("evxType", nil)
                    evxNPC:SetNWString("evxType2", nil)

                    evxMixNPCs[evxNPC] = nil
                    evxTickNPCs[evxNPC] = nil

                    evxApply(evxNPC)
                end
            end
        end
    end

    recalculateWeights()

    cvars.AddChangeCallback("evx_rate_nothing", recalculateWeights)
    for k, v in pairs(evxTypes) do
        cvars.AddChangeCallback("evx_rate_" .. v, recalculateWeights)
    end

    concommand.Add("evx_rate_reset_all", function()
        GetConVar("evx_rate_nothing"):Revert()
        for _, v in pairs(evxTypes) do
            GetConVar("evx_rate_" .. v):Revert()
        end
        GetConVar("evx_random_spiders_chance"):Revert()
        GetConVar("evx_essence_chance"):Revert()
        GetConVar("evx_essence_timer_factor"):Revert()
        GetConVar("evx_level_force"):Revert()
    end)

    -- TODO NPC variation exclusions:
    -- copy chances table
    -- remove bad variations for this npc
    -- subtract removed weights from the weightsum 
    -- use new weightsum and new chances table

    -- Jerkakame
    -- infected variant
    -- that spawns a headcrab
    -- the headcrab infects others

    local evxChancesType2 = {
        ["explosion"] = 50,
        ["knockback"] = 20,
        ["boss"] = 20,
        ["mother"] = 20,
        ["bigboss"] = 5
    }
    local weightSumType2 = 0
    for k, v in pairs(evxChancesType2) do weightSumType2 = weightSumType2 + v end

    function evxInit(ent)
        -- reset these before a modifier changes it
        ent:SetModelScale(1)
        if not ent:IsPlayer() then
            ent:SetHealth(ent:GetMaxHealth())
        else
            ent:SetHealth(math.min(ent:GetMaxHealth(), ent:Health() + 15))
        end
        ent:SetMaterial("")
        ent:SetRenderFX(kRenderFxNone)
        ent:SetRenderMode(RENDERMODE_NORMAL)

        if IsUsingColors() then
            local variationStrength = math.max(0.4,
                                               ent:GetNWInt("evxLevel", 1) / 100)

            if ent:GetNWString("evxType") == 'spiderbaby' or
                (not IsUsingLevelColors()) then variationStrength = 1 end

            local col = evxConfig[ent:GetNWString("evxType")].color
            local def = Color(255, 255, 255, 255)
            local lerpedCol = Color(Lerp(variationStrength, def.r, col.r),
                                    Lerp(variationStrength, def.g, col.g),
                                    Lerp(variationStrength, def.b, col.b))

            ent:SetColor(lerpedCol)
        end

        if ent:GetNWString("evxType2", false) then
            ent:SetMaterial("models/shiny")

            if evxConfig[ent:GetNWString("evxType2")].tick ~= nil then
                evxTickNPCs[ent] = true
            end

            evxMixNPCs[ent] = true

            safeCall(evxConfig[ent:GetNWString("evxType2")].spawn, ent)
        end

        safeCall(evxConfig[ent:GetNWString("evxType")].spawn, ent)

        if evxConfig[ent:GetNWString("evxType")].tick ~= nil then
            evxTickNPCs[ent] = true
        end

        evxNPCs[ent] = true

        if ent:IsPlayer() then evxPlayerNPCs[ent] = true end
    end

    local function EVXOnKilled(ent, attacker, inflictor)
        if not IsEvxEnabled() then return end

        -- we're a ev-x enemy getting killed
        if IsValid(ent) and HasValidEVXType(ent) then
            safeCall(evxConfig[ent:GetNWString("evxType")].killed, ent,
                     attacker, inflictor)

            if not bannedEssences[ent:GetNWString("evxType")] and math.random() <
                GetEssenceChance() then
                local essence = ents.Create("sent_evx_essence")
                essence:SetPos(ent:GetPos())
                essence:SetAngles(ent:GetAngles())
                essence:Spawn()
                essence:Activate()

                essence:SetEVXType(ent:GetNWString("evxType"),
                                   ent:GetNWInt("evxLevel"), evxConfig)
            end

            if ent:GetNWString("evxType2", false) then
                safeCall(evxConfig[ent:GetNWString("evxType2")].killed, ent,
                         attacker, inflictor)
            end

            evxNPCs[ent] = nil
            evxPlayerNPCs[ent] = nil
            evxTickNPCs[ent] = nil
            evxMixNPCs[ent] = nil
        end
    end

    hook.Add("OnNPCKilled", "EVXOnNPCKilled", function(ent, attacker, inflictor)
        EVXOnKilled(ent, attacker, inflictor)
    end)

    hook.Add("PlayerDeath", "EVXOnPlayerKilled",
             function(ent, inflictor, attacker)
        EVXOnKilled(ent, attacker, inflictor)

        if HasValidEVXType(ent) then resetEVXFor(ent) end
    end)

    hook.Add("EntityRemoved", "EVXEntityRemoved", function(ent)
        if IsValid(ent) and HasValidEVXType(ent) then
            evxNPCs[ent] = nil
            evxPlayerNPCs[ent] = nil
            evxTickNPCs[ent] = nil
            evxMixNPCs[ent] = nil
        end
    end)

    hook.Add("EntityTakeDamage", "EVXEntityTakeDamage",
             function(target, dmginfo)
        if not IsEvxEnabled() then return end

        -- we're a ev-x enemy taking damage
        if IsValid(target) and HasValidEVXType(target) then
            safeCall(evxConfig[target:GetNWString("evxType")].takedamage,
                     target, dmginfo)

            if target:GetNWString("evxType2", false) then
                safeCall(evxConfig[target:GetNWString("evxType2")].takedamage,
                         target, dmginfo)
            end
        end

        -- we're an entity taking damage from an ev-x enemy
        if IsValid(target) and IsEntity(target) and
            IsValid(dmginfo:GetAttacker()) and
            HasValidEVXType(dmginfo:GetAttacker()) then
            safeCall(evxConfig[dmginfo:GetAttacker():GetNWString("evxType")]
                         .givedamage, target, dmginfo)

            if dmginfo:GetAttacker():GetNWString("evxType2", false) then
                safeCall(
                    evxConfig[dmginfo:GetAttacker():GetNWString("evxType2")]
                        .givedamage, target, dmginfo)
            end
        end
    end)

    hook.Add("OnEntityCreated", "EVXSpawnedNPC", evxApply)

    hook.Add("KeyPress", "EVXKeyPress", function(ply, key)
        if IsValid(ply) and HasValidEVXType(ply) then
            if key == IN_ATTACK2 and ply:Crouching() then
                safeCall(evxConfig[ply:GetNWString("evxType")].plysecondary, ply)
            end
        end
    end)

    hook.Add("Think", "EVXThink", function()
        if not IsEvxEnabled() then return end

        for evxPendingIndex = 1, #evxPendingInit do
            local evxNPC = evxPendingInit[evxPendingIndex]
            if IsValid(evxNPC) and HasValidEVXType(evxNPC) then
                if evxNPC:IsPlayer() then
                    local level = evxNPC:GetNWInt("evxLevel", 0)

                    evxNPC:SetNWFloat("essenceMax", 1 / level * 8000 *
                                          GetEssenceTimerFactor())

                    if level == 100 and CanPlayMusic() then
                        evxNPC:EmitSound("evx/credits.mp3")
                    end
                end

                evxInit(evxNPC)
            end
        end

        for evxPlayerNPC, _ in pairs(evxPlayerNPCs) do
            if CurTime() - evxPlayerNPC:GetNWFloat("essenceStart", 0) >
                evxPlayerNPC:GetNWFloat("essenceMax", 0) then
                resetEVXFor(evxPlayerNPC)
            end
        end

        for evxNPC, _ in pairs(evxTickNPCs) do
            if IsValid(evxNPC) and HasValidEVXType(evxNPC) then
                safeCall(evxConfig[evxNPC:GetNWString("evxType")].tick, evxNPC)
            end

            if IsValid(evxNPC) and evxNPC:GetNWString("evxType2", false) then
                safeCall(evxConfig[evxNPC:GetNWString("evxType2")].tick, evxNPC)
            end
        end

        if IsUsingColors() then
            for evxNPC, _ in pairs(evxMixNPCs) do
                if IsValid(evxNPC) and HasValidEVXType(evxNPC) and
                    evxNPC:GetNWString("evxType2", false) then
                    if evxNPC.evxMix2Flash == nil then
                        evxNPC.evxMix2Flash = false
                        evxNPC.evxMix2Last = CurTime()
                    end

                    local col = Color(255, 255, 255, 255)

                    if evxNPC.evxMix2Flash then
                        col = evxConfig[evxNPC:GetNWString("evxType")].color
                    else
                        col = evxConfig[evxNPC:GetNWString("evxType2")].color
                    end

                    local curr = evxNPC:GetColor()
                    evxNPC:SetColor(Color(Lerp(0.3, curr.r, col.r),
                                          Lerp(0.3, curr.g, col.g),
                                          Lerp(0.3, curr.b, col.b), 255))

                    -- evxNPC:SetColor(col)

                    if CurTime() - evxNPC.evxMix2Last > 0.25 then
                        evxNPC.evxMix2Flash = not evxNPC.evxMix2Flash
                        evxNPC.evxMix2Last = CurTime()
                    end
                end
            end
        end

        evxPendingInit = {}
    end)
end
