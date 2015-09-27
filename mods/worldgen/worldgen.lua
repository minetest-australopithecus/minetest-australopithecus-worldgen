--[[
Copyright (c) 2015, Robert 'Bobby' Zenz
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

* Redistributions of source code must retain the above copyright notice, this
  list of conditions and the following disclaimer.

* Redistributions in binary form must reproduce the above copyright notice,
  this list of conditions and the following disclaimer in the documentation
  and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
--]]


WorldGen = {}


function WorldGen:new(name, noise_manager)
	local instance = {
		initialized = false,
		modules = List:new(),
		name = name or "WorldGen",
		noise_manager = noise_manager or NoiseManager:new(),
		persistent = {},
		prototypes = List:new()
	}
	
	setmetatable(instance, self)
	self.__index = self
	
	return instance
end

function WorldGen:init()
	self.prototypes:foreach(function(prototype, index)
		log.info(self.name .. ": Initializing module \"" .. prototype.name .. "\"")
		local module = self:constructor_to_module(prototype)
		self.modules:add(module)
	end)
	
	self.initialized = true
	
	-- Destroy the prototypes so that they can be collected by the GC.
	self.prototypes = nil
end

function WorldGen:prepare_module_noises(module, minp, maxp)
	for key, value in pairs(module.noise_objects) do
		local valuemap = nil
		
		if value.type == "2D" then
			valuemap = value.map:get2dMap({
				x = minp.x,
				y = minp.z
			})
			valuemap = arrayutil.swapped_reindex2d(valuemap, minp.x, minp.z)
		elseif value.type == "3D" then
			valuemap = value.map:get3dMap({
				x = minp.x,
				y = minp.y,
				z = minp.z
			})
			valuemap = arrayutil.swapped_reindex3d(valuemap, minp.x, minp.y, minp.z)
		end
		
		module.noises[key] = valuemap
	end
end

function WorldGen:prepare_module_randoms(module, seed)
	local random_source = PcgRandom(seed)
	
	module.pcgrandom_names:foreach(function(pcgrandom_name, index)
		module.pcgrandoms[pcgrandom_name] = PcgRandom(random_source:next())
	end)
	
	module.pseudorandom_names:foreach(function(pseudorandom_name, index)
		module.pseudorandoms[pseudorandom_name] = PseudoRandom(random_source:next())
	end)
end

function WorldGen:prototype_to_module(prototype)
	local module = {
		condition = prototype.condition,
		name = constructor.name,
		nodes = {},
		noise_objects = {},
		noises = {},
		objects = {},
		params = {},
		pcgrandom_names = List:new(),
		pcgrandoms = {},
		pseudorandom_names = List:new(),
		pseudorandoms = {},
		run_2d = prototype.run_2d,
		run_3d = prototype.run_3d,
		run_after = prototype.run_after,
		run_before = prototype.run_before
	}
	
	prototype.nodes:foreach(function(node, index)
		module.nodes[node.name] = nodeutil.get_id(node.node)
		
		log.info(self.name .. ": Added node \"",
			node.node_name,
			"\" as \"",
			node.name,
			"\" with ID \"",
			module.nodes[node.name],
			"\".")
		
		if module.nodes[node.name] < 0 or module.nodes[node.name] == 127 then
			log.error(self.name .. ": Node \"" .. node.node_name .. "\" was not found.")
		end
	end)
	
	prototype.noises2d:foreach(function(noise_param, index)
		local noisemap = self.noise_manager:get_map2d(
			noise_param.octaves,
			noise_param.persistence,
			noise_param.scale,
			noise_param.spreadx,
			noise_param.spready,
			noise_param.flags
		)
		
		module.noise_objects[noise_param.name] = {
			map = noisemap,
			type = "2D"
		}
	end)
	
	prototype.noises3d:foreach(function(noise_param, index)
		local noisemap = self.noise_manager:get_map3d(
			noise_param.octaves,
			noise_param.persistence,
			noise_param.scale,
			noise_param.spreadx,
			noise_param.spready,
			noise_param.spreadz,
			noise_param.flags
		)
		
		module.noise_objects[noise_param.name] = {
			map = noisemap,
			type = "3D"
		}
	end)
	
	prototype.objects:foreach(function(object, index)
		module.objects[object.name] = object.object
	end)
	
	prototype.params:foreach(function(param, index)
		module.params[param.name] = param.value
	end)
	
	prototype.pcgrandoms:foreach(function(pcgrandom, index)
		module.pcgrandom_names:add(pcgrandom)
	end)
	
	prototype.pseudorandoms:foreach(function(pseudorandom, index)
		module.pseudorandom_names:add(pseudorandom)
	end)
	
	return module
end

function WorldGen:register(name, module)
	local prototype = nil
	
	if type(module) == "table" then
		prototype = tableutil.clone(module)
		prototype.name = name
	else
		local prototype = ModuleConstructor:new(name)
		module(prototype)
	end
	
	self.prototypes:add(prototype)
end

function WorldGen:run(map_manipulator, minp, maxp, seed)
	if not self.initialized then
		self:init()
	end
	
	log.info("")
	log.info("-------- " .. self.name .. " --------")
	log.info("From: " .. tableutil.to_string(minp, true, false))
	log.info("To: " .. tableutil.to_string(maxp, true, false))
	
	local metadata = {
		minp = minp,
		maxp = maxp,
		persistent = self.persistent
	}
	
	stopwatch.start("worldgen.modules (" .. self.name .. ")")
	
	self.modules:foreach(function(module, index)
		self:run_module(module, map_manipulator, metadata, minp, maxp, seed)
	end)
	
	log.info("--------------------------")
	stopwatch.stop("worldgen.modules (" .. self.name .. ")", "Summary")
	log.info("==========================\n")
end

function WorldGen:run_module(module, map_manipulator, metadata, minp, maxp, seed)
	stopwatch.start("worldgen.module (" .. self.name .. ")")
	
	if module.condition == nil or module.condition(module, metadata, minp, maxp) then
		self:prepare_module_noises(module, minp, maxp)
		self:prepare_module_randoms(module, seed)
		
		if module.run_before ~= nil then
			module.run_before(module, metadata, map_manipulator, minp, maxp)
		end
		
		worldgenutil.iterate3d(minp, maxp, function(x, z, y)
			if module.run_3d ~= nil then
				module.run_3d(module, metadata, map_manipulator, x, z, y)
			end
		end, nil, function(x, z)
			if module.run_2d ~= nil then
				module.run_2d(module, metadata, map_manipulator, x, z)
			end
		end)
		
		if module.run_after ~= nil then
			module.run_after(module, metadata, map_manipulator, minp, maxp)
		end
	end
	
	stopwatch.stop("worldgen.module (" .. self.name .. ")", module.name)
end

