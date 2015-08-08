local stdnse    = require "stdnse"
local shortport = require "shortport"
local tn3270    = require "tn3270"
local brute     = require "brute"
local creds     = require "creds"
local unpwdb    = require "unpwdb"

description = [[
Many mainframes use USS tables with pre programmed application macros
to allow you to connect to various applications (CICS, IMS, TSO, and many more).

This script attempts to brute force those macros.  

This script is based on mainframe_brute by Dominic White 
(https://github.com/sensepost/mainframe_brute). However, this script 
doesn't rely on any third party libraries or tools and instead uses 
the NSE TN3270 library which emulates a TN3270 screen in lua. 
]]

--@args vtam-macro-enum.idlist Path to list of transaction IDs.
--  Defaults to <code>nselib/data/usernames.lst</code>.
--@args vtam-macro-enum.commands Commands in a semi-colon seperated list needed
--  to access CICS. Defaults to <code>nothing</code>.
--@args vtam-macro-enum.path Folder used to store valid transaction id 'screenshots'
--  Defaults to <code>None</code> and doesn't store anything.
--
--@usage
-- nmap --script=vtam-enum -p 23 <targets>
--
-- nmap --script=vtam-enum --script-args=
-- vtam-macro-enum.idlist=default_cics.txt,
-- vtam-macro-enum.command="exit;logon applid(cics42)",
-- vtam-macro-enum.path="/home/dade/screenshots/",
-- vtam-macro-enum.noSSL=true -p 23 <targets>
--
--@output
-- PORT   STATE SERVICE
-- 23/tcp open  tn3270
-- | vtam-enum:
-- |   VTAM Application ID:
-- |     TSO: Valid - ID
-- |_  Statistics: Performed 6 guesses in 10 seconds, average tps: 0
--
-- @changelog
-- 2015-07-04 - v0.1 - created by Soldier of Fortran
--

author = "Soldier of Fortran"
license = "Same as Nmap--See http://nmap.org/book/man-legal.html"
categories = {"intrusive", "auth"}
dependencies = {"tn3270-info"}

portrule = shortport.port_or_service({23,992,623}, {"tn3270"})

--- Saves the Screen generated by the VTAM command to disk
--
-- @param filename string containing the name and full path to the file
-- @param data contains the data
-- @return status true on success, false on failure
-- @return err string containing error message if status is false
local function save_screens( filename, data )
	local f = io.open( filename, "w")
	if ( not(f) ) then
		return false, ("Failed to open file (%s)"):format(filename)
	end
	if ( not(f:write( data ) ) ) then
		return false, ("Failed to write file (%s)"):format(filename)
	end
	f:close()

	return true
end

--- Levenshtein Distance Calculator between screens
-- 
-- @param str1 first string
-- @param str2 second string
-- @return percantage of screen similarity
--
-- From: https://gist.github.com/Badgerati/3261142
local function levenshtein(str1, str2)
	local len1 = string.len(str1)
	local len2 = string.len(str2)
	local matrix = {}
	local cost = 0
	
        -- quick cut-offs to save time
	if (len1 == 0) then
		return len2
	elseif (len2 == 0) then
		return len1
	elseif (str1 == str2) then
		return 0
	end
	
        -- initialise the base matrix values
	for i = 0, len1, 1 do
		matrix[i] = {}
		matrix[i][0] = i
	end
	for j = 0, len2, 1 do
		matrix[0][j] = j
	end
	
        -- actual Levenshtein algorithm
	for i = 1, len1, 1 do
		for j = 1, len2, 1 do
			if (str1:byte(i) == str2:byte(j)) then
				cost = 0
			else
				cost = 1
			end
			
			matrix[i][j] = math.min(matrix[i-1][j] + 1, matrix[i][j-1] + 1, matrix[i-1][j-1] + cost)
		end
	end
	
        -- return the last value - this is the Levenshtein distance
	return ((1920 - matrix[len1][len2]) / 1920) * 100
end

-- connectionpool for future expansion
local ConnectionPool = {}

Driver = {
	new = function(self, host, port, options)
		local o = {}
		setmetatable(o, self)
		self.__index = self
		o.host = host
		o.port = port
		o.options = options
		return o
	end,
	connect = function( self )
		self.tn3270 = ConnectionPool[coroutine.running()]
		local commands = self.options['key1']
		local noSSL = self.options['key3']

		if ( self.tn3270 ) then return true end    
		self.tn3270 = Telnet:new()
		self.tn3270:disableSSL(noSSL) -- disables SSL
		local status, err = self.tn3270:initiate(self.host,self.port)
		    self.tn3270:get_screen_debug()
		if not status then
			stdnse.debug("Could not initiate TN3270: %s", err )
			return false, err
		end

		if commands ~= nil then 
			local run = stdnse.strsplit(";%s*", commands)
			for i = 1, #run do 
				stdnse.debug(1,"Issuing Command (#%s of %s) or %s", i, #run ,run[i])
				self.tn3270:send_cursor(run[i])
				self.tn3270:get_all_data()
				self.tn3270:get_screen_debug()
			end
		else
			self.tn3270:get_all_data()
			self.tn3270:get_screen_debug()
		end
		ConnectionPool[coroutine.running()] = self.tn3270
		return true
	end,
	disconnect = function( self )
		self.tn3270:disconnect()
		self.tn3270 = nil
	end,
	login = function (self, user, pass) -- pass is actually the username we want to try
		local path = self.options['key2']
		stdnse.verbose(2,"Trying VTAM ID: %s", pass)
		local previous_screen = self.tn3270:get_screen()
		stdnse.debug(2,"===== BEFORE =====")
		self.tn3270:get_screen_debug()
		self.tn3270:send_cursor(pass)
		self.tn3270:get_all_data()
		local current_screen = self.tn3270:get_screen()
		stdnse.debug(2,"===== AFTER  =====")
		
		self.tn3270:get_screen_debug()
		stdnse.debug(2,'Current Levenshtein: %s', levenshtein(previous_screen,current_screen))
		if (levenshtein(previous_screen,current_screen) >= 90 or
		    levenshtein(previous_screen,current_screen) == 0 ) then
			-- either we got 'invalid command' or we got booted
			
			-- Looks like an invalid APPLID.
			ConnectionPool[coroutine.running()] = nil
			return false,  brute.Error:new( "Invalid VTAM Application ID" ) 
		else
			ConnectionPool[coroutine.running()] = nil
			return true, creds.Account:new(string.upper(pass), " Valid", "ID")

		end

	end
}


--- Iterator function that returns lines from a file
-- @param userslist Path to file list in data location.
-- @return status false if error.
-- @return string current line.
local vtamiterator = function(list)
	local f = nmap.fetchfile(list) or list
	if not f then
		return false, ("\n ERROR: Couldn't find %s"):format(list)
	end
	f = io.open(f)
	if ( not(f) ) then
		return false, ("\n  ERROR: Failed to open %s"):format(list)
	end
	return function()
		for line in f:lines() do
		return line
    end
  end
end

-- Checks if it's a valid VTAM name
local valid_name = function(x)
  local patt = "[%w@#%$]"
  stdnse.verbose(2,"Checking: %s", x)
  return (string.len(x) <= 8 and string.match(x,patt))
end


action = function(host, port)
	local result = {}
	local status, err
	local vtam_id_file = stdnse.get_script_args(SCRIPT_NAME .. ".idlist")
		or "nselib/data/usernames.lst"
	local path = stdnse.get_script_args(SCRIPT_NAME .. 'path') -- Folder for 'screen shots'
	local commands = stdnse.get_script_args(SCRIPT_NAME .. 'command') -- Commands to send to get to VTAM
	local noSSL = stdnse.get_script_args(SCRIPT_NAME .. 'noSSL') or false
	local options = { key1 = commands, key2 = path, key3=noSSL }
 	
 	stdnse.debug("Starting USS Table Macro Enumeration")
 	local engine = brute.Engine:new(Driver, host, port, options)
 	engine.options.script_name = SCRIPT_NAME
 	local iterator, err = vtamiterator(vtam_id_file)
 	
 	if not iterator then
 		return err
 	end

 	engine:setPasswordIterator(unpwdb.filter_iterator(iterator,valid_name))
 	engine:setMaxThreads(1)
 	engine.options.passonly = true
 	engine.options:setTitle("Login Macro")
 	status, result = engine:start()


	return result


end