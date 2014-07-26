print("gamemode started to load...")

--[[
    SETTINGS
]]

-- Voting period
local votingTime = 60

-- Banning Period
local banningTime = 90

-- Picking Time
local pickingTime = 120

-- Should we auto allocate teams?
local autoAllocateTeams = false

--[[
    VOTEABLE OPTIONS
]]

-- Total number of skill slots to allow
local maxSlots = 5

-- Total number of normal skills to allow
local maxSkills = 4

-- Total number of ults to allow (Ults are always on the right)
local maxUlts = 1

-- Should we ban troll combos?
local banTrollCombos = true

--[[
    GAMEMODE STUFF
]]

-- Max number of bans
local maxBans = 5

-- Colors
local COLOR_BLUE = '#4B69FF'
local COLOR_RED = '#EB4B4B'
local COLOR_GREEN = '#ADE55C'

-- Stage constants
local STAGE_WAITING = 0
local STAGE_VOTING = 1
local STAGE_BANNING = 2
local STAGE_PICKING = 3
local STAGE_PLAYING = 4

-- The current stage we are in
local currentStage = STAGE_WAITING

-- Player's vote data, key = playerID
local voteData = {}

-- Table of banned skills
local bannedSkills = {}

-- Skill list for a given player
local skillList = {}

-- The total amount banned by each player
local totalBans = {}

-- When the hero selection started
local heroSelectionStart = nil

-- A list of warning attached to skills
local skillWarnings = {
    life_stealer_infest = '<font color="'..COLOR_RED..'">Warning:</font> <font color="'..COLOR_BLUE..'">life_stealer_infest</font> <font color="'..COLOR_GREEN..'">requires </font><font color="'..COLOR_BLUE..'">life_stealer_rage</font> <font color="'..COLOR_GREEN..'">if you want to uninfest.</font>',
    phantom_lancer_phantom_edge = '<font color="'..COLOR_RED..'">Warning:</font> <font color="'..COLOR_BLUE..'">phantom_lancer_phantom_edge</font> <font color="'..COLOR_GREEN..'">requires </font><font color="'..COLOR_BLUE..'">phantom_lancer_juxtapose</font> <font color="'..COLOR_GREEN..'">in order to make illusions.</font>',
    keeper_of_the_light_spirit_form = '<font color="'..COLOR_RED..'">Warning:</font> <font color="'..COLOR_BLUE..'">keeper_of_the_light_spirit_form</font> <font color="'..COLOR_GREEN..'">will not give you the two extra spells!</font>',
    ogre_magi_multicast = '<font color="'..COLOR_RED..'">Warning:</font> <font color="'..COLOR_BLUE..'">ogre_magi_multicast</font> <font color="'..COLOR_GREEN..'">ONLY works on Ogre Magi\'s spells!</font>',
    --doom_bringer_devour = '<font color="'..COLOR_RED..'">Warning:</font> <font color="'..COLOR_BLUE..'">doom_bringer_devour</font> <font color="'..COLOR_GREEN..'">will replace your slot 4 and 5 with creep skills!</font>',
    rubick_spell_steal = '<font color="'..COLOR_RED..'">Warning:</font> <font color="'..COLOR_BLUE..'">rubick_spell_steal</font> <font color="'..COLOR_GREEN..'">will use up slots 4, 5 and 6!</font>',
}

-- This will contain the total number of votable options
local totalVotableOptions = 0

-- Load voting options
local votingList = LoadKeyValues('scripts/kv/voting.kv');

-- This will store the total number of choices for each option
local totalChoices = {}

-- Generate choices index
for k,v in pairs(votingList) do
    -- Count number of choices
    local total = 0
    for kk, vv in pairs(v.options) do
        total = total+1
    end

    -- Store it
    totalChoices[tonumber(k)] = total

    -- We found another option
    totalVotableOptions = totalVotableOptions+1
end

-- Ban List
local banList = LoadKeyValues('scripts/kv/bans.kv')

-- Ability stuff
local abs = LoadKeyValues('scripts/npc/npc_abilities.txt')
local absCustom = LoadKeyValues('scripts/npc/npc_abilities_custom.txt')
local skillLookupList = LoadKeyValues('scripts/kv/abilities.kv').abs
local skillLookup = {}
for k,v in pairs(skillLookupList) do
    local skillSplit = vlua.split(v, '||')

    if #skillSplit == 1 then
        skillLookup[v] = tonumber(k)
    else
        -- Store the keys
        for i=1,#skillSplit do
            skillLookup[skillSplit[i]] = -(tonumber(k)+1000*(i-1))
        end
    end
