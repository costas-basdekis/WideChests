local bounding_box = require("__flib__/bounding-box")

--- @param box BoundingBox
--- @return number
function bounding_box.area(box)
	return bounding_box.width(box) * bounding_box.height(box)
end

--- @alias ChestGroup
--- | { entities: LuaEntity[], bounding_box: BoundingBox, merged_chest_name: string }

--- @param event chest_merged_event
local function raise_on_chest_merged(event)
	script.raise_event(MergingChests.on_chest_merged_event_name, event)
end

--- @param entities LuaEntity[]
--- @return { [string]: { [boolean]: LuaEntity[] } }
local function group_by_name(entities)
	local groups = { }
	for _, entity in ipairs(entities) do
		local is_ghost = entity.name == 'entity-ghost'
		local entity_name = is_ghost and entity.ghost_name or entity.name
		groups[entity_name] = groups[entity_name] or {}
		groups[entity_name][is_ghost] = groups[entity_name][is_ghost] or {}
		table.insert(groups[entity_name][is_ghost], entity)
	end
	return groups
end

--- @alias Histogram
--- | number[]
--- | { min_index: integer, max_index: integer }

--- @param histogram Histogram
--- @param is_size_allowed fun(width: integer, height: integer): boolean
--- @return integer index, integer width, integer height
local function find_largest_rectangle_under_histogram(histogram, is_size_allowed)
	local max_index = 0
	local max_width = 0
	local max_height = 0

	local stack = { }
	local top = 0
	local index = 0

	local function calculate_area_and_update()
		local peak = stack[top]
		top = top - 1

		local width = histogram[peak + histogram.min_index]
		local height = top == 0 and index or (index - stack[top] - 1)

		if width * height > max_width * max_height and is_size_allowed(width, height) then
			max_index = index + histogram.min_index - height
			max_width = width
			max_height = height
		end
	end

	while index < histogram.max_index - histogram.min_index + 1 do
		if top == 0 or histogram[stack[top] + histogram.min_index] <= histogram[index + histogram.min_index] then
			top = top + 1
			stack[top] = index
			index = index + 1
		else
			calculate_area_and_update()
		end
	end

	while top > 0 do
		calculate_area_and_update()
	end

	return max_index, max_width, max_height
end

--- @param grid Grid
--- @param is_size_allowed fun(width: integer, height: integer): boolean
--- @return BoundingBox | nil
local function find_largest_rectangle(grid, is_size_allowed)
	--- @type BoundingBox | nil
	local rectangle = nil

	--- @type Histogram
	local histogram = {
		min_index = grid.min_y,
		max_index = grid.max_y
	}
	for x = grid.min_x, grid.max_x do
		for y = grid.min_y, grid.max_y do
			if grid[x] and grid[x][y] then
				histogram[y] = (histogram[y] or 0) + 1
			else
				histogram[y] = 0
			end
		end

		local y_start, width, height = find_largest_rectangle_under_histogram(histogram, is_size_allowed)

		if width * height > (rectangle and bounding_box.area(rectangle) or 0) then
			rectangle = {
				left_top = {
					x = x - width + 1,
					y = y_start
				},
				right_bottom = {
					x = x + 1,
					y = y_start + height
				}
			}
		end
	end

	return rectangle
end

--- @param entities LuaEntity[]
--- @param entity_name string
--- @param is_ghost boolean
--- @return ChestGroup[]
local function group_chests(entities, entity_name, is_ghost)
	local chest_grid = MergingChests.entities_to_grid(entities)

	local groups = { }
	local merged = false

	repeat
		merged = false

		--- @param width integer
		--- @param height integer
		--- @return boolean
		local function is_size_allowed(width, height)
			return game.entity_prototypes[MergingChests.get_merged_chest_name(entity_name, width, height)] ~= nil
		end

		local rectangle = find_largest_rectangle(chest_grid, is_size_allowed)

		if rectangle and (bounding_box.width(rectangle) > 1 or bounding_box.height(rectangle) > 1) then
			--- @type ChestGroup
			local group = {
				entities = { },
				merged_chest_name = MergingChests.get_merged_chest_name(entity_name, bounding_box.width(rectangle), bounding_box.height(rectangle)),
				bounding_box = rectangle,
				is_ghost = is_ghost,
			}
			for x = rectangle.left_top.x, rectangle.right_bottom.x - 1 do
				for y = rectangle.left_top.y, rectangle.right_bottom.y - 1 do
					table.insert(group.entities, chest_grid[x][y])
					chest_grid[x][y] = nil
				end
			end

			table.insert(groups, group)
			merged = true
		end
	until not merged

	return groups
end

--- @param player LuaPlayer
--- @param chest_name string
--- @param position MapPosition
--- @param is_ghost boolean
--- @param bar integer
--- @return LuaEntity?
local function create_merged_chest(player, chest_name, position, is_ghost, bar)
	local entity_data = {
		position = position,
		force = player.force,
		raise_built = true,
		bar = bar
	}
	if is_ghost then
		entity_data.name = 'entity-ghost'
		entity_data.inner_name = chest_name
	else
		entity_data.name = chest_name
	end
	return player.surface.create_entity(entity_data)
end

