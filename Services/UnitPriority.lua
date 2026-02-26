local _, ns = ...

local UnitPriority = {}
ns.Services.UnitPriority = UnitPriority

function UnitPriority:Resolve(priorityList)
    for _, unit in ipairs(priorityList) do
        if UnitExists(unit) then
            return unit
        end
    end
    return nil
end

function UnitPriority:FocusOrTarget()
    return self:Resolve({ "focus", "target" })
end