end

-- Merge custom abilities into main abiltiies file
for k,v in pairs(absCustom) do
    abs[k] = v
end

local function isUlt(skillName)
    -- Check if it is tagged as an ulty
    if abs[skillName] and abs[skillName].AbilityType and abs[skillName].AbilityType == 'DOTA_ABILITY_TYPE_ULTIMATE' then
        return true
    end

    return false
end

-- Checks to see if this is a valid skill
local function isValidSkill(skillName)
    if skillLookup[skillName] == nil then return false end

    -- For now, no validation
    return true
end

-- Returns the ID for a skill, or -1
local function getSkillID(skillName)
    -- If the skill wasn't found, return -1
    if skillLookup[skillName] == nil then return -1 end

    -- Otherwise, return the correct value
    return skillLookup[skillName]
end

-- Ensures this is a valid slot
local function isValidSlot(slotNumber)
    if slotNumber < 0 or slotNumber >= maxSlots then return false end
    return true
end

-- Checks to see if a skill is already banned
local function isSkillBanned(skillName)
    return bannedSkills[skillName] or false
end

local function banSkill(skillName)
    -- Make sure the skill isn't already banned
    if not isSkillBanned(skillName) then
        -- Store the ban
        bannedSkills[skillName] = true

        -- Fire the ban event
        FireGameEvent('lod_ban', {
            skill = skillName
        })
    end
end

local function getPlayerSlot(playerID)
    -- Grab the cmd player
    local cmdPlayer = PlayerResource:GetPlayer(playerID)
    if not cmdPlayer then return -1 end

    -- Find player slot
    local team = cmdPlayer:GetTeam()
    local playerSlot = 0
    for i=0, 9 do
        if i >= playerID then break end

        if PlayerResource:GetTeam(i) == team then
            playerSlot = playerSlot + 1
        end
    end
    if team == DOTA_TEAM_BADGUYS then
        playerSlot = playerSlot + 5
    end

    return playerSlot
end

local function sendChatMessage(playerID, msg)
    -- Fire the event
     FireGameEvent('lod_msg', {
        playerID = playerID,
        msg = msg
    })
end

local function CheckBans(skillList, slotNumber, skillName)
    -- Should we ban troll combos?
    if banTrollCombos then
        -- Loop over all the banned combinations
        for k,v in pairs(banList.BannedCombinations) do
            -- Check if this is possibly banned
            if(v['1'] == skillName or v['2'] == skillName) then
                -- Loop over all our slots
                for i=1,maxSlots do
                    -- Ignore the skill in our current slot
                    if i ~= slotNumber then
                        -- Check the banned combo
                        if v['1'] == skillName and skillList[i] == v['2'] then
                            return '<font color="'..COLOR_RED..'">'..skillName..'</font> can not be used with '..'<font color="'..COLOR_RED..'">'..v['2']..'</font>'
                        elseif v['2'] == skillName and skillList[i] == v['1'] then
                            return '<font color="'..COLOR_RED..'">'..skillName..'</font> can not be used with '..'<font color="'..COLOR_RED..'">'..v['1']..'</font>'
                        end
                    end
                end
            end
        end
    end
end

local function optionToValue(optionNumber, choice)
    local option = votingList[tostring(optionNumber)]
    if option then
        if option.values and option.values[tostring(choice)] then
            return option.values[tostring(choice)]
        end
    end

    return -1
end

-- This function tallys the votes, and sets the options
local function finishVote()
    -- Create container for all the votes
    local votes = {}
    for i=0,totalVotableOptions-1 do
        votes[i] = {}
    end

    -- Loop over all players
    for i=0,9 do
        -- Ensure this player is actually in
        if PlayerResource:IsValidPlayer(i) then
            -- Ensure they have vote data
            voteData[i] = voteData[i] or {}

            -- Loop over all options
            for j=0,totalVotableOptions-1 do
                -- Increment the vote count by 1
                votes[j][voteData[i][j] or 0] = (votes[j][voteData[i][j] or 0] or 0) + 1
            end
        end
    end

    local winners = {}

    -- For now, the winner will be the choice with the most votes (if there is a draw, the one that comes first in Lua will win)
    for i=0,totalVotableOptions-1 do
        local high = 0
        local winner = 0

        for k,v in pairs(votes[i]) do
            if v > high then
                winner = k
                high = v
            end
        end

        -- Store the winner
        winners[i] = winner
    end

    -- Set options
    maxSlots = optionToValue(1, winners[1])
    maxSkills = optionToValue(2, winners[2])
    maxUlts = optionToValue(3, winners[3])

    if winners[4] == 1 then
        -- No banning phase
        banningTime = 0
    end

    if winners[5] == 1 then
        -- No troll combos
        banTrollCombos = false
    end
