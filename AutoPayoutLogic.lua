-- AutoPayoutLogic.lua
-------------------------------------------------------------------------------
-- Ported payout engine for Dan UI.
--
-- Original logic from "Auto Payout" by Oppzippy (MIT). All Ace3 dependencies
-- have been removed: AceLocale strings are inlined, AceEvent is replaced by the
-- lightweight EventHandler below, and CallbackHandler is replaced with plain
-- callback function fields. Pure logic only - no UI lives here.
-------------------------------------------------------------------------------

---@class addon
local addon = select(2, ...)

-------------------------------------------------------------------------------
-- CSV
-------------------------------------------------------------------------------
local CSV = {}
addon.CSV = CSV

---@param t table
---@return string
function CSV.ToCSV(t)
	local csv = {}
	for i, line in ipairs(t) do
		csv[i] = table.concat(line, ",")
	end
	return table.concat(csv, "\n")
end

---@param csv string
---@return string[][]
function CSV.ToTable(csv)
	local t = {}
	for line in csv:gmatch("[^\r\n]+") do
		local row = {}
		t[#t + 1] = row

		-- Convert four+ spaces TSV to CSV
		line = line:gsub("    [ ]*", ",")

		for cell in line:gmatch("[^,\t]+") do
			row[#row + 1] = cell
		end
	end
	return t
end

-------------------------------------------------------------------------------
-- EventHandler
-- A standalone event dispatcher. Used instead of AceEvent so it does not hold
-- references to embedded tables (lets executors get garbage collected).
-------------------------------------------------------------------------------
local EventHandler = {}
addon.EventHandler = EventHandler

local eventFrame = CreateFrame("Frame")
local callbacks = {}

eventFrame:SetScript("OnEvent", function(_, event, ...)
	local eventCallbacks = callbacks[event]
	for self, callback in next, eventCallbacks do
		self[callback](self, event, ...)
	end
end)

local function RegisterEvent(self, event, callback)
	assert(type(self[callback]) == "function", "Callback function must be set")
	eventFrame:RegisterEvent(event)
	if not callbacks[event] then callbacks[event] = {} end
	callbacks[event][self] = callback
end

local function UnregisterEvent(self, event)
	local eventCallbacks = callbacks[event]
	if eventCallbacks and eventCallbacks[self] then
		eventCallbacks[self] = nil
		if not next(eventCallbacks) then
			eventFrame:UnregisterEvent(event)
			callbacks[event] = nil
		end
	end
end

local function UnregisterAllEvents(self)
	for event, _ in next, callbacks do
		UnregisterEvent(self, event)
	end
end

function EventHandler.Embed(t)
	t.RegisterEvent = function(self, event, callback)
		RegisterEvent(self, event, callback or event)
	end
	t.UnregisterEvent = function(self, event)
		UnregisterEvent(self, event)
	end
	t.UnregisterAllEvents = function(self)
		UnregisterAllEvents(self)
	end
end

-------------------------------------------------------------------------------
-- PayoutSplitter
-- Splits a single payment into multiple mails once it exceeds a gold limit.
-------------------------------------------------------------------------------
---@class PayoutSplitter
---@field splitAfterCopper number
---@field maxSplits number
local PayoutSplitterPrototype = {}
addon.PayoutSplitterPrototype = PayoutSplitterPrototype

---@param splitAfterCopper number
---@param maxSplits number
---@return PayoutSplitter
function PayoutSplitterPrototype.Create(splitAfterCopper, maxSplits)
	local splitter = setmetatable({}, { __index = PayoutSplitterPrototype })
	splitter.splitAfterCopper = splitAfterCopper
	splitter.maxSplits = maxSplits
	return splitter
end

---@param payments table
---@return table
function PayoutSplitterPrototype:SplitPayments(payments)
	local t = {}
	for _, payment in ipairs(payments) do
		local splitPaymentValues = self:SplitPayment(payment.copper)
		for _, splitPaymentValue in ipairs(splitPaymentValues) do
			local newPayment = self:ClonePayment(payment)
			newPayment.copper = splitPaymentValue
			t[#t + 1] = newPayment
		end
	end
	return t
end

---@param copper number
---@return table
function PayoutSplitterPrototype:SplitPayment(copper)
	local t = {}
	local count = 0
	while copper > 0 do
		count = count + 1
		local payoutCopper = copper
		if payoutCopper > self.splitAfterCopper and count <= self.maxSplits then
			payoutCopper = self.splitAfterCopper
		end
		copper = copper - payoutCopper
		t[#t + 1] = payoutCopper
	end
	return t
end

---@param payment table
---@return table
function PayoutSplitterPrototype:ClonePayment(payment)
	local t = {}
	for k, v in next, payment do
		t[k] = v
	end
	return t
end

-------------------------------------------------------------------------------
-- PayoutQueue
-- Parses the CSV into payments and hands them out one at a time.
-------------------------------------------------------------------------------
---@class PayoutQueue
---@field payouts table
local PayoutQueuePrototype = {}
addon.PayoutQueuePrototype = PayoutQueuePrototype

do
	local function trim(s)
		local trimmed = s:gsub("%s*(.-)%s*", "%1")
		return trimmed
	end

	function PayoutQueuePrototype.ParseCSV(csv)
		local payments = {}
		local rows = addon.CSV.ToTable(csv or "")
		for _, row in ipairs(rows) do
			local player, copperString = row[1], row[2]
			player = trim(player)
			local copper = tonumber(copperString)
			if #player > 0 then
				if not copper then
					error({ message = player .. " is not assigned a gold value" })
				elseif copper < 0 then
					error({ message = "You can not send negative gold to " .. player .. "." })
				elseif copper > 0 then
					payments[#payments + 1] = {
						copper = copper,
						player = player,
					}
				end
			end
		end
		return payments
	end
end

---@param payments table
---@param globalSubject string
---@return PayoutQueue
function PayoutQueuePrototype.Create(payments, globalSubject)
	local payoutQueue = setmetatable({}, { __index = PayoutQueuePrototype })
	payoutQueue.payouts = {}
	payoutQueue.index = 1
	if payments then
		for _, payment in ipairs(payments) do
			if globalSubject then
				payment.subject = globalSubject
			end
			payoutQueue:AddPayment(payment)
		end
	end
	return payoutQueue
end

---@param payment table
function PayoutQueuePrototype:AddPayment(payment)
	local nextIndex = #self.payouts + 1
	self.payouts[nextIndex] = {
		player = payment.player,
		copper = payment.copper,
		subject = payment.subject,
		id = nextIndex,
	}
end

---@return fun(): table?
function PayoutQueuePrototype:IteratePayouts()
	local i = 1
	return function()
		local payment = self.payouts[i]
		if payment then
			i = i + 1
			return payment
		end
	end
end

---@return table?
function PayoutQueuePrototype:Peek()
	return self.payouts[self.index]
end

---@return table
function PayoutQueuePrototype:Pop()
	local payment = self.payouts[self.index]
	self.index = self.index + 1
	return payment
end

-------------------------------------------------------------------------------
-- PayoutExecutor
-- Drives the actual mail sending, one payout at a time.
-------------------------------------------------------------------------------
local function Debug(...)
	if DanUIDB and DanUIDB.AutoPayout and DanUIDB.AutoPayout.debug then
		print("|cff77DD77DUI_AutoPayout:|r", ...)
	end
end

local function Debugf(fmt, ...)
	if DanUIDB and DanUIDB.AutoPayout and DanUIDB.AutoPayout.debug then
		print("|cff77DD77DUI_AutoPayout:|r " .. string.format(fmt, ...))
	end
end

---@class PayoutExecutor
---@field payoutQueue PayoutQueue
---@field frame Frame
---@field onMailSent? fun(payout: table)
---@field onMailFailed? fun(payout: table)
---@field onStopPayout? fun()
local PayoutExecutorPrototype = {}
addon.PayoutExecutorPrototype = PayoutExecutorPrototype

---@param payoutQueue table
---@return PayoutExecutor
function PayoutExecutorPrototype.Create(payoutQueue)
	local payoutExecutor = setmetatable({}, { __index = PayoutExecutorPrototype })
	addon.EventHandler.Embed(payoutExecutor)
	payoutExecutor.payoutQueue = payoutQueue
	payoutExecutor.frame = CreateFrame("Frame")
	payoutExecutor:RegisterEvent("MAIL_SEND_SUCCESS")
	payoutExecutor:RegisterEvent("MAIL_FAILED")
	return payoutExecutor
end

function PayoutExecutorPrototype:Start()
	self.isPayoutInProgress = true
	self:SendNext()
end

function PayoutExecutorPrototype:Destroy()
	self:Stop()
	self:UnregisterEvent("MAIL_SEND_SUCCESS")
	self:UnregisterEvent("MAIL_FAILED")
end

function PayoutExecutorPrototype:Stop()
	if self.stopTicker then return end

	self:HaltIfNotBusy()
	if self.isPayoutInProgress then
		self.stopTicker = C_Timer.NewTicker(0, function()
			self:HaltIfNotBusy()
		end)
	end
end

function PayoutExecutorPrototype:HaltIfNotBusy()
	if not C_Mail.IsCommandPending() then
		self:Halt()
	end
end

function PayoutExecutorPrototype:Halt()
	if self.isPayoutInProgress then
		self.isPayoutInProgress = false
		if self.onStopPayout then self.onStopPayout() end
		if self.stopTicker then
			self.stopTicker:Cancel()
			self.stopTicker = nil
		end
	end
end

function PayoutExecutorPrototype:GetNextMail()
	return self.payoutQueue:Peek()
end

---@param predictedMoney? number
function PayoutExecutorPrototype:SendNext(predictedMoney)
	local nextPayout = self.payoutQueue:Peek()
	if not nextPayout then self:Halt() return end
	if self:CanSend(nextPayout, predictedMoney) then
		C_Timer.After(0, function()
			SetSendMailMoney(nextPayout.copper)
			SendMail(nextPayout.player, nextPayout.subject, "")
		end)
	else
		nextPayout.isPaid = false
		if self.onMailFailed then self.onMailFailed(nextPayout) end
		self.payoutQueue:Pop()
		self:SendNext(predictedMoney)
	end
end

---@param payout table
---@param predictedMoney? number
---@return boolean
function PayoutExecutorPrototype:CanSend(payout, predictedMoney)
	if UnitIsUnit(payout.player, "player") then
		-- Can not send mail to yourself
		Debug("You can not send mail to yourself")
		return false
	end
	if payout.copper + 30 > (predictedMoney or GetMoney()) then -- 30c postage fee
		Debugf("Not enough gold: %s should get %f", payout.player, payout.copper)
		return false
	end
	return true
end

function PayoutExecutorPrototype:MAIL_SEND_SUCCESS()
	local payout = self.payoutQueue:Pop()
	payout.isPaid = true
	if self.onMailSent then self.onMailSent(payout) end
	Debugf("%s sent", payout.player)
	-- GetMoney doesnt update until another message is received from the server
	local predictedMoney = GetMoney() - payout.copper - 30
	if self.isPayoutInProgress and not self.stopTicker then
		self:SendNext(predictedMoney)
	end
end

function PayoutExecutorPrototype:MAIL_FAILED()
	local payout = self.payoutQueue:Pop()
	payout.isPaid = false
	if self.onMailFailed then self.onMailFailed(payout) end
	Debugf("Mail send to %s failed", payout.player)
	if not self.stopTicker then
		self:Halt()
	end
end