local function break_down_merged_entities(entities)
	local split_chests = {}

	for _, chest in ipairs(entities) do
		local is_ghost = chest.name == 'entity-ghost'
		local chest_name = is_ghost and chest.ghost_name or chest.name
		local split_chest_name, width, height = MergingChests.get_merged_chest_info(chest_name)
		if split_chest_name == nil then
			split_chest_name, width, height = chest_name, 1, 1
		end
		local left_top = {
			x = chest.position.x - (width - 1) / 2,
			y = chest.position.y - (height - 1) / 2
		}
		for dX = 0, width - 1 do
			for dY = 0, height - 1 do
				local split_chest = {
					position = { x = left_top.x + dX, y = left_top.y + dY },
					is_fake = true,
					original_entity = chest,
				}
				if is_ghost then
					split_chest.name = 'entity-ghost'
					split_chest.ghost_name = split_chest_name
					split_chest.ghost_prototype = chest.ghost_prototype
				else
					split_chest.name = split_chest_name
					split_chest.prototype = chest.prototype
				end
				table.insert(split_chests, split_chest)
			end
		end
	end

	return split_chests
end

local function replace_original_entities_in_groups(chest_groups)
	for _, group in ipairs(chest_groups) do
		local original_entities = {}
		local replaced_entities = {}
		for _, entity in ipairs(group.entities) do
			if not original_entities[entity.original_entity] then
				original_entities[entity.original_entity] = true
				table.insert(replaced_entities, entity.original_entity)
			end
		end
		group.entities = replaced_entities
	end
end

local function group_original_entities_by_merge(chest_groups)
	local groups_set_by_original_entity = {}
	for _, chest_group in ipairs(chest_groups) do
		for _, entity in ipairs(chest_group.entities) do
			if not groups_set_by_original_entity[entity.original_entity] then
				groups_set_by_original_entity[entity.original_entity] = {}
			end
			groups_set_by_original_entity[entity.original_entity][chest_group] = true
		end
	end
	local groups_by_original_entity = {}
	for original_entity, groups in pairs(groups_set_by_original_entity) do
		local original_entity_groups = {}
		for group, _ in pairs(groups) do
			table.insert(original_entity_groups, group)
		end
		if #original_entity_groups > 1 then
			table.insert(groups_by_original_entity, {
				original_entity = original_entity,
				groups = original_entity_groups,
			})
		end
	end
	if #groups_by_original_entity == 0 then
		return nil
	end
	return groups_by_original_entity
end

local function merge_entities(event, chest_groups, is_ghost)
	local player = game.players[event.player_index]
	for _, chest_group_to_merge in ipairs(chest_groups) do
		if is_ghost or MergingChests.can_move_inventories(chest_group_to_merge.entities, chest_group_to_merge.merged_chest_name, bounding_box.area(chest_group_to_merge.bounding_box)) then
			local total_bar = MergingChests.get_total_bar(chest_group_to_merge.entities, is_ghost)
			local merged_chest = create_merged_chest(player, chest_group_to_merge.merged_chest_name, bounding_box.center(chest_group_to_merge.bounding_box), is_ghost, total_bar)
			if merged_chest then
				if not is_ghost then
					MergingChests.move_inventories(chest_group_to_merge.entities, { merged_chest })
				end
				MergingChests.reconnect_circuits(chest_group_to_merge.entities, { merged_chest })

				raise_on_chest_merged({
					player_index = event.player_index,
					surface = event.surface,
					merged_chest = merged_chest,
					split_chests = chest_group_to_merge.entities,
					is_ghost = is_ghost,
				})

				for _, entity in ipairs(chest_group_to_merge.entities) do
					entity.destroy({ raise_destroy = true })
				end
			end
		else
			player.create_local_flying_text({
				text = 'flying-text.'..MergingChests.prefix_with_modname('items-would-be-deleted-merge'),
				position = chest_group_to_merge.entities[1].position
			})
		end
	end
end

local function on_player_selected_area(event)
	if event.item and event.item == MergingChests.merge_selection_tool_name then
		local entity_groups = group_by_name(event.entities)
		for entity_name, group in pairs(entity_groups) do
			for is_ghost, entities in pairs(group) do
				merge_entities(event, group_chests(entities, entity_name, is_ghost), is_ghost)
			end
		end
	elseif event.item and event.item == MergingChests.merge_full_selection_tool_name then
		local player = game.players[event.player_index]
		local split_chests = break_down_merged_entities(event.entities)
		local entity_groups = group_by_name(split_chests)
		for entity_name, group in pairs(entity_groups) do
			for is_ghost, entities in pairs(group) do
				local chest_groups = group_chests(entities, entity_name, is_ghost)
				local groups_by_original_entity = group_original_entities_by_merge(chest_groups)
				if groups_by_original_entity == nil then
					replace_original_entities_in_groups(chest_groups)
					merge_entities(event, chest_groups, is_ghost)
				else
					player.create_local_flying_text({
						text = 'flying-text.'..MergingChests.prefix_with_modname('items-would-be-deleted-merge'),
						position = groups_by_original_entity[1].original_entity.position
					})
				end
			end
		end
	end
end

script.on_event(defines.events.on_player_selected_area, on_player_selected_area)