end

-- This will be fired when the game starts
local function backdoorFix()
    local ents = Entities:FindAllByClassname('npc_dota_tower')

    -- List of towers to not protect
    local blocked = {
        dota_goodguys_tower1_bot = true,
        dota_goodguys_tower1_mid = true,
        dota_goodguys_tower1_top = true,
        dota_badguys_tower1_bot = true,
        dota_badguys_tower1_mid = true,
        dota_badguys_tower1_top = true
    }

    for k,ent in pairs(ents) do
        local name = ent:GetName()

        -- Should we protect it?
        if not blocked[name] then
            -- Protect it
            ent:AddNewModifier(ent, nil, 'modifier_invulnerable', {})
        end
    end

    -- Protect rax
    ents = Entities:FindAllByClassname('npc_dota_barracks')
    for k,ent in pairs(ents) do
        ent:AddNewModifier(ent, nil, 'modifier_invulnerable', {})
    end
end

local canInfo = true
local function sendPickingInfo()
    -- Stop spam of this command
    if not canInfo then return end
    canInfo = false

    -- Send out info after a short delay
    thisEntity:SetThink(function()
        -- They can ask for info again
        canInfo = true

        -- Send picking info to everyone
        FireGameEvent('lod_picking_info', {
            startTime = heroSelectionStart,
            banningTime = banningTime,
            pickingTime = pickingTime,
            slots = maxSlots,
            skills = maxSkills,
            ults = maxUlts
        })
    end, 'DelayedInfoTimer', 1, nil)
end

local canVoteInfo = true
local function sendVotingInfo()
    -- Stop spam of this command
    if not canVoteInfo then return end
    canVoteInfo = false

    -- Send out info after a short delay
    thisEntity:SetThink(function()
        -- They can ask for info again
        canVoteInfo = true

        -- Send picking info to everyone
        FireGameEvent('lod_voting_info', {
            startTime = heroSelectionStart,
            votingTime = votingTime
        })
    end, 'DelayedVoteInfoTimer', 1, nil)
end

local canState = true
local function sendStateInfo()
    -- Stop spam of this command
    if not canState then return end
    canState = false

    -- Send out info after a short delay
    thisEntity:SetThink(function()
        -- They can ask for info again
        canState = true

        -- Build the state table
        local s = {}

        -- Loop over all players
        for i=0,9 do
            -- Grab their skill list
            local l = skillList[i] or {}

            -- Loop over this player's skills
            for j=1,6 do
                -- Ensure the slot is filled
                s[tostring(i..j)] = s[tostring(i..j)] or -1

                local slot = getPlayerSlot(i)
                if slot ~= -1 then
                    -- Store the ID of this skill
                    s[tostring(slot..j)] = getSkillID(l[j])
                end
            end
        end

        local banned = {}
        for k,v in pairs(bannedSkills) do
            table.insert(banned, k)
        end

        -- Store bans
        for i=1,50 do
            s['b'..i] = getSkillID(banned[i])
        end

        -- Send picking info to everyone
        FireGameEvent('lod_state', s)
    end, 'DelayedStateTimer', 1, nil)
end

