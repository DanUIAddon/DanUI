-------------------------------------------------------------------------------
-- Premade Groups Filter
-------------------------------------------------------------------------------
-- Copyright (C) 2026 Bernhard Saumweber
--
-- This program is free software; you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation; either version 2 of the License, or
-- (at your option) any later version.
--
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.
--
-- You should have received a copy of the GNU General Public License along
-- with this program; if not, write to the Free Software Foundation, Inc.,
-- 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
-------------------------------------------------------------------------------

local PGF = select(2, ...)
local L = PGF.L
local C = PGF.C

function PGF.HandleSyntaxError(error)
    PGF.StaticPopup_Show("PGF_ERROR_EXPRESSION", string.format(L["error.syntax"], error))
end

function PGF.HandleSemanticError(error)
    if error and (error:find("name") or error:find("comment")) then
        PGF.StaticPopup_Show("PGF_ERROR_EXPRESSION", string.format(L["error.semantic.protected"], error))
    else
        PGF.StaticPopup_Show("PGF_ERROR_EXPRESSION", string.format(L["error.semantic"], error))
    end
end

-- DUI: compiled-expression cache.
--
-- The filter loop calls DoesPassThroughFilter once per search result, always
-- with the same expression string, so loadstring was compiling an identical
-- chunk for every group in the list on every refresh - a hundred compiles where
-- one would do. Cache by expression text; setfenv is still applied per result,
-- which is what actually binds the chunk to that result's values.
--
-- The cache is dropped wholesale once it grows past a sane bound, so a session
-- spent editing the advanced expression cannot accumulate chunks without limit.
local compiledCache = {}
local compiledCount = 0
local COMPILE_CACHE_MAX = 100

local function Compile(exp)
    local cached = compiledCache[exp]
    if cached then return cached.func, cached.err end

    local func, err = loadstring("return " .. exp)
    if compiledCount >= COMPILE_CACHE_MAX then
        compiledCache = {}
        compiledCount = 0
    end
    compiledCache[exp] = { func = func, err = err }
    compiledCount = compiledCount + 1
    return func, err
end

function PGF.DoesPassThroughFilter(env, exp)
    --local exp = "mythic and tansk < 0 and members==4"  -- raises semantic error
    --local exp = "and and tanks==0 and members==4"      -- raises syntax error
    --local exp = "mythic and tanks==0 and members==4"   -- correct statement
    local func, err = Compile(exp)
    if err then
        PGF.HandleSyntaxError(err)
        return true -- do not filter in case of error
    end
    setfenv(func, env)
    local status, result = pcall(func)
    if status then
        if type(result) == "boolean" then
            return result -- successful execution
        else
            PGF.HandleSemanticError("expression did not evaluate to boolean, but to '" .. tostring(result) .. "' of type " .. type(result))
            return true -- do not filter in case of error
        end
    else
        PGF.HandleSemanticError(result)
        return true -- do not filter in case of error
    end
end