-- Run to handle
local function think()
    -- Decide what to do
    if currentStage == STAGE_WAITING then
        -- Wait for hero selection to start
        if GameRules:State_Get() >= DOTA_GAMERULES_STATE_HERO_SELECTION then
            -- Store when the hero selection started
            heroSelectionStart = GameRules:GetGameTime()

            -- Move onto the voting stage
            currentStage = STAGE_VOTING

            -- Send the voting info
            sendVotingInfo()

            -- Sleep unti the voting time is over
            return votingTime
        end

        -- Set the hero selection time
        GameRules:SetHeroSelectionTime(banningTime+pickingTime+votingTime)
        GameRules:SetSameHeroSelectionEnabled(true)

        -- Run again in a moment
        return 0.25
    end

    if currentStage == STAGE_VOTING then
        -- Workout who won
        finishVote()

        -- Move onto banning mode
        currentStage = STAGE_BANNING

        -- Send the picking info
        sendPickingInfo()

        -- Tell the users it's picking time
        if banningTime > 0 then
            sendChatMessage(-1, '<font color="'..COLOR_GREEN..'">Banning has started. You have</font> <font color="'..COLOR_RED..'">'..banningTime..' seconds</font> <font color="'..COLOR_GREEN..'">to ban upto <font color="'..COLOR_RED..'">'..maxBans..' skills</font><font color="'..COLOR_GREEN..'">. Drag and drop skills into the banning area to ban them.</font>')
        end

        -- Sleep until the banning time is up
        return banningTime
    end

    if currentStage == STAGE_BANNING then
        -- Change to picking state
        currentStage = STAGE_PICKING

        -- Tell everyone
        sendChatMessage(-1, '<font color="'..COLOR_GREEN..'">Picking has started. You have</font> <font color="'..COLOR_RED..'">'..pickingTime..' seconds</font> <font color="'..COLOR_GREEN..'">to pick your skills. Drag and drop skills into the slots to select them.</font>')

        -- Sleep until picking is over
        return pickingTime
    end

    if currentStage == STAGE_PICKING then
        -- Change to the playing stage
        currentStage = STAGE_PLAYING

        -- Stop
        return 0.1
    end

    if currentStage == STAGE_PLAYING then
        if GameRules:State_Get() == DOTA_GAMERULES_STATE_GAME_IN_PROGRESS then
            -- Fix backdoor
            backdoorFix()

            -- Finally done!
            return
        else
            -- Sleep again
            return 1
        end
    end

    -- We should never get here
    print('WARNING: Unknown stage: '+currentStage)
end

-- Stick people onto teams
local radiant = false
ListenToGameEvent('player_connect_full', function(keys)
    -- Should we auto allocate teams?
    if autoAllocateTeams then
        -- Grab the entity index of this player
        local entIndex = keys.index+1
        local ply = EntIndexToHScript(entIndex)

        -- Set their team
        if radiant then
            radiant = false
            ply:SetTeam(DOTA_TEAM_GOODGUYS)
        else
            radiant = true
            ply:SetTeam(DOTA_TEAM_BADGUYS)
        end
    end
end, nil)

-- Stick skills into slots
local handled = {}
ListenToGameEvent('npc_spawned', function(keys)
    -- Grab the unit that spawned
    local spawnedUnit = EntIndexToHScript(keys.entindex)

    -- Make sure it is a hero
    if spawnedUnit:IsHero() then
        -- Don't touch this hero more than once :O
        if handled[spawnedUnit] then return end
        handled[spawnedUnit] = true

        -- Grab their playerID
        local playerID = spawnedUnit:GetPlayerID()

        -- Don't touch bots
        if PlayerResource:IsFakeClient(playerID) then return end

        -- Grab their build
        local build = skillList[playerID] or {}

        -- Apply the build
        SkillManager:ApplyBuild(spawnedUnit, build)
    end
end, nil)

-- Abaddon ulty fix
ListenToGameEvent('entity_hurt', function(keys)
    -- Grab the entity that was hurt
    local ent = EntIndexToHScript(keys.entindex_killed)

    -- Ensure it is a valid hero
    if ent and ent:IsRealHero() then
        -- The min amount of hp
        local minHP = 400

        -- Ensure their health has dropped low enough
        if ent:GetHealth() <= minHP then
            -- Do they even have the ability in question?
            if ent:HasAbility('abaddon_borrowed_time') then
                -- Grab the ability
                local ab = ent:FindAbilityByName('abaddon_borrowed_time')

                -- Is the ability ready to use?
                if ab:IsCooldownReady() then
                    -- Grab the level
                    local lvl = ab:GetLevel()

                    -- Is the skill even skilled?
                    if lvl > 0 then
                        -- Fix their health
                        ent:SetHealth(2*minHP - ent:GetHealth())

                        -- Add the modifier
                        ent:AddNewModifier(ent, ab, 'modifier_abaddon_borrowed_time', {
                            duration = ab:GetSpecialValueFor('duration'),
                            duration_scepter = ab:GetSpecialValueFor('duration_scepter'),
                            redirect = ab:GetSpecialValueFor('redirect'),
                            redirect_range_tooltip_scepter = ab:GetSpecialValueFor('redirect_range_tooltip_scepter')
                        })

                        -- Apply the cooldown
                        if lvl == 1 then
                            ab:StartCooldown(60)
                        elseif lvl == 2 then
                            ab:StartCooldown(50)
                        else
                            ab:StartCooldown(40)
                        end
                    end
                end
            end
        end
    end
end, nil)

-- When a user tries to ban a skill
Convars:RegisterCommand('lod_ban', function(name, skillName)
    -- Grab the player
    local cmdPlayer = Convars:GetCommandClient()
    if cmdPlayer then
        local playerID = cmdPlayer:GetPlayerID()

        -- Ensure this is a valid skill
        if not isValidSkill(skillName) then
            sendChatMessage(playerID, '<font color="'..COLOR_RED..'">This doesn\'t appear to be a valid skill.</font>')
            return
        end

        -- Ensure we are in banning mode
        if currentStage ~= STAGE_BANNING then
            sendChatMessage(playerID, '<font color="'..COLOR_RED..'">You can only ban skills during the banning phase.</font>')
            return
        end

        -- Ensure they have bans left
        totalBans[playerID] = totalBans[playerID] or 0
        if totalBans[playerID] >= maxBans then
            -- Send failure message
            sendChatMessage(playerID, '<font color="'..COLOR_RED..'">You can not ban any more skills.</font>')
            -- Don't ban the skill
            return
        end

        -- Is this skill banned?
        if not isSkillBanned(skillName) then
            -- Increase the total number of bans of this person
            totalBans[playerID] = (totalBans[playerID] or 0) + 1

            -- Do the actual ban
            banSkill(skillName)

            -- Tell the user it was successful
            sendChatMessage(playerID, '<font color="'..COLOR_BLUE..'">'..skillName..'</font> was banned. <font color="'..COLOR_BLUE..'">('..totalBans[playerID]..'/'..maxBans..')</font>')
        else
            -- Already banned
            sendChatMessage(playerID, '<font color="'..COLOR_RED..'">This skill is already banned.</font>')
        end
    end
end, 'Ban a given skill', 0)

-- When a user wants to stick a skill into a slot
Convars:RegisterCommand('lod_skill', function(name, slotNumber, skillName)
    -- Grab the player
    local cmdPlayer = Convars:GetCommandClient()
    if cmdPlayer then
        local playerID = cmdPlayer:GetPlayerID()

        -- Stop people who have spawned from picking
        if handled[playerID] then
            sendChatMessage(playerID, '<font color="'..COLOR_RED..'">You have already spawned. You can no longer pick!</font>')
            return
        end

        -- Ensure we are in banning mode
        if currentStage < STAGE_PICKING then
            sendChatMessage(playerID, '<font color="'..COLOR_RED..'">You can only pick skills during the picking phase.</font>')
            return
        end

        -- Convert slot to a number
        slotNumber = tonumber(slotNumber)

        -- Ensure this is a valid slot
        if not isValidSlot(slotNumber) then
            sendChatMessage(playerID, '<font color="'..COLOR_RED..'">This is not a valid slot.</font>')
            return
        end

        -- Ensure this player has a skill list
        skillList[playerID] = skillList[playerID] or {}

        -- Ensure this is a valid skill
        if not isValidSkill(skillName) then
            -- Perhaps they tried to random?
            if skillName == 'random' then
                -- Workout if we can put an ulty here, or a skill
                local canUlt = true
                local canSkill = true

                if slotNumber < maxSlots - maxUlts then
                    canUlt = false
                end
                if slotNumber >= maxSkills then
                    canSkill = false
                end

                -- There is a chance there is no valid skill
                if not canUlt and not canSkill then
                    -- Damn scammers! No valid skills!
                    sendChatMessage(playerID, '<font color="'..COLOR_RED..'">There are no valid skills for this slot!</font>')
                    return
                end

                -- Build a list of possible skills
                local possibleSkills = {}

                for k,v in pairs(skillLookupList) do
                    if (canUlt and isUlt(v)) or (canSkill and not isUlt(v)) then
                        if not CheckBans(skillList[playerID], slotNumber+1, v) then
                            table.insert(possibleSkills, v)
                        end
                    end
                end

                -- Did we find no possible skills?
                if #possibleSkills == 0 then
                    sendChatMessage(playerID, '<font color="'..COLOR_RED..'">There are no valid skills for this slot.</font>')
                    return
                end

                -- Pick a random skill
                skillName = possibleSkills[math.random(#possibleSkills)]
            else
                sendChatMessage(playerID, '<font color="'..COLOR_RED..'">This doesn\'t appear to be a valid skill.</font>')
                return
            end
        end

        -- Is the skill banned?
        if isSkillBanned(skillName) then
            sendChatMessage(playerID, '<font color="'..COLOR_RED..'">This skill is banned.</font>')
            return
        end

        -- Ensure it isn't the same skill
        if skillList[playerID][slotNumber+1] ~= skillName then
            -- Make sure ults go into slot 3 only
            if(isUlt(skillName)) then
                if slotNumber < maxSlots - maxUlts then
                    sendChatMessage(playerID, '<font color="'..COLOR_RED..'">You can not put an ult into this slot.</font>')
                    return
                end
            else
                if slotNumber >= maxSkills then
                    sendChatMessage(playerID, '<font color="'..COLOR_RED..'">You can not put a regular skill into this slot.</font>')
                    return
                end
            end

            local msg = CheckBans(skillList[playerID], slotNumber+1, skillName)
            if msg then
                sendChatMessage(playerID, msg)
                return
            end

            -- Store this skill into the given slot
            skillList[playerID][slotNumber+1] = skillName

            -- Grab this player's playerSlot
            local playerSlot = getPlayerSlot(playerID)

            -- Tell everyone
            FireGameEvent('lod_skill', {
                playerID = playerID,
                slotNumber = slotNumber,
                skillName = skillName,
                playerSlot = playerSlot
            })

            -- Tell the player
            sendChatMessage(playerID, '<font color="'..COLOR_BLUE..'">'..skillName..'</font> was put into <font color="'..COLOR_BLUE..'">slot '..(slotNumber+1)..'</font>')

            -- Check for warnings
            if skillWarnings[skillName] then
                -- Send the warning
                sendChatMessage(playerID, skillWarnings[skillName])
            end
        end
    end
end, 'Ban a given skill', 0)

-- When a user requests the voting info
Convars:RegisterCommand('lod_voting_info', function(name)
    -- Ensure the hero selection timer isn't nil
    if heroSelectionStart ~= nil then
        -- Should we send voting info, or picking info?
        if currentStage == STAGE_VOTING then
            -- Send voting info
            sendVotingInfo()
        else
            -- Send picking info
            sendPickingInfo()
        end
    end
end, 'Send picking info out', 0)

-- When a user requests the picking info
Convars:RegisterCommand('lod_picking_info', function(name)
    -- Ensure the hero selection timer isn't nil
    if heroSelectionStart ~= nil then
        if currentStage >= STAGE_BANNING then
            sendPickingInfo()
        end
    end
end, 'Send picking info out', 0)

-- When a user requests the state info
Convars:RegisterCommand('lod_state_info', function(name)
    -- Ensure the hero selection timer isn't nil
    if heroSelectionStart ~= nil then
        if currentStage >= STAGE_BANNING then
            -- Send the state info
            sendStateInfo()
        end
    end
end, 'Send state info out', 0)

-- User is trying to update their vote
Convars:RegisterCommand('lod_vote', function(name, optNumber, theirChoice)
    -- We are only accepting numbers
    optNumber = tonumber(optNumber)
    theirChoice = tonumber(theirChoice)

    local cmdPlayer = Convars:GetCommandClient()
    if cmdPlayer then
        local playerID = cmdPlayer:GetPlayerID()

        if currentStage == STAGE_VOTING then
            if optNumber < 0 or optNumber >= totalVotableOptions then
                -- Tell the user
                sendChatMessage(playerID, '<font color="'..COLOR_RED..'">This appears to be an invalid option.</font>')
                return
            end

            -- Validate their choice
            if theirChoice < 0 or theirChoice >= totalChoices[optNumber] then
                -- Tell the user
                sendChatMessage(playerID, '<font color="'..COLOR_RED..'">This appears to be an invalid choice.</font>')
                return
            end

            -- Grab vote data
            voteData[playerID] = voteData[playerID] or {}

            -- Store vote
            voteData[playerID][optNumber] = theirChoice
        else
            -- Tell them voting is over
            sendChatMessage(playerID, '<font color="'..COLOR_RED..'">You can only vote during the voting period.</font>')
        end
    end
end, 'Update a user\'s vote', 0)

-- Setup the thinker
thisEntity:SetThink(think, 'PickingTimers', 0.25, nil)

-- Set the hero selection time
GameRules:SetHeroSelectionTime(banningTime+pickingTime+votingTime)
GameRules:SetSameHeroSelectionEnabled(true)